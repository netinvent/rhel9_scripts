#!/usr/bin/env bash

## Simplehelp Installer 2024012801 for RHEL9

# Requirements:
# RHEL9 installed

# You can define SIMPLEHELP_URL and HOST variables here or in a separate setup_simplehelp.conf file
[ -f ./setup_simplehelp.conf ] && source ./setup_simplehelp.conf
[ -z "${SIMPLEHELP_URL}" ] && (echo "SIMPLEHELP_URL not defined in ./setup_simplehelp.conf" && exit 1)
[ -z "${HOST}" ] && (echo "HOST not defined in ./setup_simplehelp.conf" && exit 1)

cd /opt
curl --output service.tar "${SIMPLEHELP_URL}"
tar -xf service.tar
./Remote\ Access-linux64-offline /S /NAME=AUTODETECT /HOST="${HOST}"
shred -vzu service.tar Remote\ Access-linux64-offline
# Arbitrary time to wait for Simplehelp service to start properly
sleep 10

echo "/opt/JWrapper-Remote Access" > /etc/statetab.d/simplehelp

# Fix for simplehelp stopping because of systemd
sed -i '/^ExecStart=.*/a RemainAfterExit=true\nRestartSec=300\nRestart=always' /etc/systemd/system/simplegateway.service
systemctl daemon-reload
systemctl enable simplegateway
systemctl restart simplegateway
sleep 10
echo "Is simplegateway running: "
systemctl is-active simplegateway

echo "Simplehelp support installed. Please check console"
