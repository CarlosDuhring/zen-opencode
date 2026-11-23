# zen_fable.ps1 - prova real no Fable 5.2 pelo openrouter.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfgPath = 'C:\Users\SENAI\.config\opencode\opencode.json'
$raw = [regex]::Replace((Get-Content $cfgPath -Raw), '(?s)^\s*//.*?\r?\n', '')
$cfg = $raw | ConvertFrom-Json
$key = $cfg.provider.openrouter.options.apiKey

$models = @('anthropic/claude-fable-5.2','anthropic/claude-fable-5.1','anthropic/claude-fable-5','anthropic/claude-opus-5.5')
foreach ($m in $models) {
    $body = @{ model=$m; messages=@(@{role='user';content='Reply with exactly: FABLE-OK'}); max_tokens=40; stream=$false } | ConvertTo-Json -Depth 5 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri 'https://openrouter.ai/api/v1/chat/completions' -Method Post -Headers @{ 'Content-Type'='application/json'; 'Authorization'="Bearer $key" } -Body $body -TimeoutSec 90 -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        $j = $r.Content | ConvertFrom-Json
        $c = $j.choices[0].message.content
        if (-not $c) { $c = $j.choices[0].message.reasoning }
        if (-not $c) { $c = '(vazio)' }
        if ($c.Length -gt 90) { $c = $c.Substring(0,90) }
        '  {0,-34} 200  {1,3}s  custo=${2}  -> {3}' -f $m, [int]$sw.Elapsed.TotalSeconds, $j.usage.cost, ($c -replace '\s+',' ')
    } catch {
        $sw.Stop()
        $code = 'ERR'; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        $note = ''
        try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $note = $sr.ReadToEnd(); $sr.Close() } catch {}
        if ($note.Length -gt 90) { $note = $note.Substring(0,90) }
        '  {0,-34} {1,-4} {2,3}s  -> {3} {4}' -f $m, $code, [int]$sw.Elapsed.TotalSeconds, $_.Exception.Message.Substring(0,[Math]::Min(40,$_.Exception.Message.Length)), ($note -replace '\s+',' ')
    }
}
