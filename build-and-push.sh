#!/usr/bin/env bash
#
# build-and-push.sh — Build the Tailscale + WARP image once and push it to
#                     GitHub Container Registry (ghcr.io) so every VPS can
#                     pull it instead of building from scratch.
#
# Usage:
#   chmod +x build-and-push.sh
#   ./build-and-push.sh
#
# Prerequisites:
#   - Docker installed and running
#   - A GitHub Personal Access Token (PAT) with `write:packages` scope
#     https://github.com/settings/tokens/new?scopes=write:packages
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

separator() {
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

separator
echo -e "${BOLD}Tailscale + Cloudflare WARP — Build & Push to ghcr.io${NC}"
separator
echo ""

# ─────────────────── config ───────────────────────────────────────
# Set these to match your GitHub username / org and desired image name.
GITHUB_USER="${GITHUB_USER:-}"          # e.g.  myusername
IMAGE_NAME="${IMAGE_NAME:-tailscale-warp-exit}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
# ──────────────────────────────────────────────────────────────────

if [[ -z "$GITHUB_USER" ]]; then
    read -rp "$(echo -e "${CYAN}GitHub username or org:${NC} ")" GITHUB_USER
    [[ -z "$GITHUB_USER" ]] && fail "GitHub username cannot be empty."
fi

FULL_IMAGE="ghcr.io/${GITHUB_USER}/${IMAGE_NAME}:${IMAGE_TAG}"
info "Image will be pushed as: ${BOLD}${FULL_IMAGE}${NC}"
echo ""

# ─────────────────── authenticate ────────────────────────────────
separator
info "Authenticating with ghcr.io…"
separator
echo ""

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    warn "GITHUB_TOKEN env var not set."
    warn "You need a Personal Access Token with the 'write:packages' scope."
    warn "Create one at: https://github.com/settings/tokens/new?scopes=write:packages"
    echo ""
    read -rsp "$(echo -e "${CYAN}Paste your GitHub PAT (input hidden):${NC} ")" GITHUB_TOKEN
    echo ""
    [[ -z "$GITHUB_TOKEN" ]] && fail "Token cannot be empty."
fi

echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
success "Logged in to ghcr.io."
echo ""

# ─────────────────── build ────────────────────────────────────────
separator
info "Building image: ${BOLD}${FULL_IMAGE}${NC}"
separator
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Write the Dockerfile next to this script if it doesn't exist yet
# (it may already exist from a previous deploy.sh run)
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
if [[ ! -f "$DOCKERFILE" ]]; then
    info "Dockerfile not found — writing it now…"
    cat > "$DOCKERFILE" << 'DOCKERFILE'
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
    success "Dockerfile written."
fi

# Write entrypoint.sh if it doesn't exist
ENTRYPOINT_FILE="${SCRIPT_DIR}/entrypoint.sh"
if [[ ! -f "$ENTRYPOINT_FILE" ]]; then
    info "entrypoint.sh not found — writing it now…"
    cat > "$ENTRYPOINT_FILE" << 'ENTRYPOINT'
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
    chmod +x "$ENTRYPOINT_FILE"
    success "entrypoint.sh written."
fi

docker build \
    --platform linux/amd64 \
    -t "$FULL_IMAGE" \
    "$SCRIPT_DIR"

success "Image built."
echo ""

# ─────────────────── push ────────────────────────────────────────
separator
info "Pushing image to ghcr.io…"
separator
echo ""

docker push "$FULL_IMAGE"

success "Image pushed: ${BOLD}${FULL_IMAGE}${NC}"
echo ""

# ─────────────────── summary ─────────────────────────────────────
separator
echo -e "${GREEN}${BOLD}  ✓ Done! Your pre-built image is now on ghcr.io.${NC}"
separator
echo ""
echo "  To use it in deploy.sh, set this env var before running:"
echo ""
echo -e "    ${BOLD}export PREBUILT_IMAGE=${FULL_IMAGE}${NC}"
echo ""
echo "  Or, if the image is public, deploy.sh will auto-detect it"
echo "  when you set PREBUILT_IMAGE at the top of the script."
echo ""
echo "  To make the package public (so VPSes can pull without auth):"
echo "    https://github.com/users/${GITHUB_USER}/packages/container/${IMAGE_NAME}/settings"
echo "    → Change visibility → Public"
echo ""
