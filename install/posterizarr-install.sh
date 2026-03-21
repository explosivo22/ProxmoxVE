#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brad (custom)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/fscorrupt/Posterizarr

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ─── Dependencies ─────────────────────────────────────────────────────────────
msg_info "Installing Dependencies"
$STD apt-get install -y \
  git \
  jq \
  cron \
  python3 \
  python3-pip \
  python3-venv \
  libfuse2
msg_ok "Installed Dependencies"

# ─── ImageMagick 7 ───────────────────────────────────────────────────────────
# Debian apt ships ImageMagick 6.x; Posterizarr requires 7.x.
setup_imagemagick

# ─── PowerShell 7.x ──────────────────────────────────────────────────────────
msg_info "Installing PowerShell 7"
wget -q "https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb" \
  -O /tmp/packages-microsoft-prod.deb
$STD dpkg -i /tmp/packages-microsoft-prod.deb
$STD apt-get update
$STD apt-get install -y powershell
rm -f /tmp/packages-microsoft-prod.deb
msg_ok "Installed PowerShell $(pwsh --version)"

# ─── Node.js 20.x ────────────────────────────────────────────────────────────
NODE_VERSION="20" setup_nodejs

# ─── FanartTV PowerShell Module ───────────────────────────────────────────────
msg_info "Installing FanartTV PowerShell Module"
$STD pwsh -Command "Install-Module -Name FanartTvAPI -Force -Scope AllUsers -Repository PSGallery"
if ! pwsh -Command "Get-Module -ListAvailable -Name FanartTvAPI" &>/dev/null; then
  msg_error "FanartTvAPI module failed to install"
  exit 1
fi
msg_ok "Installed FanartTV PowerShell Module"

# Per walkthrough: create the global PS profile and add the import statement so
# FanartTvAPI is auto-loaded every time pwsh starts.
msg_info "Configuring PowerShell Global Profile"
mkdir -p /etc/powershell
PROFILE_FILE="/etc/powershell/profile.ps1"
touch "${PROFILE_FILE}"
if ! grep -q "FanartTvAPI" "${PROFILE_FILE}"; then
  echo "Import-Module FanartTvAPI -Force" >>"${PROFILE_FILE}"
fi
msg_ok "PowerShell Profile Configured"

# ─── Posterizarr (git clone) ─────────────────────────────────────────────────
msg_info "Cloning Posterizarr"
RELEASE=$(get_latest_github_release "fscorrupt/Posterizarr")
if [[ -z "${RELEASE}" || "${RELEASE}" == "null" ]]; then
  msg_error "Failed to fetch latest Posterizarr release tag"
  exit 1
fi
$STD git clone --depth=1 --branch "${RELEASE}" \
  https://github.com/fscorrupt/Posterizarr.git /opt/posterizarr
if [[ ! -f /opt/posterizarr/Posterizarr.ps1 ]]; then
  msg_error "Git clone failed — Posterizarr.ps1 not found"
  exit 1
fi
echo "${RELEASE}" >/opt/posterizarr_version.txt
msg_ok "Cloned Posterizarr ${RELEASE}"

# ─── Directory Layout ─────────────────────────────────────────────────────────
msg_info "Creating Directory Structure"
mkdir -p /config /assets /assetsbackup /manualassets

if [[ -f /opt/posterizarr/config.example.json && ! -f /config/config.json ]]; then
  cp /opt/posterizarr/config.example.json /config/config.json
  jq '.AssetPath = "/assets"' /config/config.json > /tmp/config.json && mv /tmp/config.json /config/config.json
fi
chmod 600 /config/config.json 2>/dev/null
if [[ -f /config/config.json ]]; then
  ln -sf /config/config.json /opt/posterizarr/config.json
fi
msg_ok "Directories Created"

# ─── Web UI Setup ─────────────────────────────────────────────────────────────
msg_info "Setting Up Web UI Backend (Python)"
cd /opt/posterizarr/webui || exit 1
if [[ -f setup.sh ]]; then
  $STD bash setup.sh || { msg_error "setup.sh execution failed"; exit 1; }
else
  msg_error "webui/setup.sh not found"
  exit 1
fi
msg_ok "Web UI Backend Dependencies Installed"

msg_info "Building Web UI Frontend (Node.js)"
cd /opt/posterizarr/webui/frontend || exit 1
$STD npm run build
if [[ ! -d /opt/posterizarr/webui/frontend/build && ! -d /opt/posterizarr/webui/frontend/dist ]]; then
  msg_error "Frontend build failed — no build or dist directory found"
  exit 1
fi
msg_ok "Frontend Built"

# ─── systemd Service ─────────────────────────────────────────────────────────
msg_info "Creating Service"
if [ -f /opt/posterizarr/webui/backend/.venv/bin/python3 ]; then
  PYTHON_BIN="/opt/posterizarr/webui/backend/.venv/bin/python3"
elif [ -f /opt/posterizarr/webui/backend/venv/bin/python3 ]; then
  PYTHON_BIN="/opt/posterizarr/webui/backend/venv/bin/python3"
else
  PYTHON_BIN="/usr/bin/python3"
fi
cat <<EOF >/etc/systemd/system/posterizarr-backend.service
[Unit]
Description=Posterizarr Web UI Backend
Documentation=https://fscorrupt.github.io/posterizarr/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/posterizarr/webui/backend
ExecStart=${PYTHON_BIN} -m uvicorn main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=TERM=xterm
Environment=RUN_TIME=disabled
Environment=TZ=UTC

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now posterizarr-backend
msg_ok "Created Service"

# ─── First Run ────────────────────────────────────────────────────────────────
msg_info "Running Posterizarr first-time initialization"
cd /opt/posterizarr || exit 1
if ! pwsh Posterizarr.ps1 -Testing >/var/log/posterizarr-firstrun.log 2>&1; then
  msg_warn "First-run exited with errors (this may be normal without API keys configured)"
  msg_warn "Review /var/log/posterizarr-firstrun.log for details"
fi
msg_ok "First-run initialization complete"

# ─── Cron Job ─────────────────────────────────────────────────────────────────
msg_info "Installing Scheduled Cron Job"
systemctl enable -q cron
touch /var/log/posterizarr.log
echo "0 */2 * * * cd /opt/posterizarr && pwsh Posterizarr.ps1 >>/var/log/posterizarr.log 2>&1" | crontab -
msg_ok "Cron Job Installed (edit schedule with: crontab -e)"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
motd_ssh
customize
cleanup_lxc
