#!/bin/sh

# script to prep the LMC for milestone capture

# empty the trash (happens at logout but need to clear dirty bloks
rm -rf ~holuser/.local/share/Trash/*

# remove temporary files to clear dirty blocks (don't force)
rm -r /tmp/*

# delete the known_host files that cause issues
echo "Removing known_hosts files..."
rm ~holuser/.ssh/known_hosts
rm /root/.ssh/known_hosts

# delete the PuTTY hostkeys
echo "Removing PuTTY hostkey files..."
rm ~holuser/.putty/hostkeys

# clear dirty blocks
echo "Clearing dirty blocks..."
dd if=/dev/zero of=/tmp/zeros.txt ; rm -f /tmp/zeros.txt
