# zen_auto.ps1 - vigia o log do OpenCode. Quando o limite de cota aparece numa
# sessao de verdade, gira o WARP, derruba os tuneis da ponte e RETOMA a sessao
# sozinho. Nao gasta cota: a rotacao e so registro novo do WARP, e a retomada
# e a propria mensagem que falhou.
#
# Acoes:
#   watch             roda o vigia (usado pelo .vbs, sem janela)
#   on | off          liga / desliga o vigia
#   status            estado do vigia, WARP, ponte, IPs, ultima acao
#   backup|restore    salva / restaura o service.json
#   rotate            gira o WARP agora (sem tocar no app)
#   resume <id>       retoma uma sessao pelo ID
#   test              testa o caminho inteiro sem gastar cota

$ErrorActionPreference = 'Continue'
$S       = 'C:\Users\SENAI'
$WARP    = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
$LOG     = "$env:USERPROFILE\.local\share\opencode\log\opencode.log"
$DB      = "$env:USERPROFILE\.local\share\opencode\opencode.db"
$SVC     = "$env:USERPROFILE\.config\opencode\service.json"
$BAK     = "$S\service.json.zen-bak"
$AUTOLOG = "$S\zen_auto.log"
$NOTICE  = "$S\zen_auto.notice.txt"
$STATE   = "$S\zen_auto.state.json"
$PIDFILE = "$S\zen_auto.pid"
$BODY    = "$S\zen_body.json"
$CTL     = 'http://127.0.0.1:8898'

$COOLDOWN = 20
$MAXTRIES = 10
$PROBE_TITLES = @('zen-probe', 'zen-resume-test', 'zen-api-test')

function Say($msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    Add-Content -Path $AUTOLOG -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Load-State {
    if (Test-Path $STATE) {
        try { return (Get-Content $STATE -Raw | ConvertFrom-Json -AsHashtable) } catch { }
    }
    return @{}
}
function Save-State($obj) {
    try { ($obj | ConvertTo-Json -Depth 5) | Set-Content $STATE -Encoding UTF8 } catch { }
}

function Get-ServerPort {
    $ids = @(Get-Process opencode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if (-not $ids) { return 0 }
    $c = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
         Where-Object { $ids -contains $_.OwningProcess } |
         Select-Object -First 1
    if ($c) { return [int]$c.LocalPort }
    return 0
}

function Get-Auth {
    try {
        $pw = (Get-Content $SVC -Raw | ConvertFrom-Json).password
        return @{ user = 'opencode'; pass = $pw }
    } catch { return $null }
}

# Sessao que o usuario esta usando de verdade: a mais recente que nao e probe.
function Get-ActiveSession {
    $port = Get-ServerPort
    if (-not $port) { return '' }
    $auth = Get-Auth
    if (-not $auth) { return '' }
    try {
        $raw = curl.exe -s -m 6 -u ("{0}:{1}" -f $auth.user, $auth.pass) "http://127.0.0.1:$port/api/session" 2>$null
        $j = $raw | ConvertFrom-Json
        $best = $null
        foreach ($s in $j.data) {
            if ($s.title -and ($PROBE_TITLES -contains $s.title)) { continue }
            # so sessoes de modelo free (provider opencode) - o chat pago nao e alvo
            $prov = ''
            if ($s.model -and $s.model.providerID) { $prov = [string]$s.model.providerID }
            if ($prov -and $prov -ne 'opencode') { continue }
            $t = [int64]$s.time.updated
            if (-not $best -or $t -gt $best.t) { $best = @{ id = $s.id; t = $t; title = $s.title } }
        }
        if ($best) { return $best.id }
    } catch { }
    return ''
}

function Get-SessionTitle($sid) {
    try {
        $t = (& node "$S\zen_session_title.js" $sid 2>$null) -join ''
        return $t.Trim()
    } catch { return '' }
}

function Bridge-Health {
    try {
        $req = [System.Net.HttpWebRequest]::Create("$CTL/health")
        $req.Proxy = $null
        $req.Timeout = 5000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        return $body.Trim()
    } catch { return '' }
}
function Bridge-Rotate {
    try {
        $req = [System.Net.HttpWebRequest]::Create("$CTL/rotate")
        $req.Proxy = $null
        $req.Timeout = 8000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        Add-Content -Path 'C:\Users\SENAI\zen_br_debug.txt' -Value ((Get-Date -Format HH:mm:ss) + " ctl=$CTL body=[" + $body + "]") -ErrorAction SilentlyContinue
        return $body.Trim()
    } catch {
        Add-Content -Path 'C:\Users\SENAI\zen_br_debug.txt' -Value ((Get-Date -Format HH:mm:ss) + " ctl=$CTL ERRO=" + $_.Exception.Message) -ErrorAction SilentlyContinue
        return ('ERRO: ' + $_.Exception.Message)
    }
}
function Egress { try { return (curl.exe -s -m 15 --socks5-hostname 127.0.0.1:40000 https://api64.ipify.org 2>$null).Trim() } catch { return '' } }
function OwnIp  { try { return (curl.exe -s -m 10 --noproxy '*' https://api.ipify.org 2>$null).Trim() } catch { return '' } }

function Rotate-Warp {
    & $WARP mode proxy 2>&1 | Out-Null
    & $WARP disconnect 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $WARP --accept-tos registration delete 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $WARP --accept-tos registration new 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $WARP connect 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $st = (& $WARP status 2>&1) -join ' '
    if ($st -notmatch 'Connected') { & $WARP connect 2>&1 | Out-Null; Start-Sleep -Milliseconds 900 }
    return ((& $WARP status 2>&1) -join ' ')
}

function Resume-Session($sid) {
    if (-not $sid) { Say "  retomar: sem sessionID na linha do log"; return $false }
    $oc = 'C:\Users\SENAI\AppData\Roaming\npm\node_modules\@opencode\cli\bin\opencode.exe'
    if (-not (Test-Path $oc)) { $oc = 'C:\Users\SENAI\AppData\Roaming\npm\opencode.cmd' }
    $oldH = $env:HTTP_PROXY; $oldS = $env:HTTPS_PROXY; $oldN = $env:NO_PROXY
    $env:HTTP_PROXY = 'http://127.0.0.1:8899'
    $env:HTTPS_PROXY = 'http://127.0.0.1:8899'
    $env:NO_PROXY = '127.0.0.1,localhost,::1'
    try {
        $out = & $oc run --standalone --session $sid 'continue' 2>&1 | Out-String
        if ($out -match 'Free usage limit') {
            Say "  retomada bateu no limite de novo"
            return $false
        }
        Say "  retomada disparada para $sid"
        return $true
    } catch {
        Say "  retomada falhou: $($_.Exception.Message)"
        return $false
    } finally {
        $env:HTTP_PROXY = $oldH; $env:HTTPS_PROXY = $oldS; $env:NO_PROXY = $oldN
    }
}

function Test-Quota {
    $oc = 'C:\Users\SENAI\AppData\Roaming\npm\node_modules\@opencode\cli\bin\opencode.exe'
    if (-not (Test-Path $oc)) { $oc = 'C:\Users\SENAI\AppData\Roaming\npm\opencode.cmd' }
    $oldH = $env:HTTP_PROXY; $oldS = $env:HTTPS_PROXY; $oldN = $env:NO_PROXY
    $env:HTTP_PROXY = 'http://127.0.0.1:8899'
    $env:HTTPS_PROXY = 'http://127.0.0.1:8899'
    $env:NO_PROXY = '127.0.0.1,localhost,::1'
    try {
        $out = & $oc run --standalone --title zen-probe -m 'opencode/deepseek-v4.1-flash-free' 'responda apenas: ok' 2>&1 | Out-String
    } finally {
        $env:HTTP_PROXY = $oldH; $env:HTTPS_PROXY = $oldS; $env:NO_PROXY = $oldN
    }
    if ($out -match 'Free usage limit') { return 'LIMIT' }
    if ($out -match '\bok\b') { return 'OK' }
    return 'ERRO'
}

function Handle-Limit($sid, $line) {
    $state = Load-State
    if (-not $state) { $state = @{} }
    if (-not $state.sessions) { $state.sessions = @{} }
    $now = Get-Date

    # A sessao certa e a que o usuario esta usando agora, nao a que apareceu
    # no log (o log pode ter sessao antiga/paralela batendo no limite).
    $target = Get-ActiveSession
    if (-not $target) { $target = $sid }
    $title = if ($target) { Get-SessionTitle $target } else { '' }

    if ($title -and ($PROBE_TITLES -contains $title)) {
        Say "  ignorado: sessao de teste ($title)"
        return
    }

    $key = if ($target) { $target } else { 'sem-id' }
    $info = $state.sessions.$key
    $tries = if ($info) { [int]$info.tries } else { 0 }
    $last  = if ($info) { [datetime]$info.last } else { [datetime]::MinValue }

    if ($tries -ge $MAXTRIES) {
        Say "  sessao $key ja tentou $tries vezes - desisti desta sessao"
        return
    }
    if (($now - $last).TotalSeconds -lt $COOLDOWN) {
        Say "  cooldown: $([int]($now - $last).TotalSeconds)s desde a ultima rotacao"
        return
    }

    Say "LIMITE REAL - sessao $target" + $(if ($title) { " ($title)" } else { '' })
    $found = $false
    $eg = ''
    for ($i = 1; $i -le 5; $i++) {
        $st = Rotate-Warp
        Say ("  tentativa {0}: warp {1}" -f $i, ($st -replace '\s+', ' ').Trim())
        Start-Sleep -Seconds 2
        $eg = Egress
        Say "  egress: $eg"
        # derruba tuneis velhos ANTES de testar/retomar
        $rot = Bridge-Rotate
        Say ("  ponte: " + ($rot -replace '\s+', ' ').Trim())
        Start-Sleep -Seconds 2
        $q = Test-Quota
        Say "  cota: $q"
        if ($q -eq 'OK') { $found = $true; break }
    }

    $tries++
    $state.sessions.$key = @{ tries = $tries; last = $now.ToString('s'); title = $title }
    $state.last_limit = $now.ToString('s')
    $state.last_egress = $eg
    Save-State $state

    $ok = $false
    if ($target -and $found) { $ok = Resume-Session $target }

    $txt = "cota estourada em " + $now.ToString('HH:mm:ss') + "`n" +
           "sessao: " + $(if ($title) { $title } else { $target }) + "`n" +
           "egress novo: " + $eg + "`n" +
           "cota: " + $(if ($found) { 'OK' } else { 'nao achou bloco com cota' }) + "`n" +
           "retomada: " + $(if ($ok) { 'enviada - a sessao deve continuar sozinha' } else { 'falhou - mande a mensagem de novo' })
    [System.IO.File]::WriteAllText($NOTICE, $txt, (New-Object System.Text.UTF8Encoding($false)))
}

function Watch {
    param([string]$LogPath = $LOG, [switch]$DryRun)
    Set-Content -Path $PIDFILE -Value $PID -Encoding ASCII -ErrorAction SilentlyContinue
    Say "=== vigia iniciado (pid $PID) ==="
    Say "  log: $LogPath"
    Say "  cooldown: ${COOLDOWN}s   max tentativas: $MAXTRIES"

    $offset = 0
    if (Test-Path $LogPath) { $offset = (Get-Item $LogPath).Length }
    $carry = ''
    $lastKeep = [datetime]::MinValue

    while ($true) {
        if (((Get-Date) - $lastKeep).TotalSeconds -ge 60) {
            $lastKeep = Get-Date
            if (-not (Get-NetTCPConnection -LocalPort 8899 -State Listen -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath 'C:\Program Files\nodejs\node.exe' -ArgumentList "$S\zen_bridge.js 8899 127.0.0.1 40000" -WindowStyle Hidden
                Say '  ponte 8899 estava fora - subi de novo'
            }
        }

        if (Test-Path $LogPath) {
            $len = (Get-Item $LogPath).Length
            if ($len -lt $offset) { $offset = 0; Say '  log rotacionou - voltando ao inicio' }
            if ($len -gt $offset) {
                $fs = $null
                try {
                    $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
                    $fs.Seek($offset, 'Begin') | Out-Null
                    $count = [int]($len - $offset)
                    $buf = New-Object byte[] $count
                    $read = $fs.Read($buf, 0, $count)
                    $offset += $read
                    $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                    $idx = $chunk.LastIndexOf("`n")
                    if ($idx -ge 0) {
                        $good = $chunk.Substring(0, $idx + 1)
                        $offset -= [System.Text.Encoding]::UTF8.GetByteCount($chunk.Substring($idx + 1))
                        $carry += $good
                        $lines = $carry -split "`r?`n"
                        $carry = ''
                        foreach ($l in $lines) {
                            if ($l -match 'Free usage limit reached|QuotaExceeded') {
                                $sid = ''
                                if ($l -match 'sessionID=(ses_[A-Za-z0-9]+)') { $sid = $Matches[1] }
                                if ($DryRun) { Say "  [dry] limite detectado: $sid" }
                                else { Handle-Limit $sid $l }
                            }
                        }
                    } else {
                        $carry += $chunk
                    }
                } catch {
                    Say "  erro lendo log: $($_.Exception.Message)"
                } finally {
                    if ($fs) { $fs.Dispose() }
                }
            }
        }
        Start-Sleep -Seconds 3
    }
}

function Stop-Watcher {
    if (Test-Path $PIDFILE) {
        $p = (Get-Content $PIDFILE -Raw).Trim()
        Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        Remove-Item $PIDFILE -Force -ErrorAction SilentlyContinue
        Say "vigia parado (pid $p)"
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*zen_auto.ps1*watch*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Watcher {
    Start-Process -FilePath 'wscript.exe' -ArgumentList "$S\zen_auto.vbs" -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    if (Test-Path $PIDFILE) { Write-Host ("vigia ligado (pid " + (Get-Content $PIDFILE -Raw).Trim() + ")") }
    else { Write-Host "vigia nao subiu - veja zen_auto.log" }
}

function Show-Status {
    Write-Host "=== VIGIA ==="
    if (Test-Path $PIDFILE) {
        $p = (Get-Content $PIDFILE -Raw).Trim()
        $alive = Get-Process -Id $p -ErrorAction SilentlyContinue
        Write-Host ("  pid " + $p + " - " + $(if ($alive) { 'vivo' } else { 'morto (pidfile velho)' }))
    } else { Write-Host "  parado" }
    $st = Load-State
    if ($st.last_limit) { Write-Host ("  ultimo limite: " + $st.last_limit) }
    if ($st.last_egress) { Write-Host ("  ultimo egress: " + $st.last_egress) }

    Write-Host "=== WARP ==="
    Write-Host ("  " + ((& $WARP status 2>&1) -join ' '))
    Write-Host "=== PONTE ==="
    Write-Host ("  8899: " + $(if (Get-NetTCPConnection -LocalPort 8899 -State Listen -ErrorAction SilentlyContinue) { 'up' } else { 'DOWN' }))
    Write-Host ("  8898: " + $(if (Get-NetTCPConnection -LocalPort 8898 -State Listen -ErrorAction SilentlyContinue) { 'up' } else { 'DOWN' }))
    Write-Host ("  health: " + (Bridge-Health))
    Write-Host "=== IPs ==="
    Write-Host ("  seu: " + (OwnIp))
    Write-Host ("  egress: " + (Egress))
    Write-Host ("  servidor do app: porta " + (Get-ServerPort))
    if (Test-Path $NOTICE) {
        Write-Host "=== ULTIMO AVISO ==="
        Get-Content $NOTICE | ForEach-Object { Write-Host ("  " + $_) }
    }
    Write-Host "=== LOG (ultimas 8) ==="
    if (Test-Path $AUTOLOG) { Get-Content $AUTOLOG -Tail 8 | ForEach-Object { Write-Host ("  " + $_) } }
}

$action = if ($args.Count -gt 0) { $args[0] } else { 'status' }

switch ($action) {
    'watch'   { Watch }
    'on'      { Start-Watcher }
    'off'     { Stop-Watcher }
    'status'  { Show-Status }
    'backup'  { Copy-Item $SVC $BAK -Force; Write-Host "backup: $BAK" }
    'restore' { if (Test-Path $BAK) { Copy-Item $BAK $SVC -Force; Write-Host "service.json restaurado"; & opencode service restart 2>&1 | Out-Null } else { Write-Host "sem backup" } }
    'rotate'  { Write-Host ((Rotate-Warp)); Write-Host ("egress: " + (Egress)); Write-Host ((Bridge-Rotate)) }
    'resume'  { if ($args.Count -gt 1) { Resume-Session $args[1] } else { Write-Host "uso: resume <sessionID>" } }
    'test'    { Write-Host "porta do servidor: " ; Write-Host (Get-ServerPort); Write-Host "egress: " ; Write-Host (Egress); Write-Host "ponte: " ; Write-Host (Bridge-Health); Write-Host "warp: " ; Write-Host ((& $WARP status 2>&1) -join ' ') }
    default   { Write-Host "uso: zen_auto.ps1 watch|on|off|status|backup|restore|rotate|resume|test" }
}
