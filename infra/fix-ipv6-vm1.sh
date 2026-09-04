#!/usr/bin/env bash
set -euo pipefail

ip -6 neigh add proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true

sed -i '/ip -6 neigh add proxy 2a01:230:4:df2::55/a PostUp   = ip -6 neigh add proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true' /etc/wireguard/wg0.conf
sed -i '/ip -6 neigh del proxy 2a01:230:4:df2::55/a PostDown = ip -6 neigh del proxy 2a01:230:4:df2::a1 dev ens3 2>/dev/null || true' /etc/wireguard/wg0.conf
