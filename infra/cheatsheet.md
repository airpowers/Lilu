---
title: "Шпаргалка: Инфраструктура VM1 / VM2 / Proxmox"
author: "airpowers"
date: "2026-05-29"
geometry: margin=2cm
fontsize: 10pt
mainfont: DejaVu Sans
monofont: DejaVu Sans Mono
header-includes:
  - \usepackage{fancyhdr}
  - \pagestyle{fancy}
  - \fancyhead[L]{Инфраструктура VM1/VM2}
  - \fancyhead[R]{\thepage}
  - \usepackage{xcolor}
  - \definecolor{codebg}{RGB}{245,245,245}
  - \usepackage{mdframed}
toc: true
toc-depth: 3
---

---

# Архитектура

```
Интернет
   │
   ▼
VM1 (157.22.199.180)          ← публичный шлюз, владеет донорскими IP
   │  WireGuard туннель
   │  10.99.0.1 ↔ 10.99.0.2
   ▼
VM2 / Proxmox (176.99.153.88) ← принимает трафик, маршрутизирует в VM-ы
   │  vmbr0 (Proxmox bridge)
   ├──▶ VM 101 (cloud)   — 176.12.65.52  / 2a01:230:4:df2::55
   ├──▶ VM 100 (OPNsense) — 176.99.153.89 (WAN), 192.168.5.1 (LAN)
   └──▶ VM XXX (новые)   — 176.12.65.XX  / 2a01:230:4:df2::XX
```

**WireGuard туннель:**

| | VM1 | VM2 |
|---|---|---|
| Публичный IP | `157.22.199.180` | `176.99.153.88` |
| WireGuard IPv4 | `10.99.0.1/30` | `10.99.0.2/30` |
| WireGuard IPv6 | `fd00::1/64` | `fd00::2/64` |
| WireGuard порт | `51821` (listen) | `51820` (listen) |

**Донорские IP:**

| Пул | Диапазон |
|---|---|
| IPv4 | `176.12.65.0/24` (используем отдельные /32) |
| IPv6 | `2a01:230:4:df2::/64` (::2 и выше, ::1 занят ISP) |

---

# VM1 — Шлюз (157.22.199.180)

## Ключевые файлы

| Файл | Назначение |
|---|---|
| `/etc/wireguard/wg0.conf` | WireGuard сервер, маршруты донорских IP |
| `/etc/nftables.conf` | Защита хоста |
| `/etc/sysctl.d/99-wg-donate.conf` | ip_forward, proxy_arp |

## `/etc/wireguard/wg0.conf` (VM1)

```ini
[Interface]
PrivateKey = <ПРИВАТНЫЙ_КЛЮЧ_VM1>
ListenPort = 51821
Address    = 10.99.0.1/30, fd00::1/64

PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = sysctl -w net.ipv6.conf.all.forwarding=1
PostUp   = sysctl -w net.ipv4.conf.ens3.proxy_arp=1
PostUp   = sysctl -w net.ipv4.conf.all.rp_filter=0
PostUp   = ip route replace 176.12.65.52/32 dev wg0
PostUp   = ip route replace 176.12.65.56/32 dev wg0
PostUp   = ip -6 route replace 2a01:230:4:df2::/64 dev wg0
PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::55 dev ens3 2>/dev/null || true
PostDown = ip route del 176.12.65.52/32 dev wg0 2>/dev/null || true
PostDown = ip route del 176.12.65.56/32 dev wg0 2>/dev/null || true
PostDown = ip -6 route del 2a01:230:4:df2::/64 dev wg0 2>/dev/null || true
PostDown = ip -6 neigh del proxy 2a01:230:4:df2::55 dev ens3 2>/dev/null || true

[Peer]
PublicKey           = <ПУБЛИЧНЫЙ_КЛЮЧ_VM2>
Endpoint            = 176.99.153.88:51820
AllowedIPs          = 10.99.0.2/32, 176.12.65.52/32, 176.12.65.56/32,
                      fd00::2/128, 2a01:230:4:df2::/64
PersistentKeepalive = 25
```

## `/etc/nftables.conf` (VM1)

```
table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "wg0" ip daddr { 157.22.199.180, 10.99.0.1 } drop
        iifname "wg0" ip6 daddr { fd00::1 } drop
    }
    chain forward { type filter hook forward priority filter; policy accept; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
```

## Команды управления (VM1)

```bash
# Статус WireGuard
wg show

# Применить изменения wg0.conf без разрыва туннеля
wg syncconf wg0 <(wg-quick strip wg0)

# Перезапуск WireGuard
systemctl restart wg-quick@wg0

# Применить nftables
nft -f /etc/nftables.conf

# Добавить NDP proxy для нового IPv6 адреса
ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3

# Добавить маршрут нового IPv4
ip route replace 176.12.65.XX/32 dev wg0
```

---

# VM2 — Proxmox (176.99.153.88)

## Ключевые файлы

| Файл | Назначение |
|---|---|
| `/etc/wireguard/wg0.conf` | WireGuard клиент |
| `/etc/wireguard/wg0-postup.sh` | Policy routing, proxy_arp, маршруты к VM-ам |
| `/etc/nftables.conf` | Защита хоста |
| `/etc/iproute2/rt_tables` | Таблица `viavm1` (строка: `200 viavm1`) |
| `/etc/systemd/system/hbbs.service` | RustDesk signal server |
| `/etc/systemd/system/hbbr.service` | RustDesk relay server |
| `/opt/rustdesk/` | Бинарники RustDesk (hbbs, hbbr) |

## `/etc/wireguard/wg0.conf` (VM2)

```ini
[Interface]
PrivateKey = <ПРИВАТНЫЙ_КЛЮЧ_VM2>
Address    = 10.99.0.2/30, fd00::2/64
ListenPort = 51820
Table      = off

PostUp   = /etc/wireguard/wg0-postup.sh up
PostDown = /etc/wireguard/wg0-postup.sh down

[Peer]
PublicKey           = <ПУБЛИЧНЫЙ_КЛЮЧ_VM1>
Endpoint            = 157.22.199.180:51821
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

## `/etc/wireguard/wg0-postup.sh` (VM2)

```bash
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
        ip -6 rule add from ${DONATED_V6_PREFIX} table ${PBR_TABLE} priority 100 \
        2>/dev/null || true
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
esac
```

## `/etc/nftables.conf` (VM2)

```
table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "wg0" ip daddr { 176.99.153.88, 10.99.0.2 } drop
        iifname "wg0" ip6 daddr { fd00::2 } drop
    }
    chain forward { type filter hook forward priority filter; policy accept; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
```

## RustDesk systemd сервисы (VM2)

**`/etc/systemd/system/hbbs.service`:**
```ini
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
```

**`/etc/systemd/system/hbbr.service`:**
```ini
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
```

## Команды управления (VM2)

```bash
# WireGuard
systemctl restart wg-quick@wg0
wg show

# Policy routing: применить изменения wg0-postup.sh
/etc/wireguard/wg0-postup.sh down && /etc/wireguard/wg0-postup.sh up

# Статус routing
ip rule show | grep viavm1
ip route show table viavm1
ip route show | grep 176.12

# RustDesk
systemctl status hbbs hbbr
systemctl restart hbbs hbbr
journalctl -u hbbs -f

# nftables
nft -f /etc/nftables.conf
nft list ruleset
```

---

# Добавить новую VM с донорским IP

## Шаг 1 — VM2: добавить IPv4 в routing

```bash
# Автоматически (скрипт обновит wg0-postup.sh и применит маршруты)
bash /path/to/add-donated-ip.sh 176.12.65.XX

# Или вручную:
# 1. Добавить "176.12.65.XX" в DONATED_V4 в /etc/wireguard/wg0-postup.sh
# 2. Применить:
ip route replace 176.12.65.XX/32 dev vmbr0
echo 1 > /proc/sys/net/ipv4/conf/vmbr0/proxy_arp
ip rule add from 176.12.65.XX/32 table viavm1 priority 100
```

## Шаг 2 — VM1: добавить IPv4 в AllowedIPs и маршрут

В `/etc/wireguard/wg0.conf` добавить в AllowedIPs пира:
```
AllowedIPs = ..., 176.12.65.XX/32
```

Добавить PostUp/PostDown:
```ini
PostUp   = ip route replace 176.12.65.XX/32 dev wg0
PostDown = ip route del 176.12.65.XX/32 dev wg0 2>/dev/null || true
```

Применить без разрыва туннеля:
```bash
wg syncconf wg0 <(wg-quick strip wg0)
ip route replace 176.12.65.XX/32 dev wg0
```

## Шаг 3 — VM1: добавить NDP proxy для нового IPv6

```bash
# Применить сейчас
ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3

# Сохранить в PostUp wg0.conf:
# PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3 2>/dev/null || true
# PostDown = ip -6 neigh del proxy 2a01:230:4:df2::XX dev ens3 2>/dev/null || true
```

## Шаг 4 — Внутри новой VM: `/etc/network/interfaces`

```ini
# Узнать имя интерфейса: ip link show
# Обычно eth0 или ens18

auto eth0
iface eth0 inet static
    address 176.12.65.XX/32
    gateway 176.99.153.88

iface eth0 inet6 static
    address 2a01:230:4:df2::XX/128
    post-up   ip -6 route replace default via fe80::201:2eff:fea2:ccc5 dev eth0
    pre-down  ip -6 route del default via fe80::201:2eff:fea2:ccc5 dev eth0 \
              2>/dev/null || true
```

> **Важно:** не использовать `gateway fe80::...` — ifupdown не умеет link-local шлюз.
> Использовать `post-up` с явным `dev`.

Применить:
```bash
ifdown eth0 2>/dev/null; ip addr flush dev eth0; ifup eth0
# или просто перезагрузить VM
```

---

# Полное восстановление с нуля

## VM1 (157.22.199.180)

```bash
# Клонировать репозиторий
git clone <repo_url>
cd repo/infra

# Заполнить ключи в setup-vm1.sh, затем:
bash setup-vm1.sh
```

## VM2 (176.99.153.88)

```bash
# Положить бинарники RustDesk:
mkdir -p /opt/rustdesk
# скопировать hbbs и hbbr в /opt/rustdesk/
chmod +x /opt/rustdesk/hbbs /opt/rustdesk/hbbr

# Заполнить ключи в setup-vm2.sh, затем:
bash setup-vm2.sh
```

---

# Текущие назначения IP

| VM | IPv4 | IPv6 |
|----|------|------|
| VM 101 (cloud) | `176.12.65.52` | `2a01:230:4:df2::55` |
| VM 100 (OPNsense WAN) | `176.99.153.89` | — |
| (свободен) | `176.12.65.56` | — |

**IPv6 шлюз внутри VM:** `fe80::201:2eff:fea2:ccc5` (link-local vmbr0)

---

# OPNsense (VM 100)

- WAN: `176.99.153.89` (ens0 на VM2 → tap интерфейс VM 100)
- LAN: `192.168.5.1` (ens1 → ciscobr1 на VM2)

## Доступ к веб-интерфейсу OPNsense

```bash
# 1. На VM2: добавить временный IP на ciscobr1
ip addr add 192.168.5.254/24 dev ciscobr1

# 2. На локальной машине: SSH-туннель через VM2
ssh -L 8443:192.168.5.1:443 root@176.99.153.88

# 3. Открыть в браузере:
#    https://localhost:8443

# 4. После работы — убрать временный IP
ip addr del 192.168.5.254/24 dev ciscobr1
```

---

# Диагностика и проверка

## Проверить что туннель работает (VM2)

```bash
wg show                          # peers, handshake, трафик
ping 10.99.0.1                   # ping VM1 через WireGuard
ping6 fd00::1                    # ping VM1 IPv6
```

## Проверить routing донорских IP (VM2)

```bash
ip rule show | grep viavm1       # policy rules
ip route show table viavm1       # маршруты в таблице viavm1
ip route show | grep 176.12      # маршруты к донорским IP → vmbr0
ip -6 route show | grep 2a01     # IPv6 маршрут на vmbr0
```

## Проверить защиту nftables

```bash
# С VM1 попробовать достучаться до VM2 напрямую — должно быть заблокировано:
# ssh root@10.99.0.2    → timeout (заблокировано nftables на VM2)
# ssh root@10.99.0.1    → timeout (заблокировано nftables на VM1)

nft list ruleset                 # посмотреть правила
```

## Проверить работу донорского IP изнутри VM

```bash
# На VM 101:
ip addr show ens18               # 176.12.65.52/32 + 2a01:230:4:df2::55/128
ip route show default            # via 176.99.153.88
ip -6 route show default         # via fe80::201:2eff:fea2:ccc5

# Снаружи:
ping 176.12.65.52
ping6 2a01:230:4:df2::55
```

## Проверить RustDesk

```bash
systemctl status hbbs hbbr
ss -tlnp | grep -E '21115|21116|21117|21118'
journalctl -u hbbs --since "10 min ago"
```

## Типичные ошибки при перезагрузке

| Симптом | Причина | Решение |
|---------|---------|---------|
| `networking.service` failed, "Address already assigned" | ifupdown не знает что интерфейс уже поднят (сломанный ifstate) | `ip addr flush dev ens18 && service networking restart` |
| `gateway fe80::...` не работает | ifupdown не поддерживает link-local шлюз | Заменить на `post-up ip -6 route replace ... dev eth0` |
| IPv6 не пингуется извне | Нет NDP proxy на VM1 ens3 | `ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3` + добавить в PostUp |
| Донорский IP не доступен после reboot VM2 | wg0-postup.sh не запустился | `systemctl restart wg-quick@wg0` |
| RustDesk не стартует | Нет бинарников или неверный путь | Проверить `/opt/rustdesk/hbbs` и `hbbr`, `chmod +x` |

---

# Быстрые команды (шпаргалка)

```bash
# === VM1 ===
systemctl restart wg-quick@wg0          # перезапуск WireGuard
wg syncconf wg0 <(wg-quick strip wg0)   # применить wg0.conf без разрыва
nft -f /etc/nftables.conf               # применить nftables
ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3  # NDP proxy для нового IPv6

# === VM2 ===
systemctl restart wg-quick@wg0          # перезапуск WireGuard
/etc/wireguard/wg0-postup.sh down && \
/etc/wireguard/wg0-postup.sh up         # пересоздать маршруты
systemctl restart hbbs hbbr             # перезапуск RustDesk
nft -f /etc/nftables.conf               # применить nftables
bash add-donated-ip.sh 176.12.65.XX     # добавить новый донорский IP

# === Внутри VM (новый донорский IP) ===
ip addr flush dev eth0 && ifup eth0     # перенастроить интерфейс
systemctl status networking.service     # статус сети
```

---

*Репозиторий: airpowers/Lilu, ветка `claude/server-176-outages-reboot-KvpYp`*
