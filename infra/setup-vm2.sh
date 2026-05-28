#!/usr/bin/env bash
# Полная установка/восстановление VM2 (176.99.153.88 — Proxmox)
# Запускать от root: bash setup-vm2.sh
#
# Что делает:
#   - Устанавливает WireGuard, nftables
#   - Настраивает wg0 (клиент, policy routing для донорских IP)
#   - Настраивает nftables (защита хоста от доступа через тоннель)
#   - Создаёт systemd сервисы для RustDesk (hbbs + hbbr)
#   - Включает автозапуск всего
#
# Перед запуском:
#   - Положить бинарники RustDesk в /opt/rustdesk/ (hbbs, hbbr)
#   - Заполнить ключи ниже

set -euo pipefail
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# ЗАПОЛНИТЕ ПЕРЕД ЗАПУСКОМ
# ============================================================
VM2_PRIVATE_KEY="CPhe1r7lGShK6ZTYKFovhZpMNSazWXVNNtpkjgGSYmA="   # приватный ключ VM2
VM1_PUBLIC_KEY="MME3vkS0ai+f7vl6yOEW6F0vbMXvZKW+85iQvToCzGo="    # публичный ключ VM1
VM1_ENDPOINT="157.22.199.180:51821"                                  # адрес VM1

VM2_IP4="176.99.153.88"         # публичный IP VM2
VM2_WG4="10.99.0.2/30"         # WireGuard IPv4
VM2_WG6="fd00::2/64"           # WireGuard IPv6
WG_PORT="51820"                 # порт WireGuard на VM2

VM_BRIDGE="vmbr0"               # Proxmox мост для VM с донорскими IP
PBR_TABLE="viavm1"              # таблица policy routing

# Донорские IPv4
DONATED_V4=("176.12.65.52" "176.12.65.56")

# Донорский IPv6 префикс
DONATED_V6_PREFIX="2a01:230:4:df2::/64"
# ============================================================

log "=== Установка пакетов ==="
apt-get update -qq
apt-get install -y wireguard nftables

log "=== Таблица маршрутизации viavm1 ==="
if ! grep -q "${PBR_TABLE}" /etc/iproute2/rt_tables; then
    echo "200 ${PBR_TABLE}" >> /etc/iproute2/rt_tables
    log "Добавлена таблица ${PBR_TABLE}"
fi

log "=== Настройка WireGuard PostUp скрипта ==="
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /etc/wireguard/wg0-postup.sh << 'SCRIPT'
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
SCRIPT
chmod +x /etc/wireguard/wg0-postup.sh

log "=== Настройка WireGuard ==="
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${VM2_PRIVATE_KEY}
Address    = ${VM2_WG4}, ${VM2_WG6}
ListenPort = ${WG_PORT}
Table      = off

PostUp   = /etc/wireguard/wg0-postup.sh up
PostDown = /etc/wireguard/wg0-postup.sh down

[Peer]
PublicKey           = ${VM1_PUBLIC_KEY}
Endpoint            = ${VM1_ENDPOINT}
AllowedIPs          = 0.0.0.0/0, ::/0
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
        iifname "wg0" ip daddr { ${VM2_IP4}, 10.99.0.2 } drop
        iifname "wg0" ip6 daddr { fd00::2 } drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

log "=== RustDesk systemd сервисы ==="
if [[ -f /opt/rustdesk/hbbs ]]; then
    cat > /etc/systemd/system/hbbs.service << 'EOF'
[Unit]
Description=RustDesk Signal Server
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/opt/rustdesk/hbbs
WorkingDirectory=/opt/rustdesk
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/hbbr.service << 'EOF'
[Unit]
Description=RustDesk Relay Server
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/opt/rustdesk/hbbr
WorkingDirectory=/opt/rustdesk
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hbbs hbbr
    log "RustDesk включён"
else
    log "ВНИМАНИЕ: /opt/rustdesk/hbbs не найден — скопируйте бинарники и запустите:"
    log "  systemctl enable --now hbbs hbbr"
fi

log "=== Включение сервисов ==="
systemctl enable --now nftables
nft -f /etc/nftables.conf
systemctl enable --now wg-quick@wg0

log "=== Проверка ==="
echo ""
echo "WireGuard:"
wg show
echo ""
echo "Маршруты донорских IP:"
ip route show | grep -E '176.12|10.99'
ip -6 route show | grep 2a01 || true
echo ""
echo "IP rules:"
ip rule show | grep viavm1
echo ""
echo "nftables:"
nft list ruleset
echo ""
echo "RustDesk:"
systemctl is-active hbbs hbbr 2>/dev/null || echo "не запущен (нет бинарников?)"
echo ""
log "VM2 настроена."
