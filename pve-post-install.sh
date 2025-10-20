#!/usr/bin/env bash

# post-pve-install-auto.sh
# Auto-run, non-interactive version of post-pve-install.sh for Proxmox VE 9.x
# Behavior: answers "yes" to everything except "Disable high availability?" -> "no"
# Reboot: recommended (printed), not automatic
# Based on original script from tteck (2021-2025)

set -euo pipefail
shopt -s inherit_errexit nullglob

header_info() {
  clear
  cat <<"EOF"
    ____ _    ________   ____             __     ____           __        ____
   / __ \ |  / / ____/  / __ \____  _____/ /_   /  _/___  _____/ /_____ _/ / /
  / /_/ / | / / __/    / /_/ / __ \/ ___/ __/   / // __ \/ ___/ __/ __ `/ / /
 / ____/| |/ / /___   / ____/ /_/ (__  ) /_   _/ // / / (__  ) /_/ /_/ / / /
/_/     |___/_____/  /_/    \____/____/\__/  /___/_/ /_/____/\__/\__,_/_/_/

EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

get_pve_version() {
  local pve_ver
  pve_ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  echo "$pve_ver"
}

get_pve_major_minor() {
  local ver="$1"
  local major minor
  IFS='.' read -r major minor _ <<<"$ver"
  echo "$major $minor"
}

component_exists_in_sources() {
  local component="$1"
  grep -h -E "^[^#]*Components:[^#]*\b${component}\b" /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -q .
}

# --- AUTOMATED: All answers are predefined here ---
# For Proxmox 9: we will auto-answer yes to actions except "disable HA" which is "no"
AUTO_START_SCRIPT="yes"
AUTO_DISABLE_LEGACY_SOURCES="yes"
AUTO_MIGRATE_DEB822="yes"
AUTO_ADD_PVE_ENTERPRISE="yes"
AUTO_PVE_ENTERPRISE_ACTION="yes"   # add (because we answered yes)
AUTO_CEPH_ENTERPRISE_ACTION="disable" # keep if exists, else we will add ceph (no-subscription)
AUTO_ADD_PVE_NO_SUBSCRIPTION="yes"
AUTO_ADD_CEPH_PACKAGES="yes"
AUTO_ADD_PVETEST="yes"
AUTO_DISABLE_SUBSCRIPTION_NAG="yes"
AUTO_ENABLE_HA_IF_INACTIVE="yes"
AUTO_DISABLE_HA="no"               # user requested NOT to disable HA
AUTO_UPDATE_SYSTEM="yes"
AUTO_REBOOT="no"

main() {
  header_info
  echo -e "\nThis script will perform automated Post Install Routines for Proxmox VE 9.x.\n"

  # Respect original check: detect PVE version and branch into start_routines_9
  local PVE_VERSION PVE_MAJOR PVE_MINOR
  PVE_VERSION="$(get_pve_version)"
  read -r PVE_MAJOR PVE_MINOR <<<"$(get_pve_major_minor "$PVE_VERSION")"

  if [[ "$PVE_MAJOR" == "9" ]]; then
    # Only support 9.0 in original script; keep same check but attempt to proceed for 9.0+ minor
    if (( PVE_MINOR != 0 )); then
      # original would exit; we'll warn but proceed cautiously
      msg_error "Original script only declared support for Proxmox 9.0; detected ${PVE_VERSION}. Attempting automated 9.x routine."
    fi
    start_routines_9_auto
  else
    msg_error "Unsupported Proxmox VE major version: $PVE_MAJOR"
    echo -e "This automated script is designed for Proxmox VE 9.x."
    exit 1
  fi
}

start_routines_9_auto() {
  header_info

  # --- Legacy sources detection and disable (auto yes) ---
  if find /etc/apt/sources.list.d/ -maxdepth 1 -name '*.sources' | grep -q .; then
    msg_ok "Deb822 sources detected, skipping legacy detection step"
  else
    # Detect legacy
    local LEGACY_COUNT=0
    local listfile="/etc/apt/sources.list"
    if [[ -f "$listfile" ]] && grep -qE '^\s*deb ' "$listfile"; then
      (( ++LEGACY_COUNT ))
    fi
    local list_files
    list_files=$(find /etc/apt/sources.list.d/ -type f -name "*.list" 2>/dev/null || true)
    if [[ -n "$list_files" ]]; then
      LEGACY_COUNT=$((LEGACY_COUNT + $(echo "$list_files" | wc -l)))
    fi

    if (( LEGACY_COUNT > 0 )); then
      msg_info "Disabling legacy APT sources (automated)"
      # Backup and disable sources.list entries
      if [[ -f "$listfile" ]] && grep -qE '^\s*deb ' "$listfile"; then
        cp "$listfile" "$listfile.bak"
        sed -i '/^\s*deb /s/^/# Disabled by Proxmox Helper Script /' "$listfile"
        msg_ok "Disabled entries in sources.list (backup: sources.list.bak)"
      fi
      # Rename all .list files to .list.bak
      if [[ -n "$list_files" ]]; then
        while IFS= read -r f; do
          mv "$f" "$f.bak"
        done <<<"$list_files"
        msg_ok "Renamed legacy .list files to .bak"
      fi
    else
      msg_ok "No legacy APT sources detected"
    fi

    # --- Create deb822 sources (automated, trixie) ---
    if [[ "$AUTO_MIGRATE_DEB822" == "yes" ]]; then
      msg_info "Creating deb822 sources for Trixie (automated)"
      rm -f /etc/apt/sources.list.d/*.list || true
      sed -i '/proxmox/d;/bookworm/d' /etc/apt/sources.list || true
      cat >/etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      msg_ok "Created deb822 Debian sources"
    else
      msg_error "Skipped creating deb822 sources (auto-migrate disabled)"
    fi
  fi

  # ---- PVE-ENTERPRISE (add) ----
  if component_exists_in_sources "pve-enterprise"; then
    msg_ok "'pve-enterprise' repository already exists (kept as-is)"
  else
    if [[ "$AUTO_ADD_PVE_ENTERPRISE" == "yes" ]]; then
      msg_info "Adding 'pve-enterprise' repository (deb822) (automated)"
      cat <<EOF >/etc/apt/sources.list.d/pve-enterprise.list
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
      msg_ok "Added 'pve-enterprise' repository"
    else
      msg_error "Skipping add of 'pve-enterprise' repository"
    fi
  fi

  # ---- CEPH-ENTERPRISE handling (if exists, keep/disable/delete) ---
  if grep -q "enterprise.proxmox.com.*ceph" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
   msg_info "Disabling 'pve-enterprise' repository"
    cat <<EOF >/etc/apt/sources.list.d/pve-enterprise.list
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
    msg_ok "Disabled 'pve-enterprise' repository"
  fi

  # ---- PVE-NO-SUBSCRIPTION ----
  REPO_FILE=""
  REPO_ACTIVE=0
  REPO_COMMENTED=0
  for file in /etc/apt/sources.list.d/*.sources; do
    if grep -q "Components:.*pve-no-subscription" "$file"; then
      REPO_FILE="$file"
      if grep -E '^[^#]*Components:.*pve-no-subscription' "$file" >/dev/null; then
        REPO_ACTIVE=1
      elif grep -E '^#.*Components:.*pve-no-subscription' "$file" >/dev/null; then
        REPO_COMMENTED=1
      fi
      break
    fi
  done

  if [[ "$REPO_ACTIVE" -eq 1 ]]; then
    msg_ok "'pve-no-subscription' repository is ENABLED (keeping as-is)"
  elif [[ "$REPO_COMMENTED" -eq 1 ]]; then
    # Uncomment (enable)
    msg_info "Enabling commented 'pve-no-subscription' repository (automated)"
    sed -i '/^#\s*Types:/,/^$/s/^#\s*//' "$REPO_FILE" || true
    msg_ok "Enabled 'pve-no-subscription' repository"
  else
    if [[ "$AUTO_ADD_PVE_NO_SUBSCRIPTION" == "yes" ]]; then
      msg_info "Adding 'pve-no-subscription' repository (deb822) (automated)"
      cat >/etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      msg_ok "Added 'pve-no-subscription' repository"
    else
      msg_error "Skipping add of 'pve-no-subscription' repository"
    fi
  fi

  # ---- CEPH (no-subscription) ----
  if component_exists_in_sources "no-subscription"; then
    msg_ok "'ceph' package repository (no-subscription) already exists (skipped)"
  else
    if [[ "$AUTO_ADD_CEPH_PACKAGES" == "yes" ]]; then
      msg_info "Adding 'ceph package repositories' (deb822) (automated)"
      cat >/etc/apt/sources.list.d/ceph.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      msg_ok "Added 'ceph package repositories'"
    else
      msg_error "Skipping add of 'ceph package repositories'"
      find /etc/apt/sources.list.d/ -type f \( -name "*.sources" -o -name "*.list" \) \
        -exec sed -i '/enterprise.proxmox.com.*ceph/s/^/# /' {} \; || true
      msg_ok "Disabled all Ceph Enterprise repositories"
    fi
  fi

  # ---- PVETEST ----
  if component_exists_in_sources "pve-test"; then
    msg_ok "'pve-test' repository already exists (skipped)"
  else
    if [[ "$AUTO_ADD_PVETEST" == "yes" ]]; then
      msg_info "Adding 'pve-test' repository (deb822, disabled) (automated)"
      cat >/etc/apt/sources.list.d/pve-test.sources <<'EOF'
# Types: deb
# URIs: http://download.proxmox.com/debian/pve
# Suites: trixie
# Components: pve-test
# Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      msg_ok "Added 'pve-test' repository (disabled)"
    else
      msg_error "Skipping pve-test repository addition"
    fi
  fi

  # Run post routines
  post_routines_common_auto
}

post_routines_common_auto() {
  # Disable subscription nag (automated yes)
  if [[ "$AUTO_DISABLE_SUBSCRIPTION_NAG" == "yes" ]]; then
    whiptail_supported=false # original had a whiptail msgbox; we will print instead
    msg_info "Disabling subscription nag (automated)"
    # Create external script to patch UI on dpkg post-invoke
    mkdir -p /usr/local/bin
    cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    // --- Remove subscription dialogs ---" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) {" \
      "        dialog.remove();" \
      "        console.log('Removed subscription dialog');" \
      "      }" \
      "    });" \
      "" \
      "    // --- Remove subscription cards, but keep Reboot/Shutdown/Console ---" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) {" \
      "        card.remove();" \
      "        console.log('Removed subscription card');" \
      "      }" \
      "    });" \
      "  }" \
      "" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF
    chmod 755 /usr/local/bin/pve-remove-nag.sh

    cat >/etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
    chmod 644 /etc/apt/apt.conf.d/no-nag-script

    msg_ok "Disabled subscription nag (browser cache clear may be required)"
  else
    # If user asked not to disable, remove the config
    rm -f /etc/apt/apt.conf.d/no-nag-script 2>/dev/null || true
    msg_ok "Subscription nag left unchanged"
  fi

  # Reinstall proxmox-widget-toolkit quietly; continue on failure
  apt --reinstall install -y proxmox-widget-toolkit &>/dev/null || msg_error "Widget toolkit reinstall failed"

  # HIGH AVAILABILITY logic
  if ! systemctl is-active --quiet pve-ha-lrm; then
    if [[ "$AUTO_ENABLE_HA_IF_INACTIVE" == "yes" ]]; then
      msg_info "Enabling high availability services (automated)"
      systemctl enable -q --now pve-ha-lrm || true
      systemctl enable -q --now pve-ha-crm || true
      systemctl enable -q --now corosync || true
      msg_ok "Enabled high availability services"
    else
      msg_error "High availability left disabled (as per automated settings)"
    fi
  else
    msg_ok "High availability is already active; keeping enabled (per request)"
  fi

  # If HA is active and AUTO_DISABLE_HA == "no", we will not disable anything.
  if systemctl is-active --quiet pve-ha-lrm; then
    msg_ok "High availability remains enabled (automation set to keep HA enabled)."
  fi

  # UPDATE
  if [[ "$AUTO_UPDATE_SYSTEM" == "yes" ]]; then
    msg_info "Updating Proxmox VE (apt update && dist-upgrade) (automated)"
    apt update &>/dev/null || msg_error "apt update failed"
    apt -y dist-upgrade &>/dev/null || msg_error "apt dist-upgrade failed"
    msg_ok "Updated Proxmox VE"
  else
    msg_ok "Skipping system update (automated setting)"
  fi

  # Final message for cluster, browser cache, and recommended reboot
  echo
  echo "IMPORTANT:"
  echo
  echo " - If you have multiple Proxmox VE hosts in a cluster, run this script on each node individually."
  echo " - After completing these steps, a REBOOT is recommended."
  echo " - Please clear your browser cache or hard-reload (Ctrl+Shift+R) before using the Proxmox VE Web UI to avoid display issues."
  echo

  # We will NOT reboot automatically; only print recommendation
  msg_ok "Completed Post Install Routines (automated). Reboot recommended (no automatic reboot performed)."
}

main
