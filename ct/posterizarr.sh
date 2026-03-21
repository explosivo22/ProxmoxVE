#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/explosivo22/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brad (custom)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/fscorrupt/Posterizarr

APP="Posterizarr"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-12}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_fuse="${var_fuse:-yes}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /opt/posterizarr_version.txt ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  RELEASE=$(get_latest_github_release "fscorrupt/Posterizarr")
  if [[ -z "${RELEASE}" || "${RELEASE}" == "null" ]]; then
    msg_error "Failed to fetch latest release tag"
    exit
  fi
  if [[ "${RELEASE}" != "$(cat /opt/posterizarr_version.txt)" ]]; then
    msg_info "Updating ${APP} to ${RELEASE}"
    systemctl stop posterizarr-backend
    rm -rf /opt/posterizarr
    $STD git clone --depth=1 --branch "${RELEASE}" \
      https://github.com/fscorrupt/Posterizarr.git /opt/posterizarr
    if [[ ! -f /opt/posterizarr/Posterizarr.ps1 ]]; then
      msg_error "Git clone failed during update"
      systemctl start posterizarr-backend
      exit
    fi
    if [[ -f /config/config.json ]]; then
      ln -sf /config/config.json /opt/posterizarr/config.json
    fi
    cd /opt/posterizarr/webui || exit
    $STD bash setup.sh || { msg_error "setup.sh failed"; exit; }
    cd /opt/posterizarr/webui/frontend || exit
    $STD npm run build || { msg_error "npm build failed"; exit; }
    echo "${RELEASE}" >/opt/posterizarr_version.txt
    systemctl start posterizarr-backend
    msg_ok "Updated ${APP} to ${RELEASE}"
  else
    msg_ok "No update required. ${APP} is already at ${RELEASE}"
  fi
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access the Posterizarr Web UI:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW} Config directory inside container: /config${CL}"
echo -e "${INFO}${YW} Assets directory inside container: /assets${CL}"
