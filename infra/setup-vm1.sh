#!/usr/bin/env bash
# Полная установка/восстановление VM1 (157.22.199.180)
# Запускать от root: bash setup-vm1.sh

set -euo pipefail
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# ЗАПОЛНИТЕ ПЕРЕД ЗАПУСКОМ
# ============================================================
VM1_PRIVATE_KEY="QK6WLsZIszcYHdhP6wetts+CVWxQt6UQ0ksPLK8Uf1Y="
VM2_PUBLIC_KEY="1FhRTd/plDjoLrDvu6E7gHGlFS3xk+rhtlEUV2KFkBk="
VM2_ENDPOINT="176.99.153.88:51820"

VM1_IP4="157.22.199.180"
VM1_WG4="10.99.0.1/30"
VM1_WG6="fd00::1/64"
WG_PORT="51821"

# Активные донорские IPv4 (маршрутизируются через WireGuard на VM2)
DONATED_V4=(
    "176.12.65.52/32"    # cloud VM 101
    "176.12.65.56/32"    # резерв
    "176.12.65.218/32"   # VM 106
)
# Резерв (добавлять когда VM создана):
# "176.12.65.222/32"
# "176.12.65.227/32"
# "176.12.65.229/32"
# "176.12.65.230/32"
# "176.12.65.231/32"

# Активные донорские IPv6 (NDP proxy на ens3 + маршрут через wg0)
# ВАЖНО: НЕ используем /64 — у VM1 теперь есть собственный адрес ::2/64 на ens3 от ISP
DONATED_V6=(
    "2a01:230:4:df2::55"    # cloud VM 101
    "2a01:230:4:df2::77"    # OPNsense VM 100
    "2a01:230:4:df2::a1"    # VM2 Proxmox host
    "2a01:230:4:df2::c8"    # VM 106 (176.12.65.218)
)
# Резерв (добавлять когда VM создана):
# "2a01:230:4:df2::a3"   # 176.99.153.158
# "2a01:230:4:df2::b3"   # 176.12.65.56
# "2a01:230:4:df2::22"   # 176.12.65.222
# "2a01:230:4:df2::e4"   # 176.12.65.227
# "2a01:230:4:df2::a8"   # 176.12.65.229
# "2a01:230:4:df2::e3"   # 176.12.65.230
# "2a01:230:4:df2::d2"   # 176.12.65.231
# "2a01:230:4:df2::f6"   # 176.12.65.231

# Строим AllowedIPs из массивов
V4_ALLOWED=$(IFS=', '; echo "${DONATED_V4[*]}")
V6_128=("${DONATED_V6[@]/%//128}")
V6_ALLOWED=$(IFS=', '; echo "${V6_128[*]}")
PEER_ALLOWED="10.99.0.2/32, fd00::2/128, ${V4_ALLOWED}, ${V6_ALLOWED}"
# ============================================================

log "=== Установка пакетов ==="
apt-get update -qq
apt-get install -y wireguard nftables

log "=== Настройка sysctl ==="
cat > /etc/sysctl.d/99-wg-donate.conf << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.ens3.proxy_arp = 1
net.ipv6.conf.ens3.proxy_ndp = 1
net.ipv4.conf.all.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-wg-donate.conf

log "=== Настройка WireGuard ==="
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

{
echo "[Interface]"
echo "PrivateKey = ${VM1_PRIVATE_KEY}"
echo "ListenPort = ${WG_PORT}"
echo "Address    = ${VM1_WG4}, ${VM1_WG6}"
echo ""
echo "PostUp   = sysctl -w net.ipv4.ip_forward=1"
echo "PostUp   = sysctl -w net.ipv6.conf.all.forwarding=1"
echo "PostUp   = sysctl -w net.ipv4.conf.ens3.proxy_arp=1"
echo "PostUp   = sysctl -w net.ipv4.conf.all.rp_filter=0"
echo "PostUp   = echo 1 > /proc/sys/net/ipv6/conf/ens3/proxy_ndp"
for ip4 in "${DONATED_V4[@]}"; do
    echo "PostUp   = ip route replace ${ip4} dev wg0"
done
for ip6 in "${DONATED_V6[@]}"; do
    echo "PostUp   = ip -6 neigh add proxy ${ip6} dev ens3 2>/dev/null || true"
done
for ip6 in "${DONATED_V6[@]}"; do
    echo "PostUp   = ip -6 route replace ${ip6}/128 dev wg0"
done
echo ""
for ip4 in "${DONATED_V4[@]}"; do
    echo "PostDown = ip route del ${ip4} dev wg0 2>/dev/null || true"
done
for ip6 in "${DONATED_V6[@]}"; do
    echo "PostDown = ip -6 route del ${ip6}/128 dev wg0 2>/dev/null || true"
done
for ip6 in "${DONATED_V6[@]}"; do
    echo "PostDown = ip -6 neigh del proxy ${ip6} dev ens3 2>/dev/null || true"
done
echo ""
echo "[Peer]"
echo "PublicKey           = ${VM2_PUBLIC_KEY}"
echo "Endpoint            = ${VM2_ENDPOINT}"
echo "AllowedIPs          = ${PEER_ALLOWED}"
echo "PersistentKeepalive = 25"
} > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

log "=== Настройка nftables ==="
cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "wg0" ip daddr { ${VM1_IP4}, 10.99.0.1 } drop
        iifname "wg0" ip6 daddr { fd00::1 } drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

log "=== Включение сервисов ==="
systemctl enable --now nftables
nft -f /etc/nftables.conf
systemctl enable --now wg-quick@wg0

log "=== Проверка ==="
echo ""
echo "WireGuard:"
wg show
echo ""
echo "Маршруты IPv4:"
ip route show | grep -E '176.12|10.99'
echo ""
echo "Маршруты IPv6:"
ip -6 route show | grep -E 'df2|wg0' || true
echo ""
echo "NDP proxy:"
ip -6 neigh show dev ens3 | grep proxy || echo "(нет)"
echo ""
log "VM1 настроена."
