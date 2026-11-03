$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path $PSScriptRoot -Parent) '../../hub/setup/setup-check.ps1'
$global:SetupTestAuthScenario = 'chatgpt'
function codex {
    switch ($global:SetupTestAuthScenario) {
        chatgpt { Write-Error 'Logged in using ChatGPT'; $global:LASTEXITCODE = 0 }
        api { Write-Error 'Logged in using API key'; $global:LASTEXITCODE = 0 }
        missing { Write-Error 'Not logged in'; $global:LASTEXITCODE = 1 }
    }
}
foreach ($scenario in @('chatgpt', 'api', 'missing')) {
    $global:SetupTestAuthScenario = $scenario
    $json = & $entry -AsJson | Out-String
    $report = $json | ConvertFrom-Json
    $expected = $scenario -ne 'missing'
    if ($report.Ready -ne $expected -or $report.Checks.Count -ne $(if ($expected) { 4 } else { 3 })) { throw 'Incorrect sign-in readiness.' }
    if ($json -match 'Write-Error|CategoryInfo|Logged in using|C:\\|credit|token') { throw 'Technical sign-in details leaked into the user report.' }
    if ($scenario -eq 'chatgpt' -and $report.Checks[2].Message -notmatch 'đã đăng nhập') { throw 'Successful stderr status was rejected.' }
    if ($scenario -eq 'api' -and $report.Checks[2].Message -notmatch 'tính phí riêng') { throw 'API sign-in must not be reported as ChatGPT.' }
    if (-not $expected -and -not $report.Checks[2].Action) { throw 'Missing sign-in must include user guidance.' }
    $states = @($report.Steps | ForEach-Object State)
    if (($report.Steps | ForEach-Object Id) -join ',' -ne 'drive,node,codex,login,quota,browser,google,antigravity') { throw 'Check steps are missing or out of order.' }
    if ($expected -and $states[3] -ne 'ok') { throw 'Signed-in step must pass.' }
    if (-not $expected -and ($states[3] -ne 'fail' -or $states[4] -ne 'wait' -or $report.Steps[3].Action -ne 'login')) { throw 'Missing sign-in must block the quota step and offer sign-in.' }
}
Write-Host 'PASS: ChatGPT/API sign-in, missing login and clean setup messages, including successful stderr output.'
