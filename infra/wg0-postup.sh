#!/bin/bash
# VM2 (176.99.153.88) WireGuard PostUp/PostDown script
# Управляет policy routing для донорских IP (IPv4 + IPv6) от VM1 (157.22.199.180)
#
# Добавить новый донорский IPv4:
#   1. Добавить IP в DONATED_V4
#   2. Добавить IP/32 в AllowedIPs и PostUp на VM1 (/etc/wireguard/wg0.conf)
#   3. Применить: /etc/wireguard/wg0-postup.sh down && /etc/wireguard/wg0-postup.sh up
#
# Добавить новый донорский IPv6 (из префикса 2a01:230:4:df2::/64):
#   Ничего менять здесь не нужно — весь /64 маршрутизируется на vmbr0.
#   На VM1 добавить /128 маршрут и NDP proxy для нового адреса.
#   Внутри VM: address 2a01:230:4:df2::XX/128, gateway <link-local vmbr0>
#   (link-local: ip -6 addr show vmbr0 | grep fe80)

WG_PEER_GW4="10.99.0.1"
WG_PEER_GW6="fd00::1"
WG_DEV="wg0"
PBR_TABLE="viavm1"
VM_BRIDGE="vmbr0"

DONATED_V4=(
    "176.12.65.52"
    "176.12.65.56"
)

DONATED_V6_PREFIX="2a01:230:4:df2::/64"

case "$1" in
  up)
    # --- WireGuard gateway routes ---
    ip route replace ${WG_PEER_GW4}/32 dev ${WG_DEV}
    ip -6 route replace ${WG_PEER_GW6}/128 dev ${WG_DEV} 2>/dev/null || true

    # --- Policy routing table: донорские IP → через WireGuard ---
    ip route replace default dev ${WG_DEV} via ${WG_PEER_GW4} table ${PBR_TABLE}
    ip -6 route replace default dev ${WG_DEV} via ${WG_PEER_GW6} table ${PBR_TABLE} 2>/dev/null || true

    # --- IPv4: proxy ARP + маршруты донорских IP на мост ---
    echo 1 > /proc/sys/net/ipv4/conf/${VM_BRIDGE}/proxy_arp
    for ip4 in "${DONATED_V4[@]}"; do
        ip route replace ${ip4}/32 dev ${VM_BRIDGE}
        ip rule show | grep -q "from ${ip4}" || \
            ip rule add from ${ip4}/32 table ${PBR_TABLE} priority 100
    done

    # --- IPv6: proxy NDP + маршрут всего /64 префикса на мост ---
    echo 1 > /proc/sys/net/ipv6/conf/${VM_BRIDGE}/proxy_ndp
    echo 1 > /proc/sys/net/ipv6/conf/${WG_DEV}/proxy_ndp
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

  *)
    echo "Usage: $0 {up|down}"
    exit 1
    ;;
esac
