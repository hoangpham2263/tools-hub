function Get-WritingStyle([string]$Path) {
    $style = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($style.schema_version -ne 1 -or -not $style.review_rules) { throw 'Invalid writing style data.' }
    return $style
}

# One shared writing corpus; only the text is needed to learn phrasing.
function Get-ReviewSamples([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $seen = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ($record.body -isnot [string]) { continue }
        $body = ($record.body -replace '\s+', ' ').Trim()
        if (-not $body) { continue }
        $key = $body.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
        [pscustomobject]@{ body = $body }
    }
}

function Select-ReviewSamples($Samples) {
    $pool = @($Samples | Where-Object { $_ -and $_.body })
    if (-not $pool.Count) { return }
    # Pick once per review; repair attempts keep this same reference.
    $pool | Get-Random -Count 1
}

function Get-ReviewDraftIssue([string]$Text, $Samples) {
    if (-not $Text.Trim()) { return 'The draft was empty.' }
    if ($Text -match '[!\uFF01\u203C\u2049]') { return 'The draft used an exclamation mark. Rewrite as a plain comment without exclamatory sentences.' }
    # An exclamation without the mark: excited interjections and "what a ..." sentences read the same way.
    if ($Text -match '(?i)\b(wow|whoa|omg|yay|woohoo|hooray|yippee|oh my|oh wow)\b|\bwhat an? [a-z]+') { return 'The draft used an excited interjection or an exclamatory sentence. Rewrite as a plain, calm comment.' }
    $normalized = ([regex]::Replace($Text.ToLowerInvariant(), '[^\p{L}\p{N}]+', ' ')).Trim()
    foreach ($sample in $Samples) {
        $source = ([regex]::Replace($sample.body.ToLowerInvariant(), '[^\p{L}\p{N}]+', ' ')).Trim()
        if ($normalized -eq $source) { return 'The draft copied a reference review. Write original wording based on the attached photo.' }
        $tokens = @($source -split ' ')
        for ($i = 0; $i -le $tokens.Count - 8; $i++) {
            $phrase = $tokens[$i..($i + 7)] -join ' '
            if ((' ' + $normalized + ' ').Contains(' ' + $phrase + ' ')) {
                return 'The draft reused eight consecutive words from a reference review. Write original wording based on the attached photo.'
            }
        }
    }
    return ''
}

# The style sample sets the length: a draft far longer or shorter than it is sent back once.
function Get-ReviewWordRange([string]$SampleBody) {
    $count = @($SampleBody -split '\s+' | Where-Object { $_ }).Count
    [pscustomobject]@{ Words = $count; Min = [Math]::Max(1, [int][Math]::Floor($count * 0.6)); Max = [int][Math]::Ceiling($count * 1.3) + 2 }
}

function Get-ReviewLengthIssue([string]$Text, $Range) {
    $count = @($Text -split '\s+' | Where-Object { $_ }).Count
    if ($count -gt $Range.Max -or $count -lt $Range.Min) {
        return "The draft has $count words; the style reference has $($Range.Words). Rewrite it to $($Range.Min)-$($Range.Max) words, same length as the reference, dropping the least important detail instead of adding more."
    }
    return ''
}

# Machine-writing tells that can be found by code. Checked on the first draft only, like length: one rewrite, never a failed product.
function Get-ReviewStyleIssue([string]$Text) {
    if ($Text -match '[—–]') { return 'The draft used a dash. Use a comma or a new sentence instead.' }
    if ($Text -match '(?i)\b(stunning|elegant(ly)?|beautifully|exquisite(ly)?|breathtaking|timeless|elevates?|delve[sd]?|perfect for|must-have|highly recommend|game.?changer)\b') { return 'The draft used polished or sales wording. Use plain everyday words.' }
    if ($Text -match "(?i)\bnot (just|only)\b.{1,60}\bbut\b|(^|[.?]\s+)(overall|in conclusion|all in all|to sum up)\b|worth noting") { return 'The draft used a machine-style pattern (not just X but Y, an overall or summing-up line). Say it plainly, once.' }
    if ($Text -match '(?i)\b[a-z]+, [a-z]+,? (and|or) [a-z]+\b') { return 'The draft listed three items in a row. Mention one or two things instead.' }
    $lengths = @(($Text -split '(?<=[.?])\s+') | Where-Object { $_.Trim() } | ForEach-Object { @($_ -split '\s+' | Where-Object { $_ }).Count })
    if ($lengths.Count -ge 3 -and (($lengths | Measure-Object -Maximum).Maximum - ($lengths | Measure-Object -Minimum).Minimum) -le 2) { return 'Every sentence has about the same length. Vary them like a person would.' }
    return ''
}
