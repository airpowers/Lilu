#!/usr/bin/env bash
# Быстрая диагностика сервера 176.99.153.88
# Запускать от root: bash check-services.sh

SERVER_IP="176.99.153.88"
EXTRA_IP="157.22.199.180"

sep() { echo "───────────────────────────────────────"; }

echo "ДИАГНОСТИКА СЕРВЕРА $SERVER_IP"
echo "$(date)"
sep

echo "▶ RustDesk (hbbs/hbbr):"
for svc in hbbs hbbr; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
        active=$(systemctl is-active "$svc" 2>/dev/null)
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null)
        echo "  $svc: active=$active  enabled=$enabled"
    else
        echo "  $svc: unit-файл НЕ НАЙДЕН"
    fi
done
echo "  Порты RustDesk:"
ss -tulnp 2>/dev/null | grep -E '2111[567]' | awk '{print "    "$1,$5}' || echo "    (не слушает)"

sep
echo "▶ Proxmox:"
for svc in pvedaemon pvestatd pveproxy; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
        active=$(systemctl is-active "$svc" 2>/dev/null)
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null)
        echo "  $svc: active=$active  enabled=$enabled"
    else
        echo "  $svc: НЕ НАЙДЕН"
    fi
done
echo "  Порт 8006:"
ss -tulnp 2>/dev/null | grep ':8006' | awk '{print "    "$1,$5}' || echo "    (не слушает)"

sep
echo "▶ Сеть:"
echo "  ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
echo ""
echo "  Интерфейсы (IPv4):"
ip -4 addr show | grep "inet " | awk '{print "    "$2"\t("$NF")"}'
echo ""
echo "  Наличие $EXTRA_IP:"
if ip addr show | grep -q "$EXTRA_IP"; then
    echo "    НАЗНАЧЕН на интерфейс"
else
    echo "    не назначен — ищем NAT-правила"
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep "$EXTRA_IP" | sed 's/^/    /' || echo "    NAT-правил тоже нет!"
fi

sep
echo "▶ Правила NAT:"
iptables -t nat -L -n -v 2>/dev/null | grep -v "^$" | sed 's/^/  /'

sep
echo "Готово."
