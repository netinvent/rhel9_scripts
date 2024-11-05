#!/usr/bin/env bash

# SCRIPT BUILD 2024110502

LOG_FILE=/root/.npf-postinstall.log
POST_INSTALL_SCRIPT_GOOD=true

read -r -p "UPGRADE (Y/N): " UPGRADE

if [ "${UPGRADE}" == "Y" ] || [ "${UPGRADE}" == "y" ]; then
    UPGRADE=true
else
    UPGRADE=false
    read -r -p "PROMETHEUS TENANT: " tenant
    read -r -p "PROMETHEUS TENANT API PASSWORD: " tenant_api_password
fi

export USERNAME=prometheus
export BINARY_ARCH=linux-amd64

# Path to optional config files
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function log {
    local log_line="${1}"
    local level="${2}"

    echo "${log_line}" >> "${LOG_FILE}"
    echo "${log_line}"

    if [ "${level}" == "ERROR" ]; then
        POST_INSTALL_SCRIPT_GOOD=false
    fi
}

function log_quit {
    log "${1}" "${2}"
    exit 1
}


get_latest_git_release() {
    local org="${1}"
    local repo="${2}"

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/${org}/${repo}/releases/latest" | grep "tag_name" | cut -d'"' -f4)
    if [ $? -ne 0 ] || [ -z "${LATEST_VERSION}" ]; then
        log_quit "Failed to get latest version from ${org}/${repo}" "ERROR"
    fi
    echo "${LATEST_VERSION}"
}

get_git_archive_name() {
    local org="${1}"
    local repo="${2}"
    local binary="${3}"

    ARCHIVE_NAME=$(curl -s "https://api.github.com/repos/${org}/${repo}/releases/latest"  | grep "${binary}" | grep name | cut -d'"' -f4)
    if [ $? -ne 0 ] || [ -z "${ARCHIVE_NAME}" ]; then
        log_quit "Failed to get archive name from ${org}/${repo}" "ERROR"
    fi
    echo "${ARCHIVE_NAME}"
}

get_git_download_link() {
    local org="${1}"
    local repo="${2}"
    local binary="${3}"

    DOWNLOAD_LINK=$(curl -s "https://api.github.com/repos/${org}/${repo}/releases/latest"  | grep "${binary}" | grep download | cut -d'"' -f4)

    if [ $? -ne 0 ] || [ -z "${DOWNLOAD_LINK}" ]; then
        log_quit "Failed to get download link from ${org}/${repo}" "ERROR"
    fi
    echo "${DOWNLOAD_LINK}"
}

make_dir() {
    local dir="${1}"

    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}" || log_quit "Failed to create ${dir}" "ERROR"
    fi
}

start_service() {
    local service="${1}"

    log "Checking service status for ${service}"
    if ! systemctl is-active "${service}" > /dev/null 2>&1; then
        log "${service} is currently not active, stopping it"
        systemctl daemon-reload || log "Failed to reload systemctl daemon" "ERROR"
        systemctl start "${service}" || log "Failed to stop ${service}" "ERROR"
    else
        log "${service} is currently active, no need to start it"
    fi
}

stop_service() {
    local service="${1}"

    log "Checking service status for ${service}"
    if systemctl is-active "${service}" > /dev/null 2>&1; then
        log "${service} is currently active, stopping it"
        systemctl stop "${service}" || log "Failed to stop ${service}" "ERROR"
    else
        log "${service} is currently not active, no need to stop it"
    fi
}

get_version() {
    local binary="${1}"

    version=$(${binary} --version 2>&1 | awk '{ print $2 }')
    log "Installed ${binary} version\n:${version}"
}

goto_install_dir() {
    make_dir /opt/install
    cd /opt/install || log_quit "Failed to change directory to /opt/install" "ERROR"
}

copy_binaries() {
    local prefix="${1}"
    local binaries="${2}"

    # Remove trailing slash if
    prefix=${prefix%%/}

    for binary in "${binaries[@]}"; do
        # This is a stupid fix for bash iter over empty variables
        [ -z "${binary}" ] && continue

        if [ -f "${binary}" ]; then
            old_binary="${binary}_$(date +%Y-%m-%d-%H-%M-%S).bak"
            log "Creating backup of ${binary} to ${old_binary}"
            if mv "${prefix}/${binary}" "${prefix}/${old_binary}"; then
                cp "${binary}" "${prefix}" || log "Failed to copy ${binary} to ${prefix}" "ERROR"
                chown "${USERNAME}:${USERNAME}" "${prefix}/${binary}" || log "Failed to change ownership to ${USERNAME} on binary ${prefix}/${binary}" "ERROR"
                chmod 770 "${prefix}/${binary}" || log "Failed to change permissions on binary ${prefix}/${binary}" "ERROR"
                semanage fcontext -a -t bin_t "${prefix}/${binary}" || log "Failed to set selinux context for binary ${prefix}/${binary}" "ERROR"
            else
                log "Failed to backup ${binary}" "ERROR"
            fi
        else
            log "Binary ${binary} does not exist. Skipping copy"
        fi
    done
}

conf_firewall() {
    local ports="${1}"

    for port in "${ports[@]}"; do
        [ -z "${port}" ] && continue
        firewall-cmd --add-port="${port}" --permanent || log "Cannot add ${port} exception to firewalld" "ERROR"
    done
}

copy_opt_files() {
    local opt_files="${1}"
    local target_dir="${2}"

    if [ "${UPGRADE}" == true ]; then
        log "Not copying optional files in upgrade mode"
        return
    fi

    for file in "${opt_files[@]}"; do
        [ -z "${file}" ] && continue
        if [ "${file}" == "$(basename "${file}")" ]; then
            src_file="${SCRIPT_DIR}/${file}"
        else
            src_file="${file}"
        fi
        target_file="${target_dir}/$(basename "${file}")"
        if [ -d "${target_file}" ]; then
            log "Target file ${target_file} eixsts. Skipping copy"
            continue
        fi
        cp "${src_file}" "${target_dir}" || log "Failed to copy ${file} to ${target_dir}" "ERROR"
        chown "${USERNAME}:${USERNAME}" "${target_file}" || log "Failed to change ownership of ${target_file}" "ERROR"
    done
}

enable_service() {
    local service="${1}"

    systemctl enable "${service}" || log "Failed to enable ${service}" "ERROR"
}


log "Setup pre-requisites for prometheus"
dnf install -y tar freeipmi || log "Failed to install prerequisites" "ERROR"

log "Creating prometheus user"
id -u "${USERNAME}" > /dev/null 2>&1 || useradd --no-create-home --system --shell /usr/sbin/nologin "${USERNAME}" || log "Failed to create user ${USERNAME}" "ERROR"

log "Starting prometheus install at $(date)"

## PROMETHEUS

ORG=prometheus
REPO=prometheus
BINARIES=(prometheus promtool)
FIREWALL_PORTS=(9091/tcp)
OPT_FILES=(consoles console_libraries prometheus.yml)
LAST_VERSION=$(get_latest_git_release "${ORG}" "${REPO}")
ARCHIVE_NAME=$(get_git_archive_name "${ORG}" "${REPO}" "${BINARY_ARCH}")
DOWNLOAD_LINK=$(get_git_download_link "${ORG}" "${REPO}" "${BINARY_ARCH}")

log "Installing latest ${REPO} release ${LAST_VERSION}"
goto_install_dir

curl -OL "${DOWNLOAD_LINK}" || log "Failed to download ${REPO}" "ERROR"
tar xvf "${ARCHIVE_NAME}" || log "Failed to extract ${REPO}" "ERROR"
cd "${ARCHIVE_NAME%%.tar.gz}" || log "Failed to change directory to ${REPO}" "ERROR"
if [ "${UPGRADE}" == true ]; then
    get_version "${REPO}"
    stop_service "${REPO}"
fi
copy_binaries /usr/local/bin "${BINARIES[@]}"
make_dir /etc/prometheus/conf.d
chown -R "${USERNAME}:${USERNAME}" /etc/prometheus || log "Failed to change ownership of /etc/prometheus" "ERROR"

make_dir /var/lib/prometheus
chown -R "${USERNAME}:${USERNAME}" /var/lib/prometheus || log "Failed to change ownership of /var/lib/prometheus" "ERROR"

CURRENT_IP=$(hostname -I | awk '{ print $1 }')
log "Setup ${REPO} service with default addr ${CURRENT_IP} as external url"
cat << EOF > /etc/systemd/system/${REPO}.service
[Unit]
Description=Prometheus Time Series Collection and Processing Server
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
# Change default prometheus port since that's a cockpit port
# Add default 10GB retention size, default time is 15d
ExecStart=/usr/local/bin/prometheus --config.file /etc/prometheus/prometheus.yml --storage.tsdb.path /var/lib/prometheus/ --storage.tsdb.retention.size 10GB --web.console.templates=/etc/prometheus/consoles --web.console.libraries=/etc/prometheus/console_libraries --web.listen-address=:9101 --web.external-url=http://${CURRENT_IP}:9101
Restart=always
RestartSec=120s
Nice=-16

[Install]
WantedBy=multi-user.target
EOF
[ $? -ne 0 ] && log "Failed to create ${REPO} service" "ERROR"

conf_firewall "${FIREWALL_PORTS[@]}"

get_version "${REPO}"
if [ "${UPGRADE}" == true ]; then
    start_service "${REPO}"
else
    copy_opt_files "${OPT_FILES[@]}" /etc/prometheus
    sed -i "s/### TENANT ###/${tenant}/g" /etc/prometheus/prometheus.yml || log "Failed to replace tenant in prometheus config" "ERROR"
    sed -i "s/### TENANT_API_PASSWORD ###/${tenant_api_password}/g" /etc/prometheus/prometheus.yml || log "Failed to replace tenant api password in prometheus config" "ERROR"

fi
enable_service "${REPO}"

#### IPMI EXPORTER

ORG=prometheus-community
REPO=ipmi_exporter
BINARIES=(ipmi_exporter)
FIREWALL_PORTS=(9290/tcp)
OPT_FILES=(ipmi_exporter.yml)
LAST_VERSION=$(get_latest_git_release "${ORG}" "${REPO}")
ARCHIVE_NAME=$(get_git_archive_name "${ORG}" "${REPO}" "${BINARY_ARCH}")
DOWNLOAD_LINK=$(get_git_download_link "${ORG}" "${REPO}" "${BINARY_ARCH}")

log "Installing latest ${REPO} release ${LAST_VERSION}"
goto_install_dir

curl -OL "${DOWNLOAD_LINK}" || log "Failed to download ${REPO}" "ERROR"
tar xvf "${ARCHIVE_NAME}" || log "Failed to extract ${REPO}" "ERROR"
cd "${ARCHIVE_NAME%%.tar.gz}" || log "Failed to change directory to ${REPO}" "ERROR"
if [ "${UPGRADE}" == true ]; then
    get_version "${REPO}"
    stop_service "${REPO}"
fi
copy_binaries /usr/local/bin "${BINARIES[@]}"

log "Setup ${REPO} service"
cat << "EOF" > /etc/systemd/system/${REPO}.service
[Unit]
Description=Prometheus IPMI Exporter
Documentation=https://github.com/prometheus-community/ipmi_exporter

[Service]
ExecStart=/usr/local/bin/ipmi_exporter --config.file=/etc/prometheus/ipmi_exporter.yml
#User=prometheus
Restart=always

[Install]
WantedBy=multi-user.target
EOF
[ $? -ne 0 ] && log "Failed to create ${REPO} service" "ERROR"
conf_firewall "${FIREWALL_PORTS[@]}"
get_version "${REPO}"
if [ "${UPGRADE}" == true ]; then
    start_service "${REPO}"
else
    copy_opt_files "${OPT_FILES[@]}" /etc/prometheus
fi
enable_service "${REPO}"


#### BLACKBOX EXPORTER

ORG=prometheus
REPO=blackbox_exporter
BINARIES=(blackbox_exporter)
FIREWALL_PORTS=()
OPT_FILES=(blackbox.yml)
LAST_VERSION=$(get_latest_git_release "${ORG}" "${REPO}")
ARCHIVE_NAME=$(get_git_archive_name "${ORG}" "${REPO}" "${BINARY_ARCH}")
DOWNLOAD_LINK=$(get_git_download_link "${ORG}" "${REPO}" "${BINARY_ARCH}")


log "Installing latest ${REPO} release ${LAST_VERSION}"
goto_install_dir

curl -OL "${DOWNLOAD_LINK}" || log "Failed to download ${REPO}" "ERROR"
tar xvf "${ARCHIVE_NAME}" || log "Failed to extract ${REPO}" "ERROR"
cd "${ARCHIVE_NAME%%.tar.gz}" || log "Failed to change directory to ${REPO}" "ERROR"
if [ "${UPGRADE}" == true ]; then
    get_version "${REPO}"
    stop_service "${REPO}"
fi
copy_binaries /usr/local/bin "${BINARIES[@]}"

log "Setup ${REPO} service"
cat << "EOF" > /etc/systemd/system/${REPO}.service
[Unit]
Description=Blackbox Exporter
After=network-online.target

# This assumes you are running blackbox_exporter under the user "prometheus"

[Service]
User=prometheus
Restart=on-failure
ExecStart=/usr/local/bin/blackbox_exporter --config.file='/etc/prometheus/blackbox.yml'
Restart=always
RestartSec=60s
Nice=-18

[Install]
WantedBy=multi-user.target
EOF
[ $? -ne 0 ] && log "Failed to create ${REPO} service" "ERROR"

conf_firewall "${FIREWALL_PORTS[@]}"
copy_opt_files "${OPT_FILES[@]}" /etc/prometheus
get_version "${REPO}"
if [ "${UPGRADE}" == true ]; then
    start_service "${REPO}"
else
    copy_opt_files "${OPT_FILES[@]}" /etc/prometheus
fi
enable_service "${REPO}"

#### SNMP EXPORTER

ORG=prometheus
REPO=snmp_exporter
BINARIES=(snmp_exporter)
FIREWALL_PORTS=()

LAST_VERSION=$(get_latest_git_release "${ORG}" "${REPO}")
ARCHIVE_NAME=$(get_git_archive_name "${ORG}" "${REPO}" "${BINARY_ARCH}")
DOWNLOAD_LINK=$(get_git_download_link "${ORG}" "${REPO}" "${BINARY_ARCH}")

OPT_FILES=("/opt/install/${ARCHIVE_NAME%%.tar.gz}/snmp.yml")

log "Installing latest ${REPO} release ${LAST_VERSION}"
goto_install_dir

curl -OL "${DOWNLOAD_LINK}" || log "Failed to download ${REPO}" "ERROR"
tar xvf "${ARCHIVE_NAME}" || log "Failed to extract ${REPO}" "ERROR"
cd "${ARCHIVE_NAME%%.tar.gz}" || log "Failed to change directory to ${REPO}" "ERROR"
if [ "${UPGRADE}" == true ]; then
    get_version "${REPO}"
    stop_service "${REPO}"
fi
copy_binaries /usr/local/bin "${BINARIES[@]}"

log "Setup ${REPO} service"
cat << "EOF" > /etc/systemd/system/${REPO}.service
[Unit]
Description=SNMP Exporter
After=network-online.target

# This assumes you are running snmp_exporter under the user "prometheus"

[Service]
User=prometheus
Restart=on-failure
ExecStart=/usr/local/bin/snmp_exporter --config.file=/etc/prometheus/snmp.yml

[Install]
WantedBy=multi-user.target
EOF
[ $? -ne 0 ] && log "Failed to create ${REPO} service" "ERROR"

conf_firewall "${FIREWALL_PORTS[@]}"
copy_opt_files "${OPT_FILES[@]}" /etc/prometheus
get_version "${REPO}"
if [ "${UPGRADE}" == true ]; then
    start_service "${REPO}"
else
    copy_opt_files "${OPT_FILES[@]}" /etc/prometheus
fi
enable_service "${REPO}"

if [ ${POST_INSTALL_SCRIPT_GOOD} == true ]; then
    log "Prometheus setup completed successfully"
else
    log "Prometheus setup completed with errors" "ERROR"
fi