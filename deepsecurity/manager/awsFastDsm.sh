#!/bin/bash
dbpw='Password123!'
dsmuser=MasterAdmin
dsmpw='Password123!'
managerInstaller='https://files.trendmicro.com/products/deepsecurity/en/12.0/Manager-Linux-12.0.296.x64.sh'

download(){  
  until curl -f $@ ; 
  do
    sleep 1
  done
}
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run as root" 
   exit 1
fi


# setup dir
mkdir -p /opt/fastdsm/
cd /opt/fastdsm/

#setup repos
#curl -O https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
#yum -y install epel-release-latest-7.noarch.rpm
#yum-config-manager --add-repo https://docs.docker.com/engine/installation/linux/repo_files/centos/docker.repo
#yum makecache fast

tee /etc/yum.repos.d/docker.repo <<-EOF
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
EOF

echo "$(date) -- starting docker Install"

# get a db
echo "$(date) -- RHEL7 on EC2 is occasionally slow to get enough network to find mirrors. Let it catch up"
yum -y install docker-engine
while [ $? -ne 0 ]; do !!; done

service docker start
echo "$(date) -- creating pgsql container for dsmdb"
docker pull postgres:9
docker run --name dsmpgsqldb -p 5432:5432 -e "POSTGRES_PASSWORD=${dbpw}"  -e POSTGRES_DB=dsm -d postgres:9
echo "$(date) -- creating database in sql instance"

# persist db across restart
echo "$(date) -- creating service config to persiste db instance"
download https://s3.amazonaws.com/424d57/fastDsm/docker-dsmdb -o /etc/init.d/docker-dsmdb
chmod 755 /etc/init.d/docker-dsmdb
chkconfig --add docker-dsmdb
chkconfig docker-dsmdb on
chkconfig --add docker 
chkconfig docker on


# get ds files
echo "$(date) -- downloading manager and agent installers"
download ${managerInstaller} -o Manager-Linux.sh
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/Agent-amzn1-12.0.0-364.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/KernelSupport-amzn2-12.0.0-444.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/Agent-amzn2-12.0.0-364.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/KernelSupport-amzn1-12.0.0-458.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/Agent-RedHat_EL7-12.0.0-364.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/KernelSupport-RedHat_EL7-12.0.0-387.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/Agent-Ubuntu_18.04-12.0.0-364.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/KernelSupport-Ubuntu_18.04-12.0.0-454.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/Agent-Windows-12.0.0-360.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/Agent-RedHat_EL8-12.0.0-364.x86_64.zip"
download -O "https://files.trendmicro.com/products/deepsecurity/en/12.0/KernelSupport-RedHat_EL8-12.0.0-385.x86_64.zip"

# make a properties file
echo "$(date) -- creating dsm properties file"
echo "AddressAndPortsScreen.ManagerPort=443" >> dsm.props
echo "AddressAndPortsScreen.HeartbeatPort=4120" >> dsm.props
echo "AddressAndPortsScreen.ManagerAddress=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)" >> dsm.props
echo "CredentialsScreen.Administrator.Username=${dsmuser}" >> dsm.props
echo "CredentialsScreen.UseStrongPasswords=False" >> dsm.props
echo "CredentialsScreen.Administrator.Password=${dsmpw}" >> dsm.props
echo "SecurityUpdatesScreen.UpdateComponents=True" >> dsm.props
echo "DatabaseScreen.DatabaseType=PostgreSQL" >> dsm.props
echo "DatabaseScreen.Hostname=localhost:5432" >> dsm.props
echo "DatabaseScreen.Username=postgres" >> dsm.props
echo "DatabaseScreen.Password=${dbpw}" >> dsm.props
echo "DatabaseScreen.DatabaseName=dsm" >> dsm.props
echo "SecurityUpdateScreen.UpdateComponents=true" >> dsm.props
echo "SecurityUpdateScreen.UpdateSoftware=true" >> dsm.props
echo "SmartProtectionNetworkScreen.EnableFeedback=false" >> dsm.props
echo "SmartProtectionNetworkScreen.IndustryType=blank" >> dsm.props
echo "RelayScreen.Install=True" >> dsm.props
echo "RelayScreen.AntiMalware=True" >> dsm.props
echo "Override.Automation=True" >> dsm.props

# install manager
echo "$(date) -- installing manager"
chmod 755 Manager-Linux.sh
./Manager-Linux.sh -q -console -varfile dsm.props 
if [ $? -ne 0 ]; then 
  echo "$(date) -- manager install FAILED"
  cat /opt/fastdsm/DeepSecurityInstallerReport.csv 
  exit -1
fi
echo "$(date) -- manager install complete"
chkconfig dsm_s on

# customize dsm
yum -y install perl-XML-Twig
echo "$(date) -- starting manager customization"
curl -O https://s3.amazonaws.com/trend-micro-quick-start/v5.1/Common/Scripts/set-aia-settings.sh
chmod 755 set-aia-settings.sh
curl -O https://s3.amazonaws.com/trend-micro-quick-start/v3.7/Common/Scripts/set-lbSettings
chmod 755 set-lbSettings
curl -O https://raw.githubusercontent.com/deep-security/ops-tools/master/deepsecurity/manager-apis/bash/ds10-rest-cloudAccountCreateWithInstanceRole.sh
chmod 755 ds10-rest-cloudAccountCreateWithInstanceRole.sh
curl https://s3.amazonaws.com/trend-micro-quick-start/v5.2/Common/Scripts/dsm_s.service -o /etc/systemd/system/dsm_s.service
chmod 755 /etc/systemd/system/dsm_s.service


echo "$(date) -- waiting for manager startup to complete"
until curl -vk https://127.0.0.1:443/rest/status/manager/current/ping; do echo \"manager not started yet\" >> /tmp/4-check-service; service dsm_s start >> /tmp/4-check-service; sleep 30; done
echo "$(date) -- manager startup complete. continuing with API call customizations"
./set-aia-settings.sh ${dsmuser} ${dsmpw} localhost 443
name=$(curl http://169.254.169.254/latest/meta-data/public-hostname)
if [ -z ${name} ]; then name=$(curl http://169.254.169.254/latest/meta-data/public-ipv4); fi
./set-lbSettings ${dsmuser} ${dsmpw} ${name} 443 4120
./ds10-rest-cloudAccountCreateWithInstanceRole.sh ${dsmuser} ${dsmpw} localhost 443


echo "$(date) -- completed manager customizations"
