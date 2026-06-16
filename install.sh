#!/usr/bin/env bash
# =============================================================================
# install.sh — Dependency installer for recon_pipeline.sh
# Supports: Ubuntu/Debian, Kali Linux, macOS (Homebrew)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[*]${RESET} $*"; }
success() { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }

GO_TOOLS=(
    "subfinder:github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    "dnsx:github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    "httpx:github.com/projectdiscovery/httpx/cmd/httpx@latest"
    "katana:github.com/projectdiscovery/katana/cmd/katana@latest"
    "nuclei:github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
)

echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
  ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗
  ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║
  ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║
  ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║
  ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║
  ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝
BANNER
echo -e "  Dependency Installer${RESET}"
echo ""

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif grep -qi "kali" /etc/os-release 2>/dev/null; then
        echo "kali"
    elif grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        echo "debian"
    else
        echo "unknown"
    fi
}

OS=$(detect_os)
info "Detected OS: $OS"
echo ""

# ── Check / Install Go ────────────────────────────────────────────────────────
install_go() {
    if command -v go &>/dev/null; then
        GO_VER=$(go version | awk '{print $3}')
        success "Go already installed: $GO_VER"
        return
    fi

    info "Go not found. Installing..."
    local GO_VERSION="1.22.3"

    case "$OS" in
        macos)
            if command -v brew &>/dev/null; then
                brew install go
            else
                error "Homebrew not found. Install it from https://brew.sh then re-run."
            fi
            ;;
        debian|kali)
            local ARCH
            ARCH=$(dpkg --print-architecture)
            [[ "$ARCH" == "amd64" ]] && ARCH="amd64" || ARCH="arm64"
            local TARBALL="go${GO_VERSION}.linux-${ARCH}.tar.gz"
            wget -q "https://go.dev/dl/${TARBALL}" -O /tmp/${TARBALL}
            sudo rm -rf /usr/local/go
            sudo tar -C /usr/local -xzf /tmp/${TARBALL}
            echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.bashrc
            export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
            success "Go ${GO_VERSION} installed"
            ;;
        *)
            error "Unsupported OS. Install Go manually from https://go.dev/dl/"
            ;;
    esac
}

# ── Install nmap ──────────────────────────────────────────────────────────────
install_nmap() {
    if command -v nmap &>/dev/null; then
        success "nmap already installed: $(nmap --version | head -1)"
        return
    fi

    info "Installing nmap..."
    case "$OS" in
        macos)   brew install nmap ;;
        debian|kali) sudo apt-get install -y nmap ;;
        *) error "Install nmap manually: https://nmap.org/download.html" ;;
    esac
    success "nmap installed"
}

# ── Install Go-based tools ────────────────────────────────────────────────────
install_go_tools() {
    # Ensure ~/go/bin is in PATH
    export PATH=$PATH:$HOME/go/bin:/usr/local/go/bin

    for entry in "${GO_TOOLS[@]}"; do
        local name="${entry%%:*}"
        local pkg="${entry##*:}"

        if command -v "$name" &>/dev/null; then
            success "$name already installed"
            continue
        fi

        info "Installing $name..."
        go install "$pkg"
        if command -v "$name" &>/dev/null; then
            success "$name installed → $(command -v "$name")"
        else
            warn "$name installed but not in PATH. Add ~/go/bin to your PATH:"
            warn "  echo 'export PATH=\$PATH:\$HOME/go/bin' >> ~/.bashrc && source ~/.bashrc"
        fi
    done
}

# ── Add go/bin to PATH permanently ───────────────────────────────────────────
fix_path() {
    local shell_rc=""
    if [[ -f "$HOME/.zshrc" ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_rc="$HOME/.bashrc"
    fi

    if [[ -n "$shell_rc" ]]; then
        if ! grep -q 'go/bin' "$shell_rc"; then
            echo 'export PATH=$PATH:$HOME/go/bin:/usr/local/go/bin' >> "$shell_rc"
            info "Added ~/go/bin to $shell_rc"
        fi
    fi
}

# ── Verify all tools ──────────────────────────────────────────────────────────
verify_tools() {
    echo ""
    echo -e "${BOLD}── Verification ─────────────────────────────${RESET}"
    local all_ok=true
    for tool in subfinder dnsx httpx nmap katana nuclei; do
        if command -v "$tool" &>/dev/null; then
            success "$tool → $(command -v "$tool")"
        else
            warn "$tool NOT found in PATH"
            all_ok=false
        fi
    done

    echo ""
    if [[ "$all_ok" == "true" ]]; then
        echo -e "${GREEN}${BOLD}[✓] All dependencies installed. You're ready to run recon_pipeline.sh${RESET}"
    else
        echo -e "${YELLOW}[!] Some tools missing from PATH. Run: source ~/.bashrc${RESET}"
        echo -e "${YELLOW}    Then re-run this script to verify.${RESET}"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "$OS" in
    debian|kali)
        info "Updating apt..."
        sudo apt-get update -qq
        ;;
    macos)
        if ! command -v brew &>/dev/null; then
            error "Homebrew required. Install from https://brew.sh"
        fi
        ;;
esac

install_go
install_nmap
install_go_tools
fix_path
verify_tools
