#!/usr/bin/env bash
# =============================================================================
#  install_prerequisites.sh  –  Install all tools needed for ERP DB Sync
#
#  Supported:
#    Linux  – Ubuntu / Debian / Kali / Linux Mint / Pop!_OS
#    Linux  – CentOS / RHEL / Fedora / Amazon Linux / Rocky / AlmaLinux
#    macOS  – via Homebrew
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}── $* ──${RESET}"; }

is_installed() { command -v "$1" &>/dev/null; }

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
  elif [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
      ubuntu|debian|kali|linuxmint|pop) OS="debian" ;;
      centos|rhel|fedora|amzn|rocky|almalinux) OS="rhel" ;;
      *)
        error "Unsupported Linux distro: $ID"
        error "Supported: Ubuntu, Debian, CentOS, RHEL, Fedora, Amazon Linux, macOS"
        exit 1 ;;
    esac
  else
    error "Cannot detect OS. Supported: Ubuntu/Debian, CentOS/RHEL/Fedora, macOS."
    exit 1
  fi
  info "Detected OS: ${OS}"
}

# ── Privilege helper (must run AFTER detect_os) ───────────────────────────────
setup_sudo() {
  SUDO=""
  if [[ "$EUID" -ne 0 ]] && [[ "$OS" != "macos" ]]; then
    if command -v sudo &>/dev/null; then
      SUDO="sudo"
      info "Running as non-root — will use sudo where needed."
    else
      error "Not root and sudo not found. Re-run as root or install sudo."
      exit 1
    fi
  fi
}

# =============================================================================
#  INSTALLERS
# =============================================================================

# ── jq ────────────────────────────────────────────────────────────────────────
install_jq() {
  header "jq"
  if is_installed jq; then
    success "jq $(jq --version) already installed."
    return
  fi
  info "Installing jq …"
  case "$OS" in
    debian) $SUDO apt-get install -y jq ;;
    rhel)   $SUDO yum install -y jq 2>/dev/null || $SUDO dnf install -y jq ;;
    macos)  brew install jq ;;
  esac
  success "jq $(jq --version) installed."
}

# ── mysql-client (mysqldump) ──────────────────────────────────────────────────
install_mysql_client() {
  header "mysql-client / mysqldump"
  if is_installed mysqldump; then
    success "mysqldump already installed."
    return
  fi
  info "Installing MySQL client …"
  case "$OS" in
    debian)
      $SUDO apt-get install -y mysql-client 2>/dev/null \
        || $SUDO apt-get install -y default-mysql-client
      ;;
    rhel)
      $SUDO yum install -y mysql 2>/dev/null \
        || $SUDO dnf install -y mysql
      ;;
    macos)
      brew install mysql-client
      MYSQL_PREFIX="$(brew --prefix mysql-client)"
      if ! grep -q "mysql-client" "${HOME}/.zshrc" 2>/dev/null \
         && ! grep -q "mysql-client" "${HOME}/.bash_profile" 2>/dev/null; then
        echo "export PATH=\"${MYSQL_PREFIX}/bin:\$PATH\"" >> "${HOME}/.zshrc"
        warn "Added mysql-client to ~/.zshrc PATH. Run: source ~/.zshrc"
      fi
      export PATH="${MYSQL_PREFIX}/bin:${PATH}"
      ;;
  esac
  success "mysqldump installed."
}

# ── Python 3 + pip ────────────────────────────────────────────────────────────
install_python() {
  header "Python 3 + pip"
  if is_installed python3 && is_installed pip3; then
    success "python3 $(python3 --version 2>&1 | cut -d' ' -f2) + pip3 already installed."
    return
  fi
  info "Installing python3 and pip3 …"
  case "$OS" in
    debian) $SUDO apt-get install -y python3 python3-pip ;;
    rhel)   $SUDO yum install -y python3 python3-pip 2>/dev/null \
              || $SUDO dnf install -y python3 python3-pip ;;
    macos)  brew install python3 ;;
  esac
  success "python3 $(python3 --version 2>&1 | cut -d' ' -f2) installed."
}

# ── Flask (web dashboard) ─────────────────────────────────────────────────────
install_flask() {
  header "Flask (web dashboard)"
  if python3 -c "import flask" &>/dev/null 2>&1; then
    FLASK_VER=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
    success "Flask ${FLASK_VER} already installed."
    return
  fi
  info "Installing Flask …"
  REQ_FILE="${SCRIPT_DIR}/requirements.txt"
  if [[ -f "$REQ_FILE" ]]; then
    pip3 install -r "$REQ_FILE"
  else
    pip3 install "flask>=2.3,<4"
  fi
  FLASK_VER=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
  success "Flask ${FLASK_VER} installed."
}

# ── Docker ────────────────────────────────────────────────────────────────────
install_docker() {
  header "Docker"
  if is_installed docker; then
    success "Docker $(docker --version) already installed."
  else
    info "Installing Docker …"
    case "$OS" in
      debian)
        $SUDO apt-get install -y ca-certificates curl gnupg lsb-release
        $SUDO install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
          | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
          | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
        $SUDO apt-get update -q
        $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io
        ;;
      rhel)
        $SUDO yum install -y yum-utils 2>/dev/null \
          || $SUDO dnf install -y yum-utils
        $SUDO yum-config-manager \
          --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $SUDO yum install -y docker-ce docker-ce-cli containerd.io 2>/dev/null \
          || $SUDO dnf install -y docker-ce docker-ce-cli containerd.io
        ;;
      macos)
        warn "On macOS, install Docker Desktop manually:"
        warn "  https://docs.docker.com/desktop/install/mac-install/"
        warn "Skipping automatic Docker install on macOS."
        return
        ;;
    esac
    success "Docker installed: $(docker --version)"
  fi

  # Enable & start service; add user to docker group (Linux only)
  if [[ "$OS" != "macos" ]]; then
    $SUDO systemctl enable docker --now 2>/dev/null || true
    if ! groups "$USER" | grep -q docker; then
      $SUDO usermod -aG docker "$USER"
      warn "Added '$USER' to the docker group."
      warn "Log out and back in (or run: newgrp docker) for it to take effect."
    fi
  fi
}

# ── Docker Compose ────────────────────────────────────────────────────────────
install_docker_compose() {
  header "Docker Compose"

  # v2 plugin (preferred)
  if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose v2 plugin: $(docker compose version)"
    return
  fi

  # v1 standalone binary
  if is_installed docker-compose; then
    success "docker-compose standalone: $(docker-compose --version)"
    return
  fi

  info "Installing Docker Compose plugin …"
  case "$OS" in
    debian)
      $SUDO apt-get install -y docker-compose-plugin 2>/dev/null || true
      if ! docker compose version &>/dev/null 2>&1; then
        # Fallback: download standalone binary
        COMPOSE_VERSION=$(curl -fsSL \
          https://api.github.com/repos/docker/compose/releases/latest \
          | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
        $SUDO curl -fsSL \
          "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
          -o /usr/local/bin/docker-compose
        $SUDO chmod +x /usr/local/bin/docker-compose
      fi
      ;;
    rhel)
      $SUDO yum install -y docker-compose-plugin 2>/dev/null \
        || $SUDO dnf install -y docker-compose-plugin 2>/dev/null || true
      ;;
    macos)
      warn "Docker Compose comes bundled with Docker Desktop on macOS."
      return
      ;;
  esac

  if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose plugin: $(docker compose version)"
  elif is_installed docker-compose; then
    success "docker-compose standalone: $(docker-compose --version)"
  else
    error "Docker Compose installation failed. Install manually:"
    error "  https://docs.docker.com/compose/install/"
  fi
}

# ── Make scripts executable ───────────────────────────────────────────────────
make_executable() {
  header "Script permissions"
  local scripts=(
    "${SCRIPT_DIR}/setup.sh"
    "${SCRIPT_DIR}/sync.sh"
    "${SCRIPT_DIR}/start_api.sh"
    "${SCRIPT_DIR}/deploy_ubuntu.sh"
    "${SCRIPT_DIR}/install_prerequisites.sh"
  )
  for f in "${scripts[@]}"; do
    if [[ -f "$f" ]]; then
      chmod +x "$f"
      success "chmod +x $(basename "$f")"
    fi
  done
}

# =============================================================================
#  MAIN
# =============================================================================
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Krea Onererp — Prerequisites Installer             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# detect_os MUST run before setup_sudo (sudo helper references $OS)
detect_os

# Update package index once
if [[ "$OS" == "debian" ]]; then
  info "Updating apt package index …"
  setup_sudo
  $SUDO apt-get update -q
elif [[ "$OS" == "rhel" ]]; then
  info "Updating yum/dnf package index …"
  setup_sudo
  $SUDO yum makecache -q 2>/dev/null || $SUDO dnf makecache -q
elif [[ "$OS" == "macos" ]]; then
  setup_sudo
  if ! is_installed brew; then
    info "Installing Homebrew …"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew update -q
fi

install_jq
install_mysql_client
install_python
install_flask
install_docker
install_docker_compose
make_executable

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Installation Summary ──${RESET}"
echo ""

check_cmd() {
  local label="$1" cmd="$2"
  if is_installed "$cmd"; then
    echo -e "  ${GREEN}✔${RESET}  ${label}"
  else
    echo -e "  ${RED}✘${RESET}  ${label}  (not found in PATH)"
  fi
}

check_cmd "jq"        jq
check_cmd "mysqldump" mysqldump
check_cmd "python3"   python3
check_cmd "pip3"      pip3
check_cmd "docker"    docker

# Docker Compose: check v2 plugin first, then v1 binary
if docker compose version &>/dev/null 2>&1; then
  echo -e "  ${GREEN}✔${RESET}  Docker Compose  ($(docker compose version --short 2>/dev/null || docker compose version))"
elif is_installed docker-compose; then
  echo -e "  ${GREEN}✔${RESET}  docker-compose  (standalone)"
else
  echo -e "  ${RED}✘${RESET}  Docker Compose  (not found)"
fi

# Flask
if python3 -c "import flask" &>/dev/null 2>&1; then
  FLASK_VER=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
  echo -e "  ${GREEN}✔${RESET}  Flask ${FLASK_VER}"
else
  echo -e "  ${RED}✘${RESET}  Flask  (not installed)"
fi

echo ""
echo -e "${BOLD}── Next Steps ──${RESET}"
echo ""
info "  1.  cp .env.example .env && nano .env   ← configure credentials"
info "  2.  ./setup.sh                          ← bootstrap MySQL + register cron"
info "  3.  ./start_api.sh start                ← start web dashboard on :${API_PORT:-8080}"
echo ""
echo -e "${CYAN}  Dashboard:  http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${API_PORT:-8080}${RESET}"
echo ""
