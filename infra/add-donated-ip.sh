#!/usr/bin/env bash
# Добавить новый донорский IPv4 в систему на VM2 (176.99.153.88)
# Запускать от root
#
# Использование: bash add-donated-ip.sh <ip> [bridge]
# Пример:        bash add-donated-ip.sh 176.12.65.60
#
# Для IPv6 — просто назначьте адрес из 2a01:230:4:df2:100::/80 внутри VM.
# Маршрут для всего /80 уже настроен в wg0-postup.sh.

set -euo pipefail

NEW_IP="${1:?Использование: bash add-donated-ip.sh <ipv4>}"
VM_BRIDGE="${2:-vmbr0}"
POSTUP="/etc/wireguard/wg0-postup.sh"
PBR_TABLE="viavm1"

if [[ ! -f "$POSTUP" ]]; then
    echo "Ошибка: $POSTUP не найден"
    exit 1
fi

echo "Добавляю IPv4 $NEW_IP → $VM_BRIDGE"

# 1. Добавить в DONATED_V4 если ещё нет
if grep -q "\"$NEW_IP\"" "$POSTUP"; then
    echo "  [уже есть] $NEW_IP в $POSTUP"
else
    sed -i "/^DONATED_V4=(/a\\    \"$NEW_IP\"" "$POSTUP"
    echo "  [+] Добавлен в DONATED_V4 в $POSTUP"
fi

# 2. Применить маршрут сразу
ip route replace "${NEW_IP}/32" dev "$VM_BRIDGE"
echo 1 > "/proc/sys/net/ipv4/conf/${VM_BRIDGE}/proxy_arp"
ip rule show | grep -q "from ${NEW_IP}" || \
    ip rule add from "${NEW_IP}/32" table "$PBR_TABLE" priority 100
echo "  [+] Маршрут и ip rule применены"

# 3. Инструкции для VM1
echo ""
echo "На VM1 (157.22.199.180) добавьте в /etc/wireguard/wg0.conf:"
echo "  AllowedIPs += $NEW_IP/32"
echo ""
echo "Затем применить на VM1:"
echo "  systemctl reload wg-quick@wg0 || wg set wg0 peer <pubkey> allowed-ips ...,${NEW_IP}/32"
echo "  ip route replace ${NEW_IP}/32 dev wg0"
echo ""
echo "Настройка внутри VM (IPv4):"
echo "  ip addr add ${NEW_IP}/32 dev eth0"
echo "  ip route add default via 176.99.153.88"
echo ""
echo "Настройка внутри VM (IPv6 из пула 2a01:230:4:df2::/64):"
echo "  Адрес: любой из диапазона 2a01:230:4:df2::2 — 2a01:230:4:df2:ffff:ffff:ffff:ffff"
echo "  (::1 занят VM1 как шлюз — не использовать)"
GW6=$(ip -6 addr show "$VM_BRIDGE" | awk '/fe80/{gsub("/.*","",$2); print $2; exit}')
echo "  ip addr add 2a01:230:4:df2::<N>/64 dev eth0    # N >= 2"
echo "  ip -6 route add default via ${GW6:-<link-local vmbr0>} dev eth0"
echo "  (link-local шлюза: ${GW6:-запустите: ip -6 addr show $VM_BRIDGE | grep fe80})"
