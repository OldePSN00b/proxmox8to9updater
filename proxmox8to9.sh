#!/usr/bin/env bash
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/pve8to9-preupgrade-$STAMP"
DISABLED_REPO_DIR="/root/disabled-apt-repos"
HOST="$(hostname)"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

confirm() {
  echo
  read -rp "$1 [type YES]: " ans
  [[ "$ans" == "YES" ]] || die "Aborted."
}

cleanup_invalid_repo_extensions() {
  mkdir -p "$DISABLED_REPO_DIR"

  find /etc/apt/sources.list.d/ \
    -type f \
    ! -name "*.list" \
    ! -name "*.sources" \
    -exec mv {} "$DISABLED_REPO_DIR/" \; 2>/dev/null || true
}

disable_conflicting_repos() {
  echo
  echo "=== Backing up and disabling conflicting Proxmox/Ceph repos ==="

  mkdir -p "$BACKUP_DIR/repo-backups"
  mkdir -p "$DISABLED_REPO_DIR"

  find /etc/apt/sources.list.d/ -maxdepth 1 \
    \( -name "*.list" -o -name "*.sources" \) \
    -exec cp -a {} "$BACKUP_DIR/repo-backups/" \; 2>/dev/null || true

  for f in \
    /etc/apt/sources.list.d/pve-enterprise.list \
    /etc/apt/sources.list.d/pve-enterprise.sources \
    /etc/apt/sources.list.d/proxmox.list \
    /etc/apt/sources.list.d/proxmox.sources \
    /etc/apt/sources.list.d/pve-no-subscription.list \
    /etc/apt/sources.list.d/pve-no-subscription.sources \
    /etc/apt/sources.list.d/ceph.list \
    /etc/apt/sources.list.d/ceph.sources \
    /etc/apt/sources.list.d/ceph-quincy.list \
    /etc/apt/sources.list.d/ceph-quincy.sources \
    /etc/apt/sources.list.d/ceph-no-subscription.list \
    /etc/apt/sources.list.d/ceph-no-subscription.sources
  do
    [[ -e "$f" ]] || continue
    echo "Disabling repo file: $f"
    mv "$f" "$DISABLED_REPO_DIR/"
  done

  cleanup_invalid_repo_extensions
}

fix_systemd_boot_package() {
  echo
  echo "=== Checking for unsupported systemd-boot package ==="

  if dpkg -s systemd-boot >/dev/null 2>&1; then
    echo
    echo "FAIL: The standalone 'systemd-boot' package is installed."
    echo "This can cause Proxmox VE 9 boot-package upgrade problems."
    echo

    read -rp "Remove systemd-boot now? [y/N]: " ans

    case "$ans" in
      y|Y|yes|YES)
        apt remove -y systemd-boot
        proxmox-boot-tool refresh || true
        proxmox-boot-tool status || true
        ;;
      *)
        die "systemd-boot must be removed before continuing."
        ;;
    esac
  else
    echo "systemd-boot package is not installed."
  fi
}

fix_cpu_microcode_warning() {
  echo
  echo "=== Checking CPU microcode package ==="

  MICROCODE_PACKAGE=""

  if grep -q GenuineIntel /proc/cpuinfo; then
    MICROCODE_PACKAGE="intel-microcode"
  elif grep -q AuthenticAMD /proc/cpuinfo; then
    MICROCODE_PACKAGE="amd64-microcode"
  else
    echo "Unknown CPU vendor; skipping microcode check."
    return 0
  fi

  echo "Detected required microcode package: $MICROCODE_PACKAGE"

  if dpkg -s "$MICROCODE_PACKAGE" >/dev/null 2>&1; then
    echo "$MICROCODE_PACKAGE is already installed."
    return 0
  fi

  if grep -q "VERSION_CODENAME=trixie" /etc/os-release; then
    DEBIAN_SUITE="trixie"
    SECURITY_SUITE="trixie-security"
  else
    DEBIAN_SUITE="bookworm"
    SECURITY_SUITE="bookworm-security"
  fi

  echo "Ensuring Debian $DEBIAN_SUITE repositories include non-free-firmware..."

  cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian $DEBIAN_SUITE main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SECURITY_SUITE main contrib non-free non-free-firmware
EOF

  apt update
  apt install -y "$MICROCODE_PACKAGE"
}

write_debian_bookworm_repos() {
  cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
}

write_debian_trixie_repos() {
  cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
}

write_pve8_repos() {
  echo
  echo "=== Configuring clean Proxmox VE 8 repositories ==="

  if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
    echo "Using enterprise PVE8 repos."

    cat > /etc/apt/sources.list.d/pve-enterprise.list <<'EOF'
deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF

    if command -v ceph >/dev/null 2>&1; then
      cat > /etc/apt/sources.list.d/ceph.list <<'EOF'
deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
EOF
    fi
  else
    echo "Using no-subscription PVE8 repos."

    cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

    if command -v ceph >/dev/null 2>&1; then
      cat > /etc/apt/sources.list.d/ceph-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
EOF
    fi
  fi
}

write_pve9_repos() {
  echo
  echo "=== Configuring Proxmox VE 9 repositories ==="

  if [[ "$HAS_SUBSCRIPTION" == "true" ]]; then
    echo "Using enterprise PVE9 repos."

    cat > /etc/apt/sources.list.d/pve-enterprise.list <<'EOF'
deb https://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF

    if command -v ceph >/dev/null 2>&1; then
      cat > /etc/apt/sources.list.d/ceph.list <<'EOF'
deb https://enterprise.proxmox.com/debian/ceph-squid trixie enterprise
EOF
    fi
  else
    echo "Using no-subscription PVE9 repos."

    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources
    rm -f /etc/apt/sources.list.d/ceph.list
    rm -f /etc/apt/sources.list.d/ceph.sources

    cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

    if command -v ceph >/dev/null 2>&1; then
      cat > /etc/apt/sources.list.d/ceph-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/ceph-squid trixie no-subscription
EOF
    fi
  fi
}

enforce_final_pve9_repos() {
  echo
  echo "=== Enforcing final Proxmox VE 9 repository configuration ==="

  mkdir -p "$DISABLED_REPO_DIR"

  find /etc/apt/sources.list.d/ \
    -type f \
    \( -name "*enterprise*.list" -o -name "*enterprise*.sources" \) \
    -exec mv {} "$DISABLED_REPO_DIR/" \; 2>/dev/null || true

  cleanup_invalid_repo_extensions
  write_debian_trixie_repos
  write_pve9_repos

  echo
  echo "=== Final apt update after repo enforcement ==="
  apt update
}

[[ "$EUID" -eq 0 ]] || die "Run as root."

echo "=== Proxmox VE 8 -> 9 upgrade helper on $HOST ==="

pveversion || die "This does not look like a Proxmox VE node."

mkdir -p "$BACKUP_DIR"

cp -a /etc/apt "$BACKUP_DIR/apt" 2>/dev/null || true
cp -a /etc/pve "$BACKUP_DIR/pve" 2>/dev/null || true
cp -a /etc/network "$BACKUP_DIR/network" 2>/dev/null || true
cp -a /etc/hosts /etc/resolv.conf /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true

ROOT_AVAIL_KB="$(df --output=avail / | tail -1 | tr -d ' ')"
ROOT_AVAIL_GB="$((ROOT_AVAIL_KB / 1024 / 1024))"

echo "Root filesystem free space: ${ROOT_AVAIL_GB}G"
(( ROOT_AVAIL_GB >= 5 )) || die "Need at least 5GB free on /."

echo
echo "=== Current guests ==="
qm list || true
pct list || true

echo
echo "=== Cluster status ==="
pvecm status || true

echo
echo "=== Ceph status ==="
if command -v ceph >/dev/null 2>&1; then
  ceph --version || true
  ceph -s || true
else
  echo "Ceph command not found."
fi

confirm "Confirm you have backups and are ready to begin?"

echo
echo "=== Detecting enterprise repository access ==="

HAS_SUBSCRIPTION="false"

if curl -fsI https://enterprise.proxmox.com/debian/pve/dists/bookworm/InRelease >/dev/null 2>&1; then
  HAS_SUBSCRIPTION="true"
fi

echo "Enterprise repo accessible: $HAS_SUBSCRIPTION"

disable_conflicting_repos

echo
echo "=== Configuring Debian Bookworm repositories ==="
write_debian_bookworm_repos
write_pve8_repos

echo
echo "=== Updating current Proxmox VE 8 install ==="
apt update

fix_systemd_boot_package
fix_cpu_microcode_warning

apt dist-upgrade -y

echo
echo "=== Held packages ==="
apt-mark showhold || true

echo
echo "=== Running pve8to9 pre-check ==="

pve8to9 --full || {
  echo
  echo "pve8to9 found warnings/errors."
  confirm "Continue anyway?"
}

confirm "Ready to switch repositories from bookworm/PVE8 to trixie/PVE9?"

disable_conflicting_repos

echo
echo "=== Configuring Debian Trixie repositories ==="
write_debian_trixie_repos
write_pve9_repos

echo
echo "=== Refreshing package indexes ==="
apt update

fix_cpu_microcode_warning

echo
echo "=== Simulating dist-upgrade ==="

apt -s dist-upgrade | tee "$BACKUP_DIR/apt-simulated-dist-upgrade.txt"

if grep -E '^Remv proxmox-ve|proxmox-ve.*REMOVE|^Remv pve-manager|^Remv qemu-server' "$BACKUP_DIR/apt-simulated-dist-upgrade.txt" >/dev/null; then
  die "Simulation suggests critical Proxmox packages may be removed."
fi

confirm "Start the real Proxmox VE 9 upgrade?"

echo
echo "=== Running real dist-upgrade ==="
apt dist-upgrade

enforce_final_pve9_repos

echo
echo "=== Post-upgrade check ==="

pve8to9 || true
pveversion -v || true

cat <<EOF

Upgrade package phase completed.

Backup of original configs:
  $BACKUP_DIR

Disabled repositories moved to:
  $DISABLED_REPO_DIR

Recommended next step:
  reboot

After reboot, run:
  pveversion -v
  pve8to9
  apt update
  apt dist-upgrade

If clustered:
  pvecm status

If using Ceph:
  ceph -s

EOF