#!/bin/bash
# VM2 (176.99.153.88) WireGuard PostUp/PostDown script
# Управляет policy routing для донорских IP от VM1 (157.22.199.180)
#
# Чтобы добавить новый донорский IP:
#   1. Добавить IP в DONATED_V4 ниже
#   2. Добавить IP в AllowedIPs в /etc/wireguard/wg0.conf на VM1
#   3. Запустить: wg syncconf wg0 <(wg-quick strip wg0)
#   4. Запустить: /etc/wireguard/wg0-postup.sh up
#
# Чтобы пробросить IP в VM:
#   - Подключить VM к vmbr0 в Proxmox
#   - Внутри VM: ip addr add <donated_ip>/32 dev eth0
#   - Внутри VM: ip route add default via 176.99.153.88

WG_PEER_GW4="10.99.0.1"
WG_PEER_GW6="fd00::1"
WG_DEV="wg0"
PBR_TABLE="viavm1"
VM_BRIDGE="vmbr0"

# Список донорских IPv4 (от VM1)
DONATED_V4=(
    "176.12.65.52"
    "176.12.65.56"
)

# Донорский IPv6 префикс
DONATED_V6_PREFIX="2a01:230:4:df2:100::/80"

case "$1" in
  up)
    # Маршрут к WireGuard шлюзу
    ip route replace ${WG_PEER_GW4}/32 dev ${WG_DEV}
    ip -6 route replace ${WG_PEER_GW6}/128 dev ${WG_DEV} 2>/dev/null || true

    # Таблица viavm1: исходящий трафик с донорских IP идёт через WireGuard
    ip route replace default dev ${WG_DEV} via ${WG_PEER_GW4} table ${PBR_TABLE}
    ip -6 route replace default dev ${WG_DEV} via ${WG_PEER_GW6} table ${PBR_TABLE} 2>/dev/null || true

    # Proxy ARP на мосту — хост отвечает на ARP-запросы для донорских IP
    echo 1 > /proc/sys/net/ipv4/conf/${VM_BRIDGE}/proxy_arp

    for ip4 in "${DONATED_V4[@]}"; do
        # Входящий трафик: направить на мост (VM с этим IP ответит сама)
        ip route replace ${ip4}/32 dev ${VM_BRIDGE}

        # Исходящий трафик из VM: использовать таблицу viavm1 (через WireGuard)
        ip rule show | grep -q "from ${ip4}" || \
            ip rule add from ${ip4}/32 table ${PBR_TABLE} priority 100
    done

    # IPv6 policy routing
    ip -6 rule show | grep -q "from ${DONATED_V6_PREFIX}" || \
        ip -6 rule add from ${DONATED_V6_PREFIX} table ${PBR_TABLE} priority 100 2>/dev/null || true
    ;;

  down)
    for ip4 in "${DONATED_V4[@]}"; do
        ip rule del from ${ip4}/32 table ${PBR_TABLE} 2>/dev/null || true
        ip route del ${ip4}/32 dev ${VM_BRIDGE} 2>/dev/null || true
    done
    ip -6 rule del from ${DONATED_V6_PREFIX} table ${PBR_TABLE} 2>/dev/null || true
    ip route del default table ${PBR_TABLE} 2>/dev/null || true
    ip -6 route del default table ${PBR_TABLE} 2>/dev/null || true
    ip route del ${WG_PEER_GW4}/32 dev ${WG_DEV} 2>/dev/null || true
    ;;

  *)
    echo "Usage: $0 {up|down}"
    exit 1
    ;;
esac
