#!/usr/bin/env bash

## Simplehelp Installer 2024012801 for RHEL9

# Requirements:
# RHEL9 installed

# You can define SIMPLEHELP_URL and HOST variables here or in a separate setup_simplehelp.conf file
[ -f ./setup_simplehelp.conf ] && source ./setup_simplehelp.conf
[ -z "${SIMPLEHELP_URL}" ] && (echo "SIMPLEHELP_URL not defined in ./setup_simplehelp.conf" && exit 1)
[ -z "${HOST}" ] && (echo "HOST not defined in ./setup_simplehelp.conf" && exit 1)

LOG_FILE=/root/.npf-simplehelp.log
SCRIPT_GOOD=true

function log {
    local log_line="${1}"
    local level="${2}"

    if [ "${level}" != "" ]; then
        log_line="${level}: ${log_line}"
    fi
    echo "${log_line}" >> "${LOG_FILE}"
    echo "${log_line}"

    if [ "${level}" == "ERROR" ]; then
        SCRIPT_GOOD=false
    fi
}

function log_quit {
    log "${1}" "${2}"
    exit 1
}

cd /opt
curl --output service.tar "${SIMPLEHELP_URL}" || log_quit "Cannot download service.tar"
tar -xf service.tar || log_quit "Cannot extract service.tar"
./Remote\ Access-linux64-offline /S /NAME=AUTODETECT /HOST="${HOST}"
shred -vzu service.tar Remote\ Access-linux64-offline || log "Cannot shred service.tar or Remote Access-linux64-offline" "ERROR"
# Arbitrary time to wait for Simplehelp service to start properly
sleep 10

echo "/opt/JWrapper-Remote Access" > /etc/statetab.d/simplehelp || log "Cannot create /etc/statetab.d/simplehelp" "ERROR"

# Fix for simplehelp stopping because of systemd
sed -i '/^ExecStart=.*/a RemainAfterExit=true\nRestartSec=300\nRestart=always' /etc/systemd/system/simplegateway.service 2>> "${LOG_FILE}" || log "Cannot reconfigure simplegateway.service" "ERROR"
systemctl daemon-reload 2>> "${LOG_FILE}" || log "Cannot reload systemd deamons" "ERROR"
systemctl enable simplegateway 2>> "${LOG_FILE}" || log "Cannot enable simplegateway" "ERROR"
systemctl restart simplegateway 2>> "${LOG_FILE}" || log "Cannot restart simplegateway" "ERROR"
sleep 10
echo "Is simplegateway running: "
systemctl is-active simplegateway 2>> "${LOG_FILE}" || log "Simplegateway is not running" "ERROR"

-if [ $SCRIPT_GOOD == false ]; then
    echo "#### WARNING Installation FAILED ####"
    exit 1
else
    echo "#### Installation done (check logs) ####"
    exit 0
fi