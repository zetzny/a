#!/usr/bin/env bash

# скрипт ОБЯЗАТЕЛЬНО нужно запускать через sudo
if [[ "$EUID" -ne 0 ]]; then
    echo "❌ Этот скрипт должен быть запущен от имени root (через sudo)."
    exit 1
fi

# Определяем реального пользователя, который запустил sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

if [[ "$REAL_USER" == "root" ]]; then
    echo "❌ Не запускайте скрипт прямо из-под root. Запускайте: sudo ./script.sh"
    exit 1
fi
if pacman -Q linux-zen >/dev/null 2>&1; then
    KERNEL_HEADERS="linux-zen-headers"
    echo "Обнаружено ядро linux-zen"
elif pacman -Q linux >/dev/null 2>&1; then
    KERNEL_HEADERS="linux-headers"
    echo "Обнаружено ядро linux"
else
    echo "❌ Поддерживаются только linux и linux-zen"
    exit 1
fi
echo "============================================================"
echo " Arch Linux Post Install Setup"
echo "============================================================"

echo
read -rp "Steam login (оставьте пустым чтобы пропустить скачивание обоев): " STEAM_USER

STEAM_PASS=""
if [[ -n "$STEAM_USER" ]]; then
    read -rsp "Steam password: " STEAM_PASS
    echo
fi

echo
echo "=== Исправление структуры Btrfs для Snapper ==="
sudo pacman -S --needed --noconfirm snapper btrfs-progs btrfsmaintenance grub-btrfs inotify-tools snap-pac
snapper -c root create-config /

ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_DEV")
BASE_DEV=$(findmnt -vno SOURCE -T /)

echo "➜ Корневое устройство: $BASE_DEV"
echo "➜ UUID файловой системы: $ROOT_UUID"


FSTAB_BTRFSROOT="UUID=$ROOT_UUID /btrfsroot btrfs subvolid=5,defaults,noatime 0 0"
FSTAB_SNAPSHOTS="UUID=$ROOT_UUID /.snapshots btrfs rw,relatime,compress=zstd:3,ssd,discard=async,noatime,space_cache=v2,subvol=/@snapshots 0 0"

# Создаем точку монтирования для /btrfsroot, если её нет
if [ ! -d "/btrfsroot" ]; then
    echo "➜ Создаем директорию /btrfsroot..."
    mkdir -p "/btrfsroot"
fi

# Добавляем /btrfsroot в fstab, если его там еще нет
if ! grep -q "subvolid=5" /etc/fstab && ! grep -q "/btrfsroot" /etc/fstab; then
    echo "➜ Добавляем /btrfsroot в /etc/fstab..."
    echo "$FSTAB_BTRFSROOT" >> /etc/fstab
fi

# Добавляем @snapshots в fstab, если его там еще нет
if ! grep -q "subvol=/@snapshots" /etc/fstab; then
    echo "➜ Добавляем @snapshots в /etc/fstab..."
    echo "$FSTAB_SNAPSHOTS" >> /etc/fstab
fi

# Монтируем всё, что только что прописали
echo "➜ Монтируем новые точки..."
mount /btrfsroot 2>/dev/null || echo "⚠️ /btrfsroot уже примонтирован или занят"
mount /.snapshots 2>/dev/null || echo "⚠️ /.snapshots уже примонтирован или занят"

echo "✅ Настройка fstab и монтирование завершены успешно!"
echo ""
echo "=== Включение multilib ==="

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    sed -i '/^#\[multilib\]/,/^#Include/s/^#//' /etc/pacman.conf
fi

echo
echo "=== Обновление системы ==="

pacman -Syu --noconfirm

echo
echo "=== Определение ядра ==="


echo
echo
echo "=== Установка базовых пакетов ==="

BASE_PKGS=(
    base-devel git go reflector pacman-contrib bash-completion pciutils dkms
    curl wget rsync unzip zip less which nano htop ncdu openssh smartmontools
    networkmanager network-manager-applet noto-fonts noto-fonts-cjk
    noto-fonts-emoji ttf-dejavu "${KERNEL_HEADERS}"
    steam rust python-pip cmake
)

# Устанавливаем всё официальное одной чистой командой
pacman -S --needed --noconfirm "${BASE_PKGS[@]}"

echo


echo
echo "=== Настройка локалей ==="

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

cat <<EOF > /etc/locale.conf
LANG=en_US.UTF-8
LC_TIME=ru_RU.UTF-8
EOF

echo
echo "=== Установка yay (от пользователя $REAL_USER) ==="

if ! command -v yay >/dev/null 2>&1; then
    TMP_DIR=$(mktemp -d)
    chown -R "$REAL_USER":"$REAL_USER" "$TMP_DIR"

    # Сборку пакета делаем строго от лица обычного пользователя
    sudo -u "$REAL_USER" bash -c "
        git clone https://aur.archlinux.org/yay.git '$TMP_DIR/yay'
        cd '$TMP_DIR/yay'
        makepkg -s --noconfirm
    "
    # Устанавливаем собранный пакет от root
    pacman -U --noconfirm "$TMP_DIR/yay"/*.pkg.tar.zst
    rm -rf "$TMP_DIR"
else
    echo "yay уже установлен"
fi

echo
echo "=== Установка AUR пакетов ==="

sudo -u "$REAL_USER" yay -S --needed --noconfirm steamcmd snapper-rollback vivaldi zed xray-bin v2rayn-bin

echo
echo "=== Определение GPU ==="

GPU_PKGS=(mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader xdg-utils)
HAS_NVIDIA=0
HAS_AMD=0

if lspci -nn | grep -Eiq 'nvidia'; then HAS_NVIDIA=1; fi
if lspci -nn | grep -Eiq 'amd|advanced micro devices|radeon'; then HAS_AMD=1; fi

if [[ "$HAS_NVIDIA" -eq 1 ]]; then
    echo "NVIDIA обнаружена"
    GPU_PKGS+=(nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings)
fi

if [[ "$HAS_AMD" -eq 1 ]]; then
    echo "AMD обнаружена"
    GPU_PKGS+=(vulkan-radeon lib32-vulkan-radeon)

    # Проверяем, установлен ли rocm-bin
    if pacman -Qi rocm-bin >/dev/null 2>&1; then
        echo "➜ rocm-bin уже установлен, пропускаем сборку."
    else
        echo "➜ rocm-bin не найден. Начинаем процесс установки..."

        START_DIR=$(pwd)

        BUILD_DIR="${REAL_HOME}/rocm-bin-build"
        rm -rf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR" || exit 1

        git clone https://aur.archlinux.org/rocm-bin.git .

        chown -R "$REAL_USER:$REAL_USER" "$BUILD_DIR"

        echo "➜ Запуск сборки пакета..."
        sudo -u "$REAL_USER" makepkg -si --noconfirm

        # Возвращаемся обратно и начисто удаляем тяжелую папку сборки
        cd "$START_DIR" || exit 1
        rm -rf "$BUILD_DIR"

        echo "✅ rocm-bin успешно установлен!"
    fi
fi

pacman -S --needed --noconfirm "${GPU_PKGS[@]}"

echo
echo "=== Пересборка initramfs ==="

mkinitcpio -P

echo
echo "=== Установка системных пакетов ==="

SYSTEM_PKGS=(
    bluez bluez-utils docker snapper snap-pac grub-btrfs
    btrfs-progs btrfsmaintenance ufw zram-generator inotify-tools mokutil
)

pacman -S --needed --noconfirm "${SYSTEM_PKGS[@]}"

echo
echo "=== Инициализация и настройка Snapper ==="
sed -i \
    -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' \
    -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="20"/' \
    -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="4"/' \
    /etc/snapper/configs/root

systemctl disable --now snapper-timeline.timer || true
systemctl enable --now snapper-cleanup.timer

echo
echo "=== Настройка служб ==="

systemctl enable --now NetworkManager
systemctl enable --now bluetooth
systemctl enable --now docker
systemctl enable --now ufw
systemctl enable --now fstrim.timer
systemctl enable --now paccache.timer

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

echo
echo "=== Настройка очистки Snapper ==="

mkdir -p /etc/systemd/system/snapper-cleanup.timer.d
cat <<EOF > /etc/systemd/system/snapper-cleanup.timer.d/override.conf
[Timer]
OnCalendar=
OnCalendar=daily
Persistent=true
EOF

systemctl daemon-reload
systemctl restart snapper-cleanup.timer

echo
echo "=== Обновление GRUB ==="

if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo
echo "=== Bluetooth AIC8800 (опционально) ==="

read -rp "Установить драйвер AIC8800 Bluetooth? [y/N]: " INSTALL_AIC

if [[ "$INSTALL_AIC" =~ ^[Yy]$ ]]; then
    TMP_DIR=$(mktemp -d)
    chown -R "$REAL_USER":"$REAL_USER" "$TMP_DIR"

    sudo -u "$REAL_USER" git clone -b bluetooth https://github.com/shenmintao/aic8800d80.git "$TMP_DIR/aic8800d80"
    chmod +x "$TMP_DIR/aic8800d80/install.sh"

    echo "Будет выполнен install.sh от стороннего репозитория."
    read -rp "Продолжить? [y/N]: " CONFIRM

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        # Инсталлятору драйвера нужны рут-права
        cd "$TMP_DIR/aic8800d80" && ./install.sh
    fi
    rm -rf "$TMP_DIR"
fi

echo
echo "=== Настройка Bluetooth ==="

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

systemctl restart bluetooth

echo
echo "=== WirePlumber ==="

if command -v wireplumber >/dev/null 2>&1; then
    WP_DIR="$REAL_HOME/.config/wireplumber/wireplumber.conf.d"
    sudo -u "$REAL_USER" mkdir -p "$WP_DIR"

    cat > "$WP_DIR/51-bluetooth-fix.conf" <<EOF
monitor.bluez.properties = {
    bluez5.suspend-on-idle = false
}
EOF
    chown "$REAL_USER":"$REAL_USER" "$WP_DIR/51-bluetooth-fix.conf"
fi

echo
echo "=== Steam Workshop ==="

if [[ -n "$STEAM_USER" && -n "$STEAM_PASS" ]]; then
    WORKSHOP_ITEMS=(3666255797 3357973751 3636094866 3682353804 3700132468)
    STEAM_ARGS=(+login "$STEAM_USER" "$STEAM_PASS")

    for ITEM in "${WORKSHOP_ITEMS[@]}"; do
        STEAM_ARGS+=(+workshop_download_item 431960 "$ITEM")
    done
    STEAM_ARGS+=(+quit)
    sudo -u "$REAL_USER" steamcmd "${STEAM_ARGS[@]}"
    mkdir -p $REAL_HOME/wallpaper
    for ITEM in "${WORKSHOP_ITEMS[@]}"; do
      sudo -u "$REAL_USER" mv $REAL_HOME/.local/share/Steam/steamapps/workshop/content/431960/$ITEM $REAL_HOME/wallpaper/
    done
    echo "Oбои находятся в $REAL_HOME/wallpaper"
else
    echo "Steam Workshop пропущен"
fi

echo
echo "=== Конфигурация ~/.bashrc ==="

cat << 'EOF' > "$REAL_HOME/.bashrc"
# ==========================================================
# ~/.bashrc
# ==========================================================

[[ $- != *i* ]] && return

export PATH="$HOME/.local/bin:$PATH"
export VENV_PATH="${HOME}/.venv"
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth
export HISTIGNORE="ls:ll:pwd:exit:clear"
export EDITOR="nano"
export TERM="xterm-256color"

# Настройки Llama
LLAMA_SERVER_PATH="${HOME}/llama/llama-server"
LLAMA_KV_CACHE="q8_0"
LLAMA_TEMP="0.5"
LLAMA_CTX="50000"
BATCH_SIZE="3072"
REPEAT_PENALTY="1.1"
AGENT="false"
USE_SUDO="false"
THREADS="$(nproc)"
THREADS_BATCH="$(nproc)"
HOST="0.0.0.0"
PORT="8080"
REASONING="auto"
REASONING_BUDGET="-1"
DRAFT_MIN="0"
DRAFT_MAX="3"

shopt -s checkwinsize
shopt -s direxpand
shopt -s expand_aliases
shopt -s histappend

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
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit -m'
alias gp='git push'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate'
alias weather='curl wttr.in'
alias unpack='bsdtar -xf'

python() {
    if [[ -x "$VENV_PATH/bin/python" ]]; then
        "$VENV_PATH/bin/python" "$@"
    else
        command python "$@"
    fi
}

pip() {
    if [[ -x "$VENV_PATH/bin/pip" ]]; then
        "$VENV_PATH/bin/pip" "$@"
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
        echo "Использование:"
        echo "  fset <права> <файл>"
        echo "  fset <владелец> <права> <файл>"
        echo "  fset -R <владелец> <права> <папка>"
        return 1
    fi
}

extract() {
    if [[ ! -f "$1" ]]; then
        echo "File not found"
        return 1
    fi
    case "$1" in
        *.tar.bz2) tar xjf "$1" ;;
        *.tar.gz)  tar xzf "$1" ;;
        *.bz2)     bunzip2 "$1" ;;
        *.rar)     unrar x "$1" ;;
        *.gz)      gunzip "$1" ;;
        *.tar)     tar xf "$1" ;;
        *.tbz2)    tar xjf "$1" ;;
        *.tgz)     tar xzf "$1" ;;
        *.zip)     unzip "$1" ;;
        *.7z)      7z x "$1" ;;
        *) echo "Unsupported archive" ;;
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
        # Вместо "sudo command nano" используем прямой путь к бинарнику
        sudo /usr/bin/nano "$@"
    else
        command nano "$@"
    fi
}

clean() {
    echo "🧹 Начинаем очистку системы..."
    if pacman -Qdtq >/dev/null 2>&1; then
        pacman -Qdtq | xargs -r sudo pacman -Rns
    fi
    sudo paccache -rk1
    sudo journalctl --vacuum-time=3d
    rm -rf ~/.cache/*
    echo "🗑️ Удаление битых симлинков..."
    find ~/.local/bin -xtype l -delete 2>/dev/null
    systemctl --failed --all
}

rollback() {
    if [[ -z "${1:-}" ]]; then
        echo "❌ Error: Введите номер снимка (Пример: rollback 69)"
        return 1
    fi
    local target="$1"
    local last
    last=$(sudo snapper list | awk '$1 ~ /^[0-9]+$/ { id=$1 } END { print id }')

    if [[ ! "$last" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: Не удалось определить ID последнего снимка."
        return 1
    fi

    sudo snapper --ambit classic rollback "$target"
    local next=$((last + 2))
    echo "CONFIRM" | sudo snapper-rollback "$next"
}

nmem() {
    echo "═══════════════════════════════════════"
    echo "  📊 MEMORY STATUS"
    echo "═══════════════════════════════════════"
    echo ""
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

lrun() {
    local M_VAL="" MD_VAL="" MM_VAL="" EXTRA_ARGS=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -fold)
                local FOLD_PATH="${2%/}"
                if [[ ! -f "$FOLD_PATH/model.gguf" ]]; then
                    echo "❌ Error: 'model.gguf' не найден в папке '$FOLD_PATH'."
                    return 1
                fi
                M_VAL="$FOLD_PATH/model.gguf"
                [[ -f "$FOLD_PATH/mtp.gguf" ]] && MD_VAL="$FOLD_PATH/mtp.gguf"
                [[ -f "$FOLD_PATH/mmproj.gguf" ]] && MM_VAL="$FOLD_PATH/mmproj.gguf"
                shift 2 ;;
            -m) M_VAL="$2"; shift 2 ;;
            -md) MD_VAL="$2"; shift 2 ;;
            --mmproj|-mmproj) MM_VAL="$2"; shift 2 ;;
            *) EXTRA_ARGS+=("$1"); shift 1 ;;
        esac
    done
    if [[ -z "$M_VAL" ]]; then
        echo "❌ Error: Главная модель (-m или -fold) обязательна для запуска."
        return 1
    fi
    local CMD=()
    [[ "$USE_SUDO" = "true" ]] && CMD+=(sudo)
    CMD+=("$LLAMA_SERVER_PATH")
    [[ "$AGENT" = "true" ]] && CMD+=("--agent")
    CMD+=(
        "--spec-draft-n-max" "$DRAFT_MAX"
        "--spec-draft-n-min" "$DRAFT_MIN"
        "--metrics"
        "--reasoning" "$REASONING"
        "--reasoning-budget" "$REASONING_BUDGET"
        "--mlock"
        "--no-mmap"
        "-t" "$THREADS"
        "-tb" "$THREADS_BATCH"
        "--host" "$HOST"
        "--port" "$PORT"
        "-fa" "on"
        "-ctk" "$LLAMA_KV_CACHE"
        "-ctv" "$LLAMA_KV_CACHE"
        "-ngl" "all"
        "-ctkd" "$LLAMA_KV_CACHE"
        "-ctvd" "$LLAMA_KV_CACHE"
        "--temp" "$LLAMA_TEMP"
        "--repeat-penalty" "$REPEAT_PENALTY"
        "-ngld" "all"
        "--batch-size" "$BATCH_SIZE"
        "--alias" "model"
        "--ctx-size" "$LLAMA_CTX"
        "-m" "$M_VAL"
    )
    [[ -n "$MD_VAL" ]] && CMD+=("-md" "$MD_VAL")
    [[ -n "$MM_VAL" ]] && CMD+=("--mmproj" "$MM_VAL")
    CMD+=("${EXTRA_ARGS[@]}")
    echo "Запуск: ${CMD[*]}"
    "${CMD[@]}"
}

rainbow_user() {
    local user="${USER:-$(whoami)}"
    local colors=(31 33 32 36 34 35)
    local out="" i
    for ((i=0; i<${#user}; i++)); do
        local char="${user:$i:1}"
        local color="${colors[$((i % ${#colors[@]}))]}"
        # Используем чистый ASCII-код \033 без башевских \[ \]
        out+="\033[1;${color}m${char}"
    done
    out+="\033[0m"
    echo -e "$out"
}

# Генерируем имя один раз при входе в терминал
EXPORTED_USER=$(rainbow_user)

# Собираем чистый PS1. Ему больше не нужны костыли экранирования функций!
PS1="[\[\033[1;31m\]\h\[\033[0m\]@${EXPORTED_USER} \[\033[1;32m\]\W\[\033[0m\]]\$ "

[[ -r /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion
EOF

chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/.bashrc"
echo
echo "============================================================"
echo "Установка завершена успешно!"
echo "Пожалуйста:"
echo "  • Перелогиньтесь, чтобы применились права группы docker."
echo "  • Перезагрузите систему."
echo "============================================================"
source "$REAL_HOME/.bashrc"
