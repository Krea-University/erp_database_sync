#!/usr/bin/env bash
# =============================================================================
#  install_prerequisites.sh  –  Install all tools needed for ERP DB Sync
#
#  Supported:
#    Linux  – Ubuntu / Debian / Kali
#    Linux  – CentOS / RHEL / Fedora / Amazon Linux
#    macOS  – via Homebrew
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── Already-installed check ───────────────────────────────────────────────────
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

# ── Privilege helper ──────────────────────────────────────────────────────────
SUDO=""
if [[ "$EUID" -ne 0 ]] && [[ "$OS" != "macos" ]]; then
  if command -v sudo &>/dev/null; then
    SUDO="sudo"
    info "Running as non-root – will use sudo where needed."
  else
    error "Not root and sudo not found. Re-run as root or install sudo."
    exit 1
  fi
fi

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
    success "mysqldump $(mysqldump --version | head -1) already installed."
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
      # Homebrew mysql-client is keg-only – add to PATH
      MYSQL_PREFIX="$(brew --prefix mysql-client)"
      if ! grep -q "mysql-client" "${HOME}/.zshrc" 2>/dev/null \
         && ! grep -q "mysql-client" "${HOME}/.bash_profile" 2>/dev/null; then
        echo "export PATH=\"${MYSQL_PREFIX}/bin:\$PATH\"" >> "${HOME}/.zshrc"
        warn "Added mysql-client to ~/.zshrc PATH. Run: source ~/.zshrc"
      fi
      export PATH="${MYSQL_PREFIX}/bin:${PATH}"
      ;;
  esac
  success "mysqldump installed: $(mysqldump --version | head -1)"
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

  # Start & enable service (Linux only)
  if [[ "$OS" != "macos" ]]; then
    $SUDO systemctl enable docker --now 2>/dev/null || true
    # Add current user to docker group so no sudo needed for docker commands
    if ! groups "$USER" | grep -q docker; then
      $SUDO usermod -aG docker "$USER"
      warn "Added '$USER' to the docker group."
      warn "Log out and back in (or run: newgrp docker) for group to take effect."
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

  # standalone docker-compose (v1/v2 binary)
  if is_installed docker-compose; then
    success "docker-compose standalone: $(docker-compose --version)"
    return
  fi

  info "Installing Docker Compose plugin …"
  case "$OS" in
    debian)
      $SUDO apt-get install -y docker-compose-plugin 2>/dev/null || true
      if ! docker compose version &>/dev/null 2>&1; then
        # Fallback: install standalone binary
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

# =============================================================================
#  MAIN
# =============================================================================
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Krea Onererp — Prerequisites Installer         ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

detect_os

# Update package index (Linux only, once)
if [[ "$OS" == "debian" ]]; then
  info "Updating apt package index …"
  $SUDO apt-get update -q
elif [[ "$OS" == "rhel" ]]; then
  info "Updating yum/dnf package index …"
  $SUDO yum makecache -q 2>/dev/null || $SUDO dnf makecache -q
elif [[ "$OS" == "macos" ]]; then
  if ! is_installed brew; then
    info "Installing Homebrew …"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew update -q
fi

install_jq
install_mysql_client
install_docker
install_docker_compose

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Installation Summary ──${RESET}"

check() {
  local label="$1" cmd="$2"
  if is_installed "$cmd"; then
    echo -e "  ${GREEN}✔${RESET}  ${label}"
  else
    echo -e "  ${RED}✘${RESET}  ${label}  (not found in PATH)"
  fi
}

check "jq"           jq
check "mysqldump"    mysqldump
check "docker"       docker
check "docker-compose / docker compose" docker-compose

echo ""
info "Next step:  ./setup.sh"
