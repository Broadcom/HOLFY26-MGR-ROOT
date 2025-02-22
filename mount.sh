#!/bin/sh
# 18-February 2025

clear_mount () {
   # make sure we have clean mount points
   mount | grep ${1} > /dev/null
   if [ $? = 1 ];then   # /wmchol is not mounted
      echo "Clearing ${1}..."
      rm -rf ${1} > /dev/null 2>&1
      mkdir ${1}
      chown holuser ${1}
      chgrp holuser ${1}
      chmod 775 ${1}
fi
}

secure_holuser () {
  if [ "${vlp_cloud}" != "NOT REPORTED" ] ;then
    echo "PRODUCTION - SECURING HOLUSER."
    cat ~root/test2.txt | mcrypt -d -k bca -q > ~root/clear.txt
    pw=`cat ~root/clear.txt`
    passwd holuser <<END
$pw
$pw
END
    rm -f ~root/clear.txt
    if [ -f ~holuser/.ssh/authorized_keys ];then
       mv ~holuser/.ssh/authorized_keys ~holuser/.ssh/unauthorized_keys
    fi
    # secure the router
    /usr/bin/sshpass -p $pw ssh -o StrictHostKeyChecking=accept-new root@router "rm /root/.ssh/authorized_keys"
 else
   echo "NORMAL HOLUSER."
     passwd holuser <<END
$password
$password
END
  if [ -f ~holuser/.ssh/unauthorized_keys ];then
    mv ~holuser/.ssh/unauthorized_keys ~holuser/.ssh/authorized_keys
  fi
 fi
}


maincon="console"
# the password MUST be hardcoded here in order to complete the mount
password="VMware123!"
configini="/tmp/config.ini"
LMC=false
lmcbookmarks="holuser@mainconsole:/home/holuser/.config/gtk-3.0/bookmarks"

clear_mount /wmchol
clear_mount /lmchol
clear_mount /vpodrepo

# check for /vpodrepo mount and prepare volume if possible
mount | grep /vpodrepo > /dev/null
if [ $? = 0 ];then # mount is there now is the volume ready
   if [ -d /vpodrepo/lost+found ];then
      echo "/vpodrepo volume is ready."
   fi
else
   echo "/vpodrepo mount is missing."
   # attempt to mount /dev/sdb1
   if [ -b /dev/sdb1 ];then
      echo "/dev/sdb1 is a block device file. Attempting to mount /vpodrepo..."
      mount /dev/sdb1 /vpodrepo
      if [ $? = 0 ];then
         echo "Successful mount of /vpodrepo."
		 chown holuser /vpodrepo/* > /dev/null
		 chgrp holuser /vpodrepo/* > /dev/null
      fi
   else # now the triky part need to prepare the drive
      echo "Preparing new volume..."
      if [ -b /dev/sdb ] && [ ! -b /dev/sdb1 ];then
         echo "Creating new partition on external volume /dev/sdb."
         /usr/sbin/fdisk /dev/sdb <<END
n
p
1


w
quit
END
         sleep 1 # adding a sleep to let fdisk save the changes
         if [ -b /dev/sdb1 ];then
            echo "Creating file system on /dev/sdb1"
            /usr/sbin/mke2fs -t ext4 /dev/sdb1
            echo "Mounting /vpodrepo"
            mount /dev/sdb1 /vpodrepo
            chown holuser /vpodrepo
            chgrp holuser /vpodrepo
            chmod 775 /vpodrepo
         fi
      fi
   fi
   if [ -f /vpodrepo/lost+found ];then
      echo "/vpodrepo mount is successful."
   fi
fi

while true;do
   ping -c 4 $maincon > /dev/null
   if [ $? = 0 ];then
      echo "Console is responsive. Performing remote mount..."
      break
   else
      echo "Cannot reach Console. Will try again."
   fi
   sleep 2
done

if `nc -z $maincon 2049`;then
   echo "LMC detected. Performing NFS mount..."
   while [ ! -d /lmchol/home/holuser/desktop-hol ];do
      echo "Mounting / on the LMC to /lmchol..."
      mount -t nfs -o soft,timeo=50,retrans=5,_netdev ${maincon}:/ /lmchol
      sleep 2
   done
   LMC=true
fi

while [ ! -f /wmchol/hol/LabStartup.log ] && [ $LMC = false ];do
   if `nc -z $maincon 445`;then
      echo "WMC detected. Performing administrative CIFS mount..."
      mount -t cifs --verbose -o rw,user=Administrator,pass=${password},file_mode=0777,soft,dir_mode=0777,noserverino //${maincon}/C$/ /wmchol
   fi
   sleep 2
done

# the holuser account copies the config.ini from the mainconsole (must wait for the mount)
while [ ! -f $configini ];do
   echo "Waiting for ${configini}..."
   sleep 3
done

# retrieve the cloud org from the vApp Guest Properties (is this prod or dev?)
# as of March 15, 2024 not getting guestinfo.ovfEnv
# vlp_cloud=`vmtoolsd --cmd 'info-get guestinfo.ovfEnv' 2>&1 | grep vlp_org_name | cut -f 3 -d : | cut -f 2 -d \"`
cloudinfo="/tmp/cloudinfo.txt"
vlp_cloud="NOT REPORTED"
while [ "${vlp_cloud}" = "NOT REPORTED" ];do
   sleep 5
   if [ -f $cloudinfo ];then
      vlp_cloud=`cat $cloudinfo`
      echo "vlp_cloud: $vlp_cloud"
      break
   fi
   echo "Waiting for ${cloudinfo}..."
done

secure_holuser

# LMC-specific actions
sshoptions='-o StrictHostKeyChecking=accept-new'
if [ $LMC = true ];then
   # remove the manager bookmark from nautilus
   if [ "${vlp_cloud}" != "NOT REPORTED" ] ;then
      echo "Removing manager bookmark from Nautilus."
      sshpass -p ${password} scp ${sshoptions} ${lmcbookmarks} /root/bookmarks.orig
      cat bookmarks.orig | grep -vi manager > /root/bookmarks
      sshpass -p ${password} scp ${sshoptions} /root/bookmarks ${lmcbookmarks}
   else
      echo "Not removing manager bookmark from Nautilus."
   fi
fi

