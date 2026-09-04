# Runbook: Восстановление сервисов на 176.99.153.88 после перезагрузки

## Симптомы

После перезагрузки серверов перестают работать:
1. **RustDesk** — сервер удалённого доступа
2. **Proxmox** — веб-панель управления (порт 8006)
3. **IP-переброс** с 157.22.199.180 на 176.99.153.88

---

## 1. Диагностика

### Подключение к серверу
```bash
ssh root@176.99.153.88
```

### Быстрая проверка статуса всех сервисов
```bash
systemctl status hbbr hbbs pveproxy pvedaemon pvestatd
ip addr show
ip route show
iptables -t nat -L -n -v
```

---

## 2. Восстановление RustDesk Server

### Проверка сервисов
```bash
systemctl status hbbr   # relay server (порт 21117)
systemctl status hbbs   # signal server (порт 21115, 21116)
```

### Запуск и включение автозапуска
```bash
systemctl start hbbr hbbs
systemctl enable hbbr hbbs
```

### Проверка портов
```bash
ss -tulnp | grep -E '2111[567]'
```

### Если сервисы не установлены как systemd units
```bash
# Проверить расположение бинарников
which hbbr hbbs || find / -name "hbbr" -o -name "hbbs" 2>/dev/null | head -5

# Создать unit-файл для hbbs (если отсутствует)
cat > /etc/systemd/system/hbbs.service << 'EOF'
[Unit]
Description=RustDesk Signal Server
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/hbbs -r 176.99.153.88
WorkingDirectory=/var/lib/rustdesk
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Создать unit-файл для hbbr (если отсутствует)
cat > /etc/systemd/system/hbbr.service << 'EOF'
[Unit]
Description=RustDesk Relay Server
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/hbbr
WorkingDirectory=/var/lib/rustdesk
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hbbs hbbr
```

---

## 3. Восстановление Proxmox Web Panel

### Проверка статуса
```bash
systemctl status pveproxy
systemctl status pvedaemon
systemctl status pvestatd
```

### Запуск и включение
```bash
systemctl start pvedaemon pvestatd pveproxy
systemctl enable pvedaemon pvestatd pveproxy
```

### Проверка сетевого интерфейса и bridge
```bash
ip addr show vmbr0
cat /etc/network/interfaces
```

### Если bridge vmbr0 не поднялся
```bash
ifup vmbr0
# или
systemctl restart networking
```

### Проверка доступности панели
```bash
curl -sk https://localhost:8006 | head -20
```

---

## 4. Восстановление IP-переброса с 157.22.199.180

### Диагностика текущего состояния
```bash
# Проверить, добавлен ли IP 157.22.199.180 как alias
ip addr show | grep 157.22.199.180

# Проверить правила NAT
iptables -t nat -L PREROUTING -n -v
iptables -t nat -L POSTROUTING -n -v

# Проверить ip_forward
cat /proc/sys/net/ipv4/ip_forward
```

### Вариант A: IP-алиас (дополнительный IP на интерфейсе)
```bash
# Временно (до перезагрузки)
ip addr add 157.22.199.180/32 dev eth0

# Постоянно — добавить в /etc/network/interfaces:
# auto eth0:1
# iface eth0:1 inet static
#   address 157.22.199.180
#   netmask 255.255.255.255
```

### Вариант B: DNAT / IP-forwarding (перенаправление трафика)
```bash
# Включить ip_forward постоянно
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

# Пример правил iptables (скорректируйте порты под свои нужды)
# Все TCP с 157.22.199.180 → 176.99.153.88
iptables -t nat -A PREROUTING -d 157.22.199.180 -j DNAT --to-destination 176.99.153.88
iptables -t nat -A POSTROUTING -s 176.99.153.88 -j SNAT --to-source 157.22.199.180

# Сохранить правила
apt-get install -y iptables-persistent
iptables-save > /etc/iptables/rules.v4
```

### Вариант C: Маршрутизация через Proxmox (если 157.22.199.180 — IP на другом интерфейсе)
```bash
# Проверить конфиг сетевых интерфейсов Proxmox
cat /etc/network/interfaces

# Убедиться, что все интерфейсы прописаны с auto и правильными gateway
```

---

## 5. Предотвращение проблем в будущем

### Проверить все сервисы на автозапуск
```bash
systemctl list-unit-files --state=disabled | grep -E 'hbb|pve'
```

### Сохранить правила iptables
```bash
apt-get install -y iptables-persistent
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
```

### Проверить /etc/network/interfaces на наличие всех IP и bridge
```bash
cat /etc/network/interfaces
```

---

## 6. Быстрое восстановление (скрипт)

Запустить скрипт `fix-after-reboot.sh` из этой директории:

```bash
bash infra/fix-after-reboot.sh
```
