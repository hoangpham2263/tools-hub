function Get-WritingStyle([string]$Path) {
    $style = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($style.schema_version -ne 1 -or -not $style.review_rules) { throw 'Invalid writing style data.' }
    return $style
}

function Get-ReviewStyleProfiles([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data.schema_version -ne 1) { throw 'Unsupported review style schema.' }
        foreach ($profile in $data.profiles) {
            if (-not $profile.id -or -not $profile.guidance -or $profile.min_words -lt 4 -or $profile.max_words -gt 60 -or $profile.min_words -gt $profile.max_words) {
                throw 'Invalid review writing profile.'
            }
        }
        return $data.profiles
    } catch { Write-Warning 'Review style data is invalid; using the default writing style.' }
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
