# Image generation and Gemini text through the signed-in ChatGPT / Google Flow / Gemini tab of the user's own Chrome
# (hub/bridge + hub/extension).
$script:BridgeUrl = 'http://127.0.0.1:8765'
$script:BridgeProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-ImageBridgeStatus {
    try { return Invoke-RestMethod -Uri "$script:BridgeUrl/status" -TimeoutSec 3 } catch { return $null }
}

# The shared bridge (hub/bridge) and the Tools Hub extension in the user's own Chrome: hub/bridge/ensure.mjs installs
# and starts the bridge (again after Cập nhật), starts Chrome when the extension is not connected and reloads an
# extension of another version.
function Start-ImageBridge([string]$ProjectRoot) {
    $ensure = Join-Path (Get-HubRoot $ProjectRoot) 'hub/bridge/ensure.mjs'
    $answer = $null
    try { $answer = (& node $ensure | Select-Object -Last 1) | ConvertFrom-Json } catch {}
    if (-not $answer) { throw '[CAUSE:BRIDGE] Không bật được bridge (hub/bridge). Mở Cấu hình xem Node.js đã cài chưa rồi chạy lại.' }
    if (-not $answer.ok) { throw "[CAUSE:BRIDGE] $($answer.error)" }
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
