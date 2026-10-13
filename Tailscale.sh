#!/bin/bash

# --- Initial Setup ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_NAME=$(basename "$SCRIPT_PATH")
CURR_TTY="/dev/tty1"
LOG="/tmp/ts_install.log"
LOG_VIEW="/tmp/ts_view.log"

exec > $CURR_TTY 2>&1
printf "\033c" > "$CURR_TTY"
export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Controller Setup (gptokeyb)
pkill -9 -f gptokeyb || true
if [ -f "/opt/inttools/gptokeyb" ]; then
    [[ -e /dev/uinput ]] && chmod 666 /dev/uinput 2>/dev/null || true
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
    /opt/inttools/gptokeyb -1 "$SCRIPT_NAME" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
fi

# --- Functions ---

ExitScript() {
    pkill -f "gptokeyb -1 $SCRIPT_NAME" || true
    printf "\033c\e[?25h" > "$CURR_TTY"
    exit 0
}
trap ExitScript EXIT SIGINT SIGTERM
printf "\e[?25l" > "$CURR_TTY"

# Show the last part of the log in a scrollable box (Up/Down to scroll)
ShowLog() {
    local TITLE="${1:-Log}"
    tail -n 30 "$LOG" > "$LOG_VIEW" 2>/dev/null
    [ -s "$LOG_VIEW" ] || echo "(log is empty)" > "$LOG_VIEW"
    dialog --title " $TITLE " --textbox "$LOG_VIEW" 20 76
}

# R36S has no RTC battery -> clock is often wrong -> SSL / apt errors.
SyncTime() {
    local NOW_YEAR
    NOW_YEAR=$(date +%Y)
    echo "== SyncTime: current date: $(date) ==" >> "$LOG"
    # Take the time from an HTTP Date header (-k because the cert check fails with a wrong clock)
    local HDR
    HDR=$(curl -skI --connect-timeout 8 --max-time 15 https://www.google.com 2>>"$LOG" \
          | grep -i '^date:' | head -n 1 | cut -d' ' -f2- | tr -d '\r')
    if [ -z "$HDR" ]; then
        HDR=$(curl -sI --connect-timeout 8 --max-time 15 http://www.google.com 2>>"$LOG" \
              | grep -i '^date:' | head -n 1 | cut -d' ' -f2- | tr -d '\r')
    fi
    if [ -n "$HDR" ]; then
        date -s "$HDR" >> "$LOG" 2>&1
        hwclock -w 2>/dev/null || true
        echo "SyncTime: new date: $(date)" >> "$LOG"
        return 0
    fi
    echo "SyncTime: could not get time from the internet (year=$NOW_YEAR)" >> "$LOG"
    return 1
}

# Make sure tailscaled is running. Falls back to userspace networking when there is no TUN.
EnsureDaemon() {
    if [ ! -e /dev/net/tun ]; then
        modprobe tun >> "$LOG" 2>&1 || true
        mkdir -p /dev/net
        [ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200 >> "$LOG" 2>&1 || true
        chmod 666 /dev/net/tun 2>/dev/null || true
    fi

    if [ ! -e /dev/net/tun ] || ! [ -c /dev/net/tun ]; then
        echo "No TUN device -> using userspace-networking" >> "$LOG"
        if [ -f /etc/default/tailscaled ]; then
            if grep -q '^FLAGS=' /etc/default/tailscaled; then
                sed -i 's|^FLAGS=.*|FLAGS="--tun=userspace-networking"|' /etc/default/tailscaled
            else
                echo 'FLAGS="--tun=userspace-networking"' >> /etc/default/tailscaled
            fi
        else
            echo 'FLAGS="--tun=userspace-networking"' > /etc/default/tailscaled
        fi
    fi

    systemctl enable tailscaled >> "$LOG" 2>&1 || true
    systemctl restart tailscaled >> "$LOG" 2>&1

    # Fallback if systemd can't start it
    if ! systemctl is-active --quiet tailscaled; then
        echo "systemctl failed -> starting tailscaled manually" >> "$LOG"
        mkdir -p /var/lib/tailscale /var/run/tailscale
        nohup tailscaled --tun=userspace-networking \
            --state=/var/lib/tailscale/tailscaled.state \
            --socket=/var/run/tailscale/tailscaled.sock >> "$LOG" 2>&1 &
    fi

    # Wait for the daemon socket
    local I=0
    while [ $I -lt 10 ]; do
        timeout 2s tailscale status >/dev/null 2>&1 && return 0
        # status returns non-zero when logged out but still means the daemon is up
        timeout 2s tailscale status 2>&1 | grep -qiE 'logged out|NeedsLogin|Tailscale is stopped' && return 0
        sleep 1
        I=$((I + 1))
    done
    return 1
}

ShowStatus() {
    if ! command -v tailscale &> /dev/null; then
        dialog --msgbox "Tailscale is not installed." 10 40
        return
    fi

    local TS_IP TS_STATUS
    TS_IP=$(timeout 3s tailscale ip -4 2>/dev/null)
    TS_STATUS=$(timeout 3s tailscale status --peers=false 2>&1)

    if [ -z "$TS_IP" ]; then
        dialog --msgbox "Tailscale is OFFLINE or UNLINKED.\n\n$TS_STATUS" 15 60
    else
        dialog --msgbox "Tailscale is ONLINE\n\nIP: $TS_IP\n\nStatus:\n$TS_STATUS" 15 60
    fi
}

LinkDevice() {
    dialog --infobox "Starting Tailscale and fetching Link URL..." 5 50

    if ! EnsureDaemon; then
        ShowLog "tailscaled did not start"
        return
    fi

    # Already linked?
    local EXIST_IP
    EXIST_IP=$(timeout 3s tailscale ip -4 2>/dev/null)
    if [ -n "$EXIST_IP" ]; then
        dialog --msgbox "Already linked.\n\nIP: $EXIST_IP" 10 45
        return
    fi

    rm -f /tmp/ts_auth
    tailscale up > /tmp/ts_auth 2>&1 &

    local COUNTER=0
    local AUTH_URL=""
    while [ $COUNTER -lt 20 ]; do
        AUTH_URL=$(grep -o 'https://login.tailscale.com/a/[^ ]*' /tmp/ts_auth 2>/dev/null | sed 's/[[:punct:]]$//' | head -n 1)
        [ -n "$AUTH_URL" ] && break
        sleep 1
        COUNTER=$((COUNTER + 1))
    done

    if [ -n "$AUTH_URL" ]; then
        dialog --colors --title " LINK YOUR DEVICE " \
               --msgbox "\nVisit this URL on your phone or PC:\n\n\Z1$AUTH_URL\Zn\n\nPress OK once you have authorized the device." 12 75
    else
        cp /tmp/ts_auth "$LOG" 2>/dev/null
        ShowLog "Could not get link URL"
    fi
    rm -f /tmp/ts_auth
}

InstallTailscale() {
    : > "$LOG"

    # 1) Fix the clock
    dialog --infobox "Step 1/4: Syncing system time..." 5 50
    SyncTime

    # 2) Disk space (need ~150 MB)
    local FREE_KB
    FREE_KB=$(df -Pk / | awk 'NR==2{print $4}')
    echo "Free space on /: ${FREE_KB} KB" >> "$LOG"
    if [ "${FREE_KB:-0}" -lt 150000 ]; then
        dialog --msgbox "Not enough free space on /.\n\nFree: $((FREE_KB / 1024)) MB, need ~150 MB." 10 50
        return
    fi

    # 3) Download installer (shows the real curl error)
    dialog --infobox "Step 2/4: Downloading installer..." 5 50
    rm -f /tmp/ts_install.sh
    if ! curl -fsSL --connect-timeout 15 --max-time 90 \
         -o /tmp/ts_install.sh https://tailscale.com/install.sh >> "$LOG" 2>&1; then
        echo "curl exit code: $?" >> "$LOG"
        ShowLog "Download failed"
        return
    fi

    # 4) Repair interrupted dpkg + prerequisites
    export DEBIAN_FRONTEND=noninteractive
    dialog --infobox "Step 3/4: Repairing package system and updating lists...\nThis may take a few minutes." 7 56
    echo "== dpkg --configure -a ==" >> "$LOG"
    dpkg --configure -a --force-confold >> "$LOG" 2>&1 || echo "WARNING: dpkg --configure -a returned an error" >> "$LOG"
    echo "== apt-get -f install ==" >> "$LOG"
    apt-get -f install -y -o Dpkg::Options::=--force-confold >> "$LOG" 2>&1 || echo "WARNING: apt-get -f install returned an error" >> "$LOG"
    echo "== apt-get update ==" >> "$LOG"
    apt-get update >> "$LOG" 2>&1 || echo "WARNING: apt-get update returned an error" >> "$LOG"
    apt-get install -y curl ca-certificates gnupg apt-transport-https >> "$LOG" 2>&1 || true

    # 5) Run installer
    dialog --infobox "Step 4/4: Installing Tailscale...\nThis may take a few minutes." 6 50
    sh /tmp/ts_install.sh >> "$LOG" 2>&1
    local RC=$?
    rm -f /tmp/ts_install.sh

    if [ $RC -ne 0 ] || ! command -v tailscale &> /dev/null; then
        echo "install.sh exit code: $RC" >> "$LOG"
        ShowLog "Install failed (code $RC)"
        return
    fi

    LinkDevice
}

UninstallTailscale() {
    dialog --yesno "Are you sure you want to completely remove Tailscale?" 10 45
    [ $? -ne 0 ] && return

    dialog --infobox "Removing Tailscale and configurations..." 3 45
    systemctl stop tailscaled 2>/dev/null
    pkill -f tailscaled 2>/dev/null
    apt-get remove -y tailscale 2>/dev/null
    rm -rf /var/lib/tailscale /etc/tailscale
    dialog --msgbox "Tailscale has been fully removed." 10 40
}

# --- Main Menu ---

while true; do
    MAIN_CHOICE=$(dialog --colors --backtitle "R36S Tailscale Manager by ThinhPhoenix" --title " MAIN MENU " \
        --menu "Select an option:" 18 55 9 \
        1 "Check Status / View IP" \
        2 "Install Tailscale" \
        3 "Link Device (Show URL)" \
        4 "Stop Tailscale Service" \
        5 "Start Tailscale Service" \
        6 "Fix System Time" \
        7 "View Last Log" \
        8 "Uninstall Tailscale" \
        9 "Exit" --output-fd 1)

    case "$MAIN_CHOICE" in
        1) ShowStatus ;;
        2) InstallTailscale ;;
        3)
            if ! command -v tailscale &> /dev/null; then
                dialog --msgbox "Tailscale is not installed." 8 40
            else
                : > "$LOG"
                LinkDevice
            fi
            ;;
        4)
            systemctl stop tailscaled
            pkill -f tailscaled 2>/dev/null
            dialog --infobox "Service Stopped." 3 30 ; sleep 1
            ;;
        5)
            : > "$LOG"
            if EnsureDaemon; then
                dialog --infobox "Service Started." 3 30 ; sleep 1
            else
                ShowLog "tailscaled did not start"
            fi
            ;;
        6)
            : > "$LOG"
            dialog --infobox "Syncing system time..." 3 40
            if SyncTime; then
                dialog --msgbox "Time updated:\n\n$(date)" 9 50
            else
                ShowLog "Time sync failed"
            fi
            ;;
        7) ShowLog "Last log" ;;
        8) UninstallTailscale ;;
        9|*) ExitScript ;;
    esac
done
