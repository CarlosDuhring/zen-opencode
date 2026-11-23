# zen_probe_providers.ps1 - testa cada provider configurado com 1 request minimo.
# Local puro: nao toca no opencode, nao muda rota, nao liga VPN.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfgPath = 'C:\Users\SENAI\.config\opencode\opencode.json'
$raw = Get-Content $cfgPath -Raw
$cfg = $raw | ConvertFrom-Json

$targets = @(
    @{ p='openrouter'; m='qwen/qwen3.8-27b:free' },
    @{ p='openrouter'; m='nvidia/nemotron-3-super-120b-a12b:free' },
    @{ p='openrouter'; m='stepfun/step-3.7-flash:free' },
    @{ p='openrouter'; m='dots-studio/dots-3-note-preview:free' },
    @{ p='openrouter'; m='poolside/laguna-s-2.1:free' },
    @{ p='openrouter'; m='cohere/north-mini-code:free' },
    @{ p='openrouter'; m='kilo-auto/free' },
    @{ p='google-free'; m='gemini-3.6-flash' },
    @{ p='google-free'; m='gemini-3.5-flash' },
    @{ p='google-free'; m='gemma-4-31b-it' },
    @{ p='ovh'; m='Qwen3.8-27B' },
    @{ p='ovh'; m='gpt-oss-120b' },
    @{ p='llm7'; m='deepseek-v4-pro' },
    @{ p='llm7'; m='gpt-oss:20b' },
    @{ p='groq'; m='qwen/qwen3.8-27b' },
    @{ p='kilo'; m='kilo-auto/free' }
)

foreach ($t in $targets) {
    $v = $cfg.provider.($t.p)
    if (-not $v) { "  SKIP  $($t.p) (nao configurado)"; continue }
    $base = $v.options.baseURL
    if (-not $base) { "  SKIP  $($t.p) (sem baseURL)"; continue }
    $key = $v.options.apiKey
    if (-not $key -and $v.options.headers) { $key = $v.options.headers.Authorization }
    $h = @{ 'Content-Type' = 'application/json'; 'HTTP-Referer' = 'https://opencode.ai'; 'X-Title' = 'opencode' }
    if ($key) { $h['Authorization'] = "Bearer $key" }
    $body = @{ model = $t.m; messages = @(@{ role='user'; content='diga ok' }); max_tokens = 8; stream = $false } | ConvertTo-Json -Depth 6 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri ($base.TrimEnd('/') + '/chat/completions') -Method Post -Headers $h -Body $body -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        $j = $r.Content | ConvertFrom-Json
        $txt = $j.choices[0].message.content
        if (-not $txt) { $txt = $j.choices[0].message.reasoning }
        if (-not $txt) { $txt = '(vazio)' }
        $txt = ($txt -replace '\s+',' ').Trim()
        "  OK    $($t.p)/$($t.m)  $([int]$sw.Elapsed.TotalSeconds)s  -> $($txt.Substring(0,[Math]::Min(40,$txt.Length)))"
    } catch {
        $sw.Stop()
        $code = 'ERR'
        $msg = $_.Exception.Message
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        $msg = ($msg -replace '\s+',' ').Trim()
        "  FAIL  $($t.p)/$($t.m)  $code  $([int]$sw.Elapsed.TotalSeconds)s  -> $($msg.Substring(0,[Math]::Min(70,$msg.Length)))"
    }
}
