# zen_guard.ps1 - mantem WARP + zen_bridge vivos.
# Roda no logon e a cada 5 min (tarefa "zen-bridge-guard").
# Se o bridge morrer ou o WARP cair, o opencode volta a dar ECONNREFUSED.

$ErrorActionPreference = 'SilentlyContinue'
$log = "C:\Users\SENAI\zen_guard.log"
$warp = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
$node = "C:\Program Files\nodejs\node.exe"
$bridge = "C:\Users\SENAI\zen_bridge.js"

function Log($m) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    if ((Get-Item $log).Length -gt 512KB) {
        Get-Content $log -Tail 500 | Set-Content $log -Encoding UTF8
    }
}

function Porta($p) {
    return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

# teste real: a ponte aceita CONNECT e entrega o tunel? (porta aberta mas
# processo travado tambem derruba o opencode)
function Ponte($dest) {
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $ar = $t.BeginConnect('127.0.0.1', 8899, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(3000)) { $t.Close(); return $false }
        $t.EndConnect($ar)
        $ns = $t.GetStream()
        $req = "CONNECT $dest HTTP/1.1`r`nHost: $dest`r`n`r`n"
        $b = [Text.Encoding]::ASCII.GetBytes($req)
        $ns.Write($b, 0, $b.Length)
        $buf = New-Object byte[] 64
        $n = $ns.Read($buf, 0, 64)
        $t.Close()
        $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        return ($txt -match '200')
    }
    catch { return $false }
}

# 1) WARP conectado?
if (Test-Path $warp) {
    $st = (& $warp status 2>&1) -join ' '
    if ($st -notmatch 'Connected') {
        Log "WARP desconectado, reconectando"
        & $warp connect 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        $st = (& $warp status 2>&1) -join ' '
        Log "WARP status: $st"
    }
} else {
    Log "warp-cli nao encontrado"
}

# 2) zen_bridge na 8899? (porta aberta E tunel funcionando)
$viva = (Porta 8899) -and (Ponte 'models.opencode.ai:443')
if (-not $viva) {
    if (Porta 8899) {
        Log "bridge 8899 responde mas tunel falhou -> matando e subindo de novo"
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
            Where-Object { $_.CommandLine -like '*zen_bridge.js*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    } else {
        Log "bridge 8899 caido, subindo"
    }
    Start-Process -FilePath $node -ArgumentList @($bridge, '8899', '127.0.0.1', '40000') `
        -WindowStyle Hidden -RedirectStandardOutput "C:\Users\SENAI\zen_bridge.out.log" `
        -RedirectStandardError "C:\Users\SENAI\zen_bridge.err.log"
    Start-Sleep -Seconds 2
    if ((Porta 8899) -and (Ponte 'models.opencode.ai:443')) { Log "bridge 8899 no ar (tunel ok)" } else { Log "FALHOU subir bridge 8899" }
}

# 3) sanidade: o SOCKS do WARP responde?
if (-not (Porta 40000)) { Log "AVISO: SOCKS WARP 40000 nao esta escutando" }

$ok = (Porta 8899) -and (Porta 40000)
Log ("heartbeat: bridge8899={0} socks40000={1} estado={2}" -f (Porta 8899), (Porta 40000), $(if ($ok) { 'ok' } else { 'degradado' }))
