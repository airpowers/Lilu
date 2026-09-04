#!/usr/bin/env bash
# Запускать на VM1 (157.22.199.180)
# Добавляет VM 106 (176.12.65.218 / 2a01:230:4:df2::c8) в wg0.conf и применяет маршруты.
# Также проверяет и включает proxy_arp (нужен для IPv4 донорских адресов).

set -euo pipefail

NEW_V4="176.12.65.218"
NEW_V6="2a01:230:4:df2::c8"

echo "=== Шаг 1: включаем proxy_arp на ens3 (исправляет IPv4) ==="
echo 1 > /proc/sys/net/ipv4/conf/ens3/proxy_arp
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv4/conf/ens3/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo "proxy_arp = $(cat /proc/sys/net/ipv4/conf/ens3/proxy_arp)"

echo "=== Шаг 2: применяем маршруты для VM 106 ==="
ip route replace ${NEW_V4}/32 dev wg0 && echo "  route ${NEW_V4}/32 -> wg0 OK"
ip -6 route replace ${NEW_V6}/128 dev wg0 && echo "  route ${NEW_V6}/128 -> wg0 OK"

echo "=== Шаг 3: NDP proxy для VM 106 ==="
echo 1 > /proc/sys/net/ipv6/conf/ens3/proxy_ndp
ip -6 neigh add proxy ${NEW_V6} dev ens3 2>/dev/null && echo "  proxy ${NEW_V6} OK" || echo "  proxy ${NEW_V6} уже есть"

echo "=== Шаг 4: обновляем wg0.conf ==="
PRIV_KEY=$(grep PrivateKey /etc/wireguard/wg0.conf | awk '{print $3}')
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${PRIV_KEY}
ListenPort = 51821
Address    = 10.99.0.1/30, fd00::1/64

PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = sysctl -w net.ipv6.conf.all.forwarding=1
PostUp   = sysctl -w net.ipv4.conf.ens3.proxy_arp=1
PostUp   = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp   = echo 1 > /proc/sys/net/ipv6/conf/ens3/proxy_ndp
PostUp   = ip route replace 176.12.65.52/32 dev wg0
PostUp   = ip route replace 176.12.65.56/32 dev wg0
PostUp   = ip route replace 176.12.65.218/32 dev wg0
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::55 dev ens3 2>/dev/null || true
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::77 dev ens3 2>/dev/null || true
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::c8 dev ens3 2>/dev/null || true
PostUp   = ip -6 route replace 2a01:230:4:df2::55/128 dev wg0
PostUp   = ip -6 route replace 2a01:230:4:df2::77/128 dev wg0
PostUp   = ip -6 route replace 2a01:230:4:df2::a1/128 dev wg0
PostUp   = ip -6 route replace 2a01:230:4:df2::c8/128 dev wg0

PostDown = ip route del 176.12.65.52/32 dev wg0 2>/dev/null || true
PostDown = ip route del 176.12.65.56/32 dev wg0 2>/dev/null || true
PostDown = ip route del 176.12.65.218/32 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::55/128 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::77/128 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::a1/128 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::c8/128 dev wg0 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::55 dev ens3 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::77 dev ens3 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::c8 dev ens3 2>/dev/null || true

[Peer]
PublicKey           = 1FhRTd/plDjoLrDvu6E7gHGlFS3xk+rhtlEUV2KFkBk=
Endpoint            = 176.99.153.88:51820
AllowedIPs          = 10.99.0.2/32, fd00::2/128, 176.12.65.52/32, 176.12.65.56/32, 176.12.65.218/32, 2a01:230:4:df2::55/128, 2a01:230:4:df2::77/128, 2a01:230:4:df2::a1/128, 2a01:230:4:df2::c8/128
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf
echo "wg0.conf обновлён"

echo "=== Шаг 5: применяем новый AllowedIPs без разрыва туннеля ==="
wg syncconf wg0 <(wg-quick strip wg0)

echo ""
echo "=== Проверка ==="
echo "--- proxy_arp ens3 ---"
cat /proc/sys/net/ipv4/conf/ens3/proxy_arp
echo "--- IPv4 маршруты через wg0 ---"
ip route show | grep wg0
echo "--- IPv6 маршруты через wg0 ---"
ip -6 route show | grep wg0
echo "--- NDP proxy ---"
ip -6 neigh show dev ens3 | grep proxy || echo "(нет proxy записей)"
echo "--- WireGuard AllowedIPs ---"
wg show wg0 allowed-ips
echo ""
echo "Готово."
echo "Проверь IPv4: ping -c3 176.12.65.218 (с VM2 или извне)"
echo "Проверь IPv6: ping6 -c3 2a01:230:4:df2::c8"
