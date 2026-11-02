# What a post may say and how it is laid out for a platform. The rules (data/post-rules.json), the platforms
# (data/platforms.json) and the tones (data/tones.json) are data; this file reads them and checks a draft.

function Get-PostPlatform([string]$Id) {
    $platform = (Read-JsonFile (Join-Path (Get-ToolRoot) 'data/platforms.json')).platforms.$Id
    if (-not $platform) { throw "Unknown platform: $Id." }
    $platform
}

function Get-PostTone([string]$Id) {
    $tone = (Read-JsonFile (Join-Path (Get-ToolRoot) 'data/tones.json')).tones.$Id
    if (-not $tone) { throw "Unknown tone: $Id." }
    $tone
}

# The numbered rule set every post prompt ends with.
function Get-PostRulesText {
    $rules = @((Read-JsonFile (Join-Path (Get-ToolRoot) 'data/post-rules.json')).rules)
    (@(for ($i = 0; $i -lt $rules.Count; $i++) { "$($i + 1). $($rules[$i])" })) -join [Environment]::NewLine
}

# The words of a post, not counting hashtags, links or the brand's own tagline.
function Get-PostWordCount([string]$Text, $Pack) {
    $plain = $Text
    if ($Pack -and $Pack.tagline) { $plain = $plain.Replace([string]$Pack.tagline, ' ') }
    $plain = [regex]::Replace($plain, 'https?://\S+|#[\p{L}\p{N}_]+', ' ')
    @($plain -split '\s+' | Where-Object { $_ }).Count
}

# What is wrong with a finished post, or ''. Checked on the first draft only: the repair names it, and a draft that
# is only a little off is not thrown away.
function Get-PostIssue([string]$Text, $Platform, $Pack) {
    if (-not $Text.Trim()) { return 'The post was empty.' }
    $plain = if ($Pack -and $Pack.tagline) { $Text.Replace([string]$Pack.tagline, ' ') } else { $Text }
    if ($plain -match '[!！‼⁉]') { return 'The post used an exclamation mark. Rewrite it as a calm, plain post.' }
    if ($plain -match '[—–]') { return 'The post used a dash inside a sentence. Use a comma or a new sentence.' }
    if ($plain -match '[☀-➿]|[\uD83C-\uD83E][\uDC00-\uDFFF]') { return 'The post used an emoji. Use words only.' }
    if ($plain -match '(?i)\b(stunning|elegant(ly)?|beautifully|exquisite(ly)?|breathtaking|timeless|elevates?|perfect for|must-have|highly recommend|game.?changer)\b') { return 'The post used polished or sales wording. Use plain everyday words.' }
    if ($plain -match "(?i)\bnot (just|only)\b.{1,60}\bbut\b|(^|[.?]\s+)(overall|in conclusion|all in all|to sum up)\b|worth noting") { return 'The post used a machine-style pattern (not just X but Y, or an overall or summing-up line). Say it plainly, once.' }
    $words = Get-PostWordCount $Text $Pack
    $min = [int]$Platform.words[0]; $max = [int]$Platform.words[1]
    if ($words -gt [Math]::Ceiling($max * 1.3) -or $words -lt [Math]::Floor($min * 0.6)) {
        return "The post has $words words; $($Platform.name) wants $min to $max. Rewrite it to that length."
    }
    if ($Text.Length -gt [int]$Platform.limit) { return "The post is $($Text.Length) characters; $($Platform.name) allows $($Platform.limit). Shorten it." }
    ''
}

# The reply laid out for the platform: no fences or quotes around it, links only where the platform lets them work
# (Facebook, Threads: the product link on its own line; Instagram, TikTok: none), and at most as many hashtags as the
# platform takes, the AI's own first, then the owner's and the brand's.
function Format-PostText([string]$Text, $Platform, [string]$Link, [string[]]$Tags) {
    $t = ($Text -replace "`r", '').Trim()
    $t = ($t -replace '^```[A-Za-z]*\s*', '' -replace '\s*```$', '').Trim()
    if ($t.Length -gt 1) {
        $open = [string]$t[0]; $close = [string]$t[$t.Length - 1]
        if ($open -in @('"', [string][char]0x201C) -and $close -in @('"', [string][char]0x201D)) { $t = $t.Substring(1, $t.Length - 2).Trim() }
    }
    $found = @()
    # Links go first: a hashtag the AI put before the link is then at the end, and is not added a second time.
    $t = [regex]::Replace($t, '\s*https?://\S+', '').Trim()
    while ($t -match '(\s+|^)(#[\p{L}\p{N}_]+)\s*$') { $found = @($Matches[2]) + $found; $t = $t.Substring(0, $t.Length - $Matches[0].Length).TrimEnd() }
    $t = [regex]::Replace($t, "\n{3,}", "`n`n")
    $tags = @($found + @($Tags | Where-Object { $_ })) | ForEach-Object { if ($_ -match '^#') { $_ } else { "#$_" } }
    $tags = @($tags | Select-Object -Unique | Select-Object -First ([int]$Platform.tags))
    $parts = @($t)
    if ($Platform.link -eq 'body' -and $Link) { $parts += $Link }
    if ($tags.Count) { $parts += ($tags -join ' ') }
    $join = if ($Platform.layout -eq 'line') { ' ' } else { "`n`n" }
    ($parts -join $join).Trim()
}
