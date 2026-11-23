# Arquitetura

## Visão geral

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│  opencode   │────►│  opencode.log    │────►│  zen_auto.ps1       │
│  (servidor) │     │  (log em tempo   │     │  (vigia, watch)     │
│  28894      │     │   real)          │     │                     │
└─────────────┘     └──────────────────┘     └──────────┬──────────┘
                                                         │
                    ┌────────────────────────────────────┤
                    │                                    │
                    ▼                                    ▼
          ┌──────────────────┐                 ┌──────────────────┐
          │  Cloudflare WARP │                 │  zen_bridge.js   │
          │  warp-cli        │                 │  8899 → 40000    │
          │  (SOCKS5 40000)  │◄────────────────│  (proxy HTTP)    │
          └──────────────────┘                 └──────────────────┘
                    │                                    │
                    ▼                                    ▼
             IP de saída novo                    opencode run --standalone
             (novo bloco IPv6)                   --session <id> continue
```

## Componentes

### `zen_auto.ps1` — o vigia

Loop infinito de 3 s. Lê o log do OpenCode a partir do offset atual (não relê o arquivo inteiro), separa linhas e procura o erro de cota. Quando encontra, chama `Handle-Limit`.

Funções principais:

| Função | Papel |
|---|---|
| `Get-ActiveSession` | Consulta `/api/session` e devolve a sessão mais recente do provider `opencode` que não é probe. |
| `Rotate-Warp` | Apaga o registro do WARP, cria outro, conecta. |
| `Egress` | Lê o IP de saída pelo SOCKS5 `127.0.0.1:40000`. |
| `Bridge-Rotate` | Chama `GET /rotate` na ponte para derrubar túneis velhos. |
| `Test-Quota` | Roda um probe real com o modelo free. |
| `Resume-Session` | Roda `continue` na sessão ativa. |

### `zen_bridge.js` — a ponte

O OpenCode usa Bun. Bun respeita `HTTPS_PROXY` mas **não** implementa SOCKS5. A ponte resolve isso:

1. Escuta `CONNECT` em `127.0.0.1:8899`.
2. Faz o handshake SOCKS5 com o WARP em `127.0.0.1:40000`.
3. Repassa os bytes.

Roteamento por destino:

```js
function rotaWarp(host) {
  const h = host.toLowerCase();
  if (h === 'models.opencode.ai') return false; // catálogo estático, direto
  return h === 'opencode.ai' || h.endsWith('.opencode.ai'); // via WARP
}
```

- `models.opencode.ai` → direto (não gasta cota).
- `opencode.ai` / `*.opencode.ai` → via WARP (gasta cota por IP).
- Resto → direto.

Controle em `127.0.0.1:8898`:

- `GET /health` → `{"up":true,"tunnels":N,"socks":"127.0.0.1:40000"}`
- `GET /rotate` → derruba todos os túneis e devolve `rotated N`.

### `zen_guard.ps1` — o guarda

Roda no logon e a cada 5 min (tarefa agendada `zen-bridge-guard`). Verifica:

1. WARP conectado.
2. Ponte `8899` viva **e** túnel funcionando (`CONNECT models.opencode.ai:443`).
3. SOCKS `40000` escutando.

Se algo caiu, sobe de novo. Log em `zen_guard.log`.

### `zen_keep.ps1` — o keep

Sobe o que estiver caído e garante **um único** vigia. Chamado pelo `zen_keep.vbs` no logon.

## Fluxo de recuperação

1. `opencode.log` recebe `AI.Error: Free usage limit reached`.
2. `zen_auto.ps1` detecta em até 3 s.
3. `Get-ActiveSession` pega a sessão que você está usando.
4. `Rotate-Warp` gira o IP.
5. `Egress` confirma o novo IP.
6. `Bridge-Rotate` derruba túneis velhos.
7. `Test-Quota` testa o bloco novo.
8. Se OK, `Resume-Session` manda `continue`.
9. Se não, gira de novo (até 5 vezes).

## Por que a sessão do log não serve

O log pode conter linhas de sessões antigas ou paralelas (probes, forks, testes). Se o vigia usasse o sessionID da linha, mandaria `continue` na sessão errada. Por isso ele consulta `/api/session` e escolhe a sessão **mais recente** do provider `opencode` que não é probe.

## Limites

- O limite de cota é **por IP de saída**. O WARP troca o bloco IPv6 a cada registro.
- Alguns blocos já vêm gastos; por isso até 5 tentativas.
- Se todas falharem, o vigia para e grava `zen_auto.notice.txt`.
- O `MAXTRIES` por sessão é 10; o `COOLDOWN` é 20 s.
