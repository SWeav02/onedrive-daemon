# OneDrive Daemon

An automated SharePoint / OneDrive FUSE mount and authentication monitor daemon for Linux.

> **Note**: This repository, its installation tooling, and packaging were generated with the assistance of **Gemini 3.8 Flash**.

---

## Overview

When accessing institutional or corporate Microsoft 365 OneDrive accounts protected by MFA (Duo, Microsoft Authenticator, or SSO), WebDAV tokens and SharePoint cookies (`FedAuth` and `rtFa`) periodically expire. Standard mount tools typically fail silently once session tokens expire.

**OneDrive Daemon** solves this by:
1. **Automated Rclone FUSE Mounting**: Mounts your OneDrive library to a local directory (default: `~/OneDrive`) with user permissions.
2. **Headless & Interactive Watchdog**: Periodically verifies session validity against SharePoint.
3. **MFA / SSO Token Refresh**: When tokens expire or are revoked, launches an interactive browser window via Playwright for you to complete MFA/SSO, extracts fresh `FedAuth`/`rtFa` session cookies, updates `rclone.conf`, and remounts seamlessly.
4. **Desktop Notifications**: Sends native Linux desktop notifications via `notify-send` when authentication is required or when reconnection succeeds.
5. **Systemd Integration**: Runs automatically on user login via a systemd user service.

---

### Why Standard Mounting Methods May Not Work

Most Linux OneDrive guides instruct you to set up an rclone remote of type `onedrive` using Microsoft Graph API / Azure AD OAuth. In university or enterprise environments, this standard route often fails due to strict organization policies:

- **Third-Party App Restrictions**: Many organizations disable user consent for third-party Azure AD enterprise applications. When trying to authenticate Rclone, you may encounter an *"Approval required"* or *"Need admin approval"* prompt blocking access.
- **Conditional Access Policies (CAP)**: Enterprise policies may require Intune-managed / compliant devices or block non-browser OAuth user agents on Linux.
- **Token Expiration Constraints**: Aggressive session lifetime and continuous access evaluation policies revoke headless refresh tokens.

> [!TIP]
> **Requesting IT Permissions:**
> If your institution's IT department is responsive and willing to accommodate Linux workstations, you can request that they register a dedicated Enterprise Application for Rclone in Microsoft Entra (Azure AD) with `Files.ReadWrite.All` delegated permissions, or approve Rclone's default Client ID. Providing your IT team with a custom Client ID and Secret allows standard rclone Graph API mounts.

When IT approval is unavailable or organizational policy restricts Graph API apps, **OneDrive Daemon** provides a reliable alternative: it uses SharePoint's native WebDAV endpoint coupled with an automated Playwright browser session. Because authentication occurs inside a genuine browser window (Firefox), it satisfies corporate Single Sign-On (SSO) and multi-factor prompts (Duo, Okta, Microsoft Authenticator) identically to logging in through the web portal.

---

## Prerequisites

Before running the installer, ensure the following system utilities are installed:

- **rclone**: Cloud storage sync and FUSE mounting tool
- **fuse3** (or **fuse**): Linux FUSE kernel module (`fusermount`)
- **libnotify-bin**: For desktop notification popups (`notify-send`)

On Debian / Ubuntu:
```bash
sudo apt update
sudo apt install -y rclone fuse3 libnotify-bin
```

On Fedora / RHEL:
```bash
sudo dnf install -y rclone fuse3 libnotify
```

On Arch Linux:
```bash
sudo pacman -S rclone fuse3 libnotify
```

> [!TIP]
> If you encounter `fusermount: option allow_other only allowed if 'user_allow_other' is set in /etc/fuse.conf`, edit `/etc/fuse.conf` as root and uncomment the line `user_allow_other`.

---

## Installation & Setup

### Step 1: Clone the Repository

```bash
git clone https://github.com/yourusername/onedrive_daemon.git
cd onedrive_daemon
```

### Step 2: Set Up Python Virtual Environment

Choose either **uv** (recommended for speed) or standard Python **venv**:

#### Option A: Using `uv` (Recommended)

```bash
# Automatically create virtual environment and sync dependencies from pyproject.toml
uv sync

# Activate it
source .venv/bin/activate
```

#### Option B: Using standard `pip` and `venv`

```bash
# Create virtual environment
python3 -m venv .venv

# Activate it
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

---

### Step 3: Run the Guided Installer

Ensure your virtual environment is activated (`source .venv/bin/activate`), then run:

```bash
./install.sh
```

The installer will:
1. Verify system tools and Python dependencies.
2. Check Playwright browser binaries and offer to install Firefox if needed.
3. Guide you through entering your configuration values (with explanations of where to find them).
4. Save your configuration to `~/.config/onedrive_daemon/config.yaml` with secure file permissions (`chmod 600`).
5. Generate and install the systemd user service unit (`~/.config/systemd/user/onedrive.service`).
6. Offer to enable and start the service immediately.

> [!NOTE]
> If you make a typo or need to re-run `./install.sh` later, the installer remembers all previously entered values. You can press `Enter` to retain any existing setting or input `r` at the summary confirmation prompt to adjust specific values without restarting from scratch.

---

## Finding Your OneDrive / SharePoint URL

Modern OneDrive Online interfaces typically do not display the WebDAV folder structure directly in the address bar. Instead, retrieve the canonical URL via OneDrive's diagnostic settings:

1. Open your web browser and sign in to **OneDrive Online** (e.g. through your institution or Microsoft 365 portal).
2. Click the **Settings gear icon** (⚙) in the top-right navigation header.
3. Click **More settings** (or **OneDrive settings** &rarr; **More settings**).
4. Scroll to the bottom of the page and click **Diagnostic information**.
5. Copy the **OneDrive web URL** displayed there.

**Example Diagnostic URL:**
```text
https://<tenant>-my.sharepoint.com/personal/<username>_<tenant_domain>/_layouts/15/onedrive.aspx
```

*Example for UNC Chapel Hill:*
`https://adminliveunc-my.sharepoint.com/personal/sweav_ad_unc_edu/_layouts/15/onedrive.aspx`

> [!TIP]
> You can paste the raw Diagnostic Information URL directly into `./install.sh`. The installer (and daemon) will automatically parse it and convert it into the required WebDAV documents endpoint:
> `https://<tenant>-my.sharepoint.com/personal/<username>_<tenant_domain>/Documents`

---

## Configuration Reference

Settings are stored in `~/.config/onedrive_daemon/config.yaml` (see [`config.example.yaml`](config.example.yaml) for a template):

```yaml
# Target SharePoint document library URL
onedrive_url: "https://<tenant>-my.sharepoint.com/personal/<user>_<domain>/Documents"

# Name of the rclone remote entry (default: onedrive)
remote_name: "onedrive"

# Local folder path where OneDrive will be mounted (default: ~/OneDrive)
mount_point: "~/OneDrive"

# Seconds between token health checks (default: 900 = 15 minutes)
check_interval_seconds: 900

# Persistent browser profile location for saved authentication
browser_profile: "~/.config/onedrive_daemon/browser_profile"

# Path to rclone config file (default: ~/.config/rclone/rclone.conf)
rclone_conf: "~/.config/rclone/rclone.conf"
```

### Environment Variable Overrides

All YAML settings can be overridden at runtime via environment variables:
- `ONEDRIVE_URL`
- `ONEDRIVE_REMOTE_NAME`
- `ONEDRIVE_MOUNT_POINT`
- `ONEDRIVE_CHECK_INTERVAL`
- `ONEDRIVE_BROWSER_PROFILE`
- `RCLONE_CONFIG`
- `ONEDRIVE_DAEMON_CONFIG` (custom path to `config.yaml`)

---

## Managing the Service

Once installed, manage the background daemon with standard `systemctl --user` commands:

```bash
# Check service status
systemctl --user status onedrive.service

# View live daemon logs
journalctl --user -u onedrive.service -f

# Restart daemon / remount
systemctl --user restart onedrive.service

# Stop daemon & unmount
systemctl --user stop onedrive.service

# Start daemon
systemctl --user start onedrive.service
```

### Running Standalone (Without Systemd)

You can also run the daemon directly in a terminal:

```bash
source .venv/bin/activate
python3 onedrive_daemon.py
```
Press `Ctrl+C` to cleanly unmount and terminate.

---

## Uninstallation

To completely remove the service, configuration, and mounts:

```bash
./uninstall.sh
```

The uninstaller will:
1. Stop and disable `onedrive.service`.
2. Remove the systemd service file and reload systemd.
3. Cleanly unmount your OneDrive mount point.
4. Prompt whether to delete `~/.config/onedrive_daemon` (configuration & browser credentials).
5. Prompt whether to remove the remote entry from `~/.config/rclone/rclone.conf`.

---

## Troubleshooting

### FUSE Permission Denied
If mounting fails with `fusermount: option allow_other only allowed if 'user_allow_other' is set in /etc/fuse.conf`:
```bash
sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf
```

### Headless Browser Authentication Display
If the browser window fails to appear during MFA prompts when running under systemd, verify your desktop session environment variables:
```bash
echo $WAYLAND_DISPLAY
echo $DISPLAY
```
The service unit includes `PassEnvironment=DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS` to pass display servers to the daemon.

### Resetting Saved Browser Login
To clear saved browser sessions and force a fresh browser login from scratch:
```bash
rm -rf ~/.config/onedrive_daemon/browser_profile
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.

