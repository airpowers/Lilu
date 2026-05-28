#!/usr/bin/env bash
# Добавить новый донорский IP в систему
# Запускать на VM2 (176.99.153.88) от root
#
# Использование: bash add-donated-ip.sh <ip> [vm_bridge]
# Пример:        bash add-donated-ip.sh 176.12.65.60
# Пример:        bash add-donated-ip.sh 176.12.65.60 vmbr1

set -euo pipefail

NEW_IP="${1:?Укажите IP: bash add-donated-ip.sh <ip>}"
VM_BRIDGE="${2:-vmbr0}"
POSTUP="/etc/wireguard/wg0-postup.sh"
WG_CONF_VM1="/etc/wireguard/wg0.conf"

echo "Добавляю $NEW_IP → $VM_BRIDGE"

# 1. Добавить в wg0-postup.sh
if grep -q "\"$NEW_IP\"" "$POSTUP"; then
    echo "  [уже есть] $NEW_IP в $POSTUP"
else
    sed -i "/^DONATED_V4=(/a\\    \"$NEW_IP\"" "$POSTUP"
    echo "  [+] Добавлен в DONATED_V4 в $POSTUP"
fi

# 2. Применить маршрут сразу (без рестарта WireGuard)
PBR_TABLE="viavm1"
ip route replace "${NEW_IP}/32" dev "$VM_BRIDGE"
echo 1 > "/proc/sys/net/ipv4/conf/${VM_BRIDGE}/proxy_arp"
ip rule show | grep -q "from ${NEW_IP}" || \
    ip rule add from "${NEW_IP}/32" table "$PBR_TABLE" priority 100
echo "  [+] Маршрут и ip rule применены"

# 3. Напомнить про VM1
echo ""
echo "Осталось на VM1 (157.22.199.180):"
echo "  Добавить в /etc/wireguard/wg0.conf в секцию [Peer] AllowedIPs:"
echo "  $NEW_IP/32"
echo ""
echo "  Затем применить:"
echo "  ssh root@157.22.199.180 \"ip route replace $NEW_IP/32 dev wg0 && wg set wg0 peer \$(wg show wg0 peers) allowed-ips \$(wg show wg0 allowed-ips | awk '{print \$2}'),$NEW_IP/32\""
echo ""
echo "  Или просто перезапустить WireGuard на VM1:"
echo "  ssh root@157.22.199.180 'systemctl restart wg-quick@wg0'"
echo ""
echo "Настройка внутри VM:"
echo "  ip addr add $NEW_IP/32 dev eth0"
echo "  ip route add default via 176.99.153.88"
echo ""
echo "Готово."
