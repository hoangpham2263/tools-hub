# Every AI call of the workflow, text or image, Codex or a web AI, goes through Invoke-AI: one place picks the AI
# (Viết review / Tạo ảnh), its options and its log line, so a fix here holds for every AI. The prompt is the same for
# all of them; the hub's AI core (hub/ai/ai.ps1, loaded first by bootstrap.ps1) adds what one AI alone needs.
# Reads: $script:Config (TextBackend, ImageBackend, Model, ReasoningEffort, timeouts), $script:Batch.Dir.

# Text: the reply (also written to $ResultFile). Image: saved at $Output; $ResultFile holds the AI's reply or log.
function Invoke-AI([string]$PromptText, [string[]]$Images, [string]$ResultFile, [ValidateSet('text', 'image')][string]$Kind = 'text', [string]$Output = '') {
    $config = if ($script:Config) { $script:Config } else { @{} }
    $ai = if ($Kind -eq 'image') { if ($config.ImageBackend) { $config.ImageBackend } else { 'codex' } }
          elseif ($config.TextBackend -in @('gemini', 'antigravity')) { $config.TextBackend } else { 'codex' }
    $options = @{}
    if ($ai -eq 'codex') {
        $options = @{ WorkDir = $script:Batch.Dir; Model = $config.Model; Effort = $config.ReasoningEffort }
        $timeoutKey = if ($Kind -eq 'image') { 'ImageTimeoutSeconds' } else { 'AiTimeoutSeconds' }
        if ($config.ContainsKey($timeoutKey)) { $options.TimeoutSec = [int]$config[$timeoutKey] }
        if ($config.ContainsKey('AiReconnectTimeoutSeconds')) { $options.ReconnectSec = [Math]::Max(1, [int]$config.AiReconnectTimeoutSeconds) }
        if ($config.ContainsKey('AiRetryDelaySeconds')) { $options.RetryDelaySec = [int]$config.AiRetryDelaySeconds }
        if ($Kind -eq 'image') { $options.ReplyFile = $ResultFile }
    }
    Write-Host "  [AI] $Kind -> $((Get-HubAIProvider $ai).Name)"
    if ($Kind -eq 'text') { return Invoke-HubAI -Kind text -Ai $ai -Prompt $PromptText -Images $Images -Output $ResultFile -Options $options }
    $result = Invoke-HubAI -Kind image -Ai $ai -Prompt $PromptText -Images $Images -Output $Output -Options $options
    # A web AI answers where the image came from; Codex replies in words, already in $ResultFile.
    if ($result.PSObject.Properties['source']) {
        [IO.File]::WriteAllText($ResultFile, "backend: $ai`nsource: $($result.source)`nbytes: $($result.bytes)", [Text.UTF8Encoding]::new($false))
        return ''
    }
    return [string]$result
}
