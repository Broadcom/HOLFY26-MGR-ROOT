#!/bin/sh
# legacy - not used any more - adding no-op code to just exit
# version 1.6 23-February 2024
# restartlsmgr.sh restarts the ~core/labstartupmgr.py script if not running

exit

# if not deployed by VLP exit
orgVDC=`vmtoolsd --cmd 'info-get guestinfo.ovfenv' 2>&1 | grep vlp_org_name | cut -f 3 -d : | cut -f 2 -d \"`
if [ ! ${orgVDC} ];then
   echo "Detected dev deployment. Exiting." >> /tmp/restartlsmgr.log
   exit 0
fi

maincon="mainconsole"
while true; do
	echo "Pinging Main Console..."
	ping -c 4 $maincon > /dev/null
	if [ $? = 0 ];then
		echo "Main Console is responding"
		break
	else
		echo "Main Console is not responding. Sleeping 5 seconds..."
		sleep 5
	fi	
done
while true; do
	date=`date`
	status=`ps -ef | grep labstartupmgr.py | grep -v grep`
	if [ $? != 0 ];then
		echo "$date need to restart labstartupmgr.py" >> /tmp/restartlsmgr.log
		mv /tmp/labstartupmgr.log /tmp/labstartupmgr.log.old
		sudo -u core -b /home/core/hol/labstartupmgr.py >> /tmp/labstartupmgr.log
		chown core /tmp/labstartupmgr.log
	fi
	sleep 5
	delete=`grep delete /tmp/labstartupmgr.log`
	if [ $? = 0 ];then
		echo "$date Delete detected. Killing labstartupmgr.py" >> /tmp/restartlsmgr.log
		/usr/bin/pkill labs
		exit 0
	fi
	sleep 5
done

