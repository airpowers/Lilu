# Шпаргалка: добавление донорских IP в VM

## Архитектура

```
Интернет → VM1 (157.22.199.180) → WireGuard → VM2 (176.99.153.88 / Proxmox)
                                                        ↓
                                              VM с донорским IP (vmbr0)
```

- **VM1** — шлюз, владеет публичными IP и IPv6 подсетью
- **VM2** — Proxmox, принимает трафик через WireGuard, маршрутизирует в VM-ы
- **VM** — получает донорский IP, выглядит как обычный публичный сервер

---

## Добавить новый IPv4

### 1. VM1 — `/etc/wireguard/wg0.conf`

Добавить в `AllowedIPs` строку `176.12.65.XX/32`:
```ini
AllowedIPs = 10.99.0.2/32, 176.12.65.52/32, 176.12.65.56/32, 176.12.65.XX/32, ...
```

Добавить в PostUp/PostDown:
```ini
PostUp   = ip route replace 176.12.65.XX/32 dev wg0
PostDown = ip route del 176.12.65.XX/32 dev wg0 2>/dev/null || true
```

Применить без разрыва туннеля:
```bash
wg syncconf wg0 <(wg-quick strip wg0)
ip route replace 176.12.65.XX/32 dev wg0
```

### 2. VM2 — `/etc/wireguard/wg0-postup.sh`

Добавить IP в массив:
```bash
DONATED_V4=( "176.12.65.52" "176.12.65.56" "176.12.65.XX" )
```

Применить сразу:
```bash
/etc/wireguard/wg0-postup.sh down && /etc/wireguard/wg0-postup.sh up
```

### 3. Внутри VM (`/etc/network/interfaces`)

```
auto eth0
iface eth0 inet static
    address 176.12.65.XX/32
    gateway 176.99.153.88
```

---

## Добавить новый IPv6

Пул: `2a01:230:4:df2::/64` (адреса `::2` и выше, `::1` занят ISP шлюзом)

### 1. VM1 — маршрут + NDP proxy

```bash
# Применить сейчас
ip -6 route add 2a01:230:4:df2::XX/128 dev wg0
ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3

# Сохранить в /etc/wireguard/wg0.conf:
# PostUp   = ip -6 route replace 2a01:230:4:df2::XX/128 dev wg0
# PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::XX dev ens3 2>/dev/null || true
# PostDown = ip -6 neigh del proxy 2a01:230:4:df2::XX dev ens3 2>/dev/null || true
```

### 2. VM2 — маршрут к VM (в `/etc/wireguard/wg0-postup.sh`, блок `up)`)

```bash
ip -6 route replace 2a01:230:4:df2::XX/128 dev vmbr0
```

Применить сразу:
```bash
ip -6 route replace 2a01:230:4:df2::XX/128 dev vmbr0
```

### 3. Внутри VM (`/etc/network/interfaces`)

```
iface eth0 inet6 static
    address 2a01:230:4:df2::XX/128
    gateway fe80::201:2eff:fea2:ccc5
```

---

## Итого на каждую новую VM

| | IPv4 | IPv6 |
|---|---|---|
| **VM1 wg0.conf** | `AllowedIPs` + `PostUp route` | `PostUp route` + `PostUp neigh proxy` |
| **VM2 wg0-postup.sh** | добавить в `DONATED_V4` | добавить `ip -6 route` в блок `up)` |
| **Внутри VM** | `/32`, gw `176.99.153.88` | `/128`, gw `fe80::201:2eff:fea2:ccc5` |

---

## Текущие назначения

| VM | IPv4 | IPv6 |
|----|------|------|
| cloud (VM 101) | `176.12.65.52` | `2a01:230:4:df2::55` |
| — | `176.12.65.56` | — |

---

## Важные файлы

| Файл | Где | Назначение |
|------|-----|------------|
| `/etc/wireguard/wg0.conf` | VM1 | WireGuard сервер, маршруты донорских IP |
| `/etc/wireguard/wg0.conf` | VM2 | WireGuard клиент |
| `/etc/wireguard/wg0-postup.sh` | VM2 | Policy routing, proxy_arp, маршруты к VM-ам |
| `/etc/nftables.conf` | VM1, VM2 | Защита хостов от доступа через тоннель |
| `/etc/systemd/system/hbbs.service` | VM2 | RustDesk signal server |
| `/etc/systemd/system/hbbr.service` | VM2 | RustDesk relay server |
| `/opt/rustdesk/` | VM2 | Бинарники и ключи RustDesk |

---

## Защита

- Доступ через WireGuard тоннель к **хосту VM1** — заблокирован (nftables)
- Доступ через WireGuard тоннель к **хосту VM2** — заблокирован (nftables)
- Трафик **насквозь** (VM1 → VM-ы) — разрешён (нужен для донорских IP)
