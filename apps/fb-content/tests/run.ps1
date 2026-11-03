# All checks run in fresh PowerShell processes (Windows PowerShell 5.1 on Windows, pwsh on macOS); no AI call is made.
param([string[]]$Name = @('prompts', 'posts', 'watermark-core', 'watermark', 'content-run'))
$ErrorActionPreference = 'Stop'
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if ($onWindows) {
    $env:PSModulePath = (Join-Path $PSHOME 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $runner = 'powershell.exe'
} else {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    $runner = if ($pwsh) { $pwsh.Source } else { (Get-Process -Id $PID).Path }
}
$project = Split-Path $PSScriptRoot -Parent
# The suites mock every AI call; the calls they count go to a file of the tests, not to the install's Lượt dùng AI.
$env:HUB_AI_USAGE_FILE = Join-Path $project 'workspace/tests/ai-usage.jsonl'
$env:TOOLS_HUB_TEST = '1'
$failures = New-Object Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem (Join-Path $project 'src'), $PSScriptRoot -Recurse -File -Filter '*.ps1')) {
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
    # The drawing is plain Node, tested with node --test (same on every OS).
    if ($testName -eq 'watermark-core') {
        Write-Host "Testing: $testName" -ForegroundColor Cyan
        & node --test (Join-Path $PSScriptRoot 'watermark-core.test.mjs')
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
