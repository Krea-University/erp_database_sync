#!/usr/bin/env bash
# =============================================================================
#  deploy_ubuntu.sh  –  One-time Ubuntu Server deployment
#  Run as a user with sudo privileges (NOT as root directly)
#  Usage: bash deploy_ubuntu.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

# ── 1. Install Docker ─────────────────────────────────────────────────────────
info "Installing Docker …"
if ! command -v docker &>/dev/null; then
  sudo apt-get update -q
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -q
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo systemctl enable docker --now
  success "Docker installed."
else
  success "Docker already installed: $(docker --version)"
fi

# Add current user to docker group so no sudo needed
if ! groups "$USER" | grep -q docker; then
  sudo usermod -aG docker "$USER"
  warn "Added '$USER' to docker group. A new shell session is needed for group to take effect."
  warn "After this script finishes, run:  newgrp docker  OR log out and back in."
fi

# ── 2. Create log/backup directories ─────────────────────────────────────────
info "Creating /var/erp_sync directories …"
sudo mkdir -p /var/erp_sync/backups /var/erp_sync/logs
sudo chown -R "$USER:$USER" /var/erp_sync
success "Directories ready: /var/erp_sync/{backups,logs}"

# ── 3. Open UFW firewall port (only if UFW is active) ────────────────────────
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  info "UFW is active — adding rule for port 3306 …"
  sudo ufw allow 3306/tcp comment "MySQL Local Docker"
  success "UFW rule added for port 3306."
else
  warn "UFW not active — skipping firewall rule."
  warn "If you have a firewall, open port 3306 manually."
fi

# ── 4. Make scripts executable ────────────────────────────────────────────────
chmod +x "${SCRIPT_DIR}/setup.sh" "${SCRIPT_DIR}/sync.sh"
success "Scripts are executable."

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║       Ubuntu Deployment Ready                    ║${RESET}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}║${RESET}  Backups : /var/erp_sync/backups                 ${GREEN}║${RESET}"
echo -e "${GREEN}║${RESET}  Logs    : /var/erp_sync/logs                    ${GREEN}║${RESET}"
echo -e "${GREEN}║${RESET}  Port    : 3306 (UFW rule added if active)        ${GREEN}║${RESET}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${RESET}"
echo -e "${GREEN}║${RESET}  Next step:  bash setup.sh                        ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
warn "If you were added to the docker group, run 'newgrp docker' before setup.sh"
