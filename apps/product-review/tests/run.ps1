# All checks run in fresh PowerShell processes (Windows PowerShell 5.1 on Windows, pwsh on macOS); no paid AI calls.
param([string[]]$Name = @('csv', 'workspace', 'ui-status', 'setup-check', 'quota', 'ai-retry', 'cli-process', 'source-data', 'reference-archive', 'product-input', 'manual-product', 'product-context', 'reference-fallback', 'scene-selection', 'image-output', 'image-delivery', 'image-tool-errors', 'manual-references', 'review-writing', 'review-metadata', 'review-pipeline', 'browser-backend', 'drive-storage', 'drive-delivery', 'multi-scene', 'batch-review', 'app-update', 'support-report', 'batch-import'))
$ErrorActionPreference = 'Stop'
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
# Suites that draw test images with System.Drawing, which macOS lacks, are skipped there.
$windowsOnly = @('manual-references')
if ($onWindows) {
    # Prefer the Windows PowerShell modules even when launched from PowerShell 7.
    $env:PSModulePath = (Join-Path $PSHOME 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $runner = 'powershell.exe'
} else {
    # pwsh installed as a dotnet tool runs inside dotnet, so prefer the pwsh command over the process path.
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    $runner = if ($pwsh) { $pwsh.Source } else { (Get-Process -Id $PID).Path }
    $Name = @($Name | Where-Object { $_ -notin $windowsOnly })
}
$project = Split-Path $PSScriptRoot -Parent
# AI calls the suites make (all mocked) are counted in a file of the tests, not in the install's Lượt dùng AI.
$env:HUB_AI_USAGE_FILE = Join-Path $project 'workspace/tests/ai-usage.jsonl'
# Nor do they touch the bridge a run on this machine uses (hub/bridge/ensure.mjs).
$env:TOOLS_HUB_TEST = '1'
$failures = New-Object Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem (Join-Path $project 'src'), $PSScriptRoot, (Join-Path $project '../../hub') -Recurse -File -Filter '*.ps1')) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    # Windows PowerShell 5.1 reads a file without a BOM as ANSI and garbles Vietnamese text.
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom -and @($bytes | Where-Object { $_ -gt 127 }).Count) { throw "Save as UTF-8 with BOM: $($file.FullName)" }
}
foreach ($testName in $Name) {
    if ($testName -notmatch '^[a-z][a-z0-9-]+$' -or $testName -eq 'run') { throw "Invalid test name: $testName" }
    $path = Join-Path $PSScriptRoot "$testName.ps1"
    if ($testName -eq 'support-report') {
        & node --test (Join-Path $PSScriptRoot 'support-report.test.mjs')
        if ($LASTEXITCODE -ne 0) { $failures.Add($testName) }
        continue
    }
    if (-not (Test-Path -LiteralPath $path)) { throw "Test not found: $testName" }
    Write-Host "Testing: $testName" -ForegroundColor Cyan
    & $runner -NoProfile -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) { $failures.Add($testName) }
}
if ($failures.Count) { throw "Failed checks: $($failures -join ', ')" }
Write-Host "PASS: syntax and $($Name.Count) test suites." -ForegroundColor Green
