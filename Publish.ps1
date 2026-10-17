<#
.SYNOPSIS
    Pubblica una nuova versione di WinOptima su GitHub.
.DESCRIPTION
    1. Legge la versione da $script:AppVersion in WinOptima.ps1 (es. '3.3' -> tag v3.3).
    2. Ricostruisce icona ed exe con Build.ps1.
    3. Crea la release su GitHub allegando WinOptima.exe: l'aggiornamento automatico dell'app la troverà.
    4. Elimina le release più vecchie, tenendo solo le ultime $Keep (con i rispettivi tag).
    Prima di lanciarlo: aggiorna la versione in WinOptima.ps1, fai commit e push.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Publish.ps1 -Notes "Novità: ..."
#>
param(
    [string]$Notes = '',
    [int]$Keep = 2,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Serve la GitHub CLI (gh) autenticata: https://cli.github.com' }
$ver = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'WinOptima.ps1')), "AppVersion\s*=\s*'([\d.]+)'").Groups[1].Value
if (-not $ver) { throw 'Versione non trovata in WinOptima.ps1.' }
$tag = "v$ver"

$dirty = git status --porcelain
if ($dirty) { throw "Ci sono modifiche non salvate in git: fai commit prima di pubblicare.`n$dirty" }
git fetch -q origin
if ((git rev-parse HEAD) -ne (git rev-parse '@{u}')) { throw 'Il branch locale non coincide con GitHub: fai push (o pull) prima di pubblicare.' }
$existing = @(gh release list --limit 100 --json tagName --jq '.[].tagName')
if ($existing -contains $tag) { throw "La release $tag esiste già: aumenta `$script:AppVersion in WinOptima.ps1." }

Write-Host "Pubblicazione di WinOptima $tag" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Build non riuscita.' }

if (-not $Notes) { $Notes = "WinOptima $ver. Scarica **WinOptima.exe** (unico file portatile). Le versioni già installate si aggiornano da sole." }
if ($WhatIf) {
    Write-Host "[WhatIf] gh release create $tag WinOptima.exe" -ForegroundColor Yellow
} else {
    gh release create $tag (Join-Path $root 'WinOptima.exe') --title "WinOptima $ver" --notes $Notes --target (git rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Creazione della release non riuscita.' }
}

# Tiene solo le ultime $Keep release (quindi al massimo $Keep exe pubblicati)
$all = gh release list --limit 100 --json tagName,createdAt | ConvertFrom-Json | Sort-Object createdAt -Descending
foreach ($old in @($all | Select-Object -Skip $Keep)) {
    if ($WhatIf) { Write-Host "[WhatIf] eliminerei la release $($old.tagName)" -ForegroundColor Yellow; continue }
    gh release delete $old.tagName --yes --cleanup-tag
    Write-Host "Eliminata la release vecchia $($old.tagName)"
}
Write-Host "Fatto: https://github.com/$((gh repo view --json nameWithOwner --jq .nameWithOwner))/releases/tag/$tag" -ForegroundColor Green
