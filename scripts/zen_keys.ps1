# zen_keys.ps1 - testa cada provedor configurado com 1 request minimo. Nao toca no app.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfgPath = 'C:\Users\SENAI\.config\opencode\opencode.json'
$raw = Get-Content $cfgPath -Raw
$raw = [regex]::Replace($raw, '(?s)^\s*//.*?\r?\n', '')
$cfg = $raw | ConvertFrom-Json

function Probe($name, $base, $key, $model) {
    $url = ($base.TrimEnd('/')) + '/chat/completions'
    $body = @{ model = $model; messages = @(@{ role = 'user'; content = 'hi' }); max_tokens = 1; stream = $false } | ConvertTo-Json -Depth 5 -Compress
    $h = @{ 'Content-Type' = 'application/json' }
    if ($key) { $h['Authorization'] = "Bearer $key" }
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -Headers $h -Body $body -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        $t = ($r.Content -replace '\s+',' ').Trim()
        if ($t.Length -gt 90) { $t = $t.Substring(0,90) }
        return [pscustomobject]@{ P=$name; M=$model; Code=$r.StatusCode; Note=$t }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            $note = ''
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $note = $sr.ReadToEnd(); $sr.Close()
                $note = ($note -replace '\s+',' ').Trim()
                if ($note.Length -gt 90) { $note = $note.Substring(0,90) }
            } catch {}
            return [pscustomobject]@{ P=$name; M=$model; Code=$code; Note=$note }
        }
        $msg = $_.Exception.Message
        if ($msg.Length -gt 60) { $msg = $msg.Substring(0,60) }
        return [pscustomobject]@{ P=$name; M=$model; Code='ERR'; Note=$msg }
    }
}

$rows = @()
foreach ($p in $cfg.provider.PSObject.Properties) {
    $name = $p.Name; $v = $p.Value
    $base = $v.options.baseURL
    if (-not $base) { $rows += [pscustomobject]@{ P=$name; M='-'; Code='NO-BASE'; Note='' }; continue }
    $key = $v.options.apiKey
    if (-not $key) { $key = $v.options.headers.Authorization }
    $models = @($v.models.PSObject.Properties | ForEach-Object { $_.Name })
    if ($models.Count -eq 0) { $rows += [pscustomobject]@{ P=$name; M='-'; Code='NO-MODEL'; Note='' }; continue }
    $rows += Probe $name $base $key $models[0]
}
$rows | ForEach-Object { '{0,-14} {1,-4} {2,-32} {3}' -f $_.P, $_.Code, $_.M, $_.Note }
