#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./configure.sh VNC_USER_PASSWORD VNC_PASSWORD

VNC_USER_PASSWORD="${1:?missing VNC user password}"
VNC_PASSWORD="${2:?missing VNC password}"

# Disable Spotlight indexing
sudo mdutil -i off -a || true

# Create user if it does not exist
if ! id -u vncuser >/dev/null 2>&1; then
  sudo dscl . -create /Users/vncuser
  sudo dscl . -create /Users/vncuser UserShell /bin/bash
  sudo dscl . -create /Users/vncuser RealName "VNC User"
  sudo dscl . -create /Users/vncuser UniqueID 1001
  sudo dscl . -create /Users/vncuser PrimaryGroupID 80
  sudo dscl . -create /Users/vncuser NFSHomeDirectory /Users/vncuser
  sudo dscl . -passwd /Users/vncuser "$VNC_USER_PASSWORD"
  sudo createhomedir -c -u vncuser >/dev/null
else
  sudo dscl . -passwd /Users/vncuser "$VNC_USER_PASSWORD"
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

# Install noVNC + websockify so Cloudflare can publish an HTTP URL
brew update
brew install python3

# Clone noVNC directly from GitHub (removed from Homebrew)
# websockify bundled with noVNC by cloning into utils/
NOVNC_DIR="/opt/noVNC"
if [ ! -d "$NOVNC_DIR" ]; then
  sudo git clone --depth=1 https://github.com/novnc/noVNC.git "$NOVNC_DIR"
  sudo git clone --depth=1 https://github.com/novnc/websockify.git "$NOVNC_DIR/utils/websockify"
fi

# Create a wrapper command so novnc_proxy is always findable
NOVNC_PROXY="$NOVNC_DIR/utils/novnc_proxy"

# Prepare logs
mkdir -p "$HOME/novnc-logs"

# Kill old listeners if rerun
pkill -f "websockify.*5900" || true
pkill -f "novnc_proxy" || true

# Use websockify Python module directly (websockify/run is a bash script)
# websockify serves noVNC web UI on port 6080 and proxies WebSocket to VNC 5900
WEBSOCKIFY_DIR="$NOVNC_DIR/utils/websockify"
cd "$WEBSOCKIFY_DIR" && nohup bash ./run 6080 --web "$NOVNC_DIR" 127.0.0.1:5900 \
  > "$HOME/novnc-logs/novnc.log" 2>&1 &
cd - >/dev/null

# Wait for noVNC web UI
for i in {1..60}; do
  if curl -fsS http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then
    echo "noVNC is listening on http://127.0.0.1:6080/vnc.html"
    exit 0
  fi
  sleep 2
done

echo "noVNC failed to start"
echo "==== noVNC log ===="
cat "$HOME/novnc-logs/novnc.log" || true
exit 1
