# The workflow's AI calls, through the hub's shared AI core (hub/ai/ai.ps1, loaded first by bootstrap.ps1).
# Reads: $script:Config (TextBackend, Model, ReasoningEffort, timeouts), $script:Batch.Dir. Images from a web AI go
# straight to Invoke-BrowserImage (workflow/steps/02-create-image.ps1); Codex makes the rest.

# A text step (Sandbox read-only: the reply) or a Codex image (workspace-write: Codex saves the PNG the prompt names).
function Invoke-AI([string]$PromptText, [string[]]$Images, [string]$ResultFile, [string]$Sandbox = 'read-only') {
    $kind = if ($Sandbox -eq 'workspace-write') { 'image' } else { 'text' }
    $config = if ($script:Config) { $script:Config } else { @{} }
    # Viết review: Gemini web or the Antigravity CLI handles every text step instead of Codex.
    $ai = if ($kind -eq 'text' -and $config.TextBackend -in @('gemini', 'antigravity')) { $config.TextBackend } else { 'codex' }
    $options = @{ WorkDir = $script:Batch.Dir; Model = $config.Model; Effort = $config.ReasoningEffort }
    $timeoutKey = if ($kind -eq 'image') { 'ImageTimeoutSeconds' } else { 'AiTimeoutSeconds' }
    if ($config.ContainsKey($timeoutKey)) { $options.TimeoutSec = [int]$config[$timeoutKey] }
    if ($config.ContainsKey('AiReconnectTimeoutSeconds')) { $options.ReconnectSec = [Math]::Max(1, [int]$config.AiReconnectTimeoutSeconds) }
    if ($config.ContainsKey('AiRetryDelaySeconds')) { $options.RetryDelaySec = [int]$config.AiRetryDelaySeconds }
    if ($ai -ne 'codex') { $options = @{} }
    return Invoke-HubAI -Kind $kind -Ai $ai -Prompt $PromptText -Images $Images -Output $ResultFile -Options $options
}
