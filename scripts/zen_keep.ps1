# zen_keep.ps1 - mantem a ponte 8899 -> WARP viva. NAO toca no service.json.
$ErrorActionPreference = 'SilentlyContinue'
$w = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'

# 1) WARP em modo proxy e conectado
$st = (& $w status 2>&1) -join ' '
if ($st -notmatch 'Connected') {
    & $w mode proxy 2>&1 | Out-Null
    & $w connect 2>&1 | Out-Null
}

# 2) ponte 8899 escutando
$up = @(Get-NetTCPConnection -LocalPort 8899 -State Listen -ErrorAction SilentlyContinue).Count
if ($up -eq 0) {
    Start-Process -FilePath 'C:\Program Files\nodejs\node.exe' `
        -ArgumentList 'C:\Users\SENAI\zen_bridge.js 8899 127.0.0.1 40000' `
        -WindowStyle Hidden
}

# vigia de limite: mantem exatamente UM rodando (sem janela)
$watchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*zen_auto.ps1" watch*' })
if ($watchers.Count -gt 1) {
    # mata os extras, mantem o mais antigo
    $keep = ($watchers | Sort-Object CreationDate | Select-Object -First 1)
    $watchers | Where-Object { $_.ProcessId -ne $keep.ProcessId } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
if ($watchers.Count -eq 0) {
    Start-Process -FilePath 'wscript.exe' -ArgumentList 'C:\Users\SENAI\zen_auto.vbs' -WindowStyle Hidden
}
