#!/usr/bin/env bash
#
# Automated Proxmox VE Post-Install Script (non-interactive)
# Based on post-pve-install.sh by tteck / MickLesk
# Modified for fully unattended execution with preconfigured answers
# Includes robust enterprise repo disabling logic
#
# Answers supplied by user (2025-10-20)

set -euo pipefail

# --- COLOR DEFINITIONS ---
RD="\033[01;31m"
YW="\033[33m"
GN="\033[1;92m"
CL="\033[m"
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

msg_info() { echo -ne " ${HOLD} ${YW}$1..."; }
msg_ok()   { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error(){ echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }

header_info() {
  clear
  cat <<'EOF'
    ____ _    ________   ____             __     ____           __        ____
   / __ \ |  / / ____/  / __ \____  _____/ /_   /  _/___  _____/ /_____ _/ / /
  / /_/ / | / / __/    / /_/ / __ \/ ___/ __/   / // __ \/ ___/ __/ __ `/ / /
 / ____/| |/ / /___   / ____/ /_/ (__  ) /_   _/ // / / (__  ) /_/ /_/ / / /
/_/     |___/_____/  /_/    \____/____/\__/  /___/_/ /_/____/\__/\__,_/_/_/
EOF
}

get_pve_version() { pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}'; }
get_pve_major_minor() { IFS='.' read -r major minor _ <<<"$1"; echo "$major $minor"; }

component_exists_in_sources() {
  local component="$1"
  grep -h -E "^[^#]*Components:[^#]*\\b${component}\\b" /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -q .
}

# --- robust pve-enterprise disable ---
disable_enterprise_repo() {
  msg_info "Disabling any 'pve-enterprise' repository files (robust)"
  for f in /etc/apt/sources.list.d/*.list; do
    if grep -qi "pve-enterprise" "$f" 2>/dev/null; then
      cp "$f" "$f".bak || true
      sed -ri '/pve-enterprise/ s/^([^#])/# \\1/' "$f" || true
      msg_ok "Commented enterprise lines in $f"
    fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qi "pve-enterprise" "$f" 2>/dev/null; then
      cp "$f" "$f".bak || true
      awk -v RS="" -v ORS="\n\n" '{block=$0; if (block ~ /[Cc]omponents:[[:space:]]*.*pve-enterprise/) {gsub(/^/, "# ", block)}; printf "%s", block}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      msg_ok "Commented enterprise stanza(s) in $f"
    fi
  done
  for f in /etc/apt/sources.list.d/*pve-enterprise* 2>/dev/null; do
    [ -e "$f" ] || continue
    mv "$f" "$f".disabled || true
    msg_ok "Renamed $f -> $f.disabled"
  done
  msg_ok "All enterprise repositories disabled"
}

run_post_common() {
  msg_info "Disabling subscription nag"
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
  sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi
EOF
  chmod 755 /usr/local/bin/pve-remove-nag.sh
  echo 'DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };' >/etc/apt/apt.conf.d/no-nag-script
  chmod 644 /etc/apt/apt.conf.d/no-nag-script
  msg_ok "Subscription nag disabled"

  msg_info "Enabling High Availability"
  systemctl enable -q --now pve-ha-lrm pve-ha-crm corosync || true
  msg_ok "High Availability enabled"

  msg_info "Updating Proxmox VE"
  apt update -qq && apt -y dist-upgrade -qq || msg_error "Update failed"
  msg_ok "System updated"

  msg_info "Skipping reboot (manual reboot recommended)"
  msg_ok "Post-install routines complete"
}

start_routines_8() {
  msg_info "Correcting Proxmox VE Sources"
  cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
  echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
  msg_ok "Sources corrected"

  disable_enterprise_repo

  msg_info "Enabling 'pve-no-subscription' repo"
  echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' >/etc/apt/sources.list.d/pve-install-repo.list
  msg_ok "No-subscription repo enabled"

  msg_info "Correcting Ceph package repositories"
  cat >/etc/apt/sources.list.d/ceph.list <<EOF
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
  msg_ok "Ceph repositories corrected"

  msg_info "Skipping PVETEST repository addition"
  msg_ok "PVETEST skipped"

  run_post_common
}

start_routines_9() {
  msg_info "Keeping existing sources format (no migration)"
  msg_ok "Sources unchanged"

  disable_enterprise_repo

  msg_info "Disabling 'ceph enterprise' repo"
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -q 'enterprise.proxmox.com.*ceph' "$f"; then
      cp "$f" "$f".bak
      awk -v RS="" -v ORS="\n\n" '{block=$0; if (block ~ /enterprise\.proxmox\.com.*ceph/) {gsub(/^/, "# ", block)}; printf "%s", block}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  done
  msg_ok "ceph enterprise disabled"

  msg_info "Keeping 'pve-no-subscription' repo as is"
  msg_ok "No-subscription repo kept"

  msg_info "Enabling 'pve-no-subscription' if disabled"
  for f in /etc/apt/sources.list.d/*.sources; do
    sed -i '/^#\s*Types:/,/^$/s/^#\s*//' "$f" || true
  done
  msg_ok "No-subscription ensured active"

  msg_info "Adding 'pve-no-subscription' if missing"
  if ! component_exists_in_sources "pve-no-subscription"; then
    cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  fi
  msg_ok "No-subscription repo present"

  msg_info "Skipping Ceph and PVETEST repo additions"
  msg_ok "Skipped optional repos"

  run_post_common
}

main() {
  header_info
  echo -e "\nRunning automated Proxmox VE Post-Install Script...\n"

  PVE_VERSION=$(get_pve_version)
  read -r MAJ MIN <<<"$(get_pve_major_minor "$PVE_VERSION")"

  if [[ "$MAJ" == "8" ]]; then
    start_routines_8
  elif [[ "$MAJ" == "9" ]]; then
    start_routines_9
  else
    msg_error "Unsupported Proxmox version: $PVE_VERSION"
    exit 1
  fi
}

main
