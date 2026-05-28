#!/usr/bin/env bash
# Восстановление сервисов на 176.99.153.88 после перезагрузки
# Запускать от root: bash fix-after-reboot.sh

set -euo pipefail

SERVER_IP="176.99.153.88"
EXTRA_IP="157.22.199.180"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
ok()  { echo "[OK]  $*"; }
err() { echo "[ERR] $*" >&2; }

# ---------- 1. RustDesk ----------
log "=== RustDesk ==="

for svc in hbbs hbbr; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
        if ! systemctl is-enabled "$svc" &>/dev/null; then
            systemctl enable "$svc"
            log "Enabled $svc"
        fi
        if ! systemctl is-active "$svc" &>/dev/null; then
            systemctl start "$svc"
            log "Started $svc"
        fi
        ok "$svc: $(systemctl is-active $svc)"
    else
        err "$svc.service unit не найден — создайте его вручную (см. runbook)"
    fi
done

# ---------- 2. Proxmox ----------
log "=== Proxmox ==="

for svc in pvedaemon pvestatd pveproxy; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
        systemctl enable "$svc" 2>/dev/null || true
        if ! systemctl is-active "$svc" &>/dev/null; then
            systemctl start "$svc"
            log "Started $svc"
        fi
        ok "$svc: $(systemctl is-active $svc)"
    else
        err "$svc не найден — это не Proxmox хост?"
    fi
done

# Поднять vmbr0 если не активен
if ip link show vmbr0 &>/dev/null; then
    state=$(cat /sys/class/net/vmbr0/operstate 2>/dev/null || echo unknown)
    if [[ "$state" != "up" ]]; then
        log "Поднимаем vmbr0..."
        ifup vmbr0 || systemctl restart networking
    fi
    ok "vmbr0: $state"
fi

# ---------- 3. IP-переброс с $EXTRA_IP ----------
log "=== IP-переброс $EXTRA_IP → $SERVER_IP ==="

# Включить ip_forward
if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward
    log "ip_forward включён"
fi

# Убедиться, что настройка сохранена
if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.d/99-ipforward.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-ipforward.conf
fi

# Определить основной интерфейс
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/{print $5; exit}')
log "Основной интерфейс: $IFACE"

# Проверить, настроен ли $EXTRA_IP как alias или через NAT
if ip addr show | grep -q "$EXTRA_IP"; then
    ok "$EXTRA_IP уже назначен на интерфейс"
else
    # Проверить наличие правил NAT для $EXTRA_IP
    if ! iptables -t nat -C PREROUTING -d "$EXTRA_IP" -j DNAT --to-destination "$SERVER_IP" 2>/dev/null; then
        iptables -t nat -A PREROUTING -d "$EXTRA_IP" -j DNAT --to-destination "$SERVER_IP"
        log "Добавлено правило PREROUTING DNAT $EXTRA_IP → $SERVER_IP"
    fi
    if ! iptables -t nat -C POSTROUTING -s "$SERVER_IP" -j SNAT --to-source "$EXTRA_IP" 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$SERVER_IP" -j SNAT --to-source "$EXTRA_IP"
        log "Добавлено правило POSTROUTING SNAT $SERVER_IP → $EXTRA_IP"
    fi
    ok "Правила NAT применены"
fi

# Сохранить правила iptables
if command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "Правила iptables сохранены в /etc/iptables/rules.v4"
fi

# ---------- Итоговый статус ----------
log "=== Итог ==="
echo ""
echo "Статус сервисов:"
for svc in hbbs hbbr pvedaemon pvestatd pveproxy; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
        printf "  %-20s %s\n" "$svc" "$(systemctl is-active $svc 2>/dev/null)"
    fi
done

echo ""
echo "IP-адреса:"
ip -4 addr show | grep "inet " | awk '{print "  "$2}'

echo ""
echo "Правила NAT (PREROUTING):"
iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -v "^Chain\|^num\|^$" | sed 's/^/  /' || echo "  (пусто)"

echo ""
log "Готово."
