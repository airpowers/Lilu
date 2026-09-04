#!/usr/bin/env bash
set -euo pipefail

cat > /etc/wireguard/wg0-postup.sh << 'EOF'
#!/bin/bash
WG_PEER_GW4="10.99.0.1"
WG_PEER_GW6="fd00::1"
WG_DEV="wg0"
PBR_TABLE="viavm1"
VM_BRIDGE="vmbr0"

DONATED_V4=( "176.12.65.52" "176.12.65.56" )
DONATED_V6_PREFIX="2a01:230:4:df2::/64"

case "$1" in
  up)
    ip route replace ${WG_PEER_GW4}/32 dev ${WG_DEV}
    ip -6 route replace ${WG_PEER_GW6}/128 dev ${WG_DEV} 2>/dev/null || true
    ip route replace default dev ${WG_DEV} via ${WG_PEER_GW4} table ${PBR_TABLE}
    ip -6 route replace default dev ${WG_DEV} via ${WG_PEER_GW6} table ${PBR_TABLE} 2>/dev/null || true

    echo 1 > /proc/sys/net/ipv4/conf/${VM_BRIDGE}/proxy_arp
    echo 1 > /proc/sys/net/ipv6/conf/${VM_BRIDGE}/proxy_ndp
    echo 1 > /proc/sys/net/ipv6/conf/${WG_DEV}/proxy_ndp

    for ip4 in "${DONATED_V4[@]}"; do
        ip route replace ${ip4}/32 dev ${VM_BRIDGE}
        ip rule show | grep -q "from ${ip4}" || \
            ip rule add from ${ip4}/32 table ${PBR_TABLE} priority 100
    done

    ip -6 route replace ${DONATED_V6_PREFIX} dev ${VM_BRIDGE} 2>/dev/null || true
    ip -6 rule show | grep -q "from ${DONATED_V6_PREFIX}" || \
        ip -6 rule add from ${DONATED_V6_PREFIX} table ${PBR_TABLE} priority 100 2>/dev/null || true
    ;;
  down)
    for ip4 in "${DONATED_V4[@]}"; do
        ip rule del from ${ip4}/32 table ${PBR_TABLE} 2>/dev/null || true
        ip route del ${ip4}/32 dev ${VM_BRIDGE} 2>/dev/null || true
    done
    ip -6 rule del from ${DONATED_V6_PREFIX} table ${PBR_TABLE} 2>/dev/null || true
    ip -6 route del ${DONATED_V6_PREFIX} dev ${VM_BRIDGE} 2>/dev/null || true
    ip route del default table ${PBR_TABLE} 2>/dev/null || true
    ip -6 route del default table ${PBR_TABLE} 2>/dev/null || true
    ip route del ${WG_PEER_GW4}/32 dev ${WG_DEV} 2>/dev/null || true
    ;;
  *) echo "Usage: $0 {up|down}"; exit 1 ;;
esac
EOF

chmod +x /etc/wireguard/wg0-postup.sh

ip addr del 2a01:230:4:df2::a1/128 dev vmbr0 2>/dev/null || true
ip -6 rule del from 2a01:230:4:df2:100::1 lookup viavm1 2>/dev/null || true

/etc/wireguard/wg0-postup.sh down && /etc/wireguard/wg0-postup.sh up
