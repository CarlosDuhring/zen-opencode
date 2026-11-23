# zen_live.ps1 - teste real: pede uma resposta de verdade em cada provedor que respondeu 200.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfgPath = "$env:USERPROFILE\.config\opencode\opencode.json"
$raw = [regex]::Replace((Get-Content $cfgPath -Raw), '(?s)^\s*//.*?\r?\n', '')
$cfg = $raw | ConvertFrom-Json

$targets = @(
    @{ n='openrouter'; m='deepseek/deepseek-v4.1-flash' },
    @{ n='openrouter'; m='qwen/qwen3.8-27b:free' },
    @{ n='kilo'; m='kilo-auto' },
    @{ n='kilo'; m='nemotron-550b' },
    @{ n='ovh'; m='Qwen3.8-27B' },
    @{ n='gemini'; m='gemini-3.6-flash' }
)

foreach ($t in $targets) {
    $v = $cfg.provider.($t.n)
    $base = $v.options.baseURL
    $key = $v.options.apiKey
    if (-not $key) { $key = $v.options.headers.Authorization }
    $url = ($base.TrimEnd('/')) + '/chat/completions'
    $body = @{ model = $t.m; messages = @(@{ role='user'; content='Say exactly: OK-2026' }); max_tokens = 10; stream = $false } | ConvertTo-Json -Depth 3 -Compress
    $h = @{ 'Content-Type' = 'application/json' }
    if ($key) { $h['Authorization'] = "Bearer $key" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -Headers $h -Body $body -TimeoutSec 40 -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        '  OK    {0}  {1}  {2}s' -f $t.n, $t.m, [int]$sw.Elapsed.TotalSeconds
    } catch {
        $sw.Stop()
        '  FAIL  {0}  {1}  {2}s  {3}' -f $t.n, $t.m, [int]$sw.Elapsed.TotalSeconds, $_.Exception.Message
    }
}
