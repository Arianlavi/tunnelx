#!/bin/bash
# -*- coding: utf-8 -*-

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="2.0"
readonly SCRIPT_NAME="dnstt-optimized"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/dnstt"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly LOG_DIR="/var/log/dnstt"
readonly DNSTT_USER="dnstt"
readonly DNSTT_PORT=5300
readonly KCP_PORT=5301
readonly SOCKS_PORT=1080

readonly DNSTT_BASE_URL="https://dnstt.network"
readonly KCPTUN_RELEASES_URL="https://api.github.com/repos/xtaci/kcptun/releases/latest"
readonly SCRIPT_URL="https://raw.githubusercontent.com/Arianlavi/tunnelx/main/dnstt.sh"

SCRIPT_INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
SCRIPT_SOURCE_PATH="$(readlink -f "$0")"

declare -g UPDATE_AVAILABLE=false
declare -g USE_KCP=false
declare -g NS_SUBDOMAIN=""
declare -g MTU_VALUE=1400
declare -g TUNNEL_MODE="socks"
declare -g PRIVATE_KEY_FILE=""
declare -g PUBLIC_KEY_FILE=""
declare -g ARCH=""
declare -g PKG_MANAGER=""

log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

log_question() {
    printf "${BLUE}[INPUT]${NC} %s" "$1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

draw_header() {
    clear
    printf "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  ${BOLD}${MAGENTA}DNSTT Optimized Server${NC} ${YELLOW}v${SCRIPT_VERSION}${NC}                                    ${CYAN}║${NC}\n"
    printf "${CYAN}║${NC}  ${GREEN}High-Performance DNS Tunnel with KCP Acceleration${NC}                   ${CYAN}║${NC}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
}

draw_box() {
    local title="$1"
    local content="$2"
    local width=70
    
    printf "${CYAN}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}\n"
    printf "${CYAN}│${NC} ${BOLD}%-${width}s${NC}${CYAN}│${NC}\n" "$title"
    printf "${CYAN}├$(printf '─%.0s' $(seq 1 $width))┤${NC}\n"
    
    while IFS= read -r line; do
        printf "${CYAN}│${NC} %-70s ${CYAN}│${NC}\n" "$line"
    done <<< "$content"
    
    printf "${CYAN}└$(printf '─%.0s' $(seq 1 $width))┘${NC}\n"
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS"
        exit 1
    fi
    
    source /etc/os-release
    
    case "$ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            ;;
        *)
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

install_dependencies() {
    log_info "Installing dependencies..."
    
    case "$PKG_MANAGER" in
        apt)
            apt update -qq
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
            apt install -y -qq curl wget jq iptables net-tools iptables-persistent dante-server socat
            ;;
        dnf|yum)
            $PKG_MANAGER install -y -q curl wget jq iptables iptables-services dante socat
            ;;
    esac
    
    log_info "Dependencies installed"
}

verify_iptables() {
    if ! command -v iptables &>/dev/null; then
        log_error "iptables not found"
        exit 1
    fi
}

install_script() {
    if [[ "$SCRIPT_SOURCE_PATH" == "$SCRIPT_INSTALL_PATH" ]]; then
        return 0
    fi
    
    log_info "Installing script to $SCRIPT_INSTALL_PATH..."
    
    cp "$SCRIPT_SOURCE_PATH" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    ln -sf "$SCRIPT_INSTALL_PATH" "/usr/local/bin/dnstt-opt" 2>/dev/null || true
    
    log_info "Script installed. Run 'dnstt-optimized' or 'dnstt-opt' to manage."
    
    if [[ "$0" != "$SCRIPT_INSTALL_PATH" ]]; then
        log_info "Restarting from installed location..."
        exec "$SCRIPT_INSTALL_PATH" "$@"
    fi
}

check_updates() {
    if [[ ! -f "$SCRIPT_INSTALL_PATH" ]]; then
        return 0
    fi
    
    log_info "Checking for updates..."
    
    local temp_script
    temp_script=$(mktemp)
    
    if curl -fsSL --connect-timeout 10 --max-time 15 "$SCRIPT_URL" -o "$temp_script" 2>/dev/null; then
        if ! diff -q "$SCRIPT_INSTALL_PATH" "$temp_script" &>/dev/null; then
            UPDATE_AVAILABLE=true
            log_warn "Update available! Use menu option 2."
        fi
    fi
    
    rm -f "$temp_script"
}

update_script() {
    log_info "Updating script..."
    
    local temp_script
    temp_script=$(mktemp)
    
    if ! curl -fsSL --connect-timeout 15 --max-time 30 "$SCRIPT_URL" -o "$temp_script"; then
        log_error "Failed to download update"
        rm -f "$temp_script"
        return 1
    fi
    
    if ! head -n1 "$temp_script" | grep -q "bash"; then
        log_error "Downloaded file is not a valid script"
        rm -f "$temp_script"
        return 1
    fi
    
    chmod +x "$temp_script"
    mv "$temp_script" "$SCRIPT_INSTALL_PATH"
    
    log_info "Update successful! Restarting..."
    sleep 1
    exec "$SCRIPT_INSTALL_PATH"
}

load_config() {
    if [[ ! -f "$CONFIG_DIR/server.conf" ]]; then
        return 1
    fi
    
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
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
}

get_user_input() {
    local existing_domain="${NS_SUBDOMAIN:-}"
    local existing_mtu="${MTU_VALUE:-1400}"
    local existing_mode="${TUNNEL_MODE:-socks}"
    
    echo ""
    printf "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}              ${BOLD}Server Configuration${NC}                          ${CYAN}║${NC}\n"
    printf "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    
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
    
    log_question "MTU value [current: ${YELLOW}$existing_mtu${NC}, press Enter to keep]: "
    read -r input_mtu
    MTU_VALUE="${input_mtu:-$existing_mtu}"
    
    if ! [[ "$MTU_VALUE" =~ ^[0-9]+$ ]] || [[ "$MTU_VALUE" -lt 512 ]] || [[ "$MTU_VALUE" -gt 9000 ]]; then
        log_warn "Invalid MTU, using default 1400"
        MTU_VALUE=1400
    fi
    
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
    
    local key_prefix
    key_prefix=$(echo "$NS_SUBDOMAIN" | tr '.' '_')
    PRIVATE_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.key"
    PUBLIC_KEY_FILE="${CONFIG_DIR}/${key_prefix}_server.pub"
}

download_dnstt() {
    log_info "Downloading dnstt-server..."
    
    local filename="dnstt-server-linux-${ARCH}"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    local attempt=1
    local max_attempts=3
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Download attempt $attempt/$max_attempts..."
        
        if curl -fsSL --connect-timeout 15 --max-time 60 \
            -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
            "${DNSTT_BASE_URL}/${filename}" \
            -o "${temp_dir}/dnstt-server" 2>/dev/null; then
            
            if [[ -s "${temp_dir}/dnstt-server" ]] && ! file "${temp_dir}/dnstt-server" | grep -q "HTML"; then
                log_info "Download successful"
                break
            fi
        fi
        
        log_warn "Attempt $attempt failed, retrying..."
        ((attempt++))
        sleep 3
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "Failed to download after $max_attempts attempts"
        log_error "URL: ${DNSTT_BASE_URL}/${filename}"
        
        if command -v wget &>/dev/null; then
            log_info "Trying wget..."
            if wget -q --timeout=30 -O "${temp_dir}/dnstt-server" "${DNSTT_BASE_URL}/${filename}" 2>/dev/null; then
                log_info "Wget succeeded"
            else
                rm -rf "$temp_dir"
                exit 1
            fi
        else
            rm -rf "$temp_dir"
            exit 1
        fi
    fi
    
    chmod +x "${temp_dir}/dnstt-server"
    mv "${temp_dir}/dnstt-server" "${INSTALL_DIR}/"
    rm -rf "$temp_dir"
    
    log_info "dnstt-server installed"
}

download_kcptun() {
    if [[ "$USE_KCP" != true ]]; then
        return 0
    fi
    
    log_info "Downloading kcptun-server..."
    
    local download_url
    download_url=$(curl -fsSL --connect-timeout 10 --max-time 15 "$KCPTUN_RELEASES_URL" 2>/dev/null | \
        jq -r ".assets[] | select(.name | contains(\"linux-${ARCH}\")) | .browser_download_url" | \
        grep "server" | head -n1) || true
    
    if [[ -z "$download_url" ]]; then
        download_url="https://github.com/xtaci/kcptun/releases/download/v20240107/kcptun-linux-${ARCH}-20240107.tar.gz"
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    if ! curl -fsSL --connect-timeout 15 --max-time 60 "$download_url" -o "${temp_dir}/kcptun.tar.gz" 2>/dev/null; then
        log_error "Failed to download kcptun"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    tar -xzf "${temp_dir}/kcptun.tar.gz" -C "$temp_dir"
    
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
    
    log_info "kcptun-server installed"
}

create_user() {
    log_info "Creating service user..."
    
    if ! id "$DNSTT_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "DNSTT Service" "$DNSTT_USER"
    fi
    
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    chown "$DNSTT_USER:$DNSTT_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

generate_keys() {
    log_info "Generating keys..."
    
    if [[ -f "$PRIVATE_KEY_FILE" && -f "$PUBLIC_KEY_FILE" ]]; then
        log_info "Using existing keys"
    else
        "${INSTALL_DIR}/dnstt-server" -gen-key \
            -privkey-file "$PRIVATE_KEY_FILE" \
            -pubkey-file "$PUBLIC_KEY_FILE"
    fi
    
    chown "$DNSTT_USER:$DNSTT_USER" "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
    chmod 600 "$PRIVATE_KEY_FILE"
    chmod 644 "$PUBLIC_KEY_FILE"
    
    log_info "Public key:"
    printf "${YELLOW}%s${NC}\n" "$(cat "$PUBLIC_KEY_FILE")"
}

get_default_interface() {
    ip route | grep default | awk '{print $5}' | head -n1 || echo "eth0"
}

configure_iptables() {
    log_info "Configuring iptables..."
    
    local interface
    interface=$(get_default_interface)
    local target_port="$DNSTT_PORT"
    
    if [[ "$USE_KCP" == true ]]; then
        target_port="$KCP_PORT"
        log_info "KCP enabled: Redirecting port 53 to KCP port $KCP_PORT"
    fi
    
    iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$target_port" 2>/dev/null && \
        iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$target_port" 2>/dev/null || true
    
    iptables -C INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
    
    if [[ "$USE_KCP" == true ]]; then
        iptables -C INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null && \
            iptables -D INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true
    fi
    
    iptables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT
    iptables -t nat -I PREROUTING -i "$interface" -p udp --dport 53 -j REDIRECT --to-ports "$target_port"
    
    if [[ "$USE_KCP" == true ]]; then
        iptables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT
    fi
    
    if command -v ip6tables &>/dev/null && [[ -f /proc/net/if_inet6 ]]; then
        ip6tables -I INPUT -p udp --dport "$DNSTT_PORT" -j ACCEPT 2>/dev/null || true
        ip6tables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$target_port" 2>/dev/null || true
        
        if [[ "$USE_KCP" == true ]]; then
            ip6tables -I INPUT -p udp --dport "$KCP_PORT" -j ACCEPT 2>/dev/null || true
        fi
    fi
    
    case "$PKG_MANAGER" in
        apt)
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
        dnf|yum)
            mkdir -p /etc/sysconfig
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            systemctl enable iptables 2>/dev/null || true
            ;;
    esac
    
    log_info "iptables configured on interface: $interface"
}

configure_firewall() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${DNSTT_PORT}/udp" 2>/dev/null || true
        firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
        [[ "$USE_KCP" == true ]] && firewall-cmd --permanent --add-port="${KCP_PORT}/udp" 2>/dev/null || true
        firewall-cmd --reload
    fi
    
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${DNSTT_PORT}/udp" 2>/dev/null || true
        ufw allow 53/udp 2>/dev/null || true
        [[ "$USE_KCP" == true ]] && ufw allow "${KCP_PORT}/udp" 2>/dev/null || true
    fi
}

detect_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp 2>/dev/null | grep -E "sshd|ssh" | awk '{print $4}' | cut -d':' -f2 | head -n1)
    echo "${ssh_port:-22}"
}

setup_dante() {
    if [[ "$TUNNEL_MODE" != "socks" ]]; then
        if systemctl is-active --quiet danted 2>/dev/null; then
            systemctl stop danted
            systemctl disable danted
        fi
        return 0
    fi
    
    log_info "Configuring SOCKS5 server..."
    
    local external_interface
    external_interface=$(get_default_interface)
    
    mkdir -p /var/log/dnstt
    touch /var/log/dnstt/danted.log
    chmod 644 /var/log/dnstt/danted.log
    
    cat > /etc/danted.conf << EOF
logoutput: /var/log/dnstt/danted.log
internal: 127.0.0.1 port = ${SOCKS_PORT}
external: ${external_interface}
user.privileged: root
user.unprivileged: nobody
socksmethod: none
clientmethod: none
client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}
socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error
}
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF

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
        log_info "Dante running on 127.0.0.1:${SOCKS_PORT}"
    else
        log_warn "Dante failed, using socat fallback"
        setup_socat_fallback
    fi
}

setup_socat_fallback() {
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
        log_info "SSH mode: tunneling to port $target_port"
    else
        target_port="$SOCKS_PORT"
    fi
    
    systemctl stop dnstt-server 2>/dev/null || true
    systemctl stop kcptun-server 2>/dev/null || true
    
    if [[ "$USE_KCP" == true ]]; then
        cat > "${SYSTEMD_DIR}/kcptun-server.service" << EOF
[Unit]
Description=KCP Accelerator
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/kcptun-server -l :${KCP_PORT} -t 127.0.0.1:${DNSTT_PORT} -mode fast3 -sndwnd 2048 -rcvwnd 2048 -datashard 10 -parityshard 3 -nocomp -dscp 46
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable kcptun-server
    else
        systemctl disable kcptun-server 2>/dev/null || true
    fi
    
    cat > "${SYSTEMD_DIR}/dnstt-server.service" << EOF
[Unit]
Description=DNSTT DNS Tunnel Server
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

StandardOutput=append:${LOG_DIR}/dnstt.log
StandardError=append:${LOG_DIR}/dnstt-error.log
SyslogIdentifier=dnstt-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dnstt-server
}

start_services() {
    log_info "Starting services..."
    
    if [[ "$USE_KCP" == true ]]; then
        systemctl restart kcptun-server
        sleep 2
    fi
    
    systemctl restart dnstt-server
    sleep 2
    
    if systemctl is-active --quiet dnstt-server; then
        log_info "DNSTT server running"
    else
        log_error "DNSTT server failed to start"
        systemctl status dnstt-server --no-pager -l
        exit 1
    fi
    
    if [[ "$USE_KCP" == true ]]; then
        if systemctl is-active --quiet kcptun-server; then
            log_info "KCP accelerator running"
        else
            log_warn "KCP accelerator failed"
        fi
    fi
}

show_status() {
    draw_header
    
    printf "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}                    ${BOLD}Service Status${NC}                          ${CYAN}║${NC}\n"
    printf "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    
    if systemctl is-active --quiet dnstt-server; then
        printf "  ${GREEN}●${NC} DNSTT Server        : ${GREEN}Running${NC}\n"
    else
        printf "  ${RED}●${NC} DNSTT Server        : ${RED}Stopped${NC}\n"
    fi
    
    if [[ "$USE_KCP" == true ]]; then
        if systemctl is-active --quiet kcptun-server 2>/dev/null; then
            printf "  ${GREEN}●${NC} KCP Accelerator     : ${GREEN}Running${NC}\n"
        else
            printf "  ${RED}●${NC} KCP Accelerator     : ${RED}Stopped${NC}\n"
        fi
    else
        printf "  ${YELLOW}○${NC} KCP Accelerator     : ${YELLOW}Disabled${NC}\n"
    fi
    
    if [[ "$TUNNEL_MODE" == "socks" ]]; then
        if systemctl is-active --quiet danted 2>/dev/null; then
            printf "  ${GREEN}●${NC} SOCKS Proxy         : ${GREEN}Running${NC} on 127.0.0.1:${SOCKS_PORT}\n"
        fi
    fi
    
    echo ""
    
    if systemctl is-active --quiet dnstt-server; then
        printf "${CYAN}Recent logs:${NC}\n"
        journalctl -u dnstt-server --no-pager -n 5 -o short 2>/dev/null || true
    fi
}

show_config() {
    draw_header
    
    if [[ ! -f "$CONFIG_DIR/server.conf" ]]; then
        log_error "No configuration found"
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
        printf "${YELLOW}Public Key:${NC}\n"
        cat "$PUBLIC_KEY_FILE"
    fi
}

show_logs() {
    log_info "Showing logs (Ctrl+C to exit)..."
    journalctl -u dnstt-server -f -n 50
}

display_final_summary() {
    draw_header
    
    local box_content=""
    box_content+="Installation completed successfully!\n"
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
    
    draw_box "Setup Complete" "$box_content"
    
    echo ""
    printf "${GREEN}Services enabled for auto-start.${NC}\n"
    echo ""
    printf "${CYAN}Client Connection Info:${NC}\n"
    echo "  Server: $NS_SUBDOMAIN"
    echo "  Port: 53 (DNS)"
    echo "  Public Key: $(cat "$PUBLIC_KEY_FILE")"
    [[ "$USE_KCP" == true ]] && echo "  KCP: Enabled"
    [[ "$TUNNEL_MODE" == "socks" ]] && echo "  Proxy: SOCKS5 on client side"
    [[ "$TUNNEL_MODE" == "ssh" ]] && echo "  Target: SSH port $(detect_ssh_port)"
}

show_menu() {
    draw_header
    
    if [[ "$UPDATE_AVAILABLE" == true ]]; then
        printf "${YELLOW}Update available! Use option 2.${NC}\n\n"
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
                return 0
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
                log_info "Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

run_installation() {
    log_info "Starting installation..."
    
    detect_os
    detect_arch
    install_dependencies
    verify_iptables
    
    if ! load_config; then
        log_info "No existing configuration found"
    fi
    
    get_user_input
    save_config
    
    download_dnstt
    download_kcptun
    
    create_user
    generate_keys
    
    configure_iptables
    configure_firewall
    
    setup_dante
    create_systemd_services
    start_services
    
    display_final_summary
}

main() {
    check_root
    install_script "$@"
    
    if [[ "$0" == "$SCRIPT_INSTALL_PATH" ]]; then
        check_updates
        handle_menu
        run_installation
    else
        run_installation
    fi
}

trap 'log_error "Interrupted"; exit 1' INT TERM

main "$@"
