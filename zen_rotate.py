#!/usr/bin/env python3
"""
zen_rotate.py - rotacao de egress via Cloudflare WARP (Linux).

Unico modo suportado: WARP. Cada `registration new` do WARP troca o bloco de
saida (novo IP) e devolve a cota do opencode.ai, que e por IP de saida.

  zen_rotate.py            gira o WARP agora (mode proxy + novo registro) e
                           confirma o IP de saida; imprime a proxy efetiva
                           (socks5://127.0.0.1:40000) ou "direct".

Requisitos:
  - warp-cli instalado (pacote cloudflare-warp) e o servico warp-svc ativo.
  - WARP em modo proxy:  warp-cli mode proxy
  - A ponte zen_bridge.js expoe socks 40000 como HTTP 8899 para o Bun/OpenCode.

Env:
  WARP_CLI    caminho do warp-cli (default: procura no PATH e em ./warp/extract/bin)
  ZEN_WARP_SOCKS  host:porta do SOCKS do WARP (default 127.0.0.1:40000)
"""
from __future__ import annotations
import os, shutil, socket, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOCKS = os.environ.get("ZEN_WARP_SOCKS", "127.0.0.1:40000")


def find_warp() -> str | None:
    env = os.environ.get("WARP_CLI")
    if env and Path(env).exists():
        return env
    for c in (shutil.which("warp-cli"),
              "/usr/bin/warp-cli",
              str(HERE / "warp/extract/bin/warp-cli")):
        if c and Path(c).exists():
            return c
    return None


def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except FileNotFoundError:
        return 127, "not found"


def port_open(host: str, port: int, timeout=0.8) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def main() -> int:
    warp = find_warp()
    if not warp:
        sys.stderr.write(
            "zen_rotate: warp-cli nao encontrado. Rode warp/install-warp.sh "
            "(precisa de sudo) e depois: warp-cli mode proxy; warp-cli connect\n")
        print("direct")
        return 1

    steps = [
        [warp, "mode", "proxy"],
        [warp, "disconnect"],
        [warp, "--accept-tos", "registration", "delete"],
        [warp, "--accept-tos", "registration", "new"],
        [warp, "connect"],
    ]
    last_rc = 0
    for cmd in steps:
        rc, out = run(cmd)
        if rc != 0 and "already" not in out.lower() and "deleted" not in out.lower():
            last_rc = rc
    time.sleep(2.0)

    host, _, port = SOCKS.partition(":")
    port = int(port or 40000)
    if port_open(host, port):
        # IP de saida efetivo (best-effort) para log.
        try:
            r = subprocess.run(
                ["curl", "-s", "--max-time", "15", "--socks5-hostname", SOCKS,
                 "https://api.cloudflare.com/cdn-cgi/trace"],
                capture_output=True, text=True)
            for line in r.stdout.splitlines():
                if line.startswith("ip="):
                    sys.stderr.write(f"zen_rotate: egress {line}\n")
        except Exception:
            pass
        print(f"socks5://{SOCKS}")
        return 0

    sys.stderr.write("zen_rotate: WARP subiu mas o SOCKS 40000 nao respondeu\n")
    print("direct")
    return 1 if last_rc else 1


if __name__ == "__main__":
    sys.exit(main())
