# zen_warp.ps1 - gira o WARP (modo proxy) e testa cota com o CLIENTE REAL.
# Nao muda o IP do Windows. Nao toca no service.json. So gira e testa.
$ErrorActionPreference = 'Continue'
$w = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
$oc = Join-Path $env:APPDATA 'npm\node_modules\@opencode\cli\bin\opencode.exe'
$env:HTTP_PROXY = 'http://127.0.0.1:8899'
$env:HTTPS_PROXY = 'http://127.0.0.1:8899'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'

function Get-Egress {
    try { return (curl.exe -s -m 12 -x http://127.0.0.1:8899 https://api.ipify.org 2>$null).Trim() } catch { return '' }
}

function Test-Quota {
    $out = & $oc run --standalone --title zen-probe -m 'opencode/deepseek-v4.1-flash-free' 'responda apenas: ok' 2>&1 | Out-String
    if ($out -match 'Free usage limit|usage limit|quota') { return 'LIMIT' }
    if ($out -match '\bok\b') { return 'OK' }
    return 'ERRO'
}

$max = 12
for ($i = 1; $i -le $max; $i++) {
    # garante WARP proxy conectado
    & $w mode proxy 2>&1 | Out-Null
    & $w connect 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800

    $ip = Get-Egress
    Write-Host ("[{0}/{1}] registro novo... saida atual: {2}" -f $i, $max, $ip)

    $tag = Test-Quota
    Write-Host ("    cota: {0}" -f $tag)

    if ($tag -eq 'OK') {
        Write-Host ("COTA ENCONTRADA: {0}" -f $ip)
        Write-Host ("seu ip segue intocado: " + (curl.exe -s -4 -m 10 --noproxy '*' https://api.ipify.org))
        exit 0
    }

    # gira o registro: apaga o antigo e cria novo (novo IP de saida)
    & $w --accept-tos registration delete 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $w --accept-tos registration new 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $w connect 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

Write-Host 'FIM: nenhum bloco do WARP com cota nesta passada'
exit 1
