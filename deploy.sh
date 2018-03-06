#!/bin/bash

nifi_version="1.4.0"

#Upgrade packages
yum update -y

echo ""
echo "RPMs up to date, formatting data disk"
sleep 3

#Format the data disk
fdisk /dev/sdc << EEOF
n
p
1
2048
536870911
w
EEOF

#Create the LVM
pvcreate /dev/sdc1
if [ "$?" != "0" ]; then
    echo "[Error] failed to create physical volume" 1>&2
    exit 1
fi
vgcreate nifivol01 /dev/sdc1
lvcreate -L 50G -n nifi_provenance nifivol01
lvcreate -L 5G -n nifi_flowfile nifivol01
lvcreate -L 25G -n nifi_logs nifivol01
lvcreate -L 50G -n zookeeper nifivol01
lvcreate --extents 100%FREE -n nifi_content nifivol01

echo ""
echo "logical volumes created"
sleep 3

#Make required filesystems
mkfs -t ext4 /dev/nifivol01/nifi_content
mkfs -t ext4 /dev/nifivol01/nifi_provenance
mkfs -t ext4 /dev/nifivol01/nifi_logs
mkfs -t ext4 /dev/nifivol01/zookeeper
mkfs -t ext4 /dev/nifivol01/nifi_flowfile

#Create the directories for mounting the filesystems
mkdir /opt/nifi
mkdir /opt/nifi/provenance_repo
mkdir /opt/nifi/flowfile_repo
mkdir /opt/nifi/content_repo
mkdir /var/log/nifi
mkdir /opt/zookeeper

#discover blockIDs for each new filesystem and modify /etc/fstab
blkID_flow=`sudo blkid -s UUID | grep nifivol01 | grep flowfile | awk '{print $2}' | grep -o '".*"' | sed 's/"//g'`
blkID_cont=`sudo blkid -s UUID | grep nifivol01 | grep content | awk '{print $2}' | grep -o '".*"' | sed 's/"//g'`
blkID_prov=`sudo blkid -s UUID | grep nifivol01 | grep provenance | awk '{print $2}' | grep -o '".*"' | sed 's/"//g'`
blkID_log=`sudo blkid -s UUID | grep nifivol01 | grep nifi_logs | awk '{print $2}' | grep -o '".*"' | sed 's/"//g'`
blkID_zk=`sudo blkid -s UUID | grep nifivol01 | grep zookeeper | awk '{print $2}' | grep -o '".*"' | sed 's/"//g'`

sudo sh -c "echo 'UUID=$blkID_flow /opt/nifi/flowfile_repo       ext4     defaults,noatime        0 0
UUID=$blkID_cont /opt/nifi/content_repo        ext4     defaults,noatime        0 0
UUID=$blkID_prov /opt/nifi/provenance_repo     ext4     defaults,noatime        0 0
UUID=$blkID_log  /var/log/nifi                 ext4     defaults,noatime        0 0
UUID=$blkID_zk   /opt/zookeeper                ext4     defaults,noatime        0 0' >> /etc/fstab"

echo ""
echo "Filesystems created, mounting"
sleep 3

mount -a

if [ "$?" != "0" ]; then
    echo "[Error] Disks not mounted" 1>&2
    exit 1
fi

#Install the latest Java
yum install -y java

#Create the nifi user and retrieve the targetted NiFi release
useradd nifi
wget -P /opt/nifi/ https://archive.apache.org/dist/nifi/$nifi_version/nifi-$nifi_version-bin.tar.gz
wget -P /opt/nifi/ https://archive.apache.org/dist/nifi/$nifi_version/nifi-toolkit-$nifi_version-bin.tar.gz
tar -xzvf /opt/nifi/nifi-$nifi_version-bin.tar.gz -C /opt/nifi

echo ""
echo "NiFi installed. configuring..."
sleep 3

#Configure nifi-current link
ln -s /opt/nifi/nifi-$nifi_version /opt/nifi/nifi-current

#Modify bootstrap.conf
sed -i 's/run.as=.*$/run.as=nifi/g' /opt/nifi/nifi-current/conf/bootstrap.conf
sed -i 's/java.arg.2=.*$/java.arg.2=-Xms4g/g' /opt/nifi/nifi-current/conf/bootstrap.conf
sed -i 's/java.arg.3=.*$/java.arg.3=-Xms4g/g' /opt/nifi/nifi-current/conf/bootstrap.conf

#modify nifi.properties
sed -i 's/nifi.flowfile.repository.directory=.*$/nifi.flowfile.repository.directory=\/opt\/nifi\/flowfile_repo/g' /opt/nifi/nifi-current/conf/nifi.properties
sed -i 's/nifi.content.repository.directory.default=.*$/nifi.content.repository.directory.default=\/opt\/nifi\/content_repo/g' /opt/nifi/nifi-current/conf/nifi.properties
sed -i 's/nifi.provenance.repository.directory.default=.*$/nifi.provenance.repository.directory.default=\/opt\/nifi\/provenance_repo/g' /opt/nifi/nifi-current/conf/nifi.properties

cd /etc/init.d
sudo /opt/nifi/nifi-current/bin/nifi.sh install
sudo ln -s /var/log/nifi /opt/nifi/nifi-current/logs
sudo chown -R nifi:nifi /opt/nifi /var/log/nifi/ /etc/init.d/nifi
chkconfig nifi on

# Add NiFi best practices
echo '* hard nofile 50000
* soft nofile 50000
* hard nproc 10000
* soft nproc 10000' >>/etc/security/limits.conf

sed -i  's/4096/10000/g' /etc/security/limits.d/20-nproc.conf

sysctl -w net.ipv4.ip_local_port_range="10000 65000"
sudo sysctl vm.swappiness=0

echo ""
echo "NiFi configured. Adding Azure best practices"
sleep 3

#Azure best practices
echo 'HOSTNAME=localhost.localdomain' >> /etc/sysconfig/network
rm -f /etc/udev/rules.d/75-persistent-net-generator.rules
ln -s /dev/null /etc/udev/rules.d/75-persistent-net-generator.rules
yum clean all
yum install python-pyasn1 WALinuxAgent
systemctl enable waagent