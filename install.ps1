<#
.SYNOPSIS
  Install the kisslove Kiro setup onto this machine (Windows / PowerShell).
.DESCRIPTION
  Copies the bundled agents, skills, steering, hooks, powers, and portable
  settings into the user's global Kiro config (~/.kiro), then installs the
  graphify CLI that the graphify skill + hook depend on.

  Safe by default: existing files are backed up to ~/.kiro-backup-<timestamp>
  before anything is overwritten. Nothing is deleted.
.NOTES
  Re-run safe. Review merge behaviour for settings/mcp.json if you already
  have MCP servers configured (this bundle ships an empty mcp.json).
#>
param(
    [switch]$SkipGraphify,   # don't attempt to install the graphify CLI
    [switch]$Force           # overwrite without creating a backup
)

$ErrorActionPreference = 'Stop'
$bundle = Join-Path $PSScriptRoot '.kiro'
$target = Join-Path $HOME '.kiro'

Write-Host "kisslove installer" -ForegroundColor Cyan
Write-Host "  bundle: $bundle"
Write-Host "  target: $target"

if (-not (Test-Path $bundle)) { throw "Bundle not found at $bundle - run this from the repo root." }

# 1. Back up any existing config we are about to touch
if ((Test-Path $target) -and -not $Force) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $HOME ".kiro-backup-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($d in @('agents','skills','steering','hooks','powers','settings')) {
        $existing = Join-Path $target $d
        if (Test-Path $existing) {
            Copy-Item $existing (Join-Path $backup $d) -Recurse -Force
        }
    }
    Write-Host "  backed up existing config -> $backup" -ForegroundColor Yellow
}

New-Item -ItemType Directory -Path $target -Force | Out-Null

# 2. Merge the bundle into ~/.kiro (copy, do not delete anything else)
foreach ($d in @('agents','skills','steering','hooks','powers')) {
    $s = Join-Path $bundle $d
    if (Test-Path $s) {
        Copy-Item (Join-Path $s '*') (Join-Path $target $d) -Recurse -Force
        Write-Host "  installed $d/" -ForegroundColor Green
    }
}

# settings: copy mcp.json/cli.json only if the user doesn't already have them
$setTarget = Join-Path $target 'settings'
New-Item -ItemType Directory -Path $setTarget -Force | Out-Null
foreach ($f in @('mcp.json','cli.json')) {
    $sp = Join-Path $bundle "settings\$f"
    $tp = Join-Path $setTarget $f
    if (Test-Path $sp) {
        if (Test-Path $tp) {
            Write-Host "  settings/$f already exists - left untouched (compare manually)" -ForegroundColor Yellow
        } else {
            Copy-Item $sp $tp -Force
            Write-Host "  installed settings/$f" -ForegroundColor Green
        }
    }
}

# 3. Install the graphify CLI (the graphify skill + hook depend on it)
if (-not $SkipGraphify) {
    Write-Host "`nInstalling graphify CLI (graphifyy)..." -ForegroundColor Cyan
    $py = $null
    foreach ($c in @('python','python3')) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { $py = $c; break }
    }
    if ($py) {
        try {
            & $py -m pip install --user --upgrade graphifyy 2>&1 | Select-Object -Last 3
            Write-Host "  graphify installed - verify with: $py -m graphify --version" -ForegroundColor Green
        } catch {
            Write-Host "  graphify install failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  install manually: $py -m pip install --user graphifyy" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Python not found - skipping. Install Python 3.10+ then: python -m pip install --user graphifyy" -ForegroundColor Yellow
    }
} else {
    Write-Host "`nSkipped graphify CLI install (--SkipGraphify)." -ForegroundColor Yellow
}

Write-Host "`nDone. Restart Kiro so it picks up the new global agents, skills, and steering." -ForegroundColor Cyan
Write-Host "In each project where you want the code graph: run  /graphify .  once." -ForegroundColor Cyan
