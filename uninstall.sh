#!/usr/bin/env bash
# ==============================================================================
# OneDrive Daemon - Uninstaller
# ==============================================================================

set -e

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/onedrive_daemon"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/onedrive.service"
RCLONE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf"

echo ""
echo "======================================================================"
echo "                   OneDrive Daemon - Uninstaller                      "
echo "======================================================================"
echo ""
echo "This script will:"
echo "  1. Stop and disable the onedrive systemd user service."
echo "  2. Remove the systemd service file."
echo "  3. Unmount your OneDrive folder."
echo "  4. Optionally remove saved configuration and browser sessions."
echo "  5. Optionally remove the remote from rclone.conf."
echo ""

read -r -p "Are you sure you want to proceed with uninstallation? [y/N]: " confirm_uninstall
if [[ ! "$confirm_uninstall" =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Detect remote name and mount point if config file exists
REMOTE_NAME="onedrive"
MOUNT_POINT="$HOME/OneDrive"

if [ -f "$CONFIG_FILE" ]; then
    DETECTED_REMOTE=$(python3 -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('remote_name', ''))" 2>/dev/null || true)
    DETECTED_MOUNT=$(python3 -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('mount_point', ''))" 2>/dev/null || true)
    [ -n "$DETECTED_REMOTE" ] && REMOTE_NAME="$DETECTED_REMOTE"
    [ -n "$DETECTED_MOUNT" ] && MOUNT_POINT=$(eval echo "$DETECTED_MOUNT")
fi

echo ""
# 1. Stop & Disable systemd user service
if systemctl --user is-active --quiet onedrive.service 2>/dev/null; then
    echo "[*] Stopping onedrive.service..."
    systemctl --user stop onedrive.service 2>/dev/null || true
fi

if systemctl --user is-enabled --quiet onedrive.service 2>/dev/null; then
    echo "[*] Disabling onedrive.service..."
    systemctl --user disable onedrive.service 2>/dev/null || true
fi

# 2. Remove systemd service file
if [ -f "$SERVICE_FILE" ]; then
    echo "[*] Removing $SERVICE_FILE..."
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload
    systemctl --user reset-failed 2>/dev/null || true
    echo "[+] Systemd user service removed."
else
    echo "[-] No systemd service file found at $SERVICE_FILE."
fi

# 3. Unmount directory & stop running rclone mounts for this remote
echo "[*] Unmounting $MOUNT_POINT (if mounted)..."
fusermount -uz "$MOUNT_POINT" 2>/dev/null || true
pkill -f "rclone mount $REMOTE_NAME:" 2>/dev/null || true

# 4. Remove configuration and browser session data
if [ -d "$CONFIG_DIR" ]; then
    echo ""
    read -r -p "Remove configuration and browser session data in $CONFIG_DIR? [Y/n]: " purge_config
    if [[ ! "$purge_config" =~ ^[Nn]$ ]]; then
        rm -rf "$CONFIG_DIR"
        echo "[+] Removed $CONFIG_DIR"
    else
        echo "[*] Preserved $CONFIG_DIR"
    fi
fi

# 5. Remove rclone entry
if [ -f "$RCLONE_CONF" ]; then
    echo ""
    read -r -p "Remove [$REMOTE_NAME] remote entry from $RCLONE_CONF? [Y/n]: " purge_rclone
    if [[ ! "$purge_rclone" =~ ^[Nn]$ ]]; then
        python3 -c "
import configparser
conf = configparser.ConfigParser()
conf.read('$RCLONE_CONF')
if conf.has_section('$REMOTE_NAME'):
    conf.remove_section('$REMOTE_NAME')
    with open('$RCLONE_CONF', 'w') as f:
        conf.write(f, space_around_delimiters=False)
    print('[+] Removed remote [$REMOTE_NAME] from $RCLONE_CONF')
else:
    print('[-] Remote [$REMOTE_NAME] not found in $RCLONE_CONF')
" 2>/dev/null || echo "[-] Could not update $RCLONE_CONF automatically."
    else
        echo "[*] Kept [$REMOTE_NAME] remote entry in $RCLONE_CONF"
    fi
fi

echo ""
echo "======================================================================"
echo "                     Uninstallation Complete!                         "
echo "======================================================================"
echo ""

