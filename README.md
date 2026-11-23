# zen-opencode

Vigia de cota do **OpenCode** para Windows. Detecta o erro *"Free usage limit reached"* no log, gira o IP de saída do Cloudflare WARP, testa a cota com um probe real e **retoma a sessão que você está usando** — sem trocar de sessão, sem perder o contexto.

> Feito para o modelo free `opencode/deepseek-v4.1-flash-free`. O limite de cota é por IP de saída; trocar o registro do WARP troca o bloco IPv6 e devolve a cota.

---

## O que ele faz

```
┌──────────────────────────────────────────────────────────────┐
│  opencode.log  ──►  zen_auto.ps1 (vigia)                     │
│                         │                                     │
│                         │ detecta "Free usage limit"          │
│                         ▼                                     │
│  1. Rotate-Warp  ──►  apaga registro WARP, cria novo, conecta │
│  2. Egress       ──►  lê o novo IP de saída (SOCKS 40000)     │
│  3. Bridge-Rotate ──► derruba túneis velhos do zen_bridge     │
│  4. Test-Quota   ──►  probe real (opencode run --standalone)  │
│  5. Resume-Session ──► continue na sessão ATIVA               │
└──────────────────────────────────────────────────────────────┘
```

- **Vigia** (`zen_auto.ps1 watch`): lê o log do OpenCode em tempo real, linha a linha.
- **Ponte** (`zen_bridge.js`): proxy HTTP `127.0.0.1:8899` → SOCKS5 do WARP `127.0.0.1:40000`. O OpenCode (Bun) não fala SOCKS5, então a ponte faz o CONNECT.
- **Guarda** (`zen_guard.ps1`): mantém WARP + ponte vivos; roda no logon e a cada 5 min.
- **Keep** (`zen_keep.ps1`): sobe o que estiver caído e garante um único vigia rodando.

---

## Requisitos

| Item | Versão / caminho |
|---|---|
| Windows | 10/11 |
| OpenCode CLI | `opencode` no PATH (npm global) |
| Node.js | 18+ (testado no 26) |
| Cloudflare WARP | `warp-cli.exe` instalado |
| PowerShell | 5.1+ |

Caminhos padrão assumidos:

```
C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe
C:\Program Files\nodejs\node.exe
%APPDATA%\npm\node_modules\@opencode\cli\bin\opencode.exe
```

---

## Instalação rápida

1. **Copie os scripts** para uma pasta (ex.: `C:\Users\SEU_USUARIO\zen-opencode`).
2. **Ajuste os caminhos** (se seu usuário não for `SENAI`):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup.ps1
   ```

   O `setup.ps1` troca `C:\Users\SENAI` pelo seu `%USERPROFILE%` em todos os arquivos.

3. **Confirme que o WARP está em modo proxy:**

   ```powershell
   & "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" mode proxy
   & "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" connect
   ```

4. **Suba a ponte e o vigia:**

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\zen_keep.ps1
   ```

5. **Ligue o vigia em background (sem janela):**

   ```powershell
   wscript .\scripts\zen_auto.vbs
   ```

---

## Uso

### `zen.cmd` — atalho principal

```bat
zen warp        :: gira o WARP agora e mostra o IP
zen rotate      :: gira o WARP + ponte, sem tocar no app
zen on          :: liga o vigia
zen autooff     :: desliga o vigia
zen             :: status completo (WARP + IPs + ponte + vigia)
```

### `zen_auto.ps1` — ações diretas

```powershell
.\scripts\zen_auto.ps1 watch      # roda o vigia em primeiro plano
.\scripts\zen_auto.ps1 on         # liga o vigia (via wscript, sem janela)
.\scripts\zen_auto.ps1 off        # desliga o vigia
.\scripts\zen_auto.ps1 backup     # salva service.json
.\scripts\zen_auto.ps1 rotate     # gira WARP + ponte agora
.\scripts\zen_auto.ps1 resume <sessionID>   # força "continue" numa sessão
```

### `zen_bridge.js` — ponte

```bat
node zen_bridge.js 8899 127.0.0.1 40000 8898
```

| Porta | Serviço |
|---|---|
| `8899` | proxy HTTP CONNECT → SOCKS5 |
| `8898` | controle: `GET /health`, `GET /rotate` |

---

## Como funciona por dentro

### 1. Detecção

O vigia lê `%USERPROFILE%\.local\share\opencode\log\opencode.log` e procura por:

```
AI.Error: Free usage limit reached
```

Quando acha, chama `Handle-Limit`.

### 2. Sessão certa

`Handle-Limit` **não** usa o sessionID da linha do log. Ele consulta `/api/session` do servidor local do OpenCode e pega a sessão **mais recente** cujo modelo é do provider `opencode` (free) e que não é um probe (`zen-probe`). Essa é a sessão que você está usando.

### 3. Rotação de IP

`Rotate-Warp` faz:

```powershell
warp-cli mode proxy
warp-cli disconnect
warp-cli --accept-tos registration delete
warp-cli --accept-tos registration new
warp-cli connect
```

Cada registro novo = novo bloco IPv6 = nova cota.

### 4. Teste de cota

`Test-Quota` roda um `opencode run --standalone --title zen-probe -m opencode/deepseek-v4.1-flash-free "responda apenas: ok"` com proxy `127.0.0.1:8899`. Se voltar `ok`, o bloco tem cota. Se voltar `Free usage limit`, gira de novo (até 5 tentativas).

### 5. Retomada

`Resume-Session` roda `opencode run --standalone --session <id> "continue"` com o proxy. A sessão continua sozinha.

### 6. Ponte (por que existe)

O OpenCode usa Bun, que respeita `HTTPS_PROXY` mas **não** faz SOCKS5. O `zen_bridge.js` aceita `CONNECT` HTTP em `127.0.0.1:8899`, faz o handshake SOCKS5 com o WARP em `127.0.0.1:40000` e repassa. Rotas:

- `opencode.ai` e `*.opencode.ai` → via WARP (gasta cota por IP).
- `models.opencode.ai` → direto (catálogo estático, não gasta cota).
- Todo o resto → direto.

---

## Arquivos

| Arquivo | Função |
|---|---|
| `scripts/zen_auto.ps1` | Vigia principal + rotação + retomada |
| `scripts/zen_bridge.js` | Proxy HTTP→SOCKS5 |
| `scripts/zen_keep.ps1` | Sobe ponte + vigia |
| `scripts/zen_guard.ps1` | Health check WARP + ponte (logon / 5 min) |
| `scripts/zen_warp.ps1` | Gira WARP e testa cota (standalone) |
| `scripts/zen.cmd` | Atalho de comandos |
| `scripts/zen_auto.vbs` | Inicia o vigia sem janela |
| `scripts/zen_keep.vbs` | Inicia o keep sem janela |
| `scripts/zen_session_title.js` | Lê o título da sessão no SQLite |
| `scripts/zen_probe_providers.ps1` | Testa providers do `opencode.json` |
| `scripts/zen_keys.ps1` | Testa chaves/providers |
| `scripts/zen_fable.ps1` | Testa modelos via OpenRouter |
| `scripts/zen_api_probe.js` | Sonda o OpenAPI do OpenCode |
| `scripts/zen_db_probe.js` | Lê o banco SQLite do OpenCode |

---

## Solução de problemas

### O vigia não retoma a sessão certa

Ele pega a sessão mais recente do provider `opencode`. Se você estiver usando um modelo pago, ele ignora. Confira:

```powershell
curl.exe -s -u "opencode:SENHA" http://127.0.0.1:28894/api/session
```

A senha fica em `%USERPROFILE%\.local\state\opencode\service.json`.

### `ECONNREFUSED` na ponte

A ponte caiu. Suba de novo:

```powershell
node scripts\zen_bridge.js 8899 127.0.0.1 40000 8898
```

Ou rode `zen_guard.ps1`.

### O WARP não conecta

```powershell
& "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" status
& "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" connect
```

### Continua no limite mesmo com IP novo

Alguns blocos do WARP já estão gastos. O `Handle-Limit` gira até 5 vezes. Se todas falharem, ele para e avisa em `zen_auto.notice.txt`.

### O `service.json` tem senha

O `zen_auto.ps1 backup` copia para `service.json.zen-bak`. **Não comite** esse arquivo — o `.gitignore` já exclui.

---

## Licença

MIT. Veja [LICENSE](LICENSE).
