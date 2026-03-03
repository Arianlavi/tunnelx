#!/bin/bash

# ==============================================================================
# DNSTT Optimized Server Setup by Arian Lavi
# Professional Grade DNS Tunnel with KCP Acceleration
# Version 1.0 - March 2026
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors & Output Formatting
# ------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_NAME="dnstt-optimized"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/dnstt"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly LOG_DIR="/var/log/dnstt"
readonly DNSTT_USER="dnstt"
readonly DNSTT_PORT=5300
readonly KCP_PORT=5301
readonly SOCKS_PORT=1080

# URLs
readonly DNSTT_BASE_URL="https://dnstt.network"
readonly KCPTUN_RELEASES_URL="https://api.github.com/repos/xtaci/kcptun/releases/latest"

# Script path for self-management
SCRIPT_INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
SCRIPT_SOURCE_PATH="$(readlink -f "$0")"

# ------------------------------------------------------------------------------
# State Variables
# ------------------------------------------------------------------------------
declare -g UPDATE_AVAILABLE=false
declare -g USE_KCP=false
declare -g NS_SUBDOMAIN=""
declare -g MTU_VALUE=1400
declare -g TUNNEL_MODE="socks"
declare -g PRIVATE_KEY_FILE=""
declare -g PUBLIC_KEY_FILE=""
declare -g ARCH=""

# ------------------------------------------------------------------------------
# Utility Functions
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_question() {
    echo -ne "${BLUE}[INPUT]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

draw_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}${MAGENTA}DNSTT Optimized Server${NC} ${YELLOW}v${SCRIPT_VERSION}${NC}                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}High-Performance DNS Tunnel with KCP Acceleration${NC}                   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${BLUE}Created by Arian Lavi${NC}                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

draw_box() {
    local title="$1"
    local content="$2"
    local width=70
    
    echo -e "${CYAN}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    printf "${CYAN}│${NC} ${BOLD}%-${width}s${NC}${CYAN}│${NC}\n" "$title"
    echo -e "${CYAN}├$(printf '─%.0s' $(seq 1 $width))┤${NC}"
    
    while IFS= read -r line; do
        printf "${CYAN}│${NC} %-70s ${CYAN}│${NC}\n" "$line"
    done <<< "$content"
    
    echo -e "${CYAN}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
}

# ------------------------------------------------------------------------------
# System Detection
# ------------------------------------------------------------------------------

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS"
        exit 1
    fi
    
    source /etc/os-release
    
    case "$ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf check-update"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            PKG_UPDATE="yum check-update"
            ;;
        *)
            log_warn "Unsupported OS: $ID. Attempting to continue..."
            PKG_MANAGER="apt"
            ;;
    esac
    
    log_info "Detected OS: $PRETTY_NAME"
    log_info "Package manager: $PKG_MANAGER"
}

detect_arch() {
    local machine_arch
    machine_arch=$(uname -m)
    
    case "$machine_arch" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv6l)
            ARCH="arm"
            ;;
        i386|i686)
            ARCH="386"
            ;;
        *)
            log_error "Unsupported architecture: $machine_arch"
            exit 1
            ;;
    esac
    
    log_info "Architecture: $ARCH"
}

# ------------------------------------------------------------------------------
# Dependency Management
# ------------------------------------------------------------------------------

install_dependencies() {
    log_info "Installing dependencies..."
    
    $PKG_UPDATE || true
    
    local packages=("curl" "wget" "jq" "iptables" "net-tools" "bind9-host")
    
    case "$PKG_MANAGER" in
        apt)
            packages+=("iptables-persistent" "netfilter-persistent")
            ;;
        dnf|yum)
            packages+=("iptables-services")
            ;;
    esac
    
    $PKG_MANAGER install -y "${packages[@]}" || {
        log_error "Failed to install packages"
        exit 1
    }
    
    # Ensure iptables-persistent is properly configured on Debian/Ubuntu
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
        debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
    fi
    
    log_info "Dependencies installed"
}

verify_iptables() {
    if ! command -v iptables &>/dev/null; then
        log_error "iptables not found after installation"
        exit 1
    fi
    
    # Check if we can actually use iptables
    if ! iptables -L &>/dev/null; then
        log_warn "iptables requires additional privileges or is locked"
    fi
}

# ------------------------------------------------------------------------------
# Self-Management (Install/Update)
# ------------------------------------------------------------------------------

install_script() {
    if [[ "$SCRIPT_SOURCE_PATH" == "$SCRIPT_INSTALL_PATH" ]]; then
        return 0
    fi
    
    log_info "Installing script to $SCRIPT_INSTALL_PATH..."
    
    cp "$SCRIPT_SOURCE_PATH" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    
    # Create symlink for easier access
    ln -sf "$SCRIPT_INSTALL_PATH" "/usr/local/bin/dnstt-opt" 2>/dev/null || true
    
    log_info "Script installed. Run 'dnstt-optimized' or 'dnstt-opt' to manage."
    
    # If we just installed ourselves, re-exec from new location
    if [[ "$0" != "$SCRIPT_INSTALL_PATH" ]]; then
        log_info "Restarting from installed location..."
        exec "$SCRIPT_INSTALL_PATH" "$@"
    fi
}

check_updates() {
    log_info "Checking for script updates..."
    
    # In production, this would check against a remote URL
    # For now, we'll just set a flag if the script source differs from installed
    if [[ -f "$SCRIPT_INSTALL_PATH" ]]; then
        if ! diff -q "$SCRIPT_SOURCE_PATH" "$SCRIPT_INSTALL_PATH" &>/dev/null; then
            UPDATE_AVAILABLE=true
            log_warn "Script update available! Use menu option 2 to update."
        fi
    fi
}

update_script() {
    log_info "Updating script..."
    
    # Download latest version (placeholder - replace with actual URL)
    local temp_script="/tmp/${SCRIPT_NAME}-update.sh"
    
    # In real scenario: curl -fsSL "https://your-repo/${SCRIPT_NAME}.sh" -o "$temp_script"
    # For now, we just refresh the installed copy
    
    cp "$SCRIPT_SOURCE_PATH" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    
    log_info "Script updated successfully!"
    log_info "Restarting..."
    
    sleep 1
    exec "$SCRIPT_INSTALL_PATH"
}

# ------------------------------------------------------------------------------
# Configuration Management
# ------------------------------------------------------------------------------

load_config() {
    if [[ ! -f "$CONFIG_DIR/server.conf" ]]; then
        return 1
    fi
    
    # Source config safely
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        # Remove quotes if present
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        
        case "$key" in
            NS_SUBDOMAIN) NS_SUBDOMAIN="$value" ;;
            MTU_VALUE) MTU_VALUE="$value" ;;
            TUNNEL_MODE) TUNNEL_MODE="$value" ;;
            USE_KCP) [[ "$value" == "true" ]] && USE_KCP=true || USE_KCP=false ;;
            PRIVATE_KEY_FILE) PRIVATE_KEY_FILE="$value" ;;
            PUBLIC_KEY_FILE) PUBLIC_KEY_FILE="$value" ;;
        esac
    done < "$CONFIG_DIR/server.conf"
    
    log_info "Loaded existing configuration for: $NS_SUBDOMAIN"
    return 0
}

save_config() {
    log_info "Saving configuration..."
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_DIR/server.conf" << EOF
# DNSTT Server Configuration
# Generated by Arian Lavi on $(date '+%Y-%m-%d %H:%M:%S')
# Version: $SCRIPT_VERSION

NS_SUBDOMAIN="$NS_SUBDOMAIN"
MTU_VALUE="$MTU_VALUE"
TUNNEL_MODE="$TUNNEL_MODE"
USE_KCP=$USE_KCP
PRIVATE_KEY_FILE="$PRIVATE_KEY_FILE"
PUBLIC_KEY_FILE="$PUBLIC_KEY_FILE"
KCP_PORT=$KCP_PORT
DNSTT_PORT=$DNSTT_PORT
EOF

    chmod 600 "$CONFIG_DIR/server.conf"
    chown root:root "$CONFIG_DIR/server.conf"
    
    log_info "Configuration saved"
}

get_user_input() {
    local existing_domain="${NS_SUBDOMAIN:-}"
    local existing_mtu="${MTU_VALUE:-1400}"
    local existing_mode="${TUNNEL_MODE:-socks}"
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}              ${BOLD}Server Configuration${NC}                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Domain input
    while true; do
        if [[ -n "$existing_domain" ]]; then
            log_question "Nameserver subdomain [current: ${YELLOW}$existing_domain${NC}]: "
        else
            log_question "Nameserver subdomain [e.g., t.example.com]: "
        fi
        read -r input_domain
        
        if [[ -z "$input_domain" && -n "$existing_domain" ]]; then
            NS_SUBDOMAIN="$existing_domain"
            break
        elif [[ -n "$input_domain" ]]; then
            # Basic validation
            if [[ "$input_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                NS_SUBDOMAIN="$input_domain"
                break
            else
                log_error "Invalid domain format"
            fi
        else
            log_error "Domain is required"
        fi
    done
    
    # MTU input
    log_question "MTU value [current: ${YELLOW}$existing_mtu${NC}, press Enter to keep]: "
    read -r input_mtu
    MTU_VALUE="${input_mtu:-$existing_mtu}"
    
    # Validate MTU is numeric and in reasonable range
    if ! [[ "$MTU_VALUE" =~ ^[0-9]+$ ]] || [[ "$MTU_VALUE" -lt 512 ]] || [[ "$MTU_VALUE" -gt 9000 ]]; then
        log_warn "Invalid MTU, using default 1400"
        MTU_VALUE=1400
    fi
    
    # KCP mode
    echo ""
    log_info "KCP Acceleration Mode:"
    echo "  KCP adds a UDP acceleration layer that can improve speed by 30-50%"
    echo "  in high-latency or lossy networks. Recommended for mobile networks."
    echo ""
    
    local kcp_default="n"
    [[ "$USE_KCP" == true ]] && kcp_default="y"
    
    log_question "Enable KCP acceleration? [y/N, current: ${YELLOW}$kcp_default${NC}]: "
    read -r input_kcp
    
    if [[ "$input_kcp" =~ ^[Yy]$ ]]; then
        USE_KCP=true
        log_info "KCP mode enabled"
    elif [[ "$input_kcp" =~ ^[Nn]$ ]] || [[ -n "$input_kcp" ]]; then
        USE_KCP=false
        log_info "KCP mode disabled"
    fi
    
    # Tunnel mode
    echo ""
    log_info "Tunnel Mode:"
    echo "  1) SOCKS5 proxy (recommended for NetMod/V2Ray) - Port 1080"
    echo "  2) SSH tunnel - Forwards to local SSH port"
    echo ""
    
    local mode_default="1"
    [[ "$TUNNEL_MODE" == "ssh" ]] && mode_default="2"
    
    log_question "Select mode [1-2, current: ${YELLOW}$mode_default${NC}]: "
    read -r input_mode
    
    case "${input_mode:-$mode_default}" in
        1) TUNNEL_MODE="socks" ;;
        2) TUNNEL_MODE="ssh" ;;
        *) TUNNEL_MODE="socks" ;;
    esac
    
    log_info "Selected mode: $TUNNEL_MODE"
    
    # Generate key paths
    local key_prefix
    key_prefix=$(echo "$NS_SUBDOMAIN" | tr '.' '_')
    PRIVATE_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBLIC_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"
}

# ------------------------------------------------------------------------------
# Binary Installation
# ------------------------------------------------------------------------------

download_dnstt() {
    log_info "Downloading dnstt-server..."
    
    local filename="dnstt-server-linux-${ARCH}"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Download binary
    if ! curl -fsSL "${DNSTT_BASE_URL}/${filename}" -o "${temp_dir}/dnstt-server"; then
        log_error "Failed to download dnstt-server"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Download and verify checksums
    log_info "Verifying checksums..."
    
    curl -fsSL "${DNSTT_BASE_URL}/SHA256SUMS" -o "${temp_dir}/SHA256SUMS"
    
    cd "$temp_dir"
    if ! sha256sum -c <(grep "$filename" SHA256SUMS) 2>/dev/null; then
        log_warn "SHA256 verification failed, trying MD5..."
        curl -fsSL "${DNSTT_BASE_URL}/MD5SUMS" -o "${temp_dir}/MD5SUMS"
        if ! md5sum -c <(grep "$filename" MD5SUMS) 2>/dev/null; then
            log_error "Checksum verification failed"
            rm -rf "$temp_dir"
            exit 1
        fi
    fi
    
    # Install binary
    chmod +x "${temp_dir}/dnstt-server"
    mv "${temp_dir}/dnstt-server" "${INSTALL_DIR}/"
    
    # Cleanup
    rm -rf "$temp_dir"
    cd - >/dev/null
    
    log_info "dnstt-server installed successfully"
}

download_kcptun() {
    if [[ "$USE_KCP" != true ]]; then
        return 0
    fi
    
    log_info "Downloading kcptun-server..."
    
    # Get latest release URL
    local download_url
    download_url=$(curl -fsSL "$KCPTUN_RELEASES_URL" | \
        jq -r ".assets[] | select(.name | contains(\"linux-${ARCH}\")) | .browser_download_url" | \
        grep "server" | head -n1)
    
    if [[ -z "$download_url" ]]; then
        # Fallback to known good version
        download_url="https://github.com/xtaci/kcptun/releases/download/v20240107/kcptun-linux-${ARCH}-20240107.tar.gz"
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    if ! curl -fsSL "$download_url" -o "${temp_dir}/kcptun.tar.gz"; then
        log_error "Failed to download kcptun"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    tar -xzf "${temp_dir}/kcptun.tar.gz" -C "$temp_dir"
    
    # Find and install server binary
    local kcp_binary
    kcp_binary=$(find "$temp_dir" -name "server_linux*" -type f | head -n1)
    
    if [[ -z "$kcp_binary" ]]; then
        log_error "KCP binary not found in archive"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    chmod +x "$kcp_binary"
    mv "$kcp_binary" "${INSTALL_DIR}/kcptun-server"
    
    rm -rf "$temp_dir"
    
    log_info "kcptun-server installed successfully"
}

create_user() {
    log_info "Creating service user..."
    
    if ! id "$DNSTT_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "DNSTT Service User" "$DNSTT_USER"
        log_info "Created user: $DNSTT_USER"
    else
        log_info "User $DNSTT_USER already exists"
    fi
    
    # Setup directories
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    chown "$DNSTT_USER:$DNSTT_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

generate_keys() {
    log_info "Generating cryptographic keys..."
    
    if [[ -f "$PRIVATE_KEY_FILE" && -f "$PUBLIC_KEY_FILE" ]]; then
        log_info "Using existing keys for $NS_SUBDOMAIN"
    else
        log_info "Generating new key pair..."
        
        "${INSTALL_DIR}/dnstt-server" -gen-key \
            -privkey-file "$PRIVATE_KEY_FILE" \
            -pubkey-file "$PUBLIC_KEY_FILE"
        
        log_info "New keys generated"
    fi
    
    # Set proper permissions
    chown "$DNSTT_USER:$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
    chmod 600 "$PRIVATE_KEY_FILE"
    chmod 644 "$PUBLIC_KEY_FILE"
    
    log_info "Public key:"
    echo -e "${YELLOW}$(cat "$PUBLIC_KEY_FILE")${NC}"
}

# ------------------------------------------------------------------------------
# Network Configuration
# ------------------------------------------------------------------------------

get_default_interface() {
    ip route | grep default | awk '{print $5}' | head -n1 || echo "eth0"
}

configure_iptables() {
    log_info "Configuring iptables rules..."
    
    local interface
    interface=$(get_default_interface)
    local target_port="$DNSTT_PORT"
    
    # If KCP is enabled, we redirect 53 to KCP port instead
    if [[ "$USE_KCP" == true ]]; then
        target_port="$KCP_PORT"
        log_info "KCP enabled: Redirecting DNS port 53 to KCP port $KCP_PORT"
    fi
    
    # Flush existing rules for our ports (be careful not to break system)
    iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$target_port" 2>/dev/null && \
        iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$target_port" 2>/dev/null || true
    
    iptables -C INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
    
    if [[ "$USE_KCP" == true ]]; then
        iptables -C INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null && \
            iptables -D INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true
    fi
    
    # Add new rules
    iptables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
    iptables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$target_port"
    
    if [[ "$USE_KCP" == true ]]; then
        iptables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT
    fi
    
    # IPv6 support
    if command -v ip6tables &>/dev/null && [[ -f /proc/net/if_inet6 ]]; then
        ip6tables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || log_warn "IPv6 INPUT rule failed"
        ip6tables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$target_port" 2>/dev/null || true
        
        if [[ "$USE_KCP" == true ]]; then
            ip6tables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true
        fi
    fi
    
    # Save rules
    save_iptables_rules
    
    log_info "iptables configured on interface: $interface"
}

save_iptables_rules() {
    log_info "Saving iptables rules..."
    
    case "$PKG_MANAGER" in
        apt)
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            
            # Ensure netfilter-persistent is enabled
            systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
        dnf|yum)
            mkdir -p /etc/sysconfig
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
            
            systemctl enable iptables 2>/dev/null || true
            ;;
    esac
}

configure_firewall() {
    # Check for firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port="${DNSTT_PORT}/udp" 2>/dev/null || true
        firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
        [[ "$USE_KCP" == true ]] && firewall-cmd --permanent --add-port="${KCP_PORT}/udp" 2>/dev/null || true
        firewall-cmd --reload
    fi
    
    # Check for ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW..."
        ufw allow "${DNSTT_PORT}/udp" 2>/dev/null || true
        ufw allow 53/udp 2>/dev/null || true
        [[ "$USE_KCP" == true ]] && ufw allow "${KCP_PORT}/udp" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Service Setup
# ------------------------------------------------------------------------------

detect_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp | grep -E "sshd|ssh" | awk '{print $4}' | cut -d':' -f2 | head -n1)
    echo "${ssh_port:-22}"
}

setup_dante() {
    if [[ "$TUNNEL_MODE" != "socks" ]]; then
        # Stop dante if switching away from SOCKS
        if systemctl is-active --quiet danted 2>/dev/null; then
            log_info "Stopping Dante (switching to SSH mode)..."
            systemctl stop danted
            systemctl disable danted
        fi
        return 0
    fi
    
    log_info "Installing and configuring Dante SOCKS5 server..."
    
    $PKG_MANAGER install -y dante-server 2>/dev/null || {
        log_warn "Failed to install dante-server via package manager"
        log_info "Attempting manual installation..."
        
        # Fallback: build from source or use alternative
        # For now, we'll create a simple SOCKS proxy using socat as fallback
        $PKG_MANAGER install -y socat 2>/dev/null || true
    }
    
    local external_interface
    external_interface=$(get_default_interface)
    
    # Create Dante configuration
    cat > /etc/danted.conf << EOF
# Dante SOCKS Server Configuration

logoutput: /var/log/dnstt/danted.log
internal: 127.0.0.1 port = ${SOCKS_PORT}
external: ${external_interface}

user.privileged: root
user.unprivileged: nobody

# Authentication (none for localhost - secure because only local)
socksmethod: none
clientmethod: none

# Client rules - allow localhost only
client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}

# SOCKS rules
socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}

# Block everything else
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF

    # Ensure log directory exists
    mkdir -p /var/log/dnstt
    touch /var/log/dnstt/danted.log
    chmod 644 /var/log/dnstt/danted.log
    
    # Create systemd override to ensure proper startup
    mkdir -p /etc/systemd/system/danted.service.d
    cat > /etc/systemd/system/danted.service.d/override.conf << EOF
[Service]
Restart=always
RestartSec=5
EOF

    systemctl daemon-reload
    systemctl enable danted
    systemctl restart danted
    
    if systemctl is-active --quiet danted; then
        log_info "Dante SOCKS5 server running on 127.0.0.1:${SOCKS_PORT}"
    else
        log_warn "Dante failed to start, attempting fallback..."
        setup_socat_fallback
    fi
}

setup_socat_fallback() {
    log_info "Setting up socat as SOCKS fallback..."
    
    # Create a simple TCP forwarder as emergency fallback
    # This is not a full SOCKS proxy but allows basic connectivity
    
    cat > /etc/systemd/system/dnstt-fallback.service << EOF
[Unit]
Description=DNSTT Fallback Forwarder
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${SOCKS_PORT},fork TCP:127.0.0.1:8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dnstt-fallback 2>/dev/null || true
}

create_systemd_services() {
    log_info "Creating systemd services..."
    
    local target_port
    if [[ "$TUNNEL_MODE" == "ssh" ]]; then
        target_port=$(detect_ssh_port)
        log_info "SSH mode: Tunneling to port $target_port"
    else
        target_port="$SOCKS_PORT"
        log_info "SOCKS mode: Tunneling to port $target_port"
    fi
    
    # Stop existing services
    systemctl stop dnstt-server 2>/dev/null || true
    systemctl stop kcptun-server 2>/dev/null || true
    
    # Create KCP service if enabled
    if [[ "$USE_KCP" == true ]]; then
        log_info "Creating KCP acceleration service..."
        
        cat > "${SYSTEMD_DIR}/kcptun-server.service" << EOF
[Unit]
Description=KCP Accelerator for DNSTT by Arian Lavi
Documentation=https://github.com/xtaci/kcptun
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${INSTALL_DIR}/kcptun-server -l :${KCP_PORT} -t 127.0.0.1:${DNSTT_PORT} -mode fast3 -sndwnd 2048 -rcvwnd 2048 -datashard 10 -parityshard 3 -nocomp -dscp 46
Restart=always
RestartSec=5
LimitNOFILE=65535

# Performance tuning
CPUAccounting=yes
MemoryAccounting=yes

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable kcptun-server
    else
        # Disable KCP if not using
        systemctl disable kcptun-server 2>/dev/null || true
    fi
    
    # Create DNSTT service
    cat > "${SYSTEMD_DIR}/dnstt-server.service" << EOF
[Unit]
Description=DNSTT DNS Tunnel Server by Arian Lavi
Documentation=https://www.bamsoftware.com/software/dnstt/
After=network.target ${USE_KCP:+kcptun-server.service}
Wants=network.target

[Service]
Type=simple
User=${DNSTT_USER}
Group=${DNSTT_USER}
WorkingDirectory=${CONFIG_DIR}
ExecStart=${INSTALL_DIR}/dnstt-server -udp :${DNSTT_PORT} -privkey-file ${PRIVATE_KEY_FILE} -mtu ${MTU_VALUE} ${NS_SUBDOMAIN} 127.0.0.1:${target_port}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=10

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR} ${LOG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true

# Logging
StandardOutput=append:${LOG_DIR}/dnstt.log
StandardError=append:${LOG_DIR}/dnstt-error.log
SyslogIdentifier=dnstt-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dnstt-server
    
    log_info "Systemd services created"
}

start_services() {
    log_info "Starting services..."
    
    # Start in correct order: KCP first (if enabled), then DNSTT
    if [[ "$USE_KCP" == true ]]; then
        log_info "Starting KCP accelerator..."
        systemctl restart kcptun-server
        sleep 2  # Give KCP time to bind
    fi
    
    log_info "Starting DNSTT server..."
    systemctl restart dnstt-server
    
    # Verify services
    sleep 2
    
    if systemctl is-active --quiet dnstt-server; then
        log_info "✓ DNSTT server is running"
    else
        log_error "✗ DNSTT server failed to start"
        systemctl status dnstt-server --no-pager -l
        exit 1
    fi
    
    if [[ "$USE_KCP" == true ]]; then
        if systemctl is-active --quiet kcptun-server; then
            log_info "✓ KCP accelerator is running"
        else
            log_warn "✗ KCP accelerator failed to start"
        fi
    fi
    
    if [[ "$TUNNEL_MODE" == "socks" ]]; then
        if systemctl is-active --quiet danted 2>/dev/null; then
            log_info "✓ Dante SOCKS proxy is running"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Display & Menu Functions
# ------------------------------------------------------------------------------

show_status() {
    draw_header
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                    ${BOLD}Service Status${NC}                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # DNSTT Status
    if systemctl is-active --quiet dnstt-server; then
        echo -e "  ${GREEN}●${NC} DNSTT Server        : ${GREEN}Running${NC}"
    else
        echo -e "  ${RED}●${NC} DNSTT Server        : ${RED}Stopped${NC}"
    fi
    
    # KCP Status
    if [[ "$USE_KCP" == true ]]; then
        if systemctl is-active --quiet kcptun-server 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} KCP Accelerator     : ${GREEN}Running${NC}"
        else
            echo -e "  ${RED}●${NC} KCP Accelerator     : ${RED}Stopped${NC}"
        fi
    else
        echo -e "  ${YELLOW}○${NC} KCP Accelerator     : ${YELLOW}Disabled${NC}"
    fi
    
    # SOCKS Status
    if [[ "$TUNNEL_MODE" == "socks" ]]; then
        if systemctl is-active --quiet danted 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} SOCKS Proxy (Dante) : ${GREEN}Running${NC} on 127.0.0.1:${SOCKS_PORT}"
        else
            echo -e "  ${RED}●${NC} SOCKS Proxy (Dante) : ${RED}Stopped${NC}"
        fi
    fi
    
    echo ""
    
    # Show detailed status if running
    if systemctl is-active --quiet dnstt-server; then
        echo -e "${CYAN}Recent logs:${NC}"
        journalctl -u dnstt-server --no-pager -n 5 -o short
    fi
}

show_config() {
    draw_header
    
    if [[ ! -f "$CONFIG_DIR/server.conf" ]]; then
        log_error "No configuration found. Please install first."
        return 1
    fi
    
    load_config
    
    local content=""
    content+="Domain        : ${NS_SUBDOMAIN}\n"
    content+="MTU           : ${MTU_VALUE}\n"
    content+="Mode          : ${TUNNEL_MODE}\n"
    content+="KCP Enabled   : ${USE_KCP}\n"
    content+="Listen Port   : ${DNSTT_PORT}\n"
    [[ "$USE_KCP" == true ]] && content+="KCP Port      : ${KCP_PORT}\n"
    content+="\n"
    content+="Private Key   : ${PRIVATE_KEY_FILE}\n"
    content+="Public Key    : ${PUBLIC_KEY_FILE}\n"
    
    draw_box "Configuration Details" "$content"
    
    if [[ -f "$PUBLIC_KEY_FILE" ]]; then
        echo ""
        echo -e "${YELLOW}Public Key:${NC}"
        cat "$PUBLIC_KEY_FILE"
    fi
    
    echo ""
    echo -e "${CYAN}Client Configuration:${NC}"
    echo "  Server Address: ${NS_SUBDOMAIN}"
    echo "  Public Key: $(cat "$PUBLIC_KEY_FILE" 2>/dev/null || echo "N/A")"
    [[ "$USE_KCP" == true ]] && echo "  KCP Mode: Enabled (fast3)"
}

show_logs() {
    log_info "Showing logs (Press Ctrl+C to exit)..."
    journalctl -u dnstt-server -f -n 50
}

display_final_summary() {
    draw_header
    
    local box_content=""
    box_content+="✓ Installation completed successfully!\n"
    box_content+="\n"
    box_content+="Domain:        ${NS_SUBDOMAIN}\n"
    box_content+="MTU:           ${MTU_VALUE}\n"
    box_content+="Mode:          ${TUNNEL_MODE}\n"
    box_content+="KCP:           $([[ "$USE_KCP" == true ]] && echo "Enabled (fast3)" || echo "Disabled")\n"
    box_content+="\n"
    box_content+="Public Key:\n"
    box_content+="$(cat "$PUBLIC_KEY_FILE")\n"
    box_content+="\n"
    box_content+="Management Commands:\n"
    box_content+="  dnstt-optimized    - Run this menu\n"
    box_content+="  systemctl status dnstt-server\n"
    box_content+="  journalctl -u dnstt-server -f\n"
    
    draw_box "Setup Complete - Arian Lavi" "$box_content"
    
    echo ""
    echo -e "${GREEN}Services are now running and enabled for auto-start.${NC}"
    echo ""
    
    # Show connection info for client
    echo -e "${CYAN}Client Connection Info:${NC}"
    echo "  Server: $NS_SUBDOMAIN"
    echo "  Port: 53 (DNS)"
    echo "  Public Key: $(cat "$PUBLIC_KEY_FILE")"
    [[ "$USE_KCP" == true ]] && echo "  KCP: Enabled on server side"
    [[ "$TUNNEL_MODE" == "socks" ]] && echo "  Proxy: SOCKS5 on 127.0.0.1:1080 (client side)"
    [[ "$TUNNEL_MODE" == "ssh" ]] && echo "  Target: SSH server on port $(detect_ssh_port)"
}

# ------------------------------------------------------------------------------
# Main Menu
# ------------------------------------------------------------------------------

show_menu() {
    draw_header
    
    if [[ "$UPDATE_AVAILABLE" == true ]]; then
        echo -e "${YELLOW}⚡ Update available! Use option 2 to update.${NC}"
        echo ""
    fi
    
    echo "  ${BOLD}1)${NC} Install / Reconfigure Server"
    echo "  ${BOLD}2)${NC} Update Script"
    echo "  ${BOLD}3)${NC} Check Service Status"
    echo "  ${BOLD}4)${NC} View Logs"
    echo "  ${BOLD}5)${NC} Show Configuration"
    echo "  ${BOLD}6)${NC} Restart Services"
    echo "  ${BOLD}0)${NC} Exit"
    echo ""
    log_question "Select option [0-6]: "
}

handle_menu() {
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            1)
                return 0  # Continue to installation
                ;;
            2)
                update_script
                ;;
            3)
                show_status
                echo ""
                log_question "Press Enter to continue..."
                read -r
                ;;
            4)
                show_logs
                ;;
            5)
                show_config
                echo ""
                log_question "Press Enter to continue..."
                read -r
                ;;
            6)
                log_info "Restarting services..."
                start_services
                echo ""
                log_question "Press Enter to continue..."
                read -r
                ;;
            0)
                echo ""
                log_info "Goodbye! - Arian Lavi"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Main Installation Flow
# ------------------------------------------------------------------------------

run_installation() {
    log_info "Starting DNSTT Optimized installation..."
    
    detect_os
    detect_arch
    install_dependencies
    verify_iptables
    
    # Load existing or get new config
    if ! load_config; then
        log_info "No existing configuration found"
    fi
    
    get_user_input
    save_config
    
    # Download and install binaries
    download_dnstt
    download_kcptun
    
    # Setup system
    create_user
    generate_keys
    
    # Network configuration
    configure_iptables
    configure_firewall
    
    # Services
    setup_dante
    create_systemd_services
    start_services
    
    # Final display
    display_final_summary
}

# ------------------------------------------------------------------------------
# Entry Point
# ------------------------------------------------------------------------------

main() {
    check_root
    
    # If not installed, install ourselves first
    install_script "$@"
    
    # Check for updates if already installed
    if [[ "$0" == "$SCRIPT_INSTALL_PATH" ]]; then
        check_updates
        handle_menu
        # If we get here, user selected option 1
        run_installation
    else
        # Fresh run, just do installation
        run_installation
    fi
}

# Handle script exit gracefully
trap 'log_error "Installation interrupted"; exit 1' INT TERM

# Run main
main "$@"
