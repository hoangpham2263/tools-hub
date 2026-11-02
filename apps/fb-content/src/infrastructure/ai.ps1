# Every AI call of this tool, text or image, goes through Invoke-AI: one place picks the AI (Viết bài / Tạo ảnh) and
# its options, so a fix here holds for every AI. The prompts are the same for all of them; the hub's AI core
# (hub/ai/ai.ps1, loaded first by bootstrap.ps1) adds what one AI alone needs.
# Reads: $script:Config (TextBackend, ImageBackend), $script:Run.Dir (Codex's working folder).

# Text: the reply (also written to $ResultFile). Image: saved at $Output; $ResultFile holds the AI's reply or log.
function Invoke-AI([string]$PromptText, [string[]]$Images, [string]$ResultFile, [ValidateSet('text', 'image')][string]$Kind = 'text', [string]$Output = '') {
    $ai = if ($Kind -eq 'image') { $script:Config.ImageBackend } else { $script:Config.TextBackend }
    $options = @{}
    if ($ai -eq 'codex') {
        $options = @{ WorkDir = $script:Run.Dir }
        if ($Kind -eq 'image') { $options.ReplyFile = $ResultFile }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $ResultFile -Parent) | Out-Null
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

# One image. A connection that dropped, a timeout or a busy service may still have delivered the image: it is
# looked for first, and only then is the request sent again (at most twice). A sign-in, quota or policy stop is final.
function Invoke-ImageAI([string]$PromptText, [string[]]$Images, [string]$Output, [string]$LogFile) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
        try {
            Invoke-AI $PromptText $Images $LogFile 'image' $Output | Out-Null
            if (Test-ImageFile $Output) { return }
            throw 'The AI finished but no readable image was saved. [CAUSE:OUTPUT_MISSING]'
        } catch {
            $message = $_.Exception.Message
            if (Test-ImageFile $Output) { return }
            $retryable = $message -match '\[CAUSE:(AI_TIMEOUT|NETWORK|BUSY|OUTPUT_MISSING)\]'
            if (-not $retryable -or $attempt -eq 2) { throw }
            Write-Host "  [RETRY] image; attempt $($attempt + 1)/2..." -ForegroundColor Yellow
        }
    }
}

# The [CAUSE:...] an error ends in, or ''.
function Get-ErrorCause([string]$Message) {
    if ($Message -match '\[CAUSE:(\w+)\]') { $Matches[1] } else { '' }
}
