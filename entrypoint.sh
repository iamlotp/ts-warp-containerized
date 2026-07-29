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
