#!/usr/bin/env bash
set -e

apt-get update
apt-get install -y ansible
ANSIBLE_FORCE_COLOR=1 PYTHONUNBUFFERED=1 ansible-playbook /root/ha_fbx.yml

ARCH=$(uname -m)
DOCKER_BINARY=/usr/bin/docker
DOCKER_REPO=homeassistant
DOCKER_SERVICE=docker.service
URL_VERSION="https://version.home-assistant.io/stable.json"
URL_BIN_HASSIO="https://raw.githubusercontent.com/home-assistant/hassio-installer/master/files/hassio-supervisor"
URL_BIN_APPARMOR="https://raw.githubusercontent.com/home-assistant/hassio-installer/master/files/hassio-apparmor"
URL_SERVICE_HASSIO="https://raw.githubusercontent.com/home-assistant/hassio-installer/master/files/hassio-supervisor.service"
URL_SERVICE_APPARMOR="https://raw.githubusercontent.com/home-assistant/hassio-installer/master/files/hassio-apparmor.service"
URL_APPARMOR_PROFILE="https://version.home-assistant.io/apparmor.txt"

# Check env
command -v systemctl > /dev/null 2>&1 || { echo "[Error] Only systemd is supported!"; exit 1; }
command -v docker > /dev/null 2>&1 || { echo "[Error] Please install docker first"; exit 1; }
command -v jq > /dev/null 2>&1 || { echo "[Error] Please install jq first"; exit 1; }
command -v curl > /dev/null 2>&1 || { echo "[Error] Please install curl first"; exit 1; }
command -v avahi-daemon > /dev/null 2>&1 || { echo "[Error] Please install avahi first"; exit 1; }
command -v dbus-daemon > /dev/null 2>&1 || { echo "[Error] Please install dbus first"; exit 1; }
command -v nmcli > /dev/null 2>&1 || echo "[Warning] No NetworkManager support on host."
command -v apparmor_parser > /dev/null 2>&1 || echo "[Warning] No AppArmor support on host."

# Check if Modem Manager is enabled
if systemctl list-unit-files ModemManager.service | grep enabled; then
    echo "[Warning] ModemManager service is enabled. This might cause issue when using serial devices."
fi

# Detect if running on snapped docker
if snap list docker >/dev/null 2>&1; then
    DOCKER_BINARY=/snap/bin/docker
    DATA_SHARE=/root/snap/docker/common/hassio
    CONFIG=$DATA_SHARE/hassio.json
    DOCKER_SERVICE="snap.docker.dockerd.service"
fi

PREFIX=${PREFIX:-/usr}
SYSCONFDIR=${SYSCONFDIR:-/etc}
DATA_SHARE=${DATA_SHARE:-$PREFIX/share/hassio}
CONFIG=$SYSCONFDIR/hassio.json

HOMEASSISTANT_DOCKER="$DOCKER_REPO/aarch64-homeassistant"
HASSIO_DOCKER="$DOCKER_REPO/aarch64-hassio-supervisor"

### Main

# Init folders
if [ ! -d "$DATA_SHARE" ]; then
    mkdir -p "$DATA_SHARE"
fi

# Read infos from web
HASSIO_VERSION=$(curl -s $URL_VERSION | jq -e -r '.supervisor')

##
# Write configuration
cat > "$CONFIG" <<- EOF
{
    "supervisor": "${HASSIO_DOCKER}",
    "homeassistant": "${HOMEASSISTANT_DOCKER}",
    "data": "${DATA_SHARE}"
}
EOF

##
# Pull supervisor image
echo "[Info] Install supervisor Docker container"
docker pull "$HASSIO_DOCKER:$HASSIO_VERSION" > /dev/null
docker tag "$HASSIO_DOCKER:$HASSIO_VERSION" "$HASSIO_DOCKER:latest" > /dev/null

##
# Install Hass.io Supervisor
echo "[Info] Install supervisor startup scripts"
curl -sL ${URL_BIN_HASSIO} > "${PREFIX}"/sbin/hassio-supervisor
curl -sL ${URL_SERVICE_HASSIO} > "${SYSCONFDIR}"/systemd/system/hassio-supervisor.service

sed -i "s,%%HASSIO_CONFIG%%,${CONFIG},g" "${PREFIX}"/sbin/hassio-supervisor
sed -i -e "s,%%DOCKER_BINARY%%,${DOCKER_BINARY},g" \
       -e "s,%%DOCKER_SERVICE%%,${DOCKER_SERVICE},g" \
       -e "s,%%HASSIO_BINARY%%,${PREFIX}/sbin/hassio-supervisor,g" \
       "${SYSCONFDIR}"/systemd/system/hassio-supervisor.service

chmod a+x "${PREFIX}"/sbin/hassio-supervisor
systemctl enable hassio-supervisor.service

#
# Install Hass.io AppArmor
if command -v apparmor_parser > /dev/null 2>&1; then
    echo "[Info] Install AppArmor scripts"
    mkdir -p "${DATA_SHARE}"/apparmor
    curl -sL ${URL_BIN_APPARMOR} > "${PREFIX}"/sbin/hassio-apparmor
    curl -sL ${URL_SERVICE_APPARMOR} > "${SYSCONFDIR}"/systemd/system/hassio-apparmor.service
    curl -sL ${URL_APPARMOR_PROFILE} > "${DATA_SHARE}"/apparmor/hassio-supervisor

    sed -i "s,%%HASSIO_CONFIG%%,${CONFIG},g" "${PREFIX}"/sbin/hassio-apparmor
    sed -i -e "s,%%DOCKER_SERVICE%%,${DOCKER_SERVICE},g" \
	   -e "s,%%HASSIO_APPARMOR_BINARY%%,${PREFIX}/sbin/hassio-apparmor,g" \
	   "${SYSCONFDIR}"/systemd/system/hassio-apparmor.service

    chmod a+x "${PREFIX}"/sbin/hassio-apparmor
    systemctl enable hassio-apparmor.service
    systemctl start hassio-apparmor.service
fi

##
# Init system
echo "[Info] Run Hass.io"
systemctl start hassio-supervisor.service

exit 0