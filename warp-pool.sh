#!/usr/bin/env bash
# warp-pool.sh - pool de egress WARP via N contas wgcf + N wireproxy SOCKS5
# Cada conta wgcf = tunel WireGuard proprio = egress de pool diferente (burla o /64 finito do warp-cli)
# Uso: warp-pool.sh setup [N] | start [N] | stop | ips [N] | rotate [N] | status
set -u
BASE="$HOME/zen-opencode"
TOOLS="$BASE/tools"
ACC="$BASE/warp-accounts"
PBASE=51000
N="${2:-5}"

mkconf() {
  local d="$1" port="$2"
  python3 - "$d" "$port" <<'PY'
import sys,re,os
d=sys.argv[1]; port=sys.argv[2]
p=open(os.path.join(d,'wgcf-profile.conf')).read()
def g(k): return re.search(r'^%s\s*=\s*(.+)$'%k,p,re.M).group(1)
cfg=f"""[Interface]
Address = {g('Address')}
PrivateKey = {g('PrivateKey')}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = {g('PublicKey')}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {g('Endpoint')}

[Socks5]
BindAddress = 127.0.0.1:{port}
"""
open(os.path.join(d,'wireproxy.conf'),'w').write(cfg)
PY
}

case "${1:-}" in
  setup)
    for i in $(seq 1 "$N"); do
      d="$ACC/acc$i"; mkdir -p "$d"
      if [ ! -f "$d/wgcf-account.toml" ]; then
        ( cd "$d" && "$TOOLS/wgcf" register --accept-tos >/dev/null 2>&1 && "$TOOLS/wgcf" generate >/dev/null 2>&1 )
        [ -f "$d/wgcf-profile.conf" ] && echo "acc$i: registrada" || { echo "acc$i: FALHOU"; continue; }
        sleep 2
      else
        echo "acc$i: ja existe"
      fi
      mkconf "$d" $((PBASE+i))
    done
    ;;
  start)
    for i in $(seq 1 "$N"); do
      d="$ACC/acc$i"; port=$((PBASE+i))
      [ -f "$d/wireproxy.conf" ] || { echo "acc$i: sem config (rode setup)"; continue; }
      if pgrep -f "$TOOLS/wireproxy -c $d/wireproxy.conf" >/dev/null; then
        echo "acc$i: ja rodando (:$port)"
      else
        setsid "$TOOLS/wireproxy" -c "$d/wireproxy.conf" >"$d/wp.log" 2>&1 </dev/null &
        echo "acc$i: iniciado (:$port)"
      fi
    done
    sleep 6
    ;;
  stop)
    pkill -f 'wireproxy -c' 2>/dev/null && echo "todos wireproxy parados" || echo "nenhum rodando"
    ;;
  ips)
    for i in $(seq 1 "$N"); do
      port=$((PBASE+i))
      ip=$(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$port https://api64.ipify.org 2>/dev/null)
      printf "acc%-2s :%-5s -> %s\n" "$i" "$port" "${ip:-<sem resposta>}"
    done
    ;;
  rotate)
    # rotaciona uma conta: apaga registro, registra de novo (novo /128), regenera config
    i="${2:-1}"
    d="$ACC/acc$i"
    pkill -f "$TOOLS/wireproxy -c $d/wireproxy.conf" 2>/dev/null
    rm -f "$d/wgcf-account.toml" "$d/wgcf-profile.conf"
    ( cd "$d" && "$TOOLS/wgcf" register --accept-tos >/dev/null 2>&1 && "$TOOLS/wgcf" generate >/dev/null 2>&1 )
    mkconf "$d" $((PBASE+i))
    setsid "$TOOLS/wireproxy" -c "$d/wireproxy.conf" >"$d/wp.log" 2>&1 </dev/null &
    sleep 5
    echo "acc$i re-registrada; egress: $(curl -s --max-time 12 --socks5-hostname 127.0.0.1:$((PBASE+i)) https://api64.ipify.org)"
    ;;
  status)
    for i in $(seq 1 "$N"); do
      d="$ACC/acc$i"; port=$((PBASE+i))
      up="down"; pgrep -f "$TOOLS/wireproxy -c $d/wireproxy.conf" >/dev/null && up="up"
      echo "acc$i :$port wireproxy=$up"
    done
    ;;
  *)
    echo "uso: $0 {setup|start|stop|ips|rotate|status} [N]" ;;
esac
