#!/bin/bash
# DEPRECATED — Superseded by enhance-config.ps1
# Kept for reference only. Use: powershell -File enhance-config.ps1 -Apply
# Dynamic multi-server xray config generator for v2rayN
# Run this after subscription updates to rebuild the optimized config
# Usage: bash generate-xray-config.sh

set -e

V2RAYN_DIR="D:/Document/Download/v2rayN-windows-64-desktop/v2rayN-windows-64"
CONFIG_DIR="$V2RAYN_DIR/binConfigs"
BIN_DIR="$V2RAYN_DIR/bin"
CURRENT_CONFIG="$CONFIG_DIR/config.json"
OUTPUT_CONFIG="$CONFIG_DIR/config-optimized.json"
PROXY_NODES_FILE="D:/Document/local/knowledge/network/proxy-nodes.json"

# Shared credentials for all VLESS+Reality nodes
UUID="[已脱敏]"
FLOW="xtls-rprx-vision"

echo "=== v2rayN Multi-Server Config Generator ==="

# Step 1: Discover nodes from configTest files (most recent ones)
echo "[1/4] Discovering available nodes from configTest files..."

declare -A NODES
TIMESTAMP=$(date +%s)

for f in "$CONFIG_DIR"/configTest*.json; do
    if [ -f "$f" ]; then
        # Extract proxy server info
        ADDR=$(grep -oP '"address":\s*"[^"]+"' "$f" | head -1 | cut -d'"' -f4)
        PORT=$(grep -oP '"port":\s*\d+' "$f" | head -1 | grep -oP '\d+')
        SNI=$(grep -oP '"serverName":\s*"[^"]+"' "$f" | head -1 | cut -d'"' -f4)
        PUBKEY=$(grep -oP '"publicKey":\s*"[^"]+"' "$f" | head -1 | cut -d'"' -f4)

        if [ -n "$ADDR" ] && [ -n "$PORT" ]; then
            KEY="${ADDR}:${PORT}"
            if [ -z "${NODES[$KEY]}" ]; then
                NODES[$KEY]="$SNI|$PUBKEY"
            fi
        fi
    fi
done

echo "  Found ${#NODES[@]} unique nodes"

# Step 2: Ping test all nodes
echo "[2/4] Testing latency for all nodes..."

declare -A PING_RESULTS
for NODE_KEY in "${!NODES[@]}"; do
    ADDR="${NODE_KEY%:*}"
    PORT="${NODE_KEY#*:}"

    # Ping test
    PING_RESULT=$(ping -n 3 "$ADDR" 2>/dev/null | grep "Average" | grep -oP '\d+ms' | grep -oP '\d+' || echo "9999")
    PING_RESULTS[$NODE_KEY]=$PING_RESULT
    echo "  $ADDR:$PORT -> ${PING_RESULT}ms"
done

# Step 3: Select top 4 nodes
echo "[3/4] Selecting top nodes..."

# Sort by ping and get top 4
TOP_NODES=$(for NODE_KEY in "${!PING_RESULTS[@]}"; do
    echo "${PING_RESULTS[$NODE_KEY]} $NODE_KEY"
done | sort -n | head -4)

PRIMARY_COUNT=0
FALLBACK_COUNT=0
PRIMARY_SELECTOR=""
FALLBACK_SELECTOR=""
OUTBOUNDS_JSON=""
OBSERVATORY_SELECTOR=""
FIRST_FALLBACK=""

while IFS=' ' read -r PING NODE_KEY; do
    ADDR="${NODE_KEY%:*}"
    PORT="${NODE_KEY#*:}"
    INFO="${NODES[$NODE_KEY]}"
    SNI="${INFO%%|*}"
    PUBKEY="${INFO##*|}"

    # Sanitize tag name
    TAG="proxy-${ADDR%%.*}-${PORT}"
    TAG=$(echo "$TAG" | sed 's/[^a-zA-Z0-9_-]//g')

    if [ $PRIMARY_COUNT -lt 2 ]; then
        ROLE="primary"
        if [ -n "$PRIMARY_SELECTOR" ]; then
            PRIMARY_SELECTOR="$PRIMARY_SELECTOR, "
        fi
        PRIMARY_SELECTOR="${PRIMARY_SELECTOR}\"$TAG\""
        PRIMARY_COUNT=$((PRIMARY_COUNT + 1))
    else
        ROLE="fallback"
        if [ -n "$FALLBACK_SELECTOR" ]; then
            FALLBACK_SELECTOR="$FALLBACK_SELECTOR, "
        fi
        FALLBACK_SELECTOR="${FALLBACK_SELECTOR}\"$TAG\""
        if [ -z "$FIRST_FALLBACK" ]; then
            FIRST_FALLBACK="$TAG"
        fi
        FALLBACK_COUNT=$((FALLBACK_COUNT + 1))
    fi

    if [ -n "$OBSERVATORY_SELECTOR" ]; then
        OBSERVATORY_SELECTOR="$OBSERVATORY_SELECTOR, "
    fi
    OBSERVATORY_SELECTOR="${OBSERVATORY_SELECTOR}\"$TAG\""

    # Generate outbound JSON
    OUTBOUND_JSON=$(cat <<EOF
    {
      "tag": "$TAG",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$ADDR",
          "port": $PORT,
          "users": [{
            "id": "$UUID",
            "email": "t@t.tt",
            "security": "auto",
            "encryption": "none",
            "flow": "$FLOW"
          }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI:-apple.com}",
          "fingerprint": "chrome",
          "publicKey": "${PUBKEY:-}",
          "shortId": "",
          "spiderX": "/"
        }
      },
      "mux": { "enabled": true, "concurrency": 8 }
    }
EOF
)

    if [ -n "$OUTBOUNDS_JSON" ]; then
        OUTBOUNDS_JSON="$OUTBOUNDS_JSON,"
    fi
    OUTBOUNDS_JSON="$OUTBOUNDS_JSON$OUTBOUND_JSON"

    echo "  $ROLE: $TAG ($ADDR:$PORT, ${PING}ms)"
done <<< "$TOP_NODES"

if [ $PRIMARY_COUNT -eq 0 ]; then
    echo "ERROR: No reachable nodes found!"
    exit 1
fi

# Step 4: Generate full config
echo "[4/4] Generating optimized config..."

FALLBACK_LINE=""
if [ -n "$FIRST_FALLBACK" ]; then
    FALLBACK_LINE="\"fallbackTag\": \"$FIRST_FALLBACK\","
fi

cat > "$OUTPUT_CONFIG" <<XRAYCONFIG
{
  "log": { "loglevel": "warning" },
  "dns": {
    "hosts": {
      "dns.google": ["[IP已脱敏]", "[IP已脱敏]"],
      "dns.alidns.com": ["[IP已脱敏]", "[IP已脱敏]"]
    },
    "servers": [
      {
        "address": "https://dns.alidns.com/dns-query",
        "domains": ["geosite:private", "geosite:cn"],
        "skipFallback": true,
        "tag": "direct-dns-1"
      },
      {
        "address": "https://cloudflare-dns.com/dns-query",
        "domains": ["geosite:google"],
        "skipFallback": true
      },
      { "address": "[IP已脱敏]", "domains": ["full:dns.alidns.com"], "skipFallback": true },
      "https://cloudflare-dns.com/dns-query"
    ],
    "tag": "dns-module"
  },
  "inbounds": [{
    "tag": "socks",
    "port": 10808,
    "listen": "[IP已脱敏]",
    "protocol": "mixed",
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"],
      "routeOnly": false
    },
    "settings": { "auth": "noauth", "udp": true, "allowTransparent": false }
  }],
  "outbounds": [
    $OUTBOUNDS_JSON,
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "observatory": {
    "subjectSelector": [$OBSERVATORY_SELECTOR],
    "probeURL": "https://www.google.com/generate_204",
    "probeInterval": "2m"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "balancers": [{
      "tag": "balancer",
      "selector": [$PRIMARY_SELECTOR],
      "strategy": { "type": "leastPing" }
      $FALLBACK_LINE
    }],
    "rules": [
      { "type": "field", "port": "443", "network": "udp", "outboundTag": "block" },
      { "type": "field", "outboundTag": "balancer", "domain": ["geosite:google"] },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "direct", "domain": ["geosite:private"] },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:cn"] },
      { "type": "field", "outboundTag": "direct", "domain": ["geosite:cn"] },
      { "type": "field", "inboundTag": ["direct-dns-1"], "outboundTag": "direct" },
      { "type": "field", "inboundTag": ["dns-module"], "outboundTag": "balancer" }
    ]
  }
}
XRAYCONFIG

echo ""
echo "Config generated: $OUTPUT_CONFIG"
echo ""
echo "To apply immediately:"
echo "  1. Stop proxy in v2rayN"
echo "  2. Copy: cp '$OUTPUT_CONFIG' '$CURRENT_CONFIG'"
echo "  3. Start proxy in v2rayN"
echo ""
echo "To run on schedule (auto-update after subscription refresh):"
echo "  Run this script, then copy config-optimized.json → config.json"
