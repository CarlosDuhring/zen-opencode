# zen_live2.ps1 - conteudo real + lista de modelos free do openrouter.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cfgPath = "$env:USERPROFILE\.config\opencode\opencode.json"
$raw = [regex]::Replace((Get-Content $cfgPath -Raw), '(?s)^\s*//.*?\r?\n', '')
$cfg = $raw | ConvertFrom-Json

"--- modelos :free do openrouter ---"
try {
    $models = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -TimeoutSec 30 -UseBasicParsing
    $models.data | Where-Object { $_.id -like '*:free' } | Select-Object -First 15 | ForEach-Object { "  " + $_.id }
} catch { "  erro: " + $_.Exception.Message }

"`n--- teste de conteudo real ---"
$tests = @(
    @{ n='openrouter'; m='deepseek/deepseek-v4.1-flash' },
    @{ n='kilo'; m='kilo-auto' },
    @{ n='ovh'; m='Qwen3.8-27B' }
)

foreach ($t in $tests) {
    $v = $cfg.provider.($t.n)
    if (-not $v) { "  SKIP  $($t.n) (provider nao configurado)"; continue }
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
