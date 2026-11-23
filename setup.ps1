# setup.ps1 - ajusta os caminhos dos scripts para o usuario atual.
# Substitui "C:\Users\SENAI" e "C:/Users/SENAI" pelo %USERPROFILE% real.
# Rode uma vez depois de copiar os scripts.

$old = 'C:\Users\SENAI'
$oldSlash = 'C:/Users/SENAI'
$new = $env:USERPROFILE
$newSlash = ($env:USERPROFILE -replace '\\', '/')

$root = $PSScriptRoot
$changed = 0

Get-ChildItem -Path $root -Recurse -File -Include *.ps1, *.vbs, *.cmd, *.js, *.md |
    Where-Object { $_.Name -ne 'setup.ps1' } |
    ForEach-Object {
        $path = $_.FullName
        $text = [System.IO.File]::ReadAllText($path)
        $orig = $text
        $text = $text.Replace($old, $new)
        $text = $text.Replace($oldSlash, $newSlash)
        if ($text -ne $orig) {
            [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("  ajustado: " + $_.Name)
            $changed++
        }
    }

if ($changed -eq 0) {
    Write-Host "  nada a ajustar (caminhos ja corretos)"
} else {
    Write-Host ("  $changed arquivo(s) ajustado(s) para " + $new)
}
