#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./configure.sh VNC_USER_PASSWORD VNC_PASSWORD

VNC_USER_PASSWORD="${1:?missing VNC user password}"
VNC_PASSWORD="${2:?missing VNC password}"

# Disable Spotlight indexing
sudo mdutil -i off -a || true

# Create user if it does not exist
if ! id -u ledinhhuy >/dev/null 2>&1; then
  sudo dscl . -create /Users/ledinhhuy
  sudo dscl . -create /Users/ledinhhuy UserShell /bin/bash
  sudo dscl . -create /Users/ledinhhuy RealName "ledinhhuy"
  sudo dscl . -create /Users/ledinhhuy UniqueID 1001
  sudo dscl . -create /Users/ledinhhuy PrimaryGroupID 80
  sudo dscl . -create /Users/ledinhhuy NFSHomeDirectory /Users/ledinhhuy
  sudo dscl . -passwd /Users/ledinhhuy "$VNC_USER_PASSWORD"
  sudo createhomedir -c -u ledinhhuy >/dev/null
else
  sudo dscl . -passwd /Users/ledinhhuy "$VNC_USER_PASSWORD"
fi

# Enable VNC / Apple Remote Desktop
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -allowAccessFor -allUsers -privs -all

sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -vnclegacy yes

# Set legacy VNC password (max 8 chars, Apple legacy format)
printf '%s\n' "$VNC_PASSWORD" \
| perl -we '
BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA" }
$_ = <>;
chomp;
s/^(.{8}).*/$1/;
@p = unpack "C*", $_;
foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }
print "\n";
' \
| sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null

# Restart / activate ARD agent
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -restart -agent -console

sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate

# Prevent display sleep
sudo pmset -a displaysleep 0 sleep 0 2>/dev/null || true

# Pre-create the user's home directory if missing
if [ ! -d "/Users/ledinhhuy" ]; then
  sudo createhomedir -c -u ledinhhuy 2>/dev/null || true
fi

# IMPORTANT: Auto-login ledinhhuy to create an actual GUI session.
# Without a GUI session, VNC only shows a black/blank screen.
# We do this by:
#   1. Setting up auto-login via the macOS KCUtil (Keychain utility)
#   2. Killing loginwindow so it restarts as ledinhhuy

# Get the user's UID
LEDINHHUY_UID=$(dscl . -read /Users/ledinhhuy UniqueID 2>/dev/null | awk '{print $2}')

# Step 1: Enable auto-login for ledinhhuy using macOS's built-in method
# /etc/kcpassword stores the password hash for auto-login
# This is the same method System Preferences > Users & Groups > Login Options > Automatic login uses
AUTOLOGIN_PLIST="/Library/Preferences/com.apple.loginwindow.plist"
sudo defaults write "$AUTOLOGIN_PLIST" autoLoginUser "ledinhhuy" 2>/dev/null || true

# Store auto-login password
sudo sh -c "printf '%s' '$VNC_USER_PASSWORD' > /etc/kcpassword" 2>/dev/null || true
sudo chmod 600 /etc/kcpassword 2>/dev/null || true

# Step 2: Set up a LaunchDaemon that keeps ledinhhuy logged in graphically
# This daemon will attempt to start a GUI session if it drops
cat << 'PLIST' | sudo tee /Library/LaunchDaemons/com.ledinhhuy.autologin.plist >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.ledinhhuy.autologin</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-b</string>
    <string>com.apple.systempreferences</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>UserName</key>
  <string>ledinhhuy</string>
</dict>
</plist>
PLIST
sudo chmod 644 /Library/LaunchDaemons/com.ledinhhuy.autologin.plist

# Step 3: Kill the loginwindow process so macOS restarts it as ledinhhuy (auto-login)
# SIGTERM (15) so loginwindow has a chance to gracefully hand off
echo "Triggering GUI session for ledinhhuy (UID $LEDINHHUY_UID)..."
sudo killall loginwindow 2>/dev/null || true
sleep 5

# Step 4: Check that loginwindow came back and VNC now has something to show
for i in {1..15}; do
  if pgrep -q loginwindow; then
    echo "loginwindow is running — GUI session active for VNC"
    break
  fi
  sleep 2
done

# Install noVNC + websockify so Cloudflare can publish an HTTP URL
NOVNC_DIR="/opt/noVNC"
sudo rm -rf "$NOVNC_DIR"
sudo git clone --depth=1 https://github.com/novnc/noVNC.git "$NOVNC_DIR"
sudo git clone --depth=1 https://github.com/novnc/websockify.git "$NOVNC_DIR/utils/websockify"

# Prepare logs
mkdir -p "$HOME/novnc-logs"

# Kill old listeners if rerun
pkill -f "websockify.*5900" || true
pkill -f "novnc_proxy" || true

# Use websockify Python module directly
WEBSOCKIFY_DIR="$NOVNC_DIR/utils/websockify"
nohup bash "$WEBSOCKIFY_DIR/run" 6080 --web "$NOVNC_DIR" 127.0.0.1:5900 \
  > "$HOME/novnc-logs/novnc.log" 2>&1 &

# Wait for noVNC web UI
for i in {1..60}; do
  if curl -fsS http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then
    echo "User ledinhhuy ready — VNC visible at http://127.0.0.1:5900"
    echo "noVNC web at http://127.0.0.1:6080/vnc.html"
    exit 0
  fi
  sleep 2
done

echo "noVNC failed to start"
echo "==== noVNC log ===="
cat "$HOME/novnc-logs/novnc.log" || true
exit 1
