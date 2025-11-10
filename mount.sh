#!/bin/bash
# 05-Nov 2025
#==============================================================================
# CONFIGURATION VARIABLES
#==============================================================================

# Retry and timeout configuration (can be overridden by environment variables)
MAX_PING_ATTEMPTS=${MAX_PING_ATTEMPTS:-30}
PING_RETRY_DELAY=${PING_RETRY_DELAY:-2}
maincon="console"
LMC=false
# the password MUST be hardcoded here in order to complete the mount
password=$(cat /home/holuser/creds.txt)
# File paths
configini="/tmp/config.ini"
lmcbookmarks="holuser@${maincon}:/home/holuser/.config/gtk-3.0/bookmarks"
MOUNT_FAILURE_FILE=${MOUNT_FAILURE_FILE:-"/tmp/.mountfailed"}

# Logging function with timestamp
log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1"
}

# Create mount failure marker file
mark_mount_failed() {
    local reason=$1
    log_message "CRITICAL: Mount operation failed - ${reason}"
    cat > "${MOUNT_FAILURE_FILE}" <<EOF
Mount Failed: ${reason}
Timestamp: $(date)
Console: ${MAINCON}
LMC Mode: ${LMC}
Script: $0
EOF
    chmod 644 "${MOUNT_FAILURE_FILE}"
}

# Generic retry function with timeout
# Usage: retry_with_timeout <max_attempts> <delay> <description> <command>
retry_with_timeout() {
    local max_attempts=$1
    local delay=$2
    local description=$3
    shift 3
    local command="$4"
    local attempt=1
    
    log_message "Starting: ${description} (max attempts: ${max_attempts})"
    
    while [ $attempt -le "$max_attempts" ]; do
        log_message "Attempt ${attempt}/${max_attempts}: ${description}"
        
        if eval "$command"; then
            log_message "SUCCESS: ${description}"
            return 0
        fi
        
        if [ $attempt -lt "$max_attempts" ]; then
            log_message "FAILED: ${description}. Retrying in ${delay} seconds..."
            sleep "$delay"
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_message "ERROR: ${description} failed after ${max_attempts} attempts"
    return 1
}


clear_mount () {
   # make sure we have clean mount points
   mount | grep "${1}" > /dev/null
   if [ $? = 1 ];then   # /wmchol is not mounted
      log_message "Clearing ${1}..."
      rm -rf "${1}" > /dev/null 2>&1
      mkdir "${1}"
      chown holuser "${1}"
      chgrp holuser "${1}"
      chmod 775 "${1}"
   fi
}

secure_holuser () {
   # update the holuser sudoers for installations on the manager
   [ -f /root/holdoers ] && cp -p /root/holdoers /etc/sudoers.d/holdoers
   # change permissions so non-privileged installs are allowed
   chmod 666 /var/lib/dpkg/lock-frontend
   chmod 666 /var/lib/dpkg/lock
   if [ "${vlp_cloud}" != "NOT REPORTED" ] ;then
      log_message "PRODUCTION - SECURING HOLUSER."
      cat ~root/test2.txt | mcrypt -d -k bca -q > ~root/clear.txt
      pw=$(cat ~root/clear.txt)
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
      log_message "NORMAL HOLUSER."
      passwd holuser <<END
$password
$password
END
      if [ -f ~holuser/.ssh/unauthorized_keys ];then
         mv ~holuser/.ssh/unauthorized_keys ~holuser/.ssh/authorized_keys
      fi
   fi
}


# Ensure clean state
rm -f "${MOUNT_FAILURE_FILE}"
clear_mount /wmchol
clear_mount /lmchol
clear_mount /vpodrepo

########## Begin /vpodrepo mount handling ##########
# check for /vpodrepo mount and prepare volume if possible
mount | grep /vpodrepo > /dev/null
if [ $? = 0 ];then # mount is there now is the volume ready
   if [ -d /vpodrepo/lost+found ];then
      log_message "/vpodrepo volume is ready."
   fi
else
   log_message "/vpodrepo mount is missing."
   # attempt to mount /dev/sdb1
   if [ -b /dev/sdb1 ];then
      log_message "/dev/sdb1 is a block device file. Attempting to mount /vpodrepo..."
      mount /dev/sdb1 /vpodrepo
      if [ $? = 0 ];then
         log_message "Successful mount of /vpodrepo."
		 chown holuser /vpodrepo/* > /dev/null
		 chgrp holuser /vpodrepo/* > /dev/null
      fi
   else # now the triky part need to prepare the drive
      log_message "Preparing new volume..."
      if [ -b /dev/sdb ] && [ ! -b /dev/sdb1 ];then
         log_message "Creating new partition on external volume /dev/sdb."
         /usr/sbin/fdisk /dev/sdb <<END
n
p
1


w
quit
END
         sleep 1 # adding a sleep to let fdisk save the changes
         if [ -b /dev/sdb1 ];then
            log_message "Creating file system on /dev/sdb1"
            /usr/sbin/mke2fs -t ext4 /dev/sdb1
            log_message "Mounting /vpodrepo"
            mount /dev/sdb1 /vpodrepo
            chown holuser /vpodrepo
            chgrp holuser /vpodrepo
            chmod 775 /vpodrepo
         fi
      fi
   fi
   if [ -f /vpodrepo/lost+found ];then
      log_message "/vpodrepo mount is successful."
   fi
fi
########## End /vpodrepo mount handling ##########

########## Begin console connectivity check ##########
# Wait for console to be reachable
if ! retry_with_timeout ${MAX_PING_ATTEMPTS} ${PING_RETRY_DELAY} \
    "Ping console ${MAINCON}" \
    "ping -c 4 ${MAINCON} > /dev/null 2>&1"; then
    mark_mount_failed "Console ${MAINCON} not reachable after ${MAX_PING_ATTEMPTS} attempts"
    exit 1
fi
########## End console connectivity check ##########

########## Begin console Type check and Mount ##########
log_message "Checking for LMC at ${maincon}:2049..."
# Loop for 6 total attempts (1 initial + 5 retries)
for i in $(seq 1 6); do
   # Correctly check the exit code of nc
   if nc -z $maincon 2049; then
      log_message "LMC detected (Attempt $i/6). Performing NFS mount..."
      while [ ! -d /lmchol/home/holuser/desktop-hol ];do
         log_message "Mounting / on the LMC to /lmchol..."
         mount -t nfs -o soft,timeo=50,retrans=5,_netdev ${maincon}:/ /lmchol
         sleep 20
      done
      LMC=true
      break # Exit the loop on success
   fi

   # If this was the last attempt, don't sleep
   if [ $i -eq 6 ]; then
      break
   fi

   log_message "Attempt $i/6 failed. Retrying in 10 seconds..."
   sleep 20
done

# Only check for WMC if LMC not detected
CNT=0
while [ ! -f /wmchol/hol/LabStartup.log ] && [ $LMC = false ];do
   ((CNT++))
   if $(nc -z $maincon 445);then
      log_message "WMC detected. Performing administrative CIFS mount..."
      mount -t cifs --verbose -o rw,user=Administrator,pass="${password}",file_mode=0777,soft,dir_mode=0777,noserverino //${maincon}/C$/ /wmchol
   fi
   sleep 2
   if [ $CNT -eq 3 ]; then
      log_message "Failed to mount WMC and LMC, failing..."
      mark_mount_failed "Neither LMC (port 2049) nor WMC (port 445) detected on ${MAINCON}"
      mkdir -p /lmchol/hol
      echo "Fail to mount console... aborting labstartup..." > /lmchol/hol/startup_status.txt
      exit 1
   fi
done

########## Begin console Type check and Mount ##########

# the holuser account copies the config.ini to /tmp from 
# either the mainconsole (must wait for the mount)
# or from the vpodrepo
while [ ! -f $configini ];do
   log_message "Waiting for ${configini}..."
   sleep 3
done

# retrieve the cloud org from the vApp Guest Properties (is this prod or dev?)
# as of March 15, 2024 not getting guestinfo.ovfEnv
# vlp_cloud=`vmtoolsd --cmd 'info-get guestinfo.ovfEnv' 2>&1 | grep vlp_org_name | cut -f 3 -d : | cut -f 2 -d \"`
cloudinfo="/tmp/cloudinfo.txt"
vlp_cloud="NOT REPORTED"
while [ "${vlp_cloud}" = "NOT REPORTED" ];do
   sleep 30
   if [ -f $cloudinfo ];then
      vlp_cloud=$(cat $cloudinfo)
      log_message "vlp_cloud: $vlp_cloud"
      break
   fi
   log_message "Waiting for ${cloudinfo}..."
done

secure_holuser

# LMC-specific actions
sshoptions='-o StrictHostKeyChecking=accept-new'
if [ $LMC = true ];then
   # remove the manager bookmark from nautilus
   if [ "${vlp_cloud}" != "NOT REPORTED" ] ;then
      log_message "Removing manager bookmark from Nautilus."
      sshpass -p "${password}" scp "${sshoptions}" ${lmcbookmarks} /root/bookmarks.orig
      cat bookmarks.orig | grep -vi manager > /root/bookmarks
      sshpass -p "${password}" scp "${sshoptions}" /root/bookmarks ${lmcbookmarks}
   else
      log_message "Not removing manager bookmark from Nautilus."
   fi
fi
