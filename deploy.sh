#!/usr/bin/env bash
#
# deploy.sh — One-shot deployment of the Tailscale + Cloudflare WARP exit-node container.
#
# Usage:
#   curl -sO <url>/deploy.sh && chmod +x deploy.sh && ./deploy.sh
#   — or —
#   bash deploy.sh
#
# To skip the Docker build and pull a pre-built image instead, set:
#   export PREBUILT_IMAGE=ghcr.io/<your-github-user>/tailscale-warp-exit:latest
# Run build-and-push.sh once to create and publish the image.
#
# The script will:
#   1. Prompt for your Tailscale auth key
#   2. Check / install Docker & Docker Compose
#   3. Create a project directory and write all required files
#   4. Pull pre-built image (if available) OR build from source
#   5. Verify WARP connectivity and print the result
#
set -euo pipefail

# ── Pre-built image ───────────────────────────────────────────────
# Built and kept up-to-date automatically by GitHub Actions.
# Override at runtime:  PREBUILT_IMAGE=other/image ./deploy.sh
# Set to empty string to force a local build:  PREBUILT_IMAGE= ./deploy.sh
PREBUILT_IMAGE="${PREBUILT_IMAGE:-ghcr.io/iamlotp/ts-warp-containerized:latest}"

# ─────────────────────────── helpers ───────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No colour

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }

separator() {
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ─────────────────────── 1. auth key input ─────────────────────

separator
echo -e "${BOLD}Tailscale + Cloudflare WARP Exit-Node — Automated Deploy${NC}"
separator
echo ""

read -rp "$(echo -e "${CYAN}Enter your Tailscale auth key:${NC} ")" TS_AUTHKEY

if [[ -z "$TS_AUTHKEY" ]]; then
    fail "Auth key cannot be empty."
    exit 1
fi

if [[ ! "$TS_AUTHKEY" =~ ^tskey- ]]; then
    warn "Key doesn't start with 'tskey-'. Make sure you pasted the right value."
    read -rp "Continue anyway? [y/N] " yn
    case "$yn" in
        [Yy]*) ;;
        *)     exit 1 ;;
    esac
fi

success "Auth key accepted."
echo ""

# ────────────────── 2. check / install Docker ──────────────────

separator
info "Checking prerequisites…"
separator
echo ""

install_docker() {
    info "Docker not found — installing via the official convenience script…"
    curl -fsSL https://get.docker.com | sh
    if command -v systemctl &>/dev/null; then
        systemctl enable --now docker
    fi
    success "Docker installed."
}

if ! command -v docker &>/dev/null; then
    install_docker
else
    success "Docker is already installed: $(docker --version)"
fi

# Make sure the Docker daemon is running
if ! docker info &>/dev/null 2>&1; then
    warn "Docker daemon is not running. Attempting to start it…"
    if command -v systemctl &>/dev/null; then
        sudo systemctl start docker
    elif command -v service &>/dev/null; then
        sudo service docker start
    fi
    sleep 2
    if ! docker info &>/dev/null 2>&1; then
        fail "Could not start the Docker daemon. Please start it manually and re-run this script."
        exit 1
    fi
    success "Docker daemon started."
fi

# Docker Compose — bundled with Docker Engine since v2, but let's verify
if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose (plugin) available: $(docker compose version --short 2>/dev/null || echo 'v2+')"
elif command -v docker-compose &>/dev/null; then
    success "docker-compose (standalone) available."
    # Alias so the rest of the script can use `docker compose`
    shim_compose() { docker-compose "$@"; }
    alias docker_compose_cmd="docker-compose"
else
    warn "Docker Compose not found — installing the plugin…"
    COMPOSE_VERSION=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | head -1 | cut -d '"' -f4)
    COMPOSE_VERSION="${COMPOSE_VERSION:-v2.29.1}"
    DOCKER_CLI_PLUGINS="${DOCKER_CLI_PLUGINS:-/usr/local/lib/docker/cli-plugins}"
    mkdir -p "$DOCKER_CLI_PLUGINS"
    curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o "$DOCKER_CLI_PLUGINS/docker-compose"
    chmod +x "$DOCKER_CLI_PLUGINS/docker-compose"
    if docker compose version &>/dev/null 2>&1; then
        success "Docker Compose plugin installed."
    else
        fail "Docker Compose installation failed. Please install it manually."
        exit 1
    fi
fi

echo ""

# ────────────────── 3. create project files ────────────────────

PROJECT_DIR="$HOME/tailscale-warp-exit"

separator
info "Setting up project directory: ${BOLD}${PROJECT_DIR}${NC}"
separator
echo ""

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# ── .env ──
cat > .env <<EOF
TS_AUTHKEY=${TS_AUTHKEY}
EOF
success "Created .env"

# ── Dockerfile ──
cat > Dockerfile <<'DOCKERFILE'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
        curl \
        gnupg \
        lsb-release \
        iproute2 \
        iptables \
        ca-certificates \
        procps \
    && rm -rf /var/lib/apt/lists/*

# --- Tailscale repo & install ---
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list

# --- Cloudflare WARP repo & install ---
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor \
        --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ noble main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

RUN apt-get update && apt-get install -y \
        tailscale \
        cloudflare-warp \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE
success "Created Dockerfile"

# ── entrypoint.sh ──
cat > entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e

echo "=== Creating TUN device ==="
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

echo "=== Enabling IP forwarding (belt-and-braces; also set via docker sysctls) ==="
sysctl -w net.ipv4.ip_forward=1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 || true

echo "=== Starting tailscaled ==="
mkdir -p /var/lib/tailscale /var/run/tailscale
tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --port=41641 &
TAILSCALED_PID=$!

until [ -S /var/run/tailscale/tailscaled.sock ]; do
    sleep 0.5
done

echo "=== Bringing up Tailscale ==="
# shellcheck disable=SC2086
tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME:-warp-exit-node}" \
    --advertise-exit-node \
    --accept-dns=false \
    ${TS_EXTRA_ARGS}

echo "=== Starting warp-svc ==="
warp-svc &
WARPSVC_PID=$!
sleep "${WARP_SLEEP:-5}"

if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    echo "=== Registering WARP client ==="
    # Command name has varied across client versions; try both.
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register

    if [ -n "$WARP_LICENSE_KEY" ]; then
        echo "=== Applying WARP+ license key ==="
        warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" 2>/dev/null \
            || warp-cli --accept-tos set-license "$WARP_LICENSE_KEY"
    fi
else
    echo "=== WARP already registered, skipping registration ==="
fi

echo "=== Setting WARP to full-tunnel mode ==="
warp-cli --accept-tos mode warp

echo "=== Connecting WARP ==="
warp-cli --accept-tos connect

echo "=== Waiting for CloudflareWARP interface ==="
for i in $(seq 1 30); do
    if ip -o link show | grep -qi cloudflarewarp; then
        break
    fi
    sleep 1
done

WARP_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -i cloudflarewarp | head -n1)
if [ -z "$WARP_IF" ]; then
    echo "WARNING: could not auto-detect WARP interface name, defaulting to CloudflareWARP"
    WARP_IF="CloudflareWARP"
fi
echo "Using WARP interface: $WARP_IF"

echo "=== Configuring NAT so Tailscale-forwarded traffic exits via WARP ==="
iptables -t nat -A POSTROUTING -o "$WARP_IF" -j MASQUERADE
iptables -A FORWARD -i tailscale0 -o "$WARP_IF" -j ACCEPT
iptables -A FORWARD -i "$WARP_IF" -o tailscale0 -m state --state ESTABLISHED,RELATED -j ACCEPT

echo "=== Setup complete. Checking egress IP/status ==="
curl -s https://cloudflare.com/cdn-cgi/trace | grep -E 'ip=|warp=' || true

term_handler() {
    echo "Shutting down..."
    warp-cli disconnect || true
    tailscale down || true
    kill -TERM "$TAILSCALED_PID" "$WARPSVC_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}
trap term_handler SIGTERM SIGINT

wait -n "$TAILSCALED_PID" "$WARPSVC_PID"
ENTRYPOINT
chmod +x entrypoint.sh
success "Created entrypoint.sh"

# ── docker-compose.yml ──
# Use a pre-built image if available, otherwise fall back to building locally.
if [[ -n "$PREBUILT_IMAGE" ]]; then
    cat > docker-compose.yml << COMPOSE
services:
  tailscale-warp-exit:
    image: ${PREBUILT_IMAGE}
    container_name: tailscale-warp-exit
    hostname: warp-exit-node
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - TS_AUTHKEY=\${TS_AUTHKEY}
      - TS_HOSTNAME=warp-exit-node
      - TS_EXTRA_ARGS=--accept-routes=false
      - WARP_SLEEP=5
      # - WARP_LICENSE_KEY=your-warp-plus-key   # optional, uncomment if you have WARP+
    volumes:
      - ts-state:/var/lib/tailscale
      - warp-state:/var/lib/cloudflare-warp

volumes:
  ts-state:
  warp-state:
COMPOSE
else
    cat > docker-compose.yml << 'COMPOSE'
services:
  tailscale-warp-exit:
    build: .
    container_name: tailscale-warp-exit
    hostname: warp-exit-node
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
      - TS_HOSTNAME=warp-exit-node
      - TS_EXTRA_ARGS=--accept-routes=false
      - WARP_SLEEP=5
      # - WARP_LICENSE_KEY=your-warp-plus-key   # optional, uncomment if you have WARP+
    volumes:
      - ts-state:/var/lib/tailscale
      - warp-state:/var/lib/cloudflare-warp

volumes:
  ts-state:
  warp-state:
COMPOSE
fi
success "Created docker-compose.yml"

echo ""

# ──────────────── 4. pull or build & start the container ────────

separator
if [[ -n "$PREBUILT_IMAGE" ]]; then
    info "Pulling pre-built image: ${BOLD}${PREBUILT_IMAGE}${NC}"
else
    info "No pre-built image set — building from source (this may take ~5 min)…"
    info "Tip: run build-and-push.sh once and set PREBUILT_IMAGE to skip this next time."
fi
separator
echo ""

if [[ -n "$PREBUILT_IMAGE" ]]; then
    # Try to pull; if it fails (e.g. private image, no auth), fall back to build
    if docker pull "$PREBUILT_IMAGE" 2>&1; then
        success "Image pulled successfully."
        docker compose up -d 2>&1
    else
        warn "Pull failed — falling back to local build…"
        # Rewrite compose file to use build: . instead
        sed -i "s|image: .*|build: .|" docker-compose.yml
        docker compose up -d --build 2>&1
    fi
else
    docker compose up -d --build 2>&1
fi

echo ""
success "Container started."
echo ""

# ──────────────── 5. health-check & verification ───────────────

separator
info "Running post-deploy verification…"
separator
echo ""

MAX_WAIT=90
INTERVAL=5
ELAPSED=0
WARP_OK=false
TS_OK=false

while (( ELAPSED < MAX_WAIT )); do
    # ── Check WARP status ──
    TRACE=$(docker exec tailscale-warp-exit curl -sf https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    if echo "$TRACE" | grep -q "warp=on"; then
        WARP_OK=true
    fi

    # ── Check Tailscale status ──
    TS_STATUS=$(docker exec tailscale-warp-exit tailscale status --json 2>/dev/null || true)
    if echo "$TS_STATUS" | grep -q '"BackendState":"Running"'; then
        TS_OK=true
    fi

    if $WARP_OK && $TS_OK; then
        break
    fi

    info "Waiting for services to come up… (${ELAPSED}s / ${MAX_WAIT}s)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
separator
echo -e "${BOLD}               DEPLOYMENT RESULT${NC}"
separator
echo ""

# ── Tailscale verdict ──
if $TS_OK; then
    TS_IP=$(echo "$TS_STATUS" | grep -o '"TailscaleIPs":\[[^]]*\]' | head -1 || true)
    success "Tailscale:  ${GREEN}RUNNING${NC}  ${TS_IP:+(IPs: ${TS_IP})}"
else
    fail "Tailscale:  ${RED}NOT READY${NC}  — check logs with: docker compose -f ${PROJECT_DIR}/docker-compose.yml logs"
fi

# ── WARP verdict ──
if $WARP_OK; then
    EGRESS_IP=$(echo "$TRACE" | grep 'ip=' | cut -d= -f2)
    WARP_STATUS=$(echo "$TRACE" | grep 'warp=' | cut -d= -f2)
    success "WARP:       ${GREEN}${WARP_STATUS:-on}${NC}  (egress IP: ${EGRESS_IP:-unknown})"
else
    fail "WARP:       ${RED}NOT CONNECTED${NC}  — check logs with: docker compose -f ${PROJECT_DIR}/docker-compose.yml logs"
fi

echo ""

if $WARP_OK && $TS_OK; then
    separator
    echo -e "${GREEN}${BOLD}  ✓ Everything is up! Your WARP-tunnelled Tailscale exit node is ready.${NC}"
    separator
    echo ""
    echo "  Next steps:"
    echo "    1. Approve the exit node in the Tailscale admin console:"
    echo "       https://login.tailscale.com/admin/machines"
    echo "       → Find 'warp-exit-node' → Edit route settings → Enable exit node"
    echo ""
    echo "    2. On any Tailscale client, run:"
    echo "       tailscale up --exit-node=warp-exit-node"
    echo ""
    echo "  Useful commands:"
    echo "    Logs:      docker compose -f ${PROJECT_DIR}/docker-compose.yml logs -f"
    echo "    Stop:      docker compose -f ${PROJECT_DIR}/docker-compose.yml down"
    echo "    Restart:   docker compose -f ${PROJECT_DIR}/docker-compose.yml restart"
    echo "    Wipe all:  docker compose -f ${PROJECT_DIR}/docker-compose.yml down -v"
    echo ""
else
    separator
    echo -e "${YELLOW}${BOLD}  ⚠ One or more services didn't pass the health check.${NC}"
    separator
    echo ""
    echo "  Inspect the container logs for details:"
    echo "    docker compose -f ${PROJECT_DIR}/docker-compose.yml logs -f"
    echo ""
fi
