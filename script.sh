#!/usr/bin/env bash
# ==============================================================================
#  PRESETS & PACKAGES DEFINITION
# ==============================================================================
WORKSHOP_ITEMS=(3666255797 3357973751 3636094866 3682353804 3700132468)

# Core Pacman Packages 
PACMAN_PKGS=(
    base-devel bash-completion bluez bluez-utils btrfs-progs 
    btrfsmaintenance cmake curl dkms dnsmasq 
    docker git go grub-btrfs inotify-tools 
    less mokutil nano ncdu network-manager-applet 
    networkmanager noto-fonts noto-fonts-cjk noto-fonts-emoji 
    openssh p7zip pacman-contrib pciutils power-profiles-daemon 
    pipewire pipewire-audio pipewire-pulse wireplumber
    reflector rsync rust rust-src snap-pac 
    snapper smartmontools steam ttf-dejavu ufw 
    unzip wget which xz zram-generator 
    zip zstd
)

# Core AUR Packages
AUR_PKGS=(
    steamcmd snapper-rollback zen-browser-bin zed 
    gendesk uv xray-bin v2rayn
)

# ==============================================================================
#  PRIVILEGE & HARDWARE DETECTION
# ==============================================================================
if [[ "$EUID" -ne 0 ]]; then
    echo " This script should be launched as root (using sudo)."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

if [[ "$REAL_USER" == "root" ]]; then
    echo " Do not launch directly as root. Run: sudo ./script.sh"
    exit 1
fi

# Detect Kernel Headers
KERNEL_HEADERS=""
if pacman -Q linux-zen >/dev/null 2>&1; then
    KERNEL_HEADERS="linux-zen-headers"
    echo "Linux-zen kernel detected"
elif pacman -Q linux >/dev/null 2>&1; then
    KERNEL_HEADERS="linux-headers"
    echo "Found Linux kernel"
else
    echo "❌ Supported only for Linux and linux-zen"
    exit 1
fi

# Detect CPU Microcode
CPU_UCODE=""
if grep -q "AuthenticAMD" /proc/cpuinfo; then
    CPU_UCODE="amd-ucode"
    echo "Found AMD processor"
elif grep -q "GenuineIntel" /proc/cpuinfo; then
    CPU_UCODE="intel-ucode"
    echo "Found Intel processor"
fi

# Detect GPU Configuration
GPU_PKGS=(mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader xdg-utils)
HAS_NVIDIA=0
HAS_AMD=0

if lspci -nn | grep -Eiq 'nvidia'; then HAS_NVIDIA=1; fi
if lspci -nn | grep -Eiq 'amd|advanced micro devices|radeon'; then HAS_AMD=1; fi

if [[ "$HAS_NVIDIA" -eq 1 ]]; then
    echo "NVIDIA card found"
    GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings)
fi

IS_ROCM_INSTALLED=0
if [[ "$HAS_AMD" -eq 1 ]]; then
    echo "AMD card found"
    GPU_PKGS+=(vulkan-radeon lib32-vulkan-radeon)
    if pacman -Qi rocm-core >/dev/null 2>&1 || pacman -Qi rocm-bin >/dev/null 2>&1 || command -v rocminfo >/dev/null 2>&1; then
        IS_ROCM_INSTALLED=1
    fi
fi

# ==============================================================================
# INTERACTIVE USER PROMPTS
# ==============================================================================
# Steam Credentials Prompt
read -rp "Steam login (leave empty to skip wallpaper install): " STEAM_USER
STEAM_PASS=""
if [[ -n "$STEAM_USER" ]]; then
    read -rsp "Steam password: " STEAM_PASS
    echo
    echo "Note: If you have Steam Guard (2FA) enabled, stay ready to allow login later"
fi

CONFIRM_ROCM="n"
if [[ "$HAS_AMD" -eq 1 && "$IS_ROCM_INSTALLED" -eq 0 ]]; then
    echo "ROCM not found. Install it?"
    read -rp "Continue? [y/N]: " CONFIRM_ROCM
fi

# ==============================================================================
# PRE-INSTALLATION SYSTEM CONFIGURATIONS & TUNING
# ==============================================================================

# Network sysctl tuning
CONFIG_FILE="/etc/sysctl.d/99-network-opt.conf"
bash -c "cat << 'EOF' > $CONFIG_FILE
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 1000
EOF"
sysctl --system

# Compilation (makepkg.conf)
MAKEPKG_CONF="/etc/makepkg.conf"
if grep -q "MAKEFLAGS=" "$MAKEPKG_CONF"; then
    sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' "$MAKEPKG_CONF"
fi
if grep -q "CFLAGS=" "$MAKEPKG_CONF"; then
    sed -i 's/^#CFLAGS=/CFLAGS=/' "$MAKEPKG_CONF"
    sed -i 's/^#CXXFLAGS=/CXXFLAGS=/' "$MAKEPKG_CONF"
    sed -i 's/-march=[a-zA-Z0-9_-]*/-march=native/g' "$MAKEPKG_CONF"
    sed -i 's/-mtune=[a-zA-Z0-9_-]*/-mtune=native/g' "$MAKEPKG_CONF"
    sed -i 's/-O2/-O3/g' "$MAKEPKG_CONF"
fi

# Enable Multilib Repository
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    sed -i '/^#\[multilib\]/,/^#Include/s/^#//' /etc/pacman.conf
fi

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

pacman -Syu --noconfirm

# ==============================================================================
#  BOOTSTRAP YAY 
# ==============================================================================
pacman -S --needed --noconfirm base-devel git

if ! command -v yay >/dev/null 2>&1; then
    TMP_DIR=$(mktemp -d)
    chown -R "$REAL_USER":"$REAL_USER" "$TMP_DIR"
    sudo -u "$REAL_USER" bash -c "
        git clone https://aur.archlinux.org/yay.git '$TMP_DIR/yay'
        cd '$TMP_DIR/yay'
        makepkg -s --noconfirm
    "
    pacman -U --noconfirm "$TMP_DIR/yay"/*.pkg.tar.zst
    rm -rf "$TMP_DIR"
else
    echo " 'yay' is already installed."
fi
# ==============================================================================
#  INSTALLATION
# ==============================================================================

PKG_LIST=("${PACMAN_PKGS[@]}" "${AUR_PKGS[@]}")

if [[ -n "$KERNEL_HEADERS" ]]; then PKG_LIST+=("$KERNEL_HEADERS"); fi
if [[ -n "$CPU_UCODE" ]]; then PKG_LIST+=("$CPU_UCODE"); fi
if [[ ${#GPU_PKGS[@]} -gt 0 ]]; then PKG_LIST+=("${GPU_PKGS[@]}"); fi

if [[ "$HAS_AMD" -eq 1 && "$IS_ROCM_INSTALLED" -eq 0 && "$CONFIRM_ROCM" =~ ^[Yy]$ ]]; then
    PKG_LIST+=("rocm-bin")
fi
sudo -u "$REAL_USER" yay -S --needed --noconfirm "${PKG_LIST[@]}"

# Regenerate Initramfs
mkinitcpio -P

# ==============================================================================
# BTRFS SETUP
# ==============================================================================

# --- BTRFS LAYOUT & SNAPPER SNAPSHOTS SETUP ---
ROOT_DEV=$(findmnt -n -o SOURCE / | cut -d'[' -f1)
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_DEV")
MNT_ROOT="/tmp/btrfs_top_level"

mkdir -p "$MNT_ROOT"
mount -o subvolid=5 "$ROOT_DEV" "$MNT_ROOT"

if [ ! -d "$MNT_ROOT/@snapshots" ]; then
    btrfs subvolume create "$MNT_ROOT/@snapshots"
fi

if [ ! -f "/etc/snapper/configs/root" ]; then
    snapper -c root create-config /
    if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
        btrfs subvolume delete /.snapshots
    else
        rmdir /.snapshots 2>/dev/null || true
    fi
    mkdir /.snapshots
fi
umount "$MNT_ROOT"

FSTAB_BTRFSROOT="UUID=$ROOT_UUID        /btrfsroot             btrfs           subvolid=5,defaults,noatime,nofail 0 0"
FSTAB_SNAPSHOTS="UUID=$ROOT_UUID        /.snapshots            btrfs           rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,nofail,subvol=/@snapshots 0 0"

if [ ! -d "/btrfsroot" ]; then mkdir -p "/btrfsroot"; fi
if ! grep -q "subvolid=5" /etc/fstab && ! grep -q "/btrfsroot" /etc/fstab; then
    echo "$FSTAB_BTRFSROOT" >> /etc/fstab
fi
if ! grep -q "subvol=/@snapshots" /etc/fstab; then
    echo "$FSTAB_SNAPSHOTS" >> /etc/fstab
fi

mount /btrfsroot 2>/dev/null || echo " /btrfsroot is already mounted or busy"
mount /.snapshots 2>/dev/null || echo " /.snapshots is already mounted or busy"

SNAPPER_CONFIG_FILE="/etc/snapper/configs/root"
if [ -f "$SNAPPER_CONFIG_FILE" ]; then
    sed -i \
        -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' \
        -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="20"/' \
        -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="4"/' \
        "$SNAPPER_CONFIG_FILE"
    sed -i "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$REAL_USER\"/" "$SNAPPER_CONFIG_FILE"
    USER_GROUP=$(id -gn "$REAL_USER")
    sed -i "s/^ALLOW_GROUPS=.*/ALLOW_GROUPS=\"$USER_GROUP\"/" "$SNAPPER_CONFIG_FILE"
else
    echo " Error: Snapper 'root' config cannot be found at path: $SNAPPER_CONFIG_FILE"
fi

if [ ! -f "/etc/snapper/configs/boot" ]; then
    if findmnt -n -o FSTYPE /boot | grep -q "btrfs"; then
        echo " /boot is Btrfs. Setting up standard Snapper boot layout..."
        snapper -c boot create-config /boot 2>/dev/null
        
        sed -i 's/TIMELINE_LIMIT_HOURLY="[^"]*"/TIMELINE_LIMIT_HOURLY="0"/' /etc/snapper/configs/boot
        sed -i 's/TIMELINE_LIMIT_DAILY="[^"]*"/TIMELINE_LIMIT_DAILY="5"/' /etc/snapper/configs/boot
        sed -i 's/TIMELINE_LIMIT_WEEKLY="[^"]*"/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/boot
        sed -i 's/TIMELINE_LIMIT_MONTHLY="[^"]*"/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/boot
        sed -i 's/TIMELINE_LIMIT_YEARLY="[^"]*"/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/boot
        sed -i -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/boot
    else
        echo "/boot is non-Btrfs (FAT32/ext4). Deploying automated Pacman boot-backup pre-hook..."
        mkdir -p /usr/local/bin
        cat << 'EOF' > /usr/local/bin/boot-backup.sh
#!/usr/bin/env bash
mkdir -p /.boot-backup
rsync -a --delete /boot/ /.boot-backup/
EOF
        chmod +x /usr/local/bin/boot-backup.sh

        mkdir -p /etc/pacman.d/hooks
        cat << 'EOF' > /etc/pacman.d/hooks/95-boot-backup.hook
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = linux*

[Action]
Description = Mirroring /boot files to Btrfs root subvolume for fallback snapshots...
When = PreTransaction
Exec = /usr/local/bin/boot-backup.sh
EOF
        /usr/local/bin/boot-backup.sh
        echo "Pre-transaction boot hook initialized successfully."
    fi
fi

if [ -d "/.snapshots" ]; then
    chown -R :"$USER_GROUP" /.snapshots
    chmod 750 /.snapshots
else
    echo " Warning: /.snapshots folder not found."
fi

mkdir -p /etc/systemd/system/snapper-cleanup.timer.d
cat <<EOF > /etc/systemd/system/snapper-cleanup.timer.d/override.conf
[Timer]
OnCalendar=
OnCalendar=daily
Persistent=true
EOF

# --- SYSTEM SERVICES & FIREWALL SETUP ---
systemctl daemon-reload
systemctl disable --now snapper-timeline.timer || true
systemctl enable --now snapper-cleanup.timer
systemctl enable --now NetworkManager
systemctl enable --now bluetooth
systemctl enable --now docker
systemctl enable --now ufw
systemctl enable --now fstrim.timer
systemctl enable --now paccache.timer
systemctl restart snapper-cleanup.timer

usermod -aG docker "$REAL_USER"

ufw default deny incoming
ufw default allow outgoing
ufw --force enable

if systemctl list-unit-files | grep -q "grub-btrfsd.service"; then
    systemctl enable --now grub-btrfsd.service
fi
if systemctl list-unit-files | grep -q "btrfs-scrub@-.timer"; then
    systemctl enable --now "btrfs-scrub@-.timer"
fi

# ZRAM Swapping Setup
ZRAM_CONF="/etc/systemd/zram-generator.conf"
bash -c "cat << 'EOF' > $ZRAM_CONF
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOF"
systemctl daemon-reload
systemctl enable --now systemd-zram-setup@zram0.service

# --- BLUETOOTH CUSTOMIZATIONS ---
BLUEZ_CONF="/etc/bluetooth/main.conf"
update_bluez_param() {
    local param="$1"
    local value="$2"
    if grep -q "^${param}" "$BLUEZ_CONF"; then
        sed -i "s/^${param}.*/${param} = ${value}/" "$BLUEZ_CONF"
    else
        sed -i "/^\[General\]/a ${param} = ${value}" "$BLUEZ_CONF"
    fi
}
update_bluez_param "Experimental" "true"
update_bluez_param "FastConnectable" "true"
update_bluez_param "MultiProfile" "multiple"
rfkill unblock bluetooth
systemctl restart bluetooth

# Wireplumber Configuration
WP_DIR="$REAL_HOME/.config/wireplumber/wireplumber.conf.d"
sudo -u "$REAL_USER" mkdir -p "$WP_DIR"
cat > "$WP_DIR/51-bluetooth-fix.conf" <<EOF
monitor.bluez.properties = {
    bluez5.suspend-on-idle = false
    bluetooth.autoswitch-to-headset = false
}
EOF
chown "$REAL_USER":"$REAL_USER" "$WP_DIR/51-bluetooth-fix.conf"

# Pipewire Configuration
PW_DIR="$REAL_HOME/.config/pipewire/pipewire.conf.d"
sudo -u "$REAL_USER" mkdir -p "$PW_DIR"
cat > "$PW_DIR/99-input-latency.conf" <<EOF
context.properties = {
    default.clock.min-quantum = 1024
}
EOF
chown "$REAL_USER":"$REAL_USER" "$PW_DIR/99-input-latency.conf"

if [ -n "$REAL_USER" ]; then
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $REAL_USER)" systemctl --user restart pipewire wireplumber pipewire-pulse
fi

# --- STEAM WORKSHOP ASSETS ---
if [[ -n "$STEAM_USER" && -n "$STEAM_PASS" ]]; then
    STEAM_ARGS=(+run_script_at_dir /tmp +login "$STEAM_USER" "$STEAM_PASS")
    for ITEM in "${WORKSHOP_ITEMS[@]}"; do
        STEAM_ARGS+=(+workshop_download_item 431960 "$ITEM")
    done
    STEAM_ARGS+=(+quit)
    
    (cd /tmp && sudo -H -u "$REAL_USER" steamcmd "${STEAM_ARGS[@]}")
    
    mkdir -p "$REAL_HOME/wallpaper"
    WORKSHOP_DIR="$REAL_HOME/.steam/SteamApps/workshop/content/431960"

    if [[ -d "$WORKSHOP_DIR" ]]; then
        for ITEM in "${WORKSHOP_ITEMS[@]}"; do
            if [[ -d "$WORKSHOP_DIR/$ITEM" ]]; then
                cp -r "$WORKSHOP_DIR/$ITEM" "$REAL_HOME/wallpaper/"
                rm -rf "$WORKSHOP_DIR/$ITEM"
            fi
        done
    else
        echo "Warning: Workshop directory cannot be found ($WORKSHOP_DIR)"
    fi
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/wallpaper"
    chmod -R 755 "$REAL_HOME/wallpaper"
    echo "Wallpapers are located at $REAL_HOME/wallpaper"
else
    echo "Steam Workshop skipped"
fi

# --- GRUB TWEAKS ---
GRUB_CONFIG="/etc/default/grub"
cp "$GRUB_CONFIG" "${GRUB_CONFIG}.bak"
echo "[+] Backup created: ${GRUB_CONFIG}.bak"

if grep -q "^GRUB_DEFAULT=" "$GRUB_CONFIG"; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$GRUB_CONFIG"
else
    echo "GRUB_DEFAULT=saved" >> "$GRUB_CONFIG"
fi

if grep -q "^GRUB_SAVEDEFAULT=" "$GRUB_CONFIG"; then
    sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' "$GRUB_CONFIG"
else
    echo "GRUB_SAVEDEFAULT=true" >> "$GRUB_CONFIG"
fi

if [ -d /boot/grub ]; then
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "Error: Folder /boot/grub not found. Check where GRUB is installed."
fi

# --- USER ENVIRONMENT CONFIGURATION (.bashrc) ---
if [[ -f "$REAL_HOME/.bashrc" && ! -f "$REAL_HOME/.bashrc.bak" ]]; then
    cp "$REAL_HOME/.bashrc" "$REAL_HOME/.bashrc.bak"
fi

cat << 'EOF' > "$REAL_HOME/.bashrc"
# ==========================================================
# ~/.bashrc
# ==========================================================
[[ $- != *i* ]] && return

export PATH="$HOME/.local/bin:$PATH"
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth
export HISTIGNORE="ls:ll:pwd:exit:clear"
export EDITOR="nano"
export TERM="xterm-256color"

shopt -s checkwinsize
shopt -s direxpand
shopt -s expand_aliases
shopt -s histappend

# Shell Aliases
alias pacman='sudo pacman'
alias mkinit='sudo mkinitcpio -P'
alias grubupd='sudo grub-mkconfig -o /boot/grub/grub.cfg'
alias sudo='sudo '
alias exe='chmod +x'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ls='ls -lah --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias weather='curl wttr.in'

# Functions
python() {
    if command -v uv &> /dev/null; then
        uv run python "$@"
    else
        command python "$@"
    fi
}

pip() {
    if command -v uv &> /dev/null; then
        uv run pip "$@"
    else
        command pip "$@"
    fi
}
mkcd() { mkdir -p "$1" && cd "$1"; }
ports() { ss -tulpn; }
myip() { curl -s ifconfig.me; }

fset() {
    if [ "$#" -eq 2 ]; then
        sudo chmod "$1" "$2"
    elif [ "$#" -eq 3 ]; then
        sudo chown "$1" "$3" && sudo chmod "$2" "$3"
    elif [ "$#" -eq 4 ] && [ "$1" = "-R" ]; then
        sudo chown -R "$2" "$4" && sudo chmod -R "$3" "$4"
    else
        echo "Usage examples:"
        echo "  fset <permissions> <file>"
        echo "  fset <owner> <permissions> <file>"
        echo "  fset -R <owner> <permissions> <folder>"
        return 1
    fi
}

alias unpack='extract'
extract() {
    if [[ ! -f "$1" ]]; then
        echo "Error: '$1' is not a valid file" >&2
        return 1
    fi
    local file=$(basename "$1")
    local ext="${file##*.}"
    local ext_lc=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local filename_lc=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    case "$filename_lc" in
        *.tar.bz2|*.tbz2|*.tbz) tar xjf "$1" ;;
        *.tar.gz|*.tgz)         tar xzf "$1" ;;
        *.tar.xz|*.txz)         tar xf "$1"  ;;
        *.tar.zst|*.tzst)       tar xf "$1"  ;;
        *.tar.lzma|*.tlz)       tar xf "$1"  ;;
        *.tar)                  tar xf "$1"  ;;
        *.bz2)                  bunzip2 -k "$1" ;; 
        *.gz)                   gunzip -k "$1"  ;; 
        *.xz)                   unxz -k "$1"    ;; 
        *.lzma)                 unlzma -k "$1"  ;; 
        *.zst)                  unzstd --keep "$1" ;;
        *.zip|*.jar|*.war|*.apk) unzip "$1"   ;;
        *.rar)                  unrar x "$1"  ;;
        *.7z)                   7z x "$1"     ;;
        *.deb)                  ar x "$1"     ;;
        *.rpm)                  rpm2cpio "$1" | cpio -idmv ;;
        *.z)                    uncompress "$1" ;;
        *)                      echo "Unsupported archive format: '$1'" >&2; return 1 ;;
    esac
}

nano() {
    if [[ $# -eq 0 ]]; then
        command nano
        return
    fi
    local dir
    dir=$(dirname "$1")
    if [[ ( -e "$1" && ! -w "$1" ) || ( ! -e "$1" && ! -w "$dir" ) ]]; then
        sudo /usr/bin/nano "$@"
    else
        command nano "$@"
    fi
}

clean() {
    if pacman -Qdtq >/dev/null 2>&1; then
        pacman -Qdtq | xargs -r sudo pacman -Rns
    fi
    sudo paccache -rk1
    sudo paccache -ruk0
    sudo pacman -Scc --noconfirm
    yay -Sc --noconfirm
    if command -v flatpak &> /dev/null; then
        flatpak uninstall --unused -y
    fi
    if command -v gio &> /dev/null; then
        gio trash --empty
    else
        rm -rf ~/.local/share/Trash/*
    fi
    sudo journalctl --vacuum-time=3d
    rm -rf ~/.cache/*
    find ~/.local/bin -xtype l -delete 2>/dev/null
    find ~/.local/state/nvim/swap/ -type f -mtime +14 -delete 2>/dev/null
    systemctl --failed --all
}

rollback() {
    if [[ -z "${1:-}" ]]; then
        echo "Error: Enter snapshot number (example: rollback 69)"
        return 1
    fi
    local target="$1"
    local last
    last=$(sudo snapper list | awk '$1 ~ /^[0-9]+$/ { id=$1 } END { print id }')

    if [[ ! "$last" =~ ^[0-9]+$ ]]; then
        echo "Error: Could not determine ID of last snapshot."
        return 1
    fi
    sudo snapper --ambit classic rollback "$target"
    local next=$((last + 2))
    echo "CONFIRM" | sudo snapper-rollback "$next"
    
    if [ -d "/.boot-backup" ]; then
        echo "Non-Btrfs layout detected. Syncing /boot with target snapshot modules..."
        sudo rsync -axHAWXS --delete /.boot-backup/ /boot/
        echo "/boot successfully synchronized to historical kernel version."
    else
        local boot_snapshot_dir="/boot/.snapshots/$target/snapshot"
        if [ -d "$boot_snapshot_dir" ]; then
            echo " Btrfs boot detected. Recovering boot files from snapper archive..."
            sudo rsync -axHAWXS --delete --exclude="/.snapshots" "$boot_snapshot_dir/" /boot/
            echo " /boot successfully synchronized with snapshot #$target."
        else
            echo " Warning: No boot backup layout found."
        fi
    fi
}

mem() {
    echo "═══════════════════════════════════════"
    echo "🔹 RAM (System Memory):"
    free -b | awk '
    function f(b) {
        if (b < 1073741824) return sprintf("%.1f MiB", b/1048576)
        return sprintf("%.1f GiB", b/1073741824)
    }
    /^Mem:/ {
        fmt = "    %-7s %-12s %-12s %-12s %-12s %-14s %-12s\n"
        printf fmt, "", "total", "used", "free", "shared", "buff/cache", "available"
        printf fmt, "Mem:", f($2), f($3), f($4), f($5), f($6), f($7)
    }'
    echo ""
    local vram_total=0
    local vram_used=0
    for card in /sys/class/drm/card*/device/mem_info_vram_total; do
        if [ -f "$card" ]; then
            local total=$(cat "$card" 2>/dev/null)
            local used=$(cat "${card%/mem_info_vram_total}/mem_info_vram_used" 2>/dev/null)
            vram_total=$((vram_total + ${total:-0}))
            vram_used=$((vram_used + ${used:-0}))
        fi
    done
    if [ $vram_total -gt 0 ]; then
        local vram_free=$((vram_total - vram_used))
        local total_gb=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $vram_total / 1073741824}")
        local used_gb=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $vram_used / 1073741824}")
        local free_gb=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $vram_free / 1073741824}")
        local used_pct=$((vram_used * 100 / vram_total))
        echo "🔸 VRAM (GPU Memory):"
        echo "    Total:  ${total_gb} GiB"
        echo "    Used:   ${used_gb} GiB (${used_pct}%)"
        echo "    Free:   ${free_gb} GiB"
    else
        echo "🔸 VRAM: No GPU detected"
    fi
    echo ""
    echo "═══════════════════════════════════════"
}

get_random_color() {
    local colors=(31 32 33 34 35 36 91 92 93 94 95 96)
    echo "${colors[$((RANDOM % ${#colors[@]}))]}"
}

rainbow_user() {
    local user="${USER:-$(whoami)}"
    local colors=(31 32 33 34 35 36 91 92 93 94 95 96)
    local out="" i
    for ((i=0; i<${#user}; i++)); do
        local char="${user:$i:1}"
        local color="${colors[$((RANDOM % ${#colors[@]}))]}"
        out+=$'\001\033[1;'"${color}m"'\002'"${char}"
    done
    echo -ne "$out"
}

set_prompt() {
    local host_color=$(get_random_color)
    local dir_color=$(get_random_color)
    local arrow_color=$(get_random_color)
    local r_user=$(rainbow_user)
    PS1="[\[\033[1;${host_color}m\]\h\[\033[0m\]@${r_user}\[\033[0m\]] | \[\033[1;${dir_color}m\]\W\[\033[0m\] | \[\033[1;${arrow_color}m\]-> \[\033[0m\] "
}

PROMPT_COMMAND=set_prompt
[[ -r /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion
EOF
chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/.bashrc"

echo
echo "============================================================"
echo "                   Installation complete!"
echo "                         Restart PC"
echo "============================================================"
