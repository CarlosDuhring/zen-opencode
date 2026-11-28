# zen-opencode — Linux (Cloudflare WARP)

Port da rotação de cota do OpenCode para Linux. A cota do modelo free
`opencode/deepseek-v4.1-flash-free` é **por IP de saída**; cada registro novo do
WARP troca o bloco de saída e devolve a cota. O vigia lê o log, gira o WARP,
testa a cota com um probe real e retoma a sessão que você está usando — sem
trocar de sessão.

> Windows: os `*.ps1` originais continuam no diretório como referência. No Linux
> os equivalentes são `zen_rotate.py` e `zen_auto.py`.

## Componentes

| Arquivo | Função |
|---|---|
| `zen_rotate.py` | gira o WARP (`mode proxy` + `registration delete/new/connect`) e confirma egress no SOCKS 40000 |
| `zen_bridge.js` | ponte HTTP CONNECT `127.0.0.1:8899` → SOCKS5 do WARP `127.0.0.1:40000` (o Bun do OpenCode não fala SOCKS) |
| `zen_auto.py` | vigia `opencode.log`, detecta `Free usage limit reached`/`FreeTierError`, gira, testa cota, `opencode run -s <id> continue` |
| `zen` | CLI de controle |
| `~/.config/systemd/user/zen-bridge.service` | bridge persistente |
| `~/.config/systemd/user/zen-auto.service` | vigia persistente |

## Pré-requisitos (instalados)

- `cloudflare-warp` 2026.8.2115.0 (pacote oficial em `warp/`), serviço `warp-svc` ativo.
- WARP em **modo proxy** (SOCKS em `127.0.0.1:40000`): `warp-cli mode proxy`.
- Node 18+ (bridge), Python 3.10+ (rotate/auto).

## Uso

```bash
zen status        # WARP + egress + bridge + serviços + estado
zen rotate        # gira o WARP agora e testa a cota
zen on | off      # liga/desliga bridge + vigia (systemd --user)
zen resume <id>   # manda "continue" numa sessão (default: a ativa)
zen logs          # últimas linhas do vigia
```

Estado e logs em `~/.local/state/zen-opencode/`:
`zen_auto.log`, `zen_auto.state.json`, `bridge.log`, `zen_auto.notice.txt`.

## Fluxo de recuperação

1. `opencode.log` recebe `Free usage limit reached` / `FreeTierError`.
2. `zen_auto.py` detecta (tail do log).
3. `zen_rotate.py` gira o WARP → novo registro → novo IP.
4. `zen_bridge.js` entrega o SOCKS como HTTP `:8899`.
5. Probe: `opencode run -m opencode/deepseek-v4.1-flash-free "responda apenas: ok"` via proxy.
6. Se voltou `ok`, retoma a sessão ativa (`opencode run -s <id> continue`). Se não, gira de novo (até `ZEN_MAXTRIES`, default 5).

A sessão ativa é escolhida por `providerID=opencode` mais recente no
`opencode.db`, ignorando probes `zen-probe` (não usa o id da linha do log).

## Variáveis

| Env | Default | Papel |
|---|---|---|
| `ZEN_MODEL_FREE` | `opencode/deepseek-v4.1-flash-free` | modelo do probe |
| `ZEN_MAXTRIES` | `5` | tentativas de rotação por evento |
| `ZEN_COOLDOWN` | `20` | segundos entre eventos |
| `ZEN_WARP_SOCKS` | `127.0.0.1:40000` | SOCKS do WARP |
| `OPENCODE_BIN` / `OPENCODE_DB` / `OPENCODE_LOG` | autodetecção | caminhos |

## Desinstalar o WARP

```bash
sudo systemctl disable --now warp-svc
sudo apt-get remove -y cloudflare-warp
```
