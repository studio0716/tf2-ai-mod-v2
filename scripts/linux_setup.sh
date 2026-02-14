#!/bin/bash
# =============================================================================
# TF2 AI Bot - Linux Setup Script
# Transforms a fresh Ubuntu 24.04 install into a fully autonomous TF2 AI bot.
# Idempotent: safe to run multiple times.
#
# Usage: bash ~/Dev/tf2_AI_mod/scripts/linux_setup.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$HOME/Dev/tf2_AI_mod"
TF2_APP_ID="1066780"
GAME_DIR="$HOME/.local/share/Steam/steamapps/common/Transport Fever 2"

echo "============================================"
echo " TF2 AI Bot - Autonomous Linux Setup"
echo "============================================"

# ------------------------------------------------------------------
# Phase 1: System packages + remote access
# ------------------------------------------------------------------
echo "[1/10] Installing system packages..."
sudo apt update
sudo apt install -y \
  nvidia-driver-550 xdotool git python3 curl \
  lib32gcc-s1 openssh-server

# Node 22+ (for OpenClaw)
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 22 ]; then
  echo "[1/10] Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt install -y nodejs
fi

# SteamCMD
if ! command -v steamcmd &>/dev/null; then
  echo "[1/10] Installing SteamCMD..."
  echo steam steam/question select "I AGREE" | sudo debconf-set-selections
  sudo apt install -y steamcmd
fi

# SSH
echo "[1/10] Enabling SSH..."
sudo systemctl enable --now ssh

# Tailscale
if ! command -v tailscale &>/dev/null; then
  echo "[1/10] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi
echo "[1/10] Starting Tailscale (log in via browser)..."
sudo tailscale up

# Sunshine
if ! command -v sunshine &>/dev/null; then
  echo "[1/10] Installing Sunshine..."
  sudo apt install -y sunshine
fi

# ------------------------------------------------------------------
# Phase 2: Clone repo (if not already present)
# ------------------------------------------------------------------
echo "[2/10] Checking repo..."
if [ ! -d "$REPO_DIR" ]; then
  echo "  Repo not found at $REPO_DIR."
  echo "  Clone it first, then re-run this script."
  echo "  e.g.: git clone <repo-url> $REPO_DIR"
  exit 1
fi
echo "  Repo found at $REPO_DIR"

# ------------------------------------------------------------------
# Phase 3: Install TF2 via SteamCMD
# ------------------------------------------------------------------
echo "[3/10] Installing Transport Fever 2 via SteamCMD..."
if [ ! -d "$GAME_DIR" ]; then
  read -p "Steam username: " STEAM_USER
  steamcmd +login "$STEAM_USER" \
    +force_install_dir "$GAME_DIR" \
    +app_update "$TF2_APP_ID" validate +quit
else
  echo "  TF2 already installed at $GAME_DIR"
fi

# ------------------------------------------------------------------
# Phase 4: Install the mod (symlink)
# ------------------------------------------------------------------
echo "[4/10] Installing mod symlink..."
MODS_DIR="$GAME_DIR/mods"
mkdir -p "$MODS_DIR"
ln -sfn "$REPO_DIR" "$MODS_DIR/AI_Optimizer_1"
echo "  Linked $REPO_DIR -> $MODS_DIR/AI_Optimizer_1"

# ------------------------------------------------------------------
# Phase 5: Transfer save game from Mac (optional)
# ------------------------------------------------------------------
echo "[5/10] Save game transfer (optional)..."
read -p "Mac hostname/IP to copy save from (Enter to skip): " MAC_HOST
if [ -n "$MAC_HOST" ]; then
  # Find local Steam userdata directory
  USERDATA_BASE="$HOME/.local/share/Steam/userdata"
  mkdir -p "$USERDATA_BASE"

  # Try to discover a user ID, or create a placeholder
  LOCAL_UID=$(ls "$USERDATA_BASE" 2>/dev/null | head -1)
  if [ -z "$LOCAL_UID" ]; then
    echo "  No Steam user ID found locally. Enter your Steam user ID:"
    read -p "  Steam user ID (numeric): " LOCAL_UID
  fi

  SAVE_DIR="$USERDATA_BASE/$LOCAL_UID/$TF2_APP_ID/local/save"
  mkdir -p "$SAVE_DIR"

  echo "  Copying saves from Mac..."
  scp -r "$MAC_HOST:~/Library/Application Support/Steam/userdata/*/$TF2_APP_ID/local/save/*" "$SAVE_DIR/" || \
    echo "  WARN: scp failed. Copy saves manually to $SAVE_DIR"
else
  echo "  Skipped."
fi

# ------------------------------------------------------------------
# Phase 6: Install OpenClaw
# ------------------------------------------------------------------
echo "[6/10] Installing OpenClaw..."
if ! command -v openclaw &>/dev/null; then
  sudo npm install -g openclaw@latest
fi
echo "  Running OpenClaw onboarding (connect Telegram, select Claude)..."
openclaw onboard --install-daemon || echo "  WARN: OpenClaw onboard failed. Run manually: openclaw onboard --install-daemon"

# ------------------------------------------------------------------
# Phase 7: Install OpenClaw TF2 skill
# ------------------------------------------------------------------
echo "[7/10] Installing OpenClaw TF2 skill..."
SKILL_DIR="$HOME/.openclaw/workspace/skills/tf2-orchestrator"
mkdir -p "$SKILL_DIR"
cp "$REPO_DIR/scripts/openclaw/SKILL.md" "$SKILL_DIR/"
echo "  Skill installed to $SKILL_DIR"

# ------------------------------------------------------------------
# Phase 8: Configure auto-login + X11
# ------------------------------------------------------------------
echo "[8/10] Configuring auto-login and X11..."
if [ -f /etc/gdm3/custom.conf ]; then
  sudo sed -i 's/^#\s*AutomaticLoginEnable.*/AutomaticLoginEnable=true/' /etc/gdm3/custom.conf
  sudo sed -i "s/^#\s*AutomaticLogin .*/AutomaticLogin=$(whoami)/" /etc/gdm3/custom.conf
  sudo sed -i 's/^#\s*WaylandEnable.*/WaylandEnable=false/' /etc/gdm3/custom.conf
  # Also handle uncommented lines (idempotent)
  sudo sed -i "s/^AutomaticLogin=.*/AutomaticLogin=$(whoami)/" /etc/gdm3/custom.conf
  sudo sed -i 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=true/' /etc/gdm3/custom.conf
  sudo sed -i 's/^WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf
  echo "  GDM3 configured for auto-login on X11."
else
  echo "  WARN: /etc/gdm3/custom.conf not found. Configure auto-login manually."
fi

# ------------------------------------------------------------------
# Phase 9: Install systemd services + watchdog
# ------------------------------------------------------------------
echo "[9/10] Installing systemd services..."
mkdir -p ~/.config/systemd/user

# OpenClaw gateway service
cat > ~/.config/systemd/user/openclaw.service << 'EOF'
[Unit]
Description=OpenClaw AI Gateway
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/openclaw gateway
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

# TF2 AI service
cat > ~/.config/systemd/user/tf2-ai.service << SVCEOF
[Unit]
Description=TF2 AI Autonomous System
After=graphical-session.target openclaw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 30
ExecStart=$REPO_DIR/scripts/tf2_supervisor.sh full-restart
ExecStop=$REPO_DIR/scripts/tf2_supervisor.sh stop
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
SVCEOF

# Sunshine game streaming service
cat > ~/.config/systemd/user/sunshine.service << 'EOF'
[Unit]
Description=Sunshine Game Streaming Server
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=5
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable openclaw.service tf2-ai.service sunshine.service

# Enable lingering so user services start at boot (before login)
loginctl enable-linger "$(whoami)"

# Watchdog cron: every 5 min
WATCHDOG_LINE="*/5 * * * * $REPO_DIR/scripts/tf2_watchdog.sh"
(crontab -l 2>/dev/null | grep -v "tf2_watchdog.sh"; echo "$WATCHDOG_LINE") | crontab -
echo "  Services installed and enabled."

# Make scripts executable
chmod +x "$REPO_DIR/scripts/tf2_supervisor.sh"
chmod +x "$REPO_DIR/scripts/tf2_watchdog.sh"

# ------------------------------------------------------------------
# Phase 10: Reboot
# ------------------------------------------------------------------
echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo "After reboot:"
echo "  - Ubuntu auto-logs in (X11)"
echo "  - OpenClaw gateway starts (Telegram connected)"
echo "  - TF2 launches + orchestrator starts (30s delay)"
echo "  - Watchdog cron checks every 5 min"
echo ""
echo "Remote access:"
echo "  - SSH:       ssh $(whoami)@$(hostname)"
echo "  - Moonlight: connect to this machine's IP via Moonlight app"
echo "  - Tailscale: ssh $(whoami)@$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')"
echo ""
read -p "Reboot now? [Y/n] " REBOOT_CONFIRM
if [[ "${REBOOT_CONFIRM:-Y}" =~ ^[Yy]$ ]]; then
  echo "Rebooting in 5 seconds..."
  sleep 5
  sudo reboot
else
  echo "Skipped reboot. Run 'sudo reboot' when ready."
fi
