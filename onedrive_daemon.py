#!/usr/bin/env python3
"""
===============================================================================
ONEDRIVE / SHAREPOINT AUTO-MOUNT & AUTHENTICATION MONITOR DAEMON
===============================================================================
WHAT THIS SCRIPT DOES:
  1. Runs in the background (or via systemd user service).
  2. Verifies SharePoint session validity against rclone.
  3. If expired or missing, triggers a desktop notification and launches a 
     browser window to refresh cookies (FedAuth/rtFa).
  4. Mounts the drive to the configured mount point (default: ~/OneDrive).
  5. Monitors health every check interval. If campus/tenant MFA revokes the token,
     it unmounts cleanly, notifies via desktop popup, and guides re-login.

CONFIGURATION:
  Loaded automatically from ~/.config/onedrive_daemon/config.yaml
  Run ./install.sh to configure or reconfigure.
===============================================================================
"""

import configparser
from datetime import datetime, timedelta, timezone
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse
import yaml
from playwright.sync_api import sync_playwright

# --- CONFIGURATION LOADER ---

def normalize_onedrive_url(raw_url: str) -> str:
    """Normalizes OneDrive/SharePoint URL (e.g. from Diagnostic Info) to WebDAV /Documents path."""
    raw = raw_url.strip().strip('"\'')
    raw = re.sub(r'^(?:OneDrive\s+web\s+URL\s*:\s*)', '', raw, flags=re.IGNORECASE).strip()
    parsed = urlparse(raw)
    if parsed.scheme and parsed.netloc:
        path = parsed.path
        match = re.match(r'^(.*?/personal/[^/?#]+)', path, re.IGNORECASE)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}{match.group(1).rstrip('/')}/Documents"
        match_site = re.match(r'^(.*?/sites/[^/?#]+)', path, re.IGNORECASE)
        if match_site:
            return f"{parsed.scheme}://{parsed.netloc}{match_site.group(1).rstrip('/')}/Documents"
        clean_path = re.sub(r'/_layouts/.*$', '', path, flags=re.IGNORECASE).rstrip('/')
        if not clean_path.endswith('/Documents'):
            clean_path += '/Documents'
        return f"{parsed.scheme}://{parsed.netloc}{clean_path}"
    return raw_url

def expand_path(p: str | Path) -> Path:
    """Expands ~ and environment variables to an absolute Path."""
    return Path(os.path.expandvars(os.path.expanduser(str(p)))).resolve()

def find_config_file() -> Path | None:
    """Locates the config file from environment or standard paths."""
    env_path = os.environ.get("ONEDRIVE_DAEMON_CONFIG")
    if env_path and Path(env_path).is_file():
        return Path(env_path)

    xdg_path = Path.home() / ".config" / "onedrive_daemon" / "config.yaml"
    if xdg_path.is_file():
        return xdg_path

    local_path = Path(__file__).resolve().parent / "config.yaml"
    if local_path.is_file():
        return local_path

    return None

def load_settings() -> dict:
    """Loads configuration with precedence: Environment variables > YAML config > Defaults."""
    config_file = find_config_file()
    file_cfg = {}
    if config_file:
        try:
            with open(config_file, "r") as f:
                loaded = yaml.safe_load(f)
                if isinstance(loaded, dict):
                    file_cfg = loaded
        except Exception as e:
            print(f"[!] Warning: Failed to parse {config_file}: {e}", file=sys.stderr)

    # 1. ONEDRIVE_URL
    raw_url = os.environ.get("ONEDRIVE_URL") or file_cfg.get("onedrive_url", "")
    if not raw_url:
        print("[!] Error: 'onedrive_url' is not configured.", file=sys.stderr)
        print("    Please run ./install.sh or edit ~/.config/onedrive_daemon/config.yaml", file=sys.stderr)
        send_notification(
            "OneDrive Daemon Error",
            "Configuration missing. Run ./install.sh to configure onedrive_url.",
            urgency="critical"
        )
        sys.exit(1)
    url = normalize_onedrive_url(raw_url)

    # 2. REMOTE_NAME
    remote = os.environ.get("ONEDRIVE_REMOTE_NAME") or file_cfg.get("remote_name", "onedrive")

    # 3. MOUNT_POINT
    raw_mount = os.environ.get("ONEDRIVE_MOUNT_POINT") or file_cfg.get("mount_point", "~/OneDrive")
    mount_point = expand_path(raw_mount)

    # 4. CHECK_INTERVAL_SECONDS
    raw_interval = os.environ.get("ONEDRIVE_CHECK_INTERVAL") or file_cfg.get("check_interval_seconds", 120)
    try:
        check_interval = int(raw_interval)
    except ValueError:
        check_interval = 120

    # 5. BROWSER_PROFILE
    raw_profile = (
        os.environ.get("ONEDRIVE_BROWSER_PROFILE")
        or file_cfg.get("browser_profile")
        or (Path.home() / ".config" / "onedrive_daemon" / "browser_profile")
    )
    browser_profile = expand_path(raw_profile)

    # 6. RCLONE_CONF
    raw_rclone = (
        os.environ.get("RCLONE_CONFIG")
        or file_cfg.get("rclone_conf")
        or (Path.home() / ".config" / "rclone" / "rclone.conf")
    )
    rclone_conf = expand_path(raw_rclone)

    return {
        "url": url,
        "remote": remote,
        "mount_point": mount_point,
        "check_interval": check_interval,
        "browser_profile": browser_profile,
        "rclone_conf": rclone_conf,
        "config_file": config_file,
    }


def send_notification(summary: str, body: str, urgency: str = "normal"):
    """Sends a native desktop notification via notify-send."""
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, "-a", "OneDrive Daemon", summary, body],
            check=False
        )
    except Exception as e:
        print(f"[!] Notification error: {e}", file=sys.stderr)


# Load global settings
SETTINGS = load_settings()
REMOTE_NAME = SETTINGS["remote"]
ONEDRIVE_URL = SETTINGS["url"]
MOUNT_POINT = SETTINGS["mount_point"]
RCLONE_CONF = SETTINGS["rclone_conf"]
BROWSER_PROFILE = SETTINGS["browser_profile"]
CHECK_INTERVAL_SECONDS = SETTINGS["check_interval"]


def is_authenticated() -> bool:
    """Tests whether rclone can list the remote without an auth failure."""
    res = subprocess.run(
        ["rclone", "lsd", f"{REMOTE_NAME}:", "--max-depth", "1"],
        capture_output=True,
        text=True
    )
    return res.returncode == 0


def refresh_cookies():
    """Opens browser context via Playwright, retrieves FedAuth/rtFa, and updates rclone.conf."""
    send_notification("OneDrive Authentication Needed", "Opening sign-in window. Please approve your login / MFA prompt.", "critical")
    print("[*] Launching browser to refresh SharePoint cookies...")

    fedauth = None
    rtfa = None

    BROWSER_PROFILE.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        context = p.firefox.launch_persistent_context(
            user_data_dir=str(BROWSER_PROFILE),
            headless=False
        )
        page = context.new_page()
        page.goto(ONEDRIVE_URL)

        # Wait up to 3 minutes for user to finish SSO / MFA
        start_time = time.time()
        while time.time() - start_time < 180:
            cookies = context.cookies()
            cookie_dict = {c["name"]: c["value"] for c in cookies}
            if "FedAuth" in cookie_dict:
                fedauth = cookie_dict["FedAuth"]
                rtfa = cookie_dict.get("rtFa", "")
                break
            time.sleep(2)

        context.close()

    if not fedauth:
        send_notification("OneDrive Login Failed", "Session timeout: FedAuth cookie was not acquired.", "critical")
        raise RuntimeError("Failed to obtain FedAuth cookie within timeout.")

    # Write updated config to rclone.conf
    RCLONE_CONF.parent.mkdir(parents=True, exist_ok=True)
    config = configparser.ConfigParser()
    if RCLONE_CONF.exists():
        config.read(RCLONE_CONF)

    cookie_val = f"FedAuth={fedauth}"
    if rtfa:
        cookie_val += f"; rtFa={rtfa}"

    if not config.has_section(REMOTE_NAME):
        config.add_section(REMOTE_NAME)

    config.set(REMOTE_NAME, "type", "webdav")
    config.set(REMOTE_NAME, "url", ONEDRIVE_URL)
    config.set(REMOTE_NAME, "vendor", "sharepoint-ntlm")
    config.set(REMOTE_NAME, "headers", f'"Cookie","{cookie_val}"')

    with open(RCLONE_CONF, "w") as f:
        config.write(f, space_around_delimiters=False)

    print("[+] Successfully updated rclone.conf with fresh session tokens.")
    send_notification("OneDrive Connected", "Credentials successfully refreshed.", "normal")


def ensure_rclone_vendor():
    """Ensures rclone.conf uses vendor=sharepoint-ntlm so PROPFIND uses Depth:0 on files."""
    if not RCLONE_CONF.exists():
        return
    config = configparser.ConfigParser()
    config.read(RCLONE_CONF)
    if config.has_section(REMOTE_NAME):
        current_vendor = config.get(REMOTE_NAME, "vendor", fallback="")
        if current_vendor != "sharepoint-ntlm":
            config.set(REMOTE_NAME, "vendor", "sharepoint-ntlm")
            with open(RCLONE_CONF, "w") as f:
                config.write(f, space_around_delimiters=False)
            print(f"[+] Updated rclone vendor from '{current_vendor}' to 'sharepoint-ntlm' in {RCLONE_CONF}")


def parse_iso_timestamp(ts_str: str) -> datetime | None:
    """Parses an RFC3339/ISO-8601 timestamp string (including nanoseconds) into a UTC datetime."""
    if not ts_str:
        return None
    try:
        s = ts_str.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        # Python 3.11+ handles arbitrary fractional digits; normalize for older 3.10 if needed
        match = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?([+-]\d{2}:\d{2})$", s)
        if match:
            base, frac, tz = match.groups()
            frac6 = (frac or "").ljust(6, "0")[:6]
            s = f"{base}.{frac6}{tz}"
        return datetime.fromisoformat(s).astimezone(timezone.utc)
    except Exception:
        return None


def get_rclone_vfs_dirs() -> tuple[Path, Path]:
    """Returns the (vfs_dir, vfs_meta_dir) paths for the configured remote."""
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "rclone"
    return cache_root / "vfs" / REMOTE_NAME, cache_root / "vfsMeta" / REMOTE_NAME


def resolve_vfs_conflicts():
    """
    Scans rclone's local VFS cache for dirty files before mounting.
    If the remote file on OneDrive has a newer modification timestamp than the
    locally cached dirty copy, discards the older local cached copy so it never
    overwrites newer remote changes.
    """
    vfs_dir, vfs_meta_dir = get_rclone_vfs_dirs()
    if not vfs_meta_dir.is_dir():
        return

    discarded = []
    for meta_path in list(vfs_meta_dir.rglob("*")):
        if not meta_path.is_file():
            continue
        try:
            with open(meta_path, "r") as f:
                meta = json.load(f)
        except Exception:
            continue

        if not meta.get("Dirty"):
            continue

        local_mtime = parse_iso_timestamp(meta.get("ModTime", ""))
        if not local_mtime:
            continue

        rel_path = meta_path.relative_to(vfs_meta_dir).as_posix()
        res = subprocess.run(
            ["rclone", "lsjson", f"{REMOTE_NAME}:{rel_path}"],
            capture_output=True,
            text=True
        )
        if res.returncode != 0 or not res.stdout.strip():
            continue

        try:
            items = json.loads(res.stdout)
        except Exception:
            continue

        if not items or not isinstance(items, list):
            continue

        remote_mtime = parse_iso_timestamp(items[0].get("ModTime", ""))
        if not remote_mtime:
            continue

        # Allow 2 seconds tolerance for sub-second truncation on WebDAV Last-Modified
        if remote_mtime > local_mtime + timedelta(seconds=2):
            data_path = vfs_dir / rel_path
            print(
                f"[!] Conflict detected for '{rel_path}': "
                f"remote ({remote_mtime.isoformat()}) is newer than cached local copy ({local_mtime.isoformat()}). "
                f"Discarding older local cached copy."
            )
            try:
                meta_path.unlink(missing_ok=True)
            except OSError:
                pass
            try:
                data_path.unlink(missing_ok=True)
            except OSError:
                pass
            discarded.append(rel_path)

    if discarded:
        summary_list = ", ".join(Path(p).name for p in discarded[:3])
        if len(discarded) > 3:
            summary_list += f" (+{len(discarded) - 3} more)"
        send_notification(
            "OneDrive Conflict Prevented",
            f"Discarded older cached copy for newer remote file(s): {summary_list}",
            urgency="normal"
        )


def unmount_drive():
    """Unmounts the local FUSE mount cleanly, forcing detachment if busy."""
    if MOUNT_POINT.exists():
        # -u: unmount, -z: lazy unmount (detaches even if file manager is open)
        subprocess.run(["fusermount", "-uz", str(MOUNT_POINT)], capture_output=True)
        time.sleep(1)


def start_mount_process() -> subprocess.Popen:
    """Starts the rclone mount subprocess in the background."""
    MOUNT_POINT.mkdir(parents=True, exist_ok=True)
    unmount_drive()
    # Terminate any existing mount process specifically for this remote
    subprocess.run(["pkill", "-f", f"rclone mount {REMOTE_NAME}:"], capture_output=True)
    time.sleep(0.5)

    ensure_rclone_vendor()
    resolve_vfs_conflicts()

    cmd = [
        "rclone", "mount", f"{REMOTE_NAME}:", str(MOUNT_POINT),
        "--vfs-cache-mode", "writes",
        "--dir-cache-time", "15s",
        "--attr-timeout", "15s",
        "--vfs-cache-max-age", "15s",
        "--vfs-write-back", "2s",
        "--allow-other",
        "--uid", str(os.getuid()),
        "--gid", str(os.getgid()),
        "--dir-perms", "0775",
        "--file-perms", "0664"
    ]
    print(f"[*] Mounting OneDrive to {MOUNT_POINT}...")
    return subprocess.Popen(cmd)


def main():
    print(f"[*] OneDrive Daemon starting...")
    print(f"[*] Remote name:     {REMOTE_NAME}")
    print(f"[*] Mount point:     {MOUNT_POINT}")
    print(f"[*] Check interval:  {CHECK_INTERVAL_SECONDS}s")
    if SETTINGS["config_file"]:
        print(f"[*] Config source:   {SETTINGS['config_file']}")

    mount_proc = None

    def handle_exit(signum, frame):
        print("\n[*] Terminating daemon, unmounting...")
        if mount_proc and mount_proc.poll() is None:
            mount_proc.terminate()
        unmount_drive()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_exit)
    signal.signal(signal.SIGTERM, handle_exit)

    ensure_rclone_vendor()

    # Initial boot check: refresh if needed
    if not is_authenticated():
        print("[!] Credentials missing or expired. Starting interactive refresh...")
        refresh_cookies()

    mount_proc = start_mount_process()
    time.sleep(3)  # Allow mount to initialize

    # Monitoring loop
    while True:
        time.sleep(CHECK_INTERVAL_SECONDS)

        # 1. Check if mount process died
        if mount_proc.poll() is not None:
            print("[!] rclone mount process died. Checking token validity...")
            if not is_authenticated():
                send_notification(
                    "OneDrive Session Expired",
                    "Security credentials revoked. Please sign in again to restore access.",
                    "critical"
                )
                refresh_cookies()
            mount_proc = start_mount_process()
            continue

        # 2. Check if token expired while process is still up
        if not is_authenticated():
            print("[!] Token expired during runtime. Terminating mount and refreshing...")
            send_notification(
                "OneDrive Session Expired",
                "Your SharePoint session timed out. Click the prompt to sign in.",
                "critical"
            )
            if mount_proc and mount_proc.poll() is None:
                mount_proc.terminate()
            unmount_drive()
            refresh_cookies()
            mount_proc = start_mount_process()


if __name__ == "__main__":
    main()
