#!/usr/bin/env bash
# Запускать на VM1 (157.22.199.180)
# Исправляет конфликт IPv6 маршрутов после того как ISP назначил 2a01:230:4:df2::2/64 на ens3.
# Проблема: AllowedIPs = 2a01:230:4:df2::/64 заставлял WireGuard добавлять маршрут
#           для всего /64 через wg0, что перебивало ISP-маршрут через ens3.
# Решение: заменить /64 на конкретные /128 для каждого донорского адреса.

set -euo pipefail

ACTIVE_V6=("2a01:230:4:df2::55" "2a01:230:4:df2::77" "2a01:230:4:df2::a1")

echo "=== Шаг 1: удаляем конфликтующий /64 маршрут ==="
ip -6 route del 2a01:230:4:df2::/64 dev wg0 2>/dev/null && echo "Удалён" || echo "Не был установлен"

echo "=== Шаг 2: включаем proxy_ndp на ens3 ==="
echo 1 > /proc/sys/net/ipv6/conf/ens3/proxy_ndp

echo "=== Шаг 3: добавляем /128 маршруты через wg0 ==="
for ip6 in "${ACTIVE_V6[@]}"; do
    ip -6 route replace "${ip6}/128" dev wg0 2>/dev/null && echo "  route ${ip6}/128 -> wg0 OK"
done

echo "=== Шаг 4: добавляем NDP proxy записи на ens3 ==="
for ip6 in "${ACTIVE_V6[@]}"; do
    ip -6 neigh add proxy "${ip6}" dev ens3 2>/dev/null && echo "  proxy ${ip6} OK" || echo "  proxy ${ip6} уже есть"
done

echo "=== Шаг 5: обновляем wg0.conf ==="
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
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::55 dev ens3 2>/dev/null || true
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::77 dev ens3 2>/dev/null || true
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true
PostUp   = ip -6 route replace 2a01:230:4:df2::55/128 dev wg0
PostUp   = ip -6 route replace 2a01:230:4:df2::77/128 dev wg0
PostUp   = ip -6 route replace 2a01:230:4:df2::a1/128 dev wg0

PostDown = ip route del 176.12.65.52/32 dev wg0 2>/dev/null || true
PostDown = ip route del 176.12.65.56/32 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::55/128 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::77/128 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::a1/128 dev wg0 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::55 dev ens3 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::77 dev ens3 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true

[Peer]
PublicKey           = 1FhRTd/plDjoLrDvu6E7gHGlFS3xk+rhtlEUV2KFkBk=
Endpoint            = 176.99.153.88:51820
AllowedIPs          = 10.99.0.2/32, fd00::2/128,
                      176.12.65.52/32, 176.12.65.56/32,
                      2a01:230:4:df2::55/128, 2a01:230:4:df2::77/128, 2a01:230:4:df2::a1/128
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf
echo "wg0.conf обновлён"

echo "=== Шаг 6: применяем новый AllowedIPs без разрыва туннеля ==="
wg syncconf wg0 <(wg-quick strip wg0)

echo ""
echo "=== Проверка ==="
echo "--- IPv6 маршруты через wg0 ---"
ip -6 route show | grep wg0
echo "--- NDP proxy ---"
ip -6 neigh show dev ens3 | grep proxy || echo "(нет proxy записей)"
echo "--- WireGuard ---"
wg show wg0
echo ""
echo "Готово. Проверь связь: ping6 -c3 2a01:230:4:df2::55"
