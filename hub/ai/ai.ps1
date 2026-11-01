# The AIs every tool can use, behind one call: Invoke-HubAI -Kind text|image -Ai <id> -Prompt ... -Output <file>.
# A tool dot-sources this file (from apps/<tool>/src: ../../../hub/ai/ai.ps1) and keeps only its own prompts and
# choices. A new AI is one entry in $script:HubAIProviders plus its provider file in providers/:
#   cli      a command on this machine (codex, agy)
#   browser  a site in the user's own Chrome, through hub/bridge and the Tools Hub extension (hub/extension/sites/)
# Errors end in [CAUSE:<kind>] (AUTH, QUOTA, BUSY, NETWORK, AI_TIMEOUT, BRIDGE, ...), which tools show and retry by.
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'providers/codex.ps1')
. (Join-Path $PSScriptRoot 'providers/antigravity.ps1')
. (Join-Path $PSScriptRoot 'providers/browser.ps1')

# Every call, one JSON line in <hub>/workspace/logs/ai-usage.jsonl (Cấu hình → Lượt dùng AI): the CLIs here, the web
# AIs in hub/bridge/server.mjs (which knows the Google account a job ran with). Tests point HUB_AI_USAGE_FILE elsewhere.
$script:HubAIUsageFile = if ($env:HUB_AI_USAGE_FILE) { $env:HUB_AI_USAGE_FILE } else { Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'workspace/logs/ai-usage.jsonl' }
function Add-HubAIUsage([string]$Ai, [string]$Kind, [string]$Account, [bool]$Ok, [string]$Cause = '', [int]$Ms = 0, $Tokens = $null) {
    $entry = [ordered]@{ t = [DateTime]::UtcNow.ToString('o'); ai = $Ai; kind = $Kind; account = $Account; ok = $Ok; ms = $Ms }
    if ($Cause) { $entry.cause = $Cause }
    if ($Tokens) { $entry.in = [long]$Tokens.Input; $entry.cached = [long]$Tokens.Cached; $entry.out = [long]$Tokens.Output }
    $line = (ConvertTo-Json -InputObject $entry -Compress) + "`n"
    # Parallel workers append to the same file: one at a time, and never fail a call over it.
    for ($i = 0; $i -lt 20; $i++) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path $script:HubAIUsageFile -Parent) | Out-Null
            [IO.File]::AppendAllText($script:HubAIUsageFile, $line, [Text.UTF8Encoding]::new($false)); return
        } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } catch { return }
    }
}

$script:HubAIProviders = [ordered]@{
    codex = [pscustomobject]@{ Name = 'Codex CLI'; Via = 'cli'; Kinds = @('text', 'image') }
    gemini = [pscustomobject]@{ Name = 'Gemini web'; Via = 'browser'; Kinds = @('text') }
    flow = [pscustomobject]@{ Name = 'Google Flow'; Via = 'browser'; Kinds = @('image') }
    antigravity = [pscustomobject]@{ Name = 'Antigravity CLI'; Via = 'cli'; Kinds = @('text') }
}

function Get-HubAIProvider([string]$Id) {
    $provider = $script:HubAIProviders[$Id]
    if (-not $provider) { throw "AI không hỗ trợ: $Id. [CAUSE:UNSUPPORTED]" }
    return $provider
}

# The AIs that can do one kind of work, for a tool's choices: @{ id; name }.
function Get-HubAIChoices([ValidateSet('text', 'image')][string]$Kind) {
    foreach ($id in $script:HubAIProviders.Keys) {
        $provider = $script:HubAIProviders[$id]
        if ($provider.Kinds -contains $Kind) { [pscustomobject]@{ id = $id; name = $provider.Name } }
    }
}

# Text: the reply, also written to $Output. Image: the image saved at $Output (PNG); Codex saves it where the prompt
# says and returns its reply, a web AI returns the bridge's answer (source, bytes).
# Options, all optional: TimeoutSec; Codex: WorkDir (required), Model, Effort, ReconnectSec, Attempts, RetryDelaySec.
function Invoke-HubAI {
    param(
        [Parameter(Mandatory)][ValidateSet('text', 'image')][string]$Kind,
        [Parameter(Mandatory)][string]$Ai,
        [Parameter(Mandatory)][string]$Prompt,
        [string[]]$Images = @(),
        [Parameter(Mandatory)][string]$Output,
        [hashtable]$Options = @{}
    )
    $provider = Get-HubAIProvider $Ai
    if ($provider.Kinds -notcontains $Kind) { throw "AI failed. $($provider.Name) không làm được việc này ($Kind). [CAUSE:UNSUPPORTED]" }
    $timeout = if ($Options.ContainsKey('TimeoutSec')) { [Math]::Max(1, [int]$Options.TimeoutSec) } else { 0 }
    if ($provider.Via -eq 'cli') {
        # The bridge counts the web AIs; the CLIs are counted here, failures too, with what stopped them.
        $watch = [Diagnostics.Stopwatch]::StartNew(); $script:CodexCallTokens = $null
        $account = if ($Ai -eq 'codex') { Get-CodexAccount } else { '' }
        try { $result = Invoke-HubAIProvider $Kind $Ai $Prompt $Images $Output $Options $timeout }
        catch {
            $cause = if ($_.Exception.Message -match '\[CAUSE:(\w+)\]') { $Matches[1] } else { 'UNKNOWN' }
            Add-HubAIUsage $Ai $Kind $account $false $cause ([int]$watch.ElapsedMilliseconds) $script:CodexCallTokens
            throw
        }
        Add-HubAIUsage $Ai $Kind $account $true '' ([int]$watch.ElapsedMilliseconds) $script:CodexCallTokens
        return $result
    }
    return Invoke-HubAIProvider $Kind $Ai $Prompt $Images $Output $Options $timeout
}

function Invoke-HubAIProvider([string]$Kind, [string]$Ai, [string]$Prompt, [string[]]$Images, [string]$Output, [hashtable]$Options, [int]$timeout) {
    switch ($Ai) {
        'codex' {
            $codex = @{
                Sandbox = $(if ($Kind -eq 'image') { 'workspace-write' } else { 'read-only' })
                WorkDir = $Options.WorkDir; Model = [string]$Options.Model; Effort = [string]$Options.Effort; TimeoutSec = $timeout
            }
            foreach ($key in @('ReconnectSec', 'Attempts', 'RetryDelaySec')) { if ($Options.ContainsKey($key)) { $codex[$key] = [int]$Options[$key] } }
            if (-not $codex.WorkDir) { throw 'Invoke-HubAI codex: Options.WorkDir is required.' }
            return Invoke-CodexExec -PromptText $Prompt -Images $Images -ResultFile $Output @codex
        }
        'antigravity' { return Invoke-AntigravityText $Prompt $Images $Output $(if ($timeout) { $timeout } else { 300 }) }
        default {
            if ($Kind -eq 'text') { return Invoke-BrowserText $Ai $Prompt $Images $Output $(if ($timeout) { $timeout } else { 300 }) }
            return Invoke-BrowserImage $Ai $Prompt $Images $Output $(if ($timeout) { $timeout } else { 600 })
        }
    }
}
