# Image generation through the signed-in ChatGPT / Google Flow tab (bridge/ + extension/).
$script:BridgeUrl = 'http://127.0.0.1:8765'
$script:BridgeProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-ImageBridgeStatus {
    try { return Invoke-RestMethod -Uri "$script:BridgeUrl/status" -TimeoutSec 3 } catch { return $null }
}
function Test-ImageBridge {
    $status = Get-ImageBridgeStatus
    if ($null -eq $status) { return $null }
    return [bool]$status.extension
}

# After Cập nhật the bridge and the extension still run the old files: a bridge started on an older server.mjs is
# stopped (Start-ImageBridge starts it again), an extension of another version than extension/manifest.json reloads.
function Stop-StaleImageBridge([string]$ProjectRoot) {
    $status = Get-ImageBridgeStatus
    if ($null -eq $status) { return }
    $changed = [DateTimeOffset]::new((Get-Item -LiteralPath (Join-Path $ProjectRoot 'bridge/server.mjs')).LastWriteTimeUtc).ToUnixTimeMilliseconds()
    if ([long]$status.code -eq $changed) { return }
    try { Invoke-RestMethod -Method Post -Uri "$script:BridgeUrl/quit" -TimeoutSec 3 | Out-Null } catch {}
    for ($i = 0; $i -lt 20 -and $null -ne (Get-ImageBridgeStatus); $i++) { Start-Sleep -Milliseconds 250 }
    if ($null -eq (Get-ImageBridgeStatus)) { return }
    # A bridge from before /quit: stop its process (started with this file's full path).
    $server = Join-Path $ProjectRoot 'bridge/server.mjs'
    if ($script:OnWindows) {
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like "*$server*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } else { & pkill -f $server 2>$null }
    for ($i = 0; $i -lt 20 -and $null -ne (Get-ImageBridgeStatus); $i++) { Start-Sleep -Milliseconds 250 }
}
function Update-ImageBridgeExtension([string]$ProjectRoot) {
    $status = Get-ImageBridgeStatus
    if ($null -eq $status) { return }
    $version = [string](Get-Content -LiteralPath (Join-Path $ProjectRoot 'extension/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    if ($status.extension -and $status.extensionVersion -and $status.extensionVersion -ne $version) {
        try { Invoke-RestMethod -Method Post -Uri "$script:BridgeUrl/reload" -TimeoutSec 3 | Out-Null } catch {}
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            $now = Get-ImageBridgeStatus
            if ($now -and $now.extension -and $now.extensionVersion -eq $version) { return }
        }
    }
}

# Start the local bridge when it is not running, then wait for the extension to connect.
function Start-ImageBridge([string]$ProjectRoot) {
    Stop-StaleImageBridge $ProjectRoot
    $state = Test-ImageBridge
    if ($null -eq $state) {
        $server = Join-Path $ProjectRoot 'bridge/server.mjs'
        # Its one package (ws) is installed on first use, so no setup step is needed for it.
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'bridge/node_modules/ws'))) {
            Push-Location (Join-Path $ProjectRoot 'bridge')
            try { & npm install --silent --no-audit --no-fund 2>&1 | Out-Null } finally { Pop-Location }
            if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'bridge/node_modules/ws'))) { throw '[CAUSE:BRIDGE] Chưa cài được bridge (npm install trong bridge/). Kiểm tra mạng rồi chạy lại.' }
        }
        # It notes why it stopped in workspace/logs/bridge-exit.log.
        if ($script:OnWindows) { Start-Process node -ArgumentList ('"' + $server + '"') -WindowStyle Hidden | Out-Null }
        else { Start-Process node -ArgumentList $server | Out-Null }
    }
    # The tools' own Chrome (hub/browser.mjs), signed in from Cấu hình, runs with no window: started hidden, or started
    # again hidden when it was left open in a window after signing in. Then the extension connects to the bridge.
    $browser = Join-Path (Get-HubRoot $ProjectRoot) 'hub/browser.mjs'
    $flags = @(if ([int]((& node --version) -replace '^v(\d+).*', '$1') -lt 22) { '--experimental-websocket' })
    $answer = (& node @flags $browser start | Select-Object -Last 1) | ConvertFrom-Json
    if ($answer.error) { throw "[CAUSE:BRIDGE] $($answer.error)" }
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-ImageBridge) { Update-ImageBridgeExtension $ProjectRoot; return }
        Start-Sleep -Milliseconds 750
    }
    throw '[CAUSE:BRIDGE] Extension Tools Hub chưa kết nối. Mở Cấu hình, bấm Mở ở dòng Chrome của tool rồi đăng nhập Google (Flow, Gemini), ChatGPT.'
}

# A bridge that stopped mid-run (the call ends with no answer, then Connection refused) is started again, so the
# next try reaches one.
function Restore-ImageBridge {
    if ($null -ne (Get-ImageBridgeStatus)) { return }
    try { Start-ImageBridge $script:BridgeProjectRoot } catch {}
}

# The bridge answers {"error": "..."} with escaped characters; the message itself is what the cause is read from.
function Get-BridgeError($ErrorRecord) {
    $text = if ($ErrorRecord.ErrorDetails.Message) { $ErrorRecord.ErrorDetails.Message } else { $ErrorRecord.Exception.Message }
    try { $json = $text | ConvertFrom-Json; if ($json.error) { return [string]$json.error } } catch {}
    return $text
}

# Browser backends cannot write files themselves; drop the file-delivery lines meant for Codex.
function ConvertTo-BrowserPrompt([string]$Prompt) {
    $lines = $Prompt -split "`r?`n" | Where-Object { $_ -notmatch '^(Save a new PNG at this exact path|Do not modify any input file|End your reply with a line: BRAND)' }
    return ($lines -join "`n").Trim()
}

# Text steps through Gemini web (Viết review: Gemini web): the reply is written to $ResultFile and returned. One
# retry for a busy page; a timeout or a missing sign-in stops there.
function Invoke-BrowserText([string]$Prompt, [string[]]$Images, [string]$ResultFile, [int]$TimeoutSec = 300) {
    $body = @{ platform = 'gemini'; prompt = $Prompt; images = @($Images | Where-Object { $_ }); output = $ResultFile; timeoutSec = $TimeoutSec } | ConvertTo-Json -Depth 4
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Invoke-RestMethod -Uri "$script:BridgeUrl/generate" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec ($TimeoutSec + 120) | Out-Null
            $text = [IO.File]::ReadAllText($ResultFile, [Text.Encoding]::UTF8).Trim()
            # One finished call, counted in the app's usage line (web AIs report no tokens).
            if ($text) { Write-Host '  [AI-CALL] gemini'; return $text }
            $detail = 'Gemini trả lời trống.'
        } catch { $detail = Get-BridgeError $_; Restore-ImageBridge }
        if ($attempt -eq 2 -or $detail -match 'Hết thời gian|timeout|đăng nhập|Extension') { break }
        Write-Host "  [RETRY] Gemini; attempt $($attempt + 1)/2..." -ForegroundColor Yellow
    }
    $cause = if ($detail -match 'Hết thời gian|timeout') { 'AI_TIMEOUT' } elseif ($detail -match 'đăng nhập|Extension') { 'BRIDGE' } else { 'BUSY' }
    throw "AI failed. Gemini web: $detail [CAUSE:$cause]"
}

function Invoke-BrowserImage([string]$Platform, [string]$Prompt, [string[]]$Images, [string]$Output, [int]$TimeoutSec = 600) {
    $body = @{ platform = $Platform; prompt = (ConvertTo-BrowserPrompt $Prompt); images = @($Images); output = $Output; timeoutSec = $TimeoutSec } | ConvertTo-Json -Depth 4
    try {
        $result = Invoke-RestMethod -Uri "$script:BridgeUrl/generate" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec ($TimeoutSec + 120)
    } catch {
        $detail = Get-BridgeError $_
        Restore-ImageBridge
        # A sign-in or a Flow account not set up for images (its first-visit screen, Tác nhân on) needs the user, so it is
        # not retried (BRIDGE).
        $cause = if ($detail -match 'Hết thời gian|timeout') { 'AI_TIMEOUT' } elseif ($detail -match 'đăng nhập|Extension|Google Flow của tài khoản đang chọn') { 'BRIDGE' } else { 'BUSY' }
        throw "[CAUSE:$cause] $Platform không tạo được ảnh. $detail"
    }
    ConvertTo-PngFile $Output
    Write-Host "  [AI-CALL] $Platform"
    return $result
}
