#!/usr/bin/env bash
# ==============================================================================
# OneDrive Daemon - Guided Interactive Installer
# ==============================================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/onedrive_daemon"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/onedrive.service"

echo ""
echo "======================================================================"
echo "           OneDrive / SharePoint Daemon - Installation Guide          "
echo "======================================================================"
echo ""

# ------------------------------------------------------------------------------
# 1. Verify Active Python Virtual Environment
# ------------------------------------------------------------------------------
if [ -z "$VIRTUAL_ENV" ]; then
    echo "[-] Error: No active Python virtual environment detected."
    echo ""
    echo "    Please create and activate a virtual environment before running"
    echo "    this installer, as described in the README:"
    echo ""
    echo "    Using uv (recommended):"
    echo "      uv sync"
    echo "      source .venv/bin/activate"
    echo ""
    echo "    Using standard python venv:"
    echo "      python3 -m venv .venv"
    echo "      source .venv/bin/activate"
    echo "      pip install -r requirements.txt"
    echo ""
    echo "    Once activated, re-run: ./install.sh"
    echo "======================================================================"
    exit 1
fi

VENV_PYTHON="$VIRTUAL_ENV/bin/python3"
if [ ! -x "$VENV_PYTHON" ]; then
    VENV_PYTHON="$VIRTUAL_ENV/bin/python"
fi

if [ ! -x "$VENV_PYTHON" ]; then
    echo "[-] Error: Python executable not found in $VIRTUAL_ENV/bin"
    exit 1
fi

echo "[+] Using active virtual environment: $VIRTUAL_ENV"

# ------------------------------------------------------------------------------
# 2. Check System Prerequisites
# ------------------------------------------------------------------------------
echo ""
echo "[*] Checking system prerequisites..."

MISSING_DEPS=()
if ! command -v rclone &>/dev/null; then
    MISSING_DEPS+=("rclone")
fi

if ! command -v fusermount &>/dev/null && ! command -v fusermount3 &>/dev/null; then
    MISSING_DEPS+=("fuse3 (fusermount)")
fi

if ! command -v notify-send &>/dev/null; then
    MISSING_DEPS+=("libnotify-bin (notify-send)")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "[!] Warning: The following system tools are missing:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "    - $dep"
    done
    echo ""
    echo "    On Ubuntu / Debian, you can install them with:"
    echo "      sudo apt update && sudo apt install -y rclone fuse3 libnotify-bin"
    echo ""
    read -r -p "Do you want to continue anyway? [y/N]: " continue_missing
    if [[ ! "$continue_missing" =~ ^[Yy]$ ]]; then
        echo "Aborting. Please install missing system packages and try again."
        exit 1
    fi
else
    echo "[+] All system prerequisites found (rclone, fusermount, notify-send)."
fi

# ------------------------------------------------------------------------------
# 3. Check Python Package Dependencies
# ------------------------------------------------------------------------------
echo ""
echo "[*] Checking Python dependencies in active virtual environment..."

if ! "$VENV_PYTHON" -c "import yaml" &>/dev/null; then
    echo "[!] PyYAML is not installed in $VIRTUAL_ENV."
    echo "    Installing PyYAML..."
    if command -v uv &>/dev/null; then
        uv pip install pyyaml --python "$VENV_PYTHON"
    else
        "$VENV_PYTHON" -m pip install pyyaml
    fi
fi

if ! "$VENV_PYTHON" -c "import playwright" &>/dev/null; then
    echo "[!] Playwright is not installed in $VIRTUAL_ENV."
    echo "    Installing Playwright..."
    if command -v uv &>/dev/null; then
        uv pip install playwright --python "$VENV_PYTHON"
    else
        "$VENV_PYTHON" -m pip install playwright
    fi
fi

# Check Playwright Firefox browser binary
echo "[*] Verifying Playwright browser binaries..."
PLAYWRIGHT_CHECK=$("$VENV_PYTHON" -c "
from playwright.sync_api import sync_playwright
try:
    with sync_playwright() as p:
        p.firefox.launch(headless=True)
    print('OK')
except Exception as e:
    print('MISSING')
" 2>/dev/null || echo "MISSING")

if [ "$PLAYWRIGHT_CHECK" != "OK" ]; then
    echo "[!] Playwright Firefox browser is not installed."
    read -r -p "Run 'playwright install firefox' now? [Y/n]: " install_browser
    if [[ ! "$install_browser" =~ ^[Nn]$ ]]; then
        echo "[*] Installing Playwright Firefox..."
        if [ -x "$VIRTUAL_ENV/bin/playwright" ]; then
            "$VIRTUAL_ENV/bin/playwright" install firefox
        else
            "$VENV_PYTHON" -m playwright install firefox
        fi
    else
        echo "[!] Note: You must run 'playwright install firefox' before the daemon can log in."
    fi
else
    echo "[+] Playwright Firefox is ready."
fi

# ------------------------------------------------------------------------------
# 4. Interactive Configuration Setup
# ------------------------------------------------------------------------------
normalize_url() {
    local raw="$1"
    "$VENV_PYTHON" -c "
import re, sys
from urllib.parse import urlparse
raw = sys.argv[1].strip().strip('\"\'')
raw = re.sub(r'^(?:OneDrive\s+web\s+URL\s*:\s*)', '', raw, flags=re.IGNORECASE).strip()
parsed = urlparse(raw)
if parsed.scheme and parsed.netloc:
    path = parsed.path
    match = re.match(r'^(.*?/personal/[^/?#]+)', path, re.IGNORECASE)
    if match:
        print(f'{parsed.scheme}://{parsed.netloc}{match.group(1).rstrip(\"/\")}/Documents')
        sys.exit(0)
    match_site = re.match(r'^(.*?/sites/[^/?#]+)', path, re.IGNORECASE)
    if match_site:
        print(f'{parsed.scheme}://{parsed.netloc}{match_site.group(1).rstrip(\"/\")}/Documents')
        sys.exit(0)
    clean_path = re.sub(r'/_layouts/.*$', '', path, flags=re.IGNORECASE).rstrip('/')
    if not clean_path.endswith('/Documents'):
        clean_path += '/Documents'
    print(f'{parsed.scheme}://{parsed.netloc}{clean_path}')
else:
    print(raw)
" "$raw"
}

echo ""
echo "======================================================================"
echo "                    Configuration Settings Setup                      "
echo "======================================================================"

# Read existing configuration if it exists
CURRENT_URL=""
CURRENT_REMOTE="onedrive"
CURRENT_MOUNT="~/OneDrive"
CURRENT_INTERVAL="120"
CURRENT_PROFILE="~/.config/onedrive_daemon/browser_profile"
CURRENT_RCLONE="~/.config/rclone/rclone.conf"

if [ -f "$CONFIG_FILE" ]; then
    echo "[*] Found existing configuration at: $CONFIG_FILE"
    CURRENT_URL=$("$VENV_PYTHON" -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('onedrive_url') or '')" 2>/dev/null || true)
    RAW_REMOTE=$("$VENV_PYTHON" -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('remote_name') or '')" 2>/dev/null || true)
    RAW_MOUNT=$("$VENV_PYTHON" -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('mount_point') or '')" 2>/dev/null || true)
    RAW_INTERVAL=$("$VENV_PYTHON" -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('check_interval_seconds') or '')" 2>/dev/null || true)
    RAW_PROFILE=$("$VENV_PYTHON" -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('browser_profile') or '')" 2>/dev/null || true)
    RAW_RCLONE=$("$VENV_PYTHON" -c "import yaml; cfg=yaml.safe_load(open('$CONFIG_FILE')) or {}; print(cfg.get('rclone_conf') or '')" 2>/dev/null || true)

    [ -n "$RAW_REMOTE" ] && CURRENT_REMOTE="$RAW_REMOTE"
    [ -n "$RAW_MOUNT" ] && CURRENT_MOUNT="$RAW_MOUNT"
    [ -n "$RAW_INTERVAL" ] && CURRENT_INTERVAL="$RAW_INTERVAL"
    [ -n "$RAW_PROFILE" ] && CURRENT_PROFILE="$RAW_PROFILE"
    [ -n "$RAW_RCLONE" ] && CURRENT_RCLONE="$RAW_RCLONE"
fi

CONFIRM_SETTINGS=false

while [ "$CONFIRM_SETTINGS" = false ]; do
    echo ""
    echo "--- Step 1: OneDrive / SharePoint Web URL ---"
    echo "Where to find your URL in OneDrive Online:"
    echo "  1. Log into your OneDrive Online account in your web browser."
    echo "  2. Click the Settings gear icon (⚙) in the top-right navigation bar."
    echo "  3. Click 'More settings' (or 'OneDrive settings' -> 'More settings')."
    echo "  4. Scroll down and click 'Diagnostic information'."
    echo "  5. Copy the 'OneDrive web URL' shown there, e.g.:"
    echo "     https://<tenant>-my.sharepoint.com/personal/<user>/_layouts/15/onedrive.aspx"
    echo ""
    echo "  (You can paste the diagnostic link directly; the installer will automatically"
    echo "   parse it into the required WebDAV '/Documents' endpoint)."
    echo ""

    if [ -n "$CURRENT_URL" ]; then
        echo "Currently stored URL: $CURRENT_URL"
        read -r -p "Enter new URL (or press [Enter] to keep current): " input_url
        if [ -n "$input_url" ]; then
            SELECTED_URL=$(normalize_url "$input_url")
            echo "[+] Parsed endpoint: $SELECTED_URL"
        else
            SELECTED_URL="$CURRENT_URL"
        fi
    else
        while [ -z "$SELECTED_URL" ]; do
            read -r -p "Enter OneDrive / SharePoint URL: " input_url
            if [ -n "$input_url" ]; then
                SELECTED_URL=$(normalize_url "$input_url")
                echo "[+] Parsed endpoint: $SELECTED_URL"
            else
                echo "[-] URL cannot be empty. Please provide your SharePoint/OneDrive URL."
            fi
        done
    fi

    echo ""
    echo "--- Step 2: Mount Point Directory ---"
    echo "Where OneDrive will appear in your local file manager."
    read -r -p "Mount Point [$CURRENT_MOUNT]: " input_mount
    SELECTED_MOUNT="${input_mount:-$CURRENT_MOUNT}"

    echo ""
    echo "--- Step 3: Rclone Remote Name ---"
    echo "The name used for the rclone remote section."
    read -r -p "Remote Name [$CURRENT_REMOTE]: " input_remote
    SELECTED_REMOTE="${input_remote:-$CURRENT_REMOTE}"

    echo ""
    echo "--- Step 4: Health Check Interval ---"
    echo "Seconds between background session checks (120 = 2 minutes)."
    read -r -p "Check Interval in seconds [$CURRENT_INTERVAL]: " input_interval
    SELECTED_INTERVAL="${input_interval:-$CURRENT_INTERVAL}"

    echo ""
    read -r -p "Configure advanced paths (browser profile, rclone.conf)? [y/N]: " ask_advanced
    if [[ "$ask_advanced" =~ ^[Yy]$ ]]; then
        read -r -p "Browser Profile Directory [$CURRENT_PROFILE]: " input_profile
        SELECTED_PROFILE="${input_profile:-$CURRENT_PROFILE}"

        read -r -p "Rclone Config File [$CURRENT_RCLONE]: " input_rclone
        SELECTED_RCLONE="${input_rclone:-$CURRENT_RCLONE}"
    else
        SELECTED_PROFILE="$CURRENT_PROFILE"
        SELECTED_RCLONE="$CURRENT_RCLONE"
    fi

    # Display summary
    echo ""
    echo "======================================================================"
    echo "                       Configuration Summary                          "
    echo "======================================================================"
    echo "  OneDrive URL:        $SELECTED_URL"
    echo "  Remote Name:         $SELECTED_REMOTE"
    echo "  Mount Point:         $SELECTED_MOUNT"
    echo "  Check Interval:      $SELECTED_INTERVAL seconds"
    echo "  Browser Profile:     $SELECTED_PROFILE"
    echo "  Rclone Config:       $SELECTED_RCLONE"
    echo "======================================================================"
    echo ""
    read -r -p "Save these settings and proceed? [Y/n/r] (r = re-enter settings): " review_choice

    if [[ "$review_choice" =~ ^[Rr]$ ]]; then
        # Update current values so re-prompt displays the newly typed entries
        CURRENT_URL="$SELECTED_URL"
        CURRENT_REMOTE="$SELECTED_REMOTE"
        CURRENT_MOUNT="$SELECTED_MOUNT"
        CURRENT_INTERVAL="$SELECTED_INTERVAL"
        CURRENT_PROFILE="$SELECTED_PROFILE"
        CURRENT_RCLONE="$SELECTED_RCLONE"
        SELECTED_URL=""
        echo "[*] Returning to settings inputs..."
    elif [[ "$review_choice" =~ ^[Nn]$ ]]; then
        echo "Installation aborted by user."
        exit 0
    else
        CONFIRM_SETTINGS=true
    fi
done

# ------------------------------------------------------------------------------
# 5. Write Configuration File
# ------------------------------------------------------------------------------
echo ""
echo "[*] Writing configuration to $CONFIG_FILE..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
# Generated by install.sh on $(date)
onedrive_url: "$SELECTED_URL"
remote_name: "$SELECTED_REMOTE"
mount_point: "$SELECTED_MOUNT"
check_interval_seconds: $SELECTED_INTERVAL
browser_profile: "$SELECTED_PROFILE"
rclone_conf: "$SELECTED_RCLONE"
EOF

chmod 600 "$CONFIG_FILE"
echo "[+] Configuration saved with secure permissions (chmod 600)."

# ------------------------------------------------------------------------------
# 6. Configure & Install Systemd User Service
# ------------------------------------------------------------------------------
echo ""
echo "[*] Setting up systemd user service..."
mkdir -p "$SYSTEMD_USER_DIR"

# Resolve expanded mount point for fusermount stop command
RESOLVED_MOUNT=$(eval echo "$SELECTED_MOUNT")

sed -e "s|@@PYTHON_PATH@@|$VENV_PYTHON|g" \
    -e "s|@@DAEMON_PATH@@|$REPO_DIR/onedrive_daemon.py|g" \
    -e "s|@@MOUNT_POINT@@|$RESOLVED_MOUNT|g" \
    "$REPO_DIR/onedrive.service.template" > "$SERVICE_FILE"

systemctl --user daemon-reload
echo "[+] Installed systemd user service: $SERVICE_FILE"

# ------------------------------------------------------------------------------
# 7. Enable & Start Service Prompt
# ------------------------------------------------------------------------------
echo ""
read -r -p "Enable and start onedrive.service now? [Y/n]: " start_service
if [[ ! "$start_service" =~ ^[Nn]$ ]]; then
    systemctl --user enable onedrive.service
    systemctl --user restart onedrive.service
    echo ""
    echo "[+] onedrive.service enabled and started!"
    echo "[*] Current service status:"
    systemctl --user --no-pager status onedrive.service || true
else
    echo ""
    echo "[*] You can enable and start the service later with:"
    echo "    systemctl --user enable --now onedrive.service"
fi

echo ""
echo "======================================================================"
echo "                     Installation Completed!                          "
echo "======================================================================"
echo "Helpful commands:"
echo "  Check status:       systemctl --user status onedrive.service"
echo "  View live logs:     journalctl --user -u onedrive.service -f"
echo "  Stop service:       systemctl --user stop onedrive.service"
echo "  Start service:      systemctl --user start onedrive.service"
echo "  Run standalone:     python3 onedrive_daemon.py"
echo "  Reconfigure:        ./install.sh"
echo "  Uninstall:          ./uninstall.sh"
echo "======================================================================"
echo ""

