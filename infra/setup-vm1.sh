#!/usr/bin/env bash
# Полная установка/восстановление VM1 (157.22.199.180)
# Запускать от root: bash setup-vm1.sh
#
# Что делает:
#   - Устанавливает WireGuard
#   - Настраивает wg0 (IP-донор для VM2)
#   - Настраивает nftables (защита: блокировка доступа через тоннель к хосту)
#   - Включает автозапуск всего

set -euo pipefail
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# ЗАПОЛНИТЕ ПЕРЕД ЗАПУСКОМ
# ============================================================
VM1_PRIVATE_KEY="QK6WLsZIszcYHdhP6wetts+CVWxQt6UQ0ksPLK8Uf1Y="   # приватный ключ VM1
VM2_PUBLIC_KEY="1FhRTd/plDjoLrDvu6E7gHGlFS3xk+rhtlEUV2KFkBk="    # публичный ключ VM2
VM2_ENDPOINT="176.99.153.88:51820"                                  # адрес VM2

VM1_IP4="157.22.199.180"        # публичный IP VM1
VM1_WG4="10.99.0.1/30"         # WireGuard IPv4
VM1_WG6="fd00::1/64"           # WireGuard IPv6
WG_PORT="51821"                 # порт WireGuard на VM1

# Донорские IPv4 (будут переданы на VM2)
DONATED_V4=("176.12.65.52/32" "176.12.65.56/32")

# Донорский IPv6 префикс
DONATED_V6="2a01:230:4:df2::/64"

# AllowedIPs — всё что принадлежит VM2
PEER_ALLOWED="10.99.0.2/32, 176.12.65.52/32, 176.12.65.56/32, fd00::2/128, 2a01:230:4:df2::/64"
# ============================================================

log "=== Установка пакетов ==="
apt-get update -qq
apt-get install -y wireguard nftables

log "=== Настройка sysctl ==="
cat > /etc/sysctl.d/99-wg-donate.conf << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.ens3.proxy_arp = 1
net.ipv4.conf.all.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-wg-donate.conf

log "=== Настройка WireGuard ==="
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${VM1_PRIVATE_KEY}
ListenPort = ${WG_PORT}
Address    = ${VM1_WG4}, ${VM1_WG6}

PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = sysctl -w net.ipv6.conf.all.forwarding=1
PostUp   = sysctl -w net.ipv4.conf.ens3.proxy_arp=1
PostUp   = sysctl -w net.ipv4.conf.all.rp_filter=0
$(for ip4 in "${DONATED_V4[@]}"; do echo "PostUp   = ip route replace ${ip4} dev wg0"; done)
PostUp   = ip -6 route replace ${DONATED_V6} dev wg0

$(for ip4 in "${DONATED_V4[@]}"; do echo "PostDown = ip route del ${ip4} dev wg0 2>/dev/null || true"; done)
PostDown = ip -6 route del ${DONATED_V6} dev wg0 2>/dev/null || true

[Peer]
PublicKey           = ${VM2_PUBLIC_KEY}
Endpoint            = ${VM2_ENDPOINT}
AllowedIPs          = ${PEER_ALLOWED}
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf

log "=== Настройка nftables ==="
cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        # Блокировать прямой доступ через WireGuard тоннель к хосту
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
echo "Маршруты:"
ip route show | grep -E '176.12|10.99'
ip -6 route show | grep 2a01 || true
echo ""
echo "nftables:"
nft list ruleset
echo ""
log "VM1 настроена."
