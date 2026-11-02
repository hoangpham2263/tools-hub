. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$tempDir = Join-Path $TestWorkspaceRoot ('review-writing-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $path = Join-Path $tempDir 'samples.jsonl'
    @(
        '{"category":"coffee-tables","body":"The curved legs stand out against the broad wooden top.","source_url":"https://example.test/table"}'
        '{"category":"coffee-tables","body":"The low shape leaves a clear view across the room."}'
        '{"category":"coffee-tables","body":"Dark edges frame the lighter grain in the middle."}'
        '{"category":"coffee-tables","body":"The rounded corners give the wide top a softer outline."}'
        '{"category":"coffee-tables","body":"The curved legs stand out against the broad wooden top."}'
        '{"category":"tees-hoodies","body":"APPAREL_ONLY The neckline has a contrasting trim."}'
        '{"category":"shop","body":"A plain short comment from a store review."}'
        '{"review_id":"legacy-photo","body":"The little front pockets stand out on the dark apron."}'
        '{"source_url":"https://example.test/products/polo-shirt","body":"The collar has a narrow contrasting edge."}'
        '{"body":"nice shape"}'
        '{"category":"other","body":"The curved legs stand out against the broad wooden top."}'
        'broken json'
    ) | Set-Content $path -Encoding UTF8
    $samples = @(Get-ReviewSamples $path)
    Assert ($samples.Count -eq 9) 'Shared loader lost uncategorized samples or failed to deduplicate across categories.'
    foreach ($sample in $samples) { Assert (($sample.PSObject.Properties.Name -join ',') -eq 'body') 'Sample retained unnecessary metadata.' }
    Assert (@($samples | Where-Object body -eq 'nice shape').Count -eq 1) 'Short uncategorized sample was excluded.'
    Assert (@(Get-ReviewSamples (Join-Path $tempDir 'missing.jsonl')).Count -eq 0) 'Missing data must allow fallback.'
    $context = [pscustomobject]@{id='coffee-tables';source_categories=@('coffee-tables');presentation='placed';product='wood coffee table';details='rounded top and visible grain'}
    $draw = @(Select-ReviewSamples $samples)
    Assert ($draw.Count -eq 1 -and $draw[0].body -in $samples.body) 'Expected one random reference from the shared file.'
    $first = @($samples[0])
    $script:SelectionCalls = 0
    function Get-Random { param($Count, [Parameter(ValueFromPipeline=$true)]$InputObject) begin { $items = @() } process { $items += $InputObject } end { $script:SelectionCalls++; $items[-1] } }
    $selected = @(Select-ReviewSamples $samples)
    Assert ($script:SelectionCalls -eq 1 -and $selected.Count -eq 1 -and $selected[0].body -eq 'nice shape') 'Selection did not draw from the full shared corpus.'
    Remove-Item Function:\Get-Random
    Assert (@(Select-ReviewSamples @()).Count -eq 0) 'Empty corpus must allow fallback.'
    $crossCategory = @(Select-ReviewSamples @($samples | Where-Object body -match 'APPAREL_ONLY'))
    Assert ($crossCategory.Count -eq 1 -and $crossCategory[0].body -match 'APPAREL_ONLY') 'Different product category was filtered out of the writing corpus.'
    Assert (-not (Get-ReviewDraftIssue 'I really like the rounded edge.' $first)) 'Natural first-person reaction rejected.'
    Assert (-not (Get-ReviewDraftIssue 'love the round edges, kinda nice' $first)) 'Informal fragment rejected.'
    Assert (-not (Get-ReviewDraftIssue 'nice colur on that edge' $first)) 'Minor spelling slip rejected.'
    Assert ([bool](Get-ReviewDraftIssue ' ' $first)) 'Empty draft passed.'
    Assert ([bool](Get-ReviewDraftIssue 'nice rounded edge!' $first)) 'Exclamation mark passed.'
    foreach ($excited in 'wow nice rounded edge', 'OMG that grain', 'What a lovely top.', 'yay the legs look good') { Assert ([bool](Get-ReviewDraftIssue $excited $first)) "Excited wording passed: $excited" }
    Assert (-not (Get-ReviewDraftIssue 'the top has a rounded edge and a dark knot near the left side.' $first)) 'Plain comment wrongly flagged as exclamatory.'
    Assert ([bool](Get-ReviewDraftIssue ($first[0].body) $first)) 'Copied review passed.'
    Assert ([bool](Get-ReviewDraftIssue ('Nice table. '+$first[0].body) $first)) 'Copied phrase passed.'
    Assert (-not (Get-ReviewDraftIssue 'The pale grain is easy to see across the broad top.' $first)) 'Original detail-led draft rejected.'
    foreach ($tell in 'the grain is stunning on this top.', 'it is not just a table but a statement.', 'overall a nice piece.', 'dark, rough, and uneven.', 'nice top — love the grain.', 'the top is wide. the legs are thick. the knots are dark. the edge is rough.') { Assert ([bool](Get-ReviewStyleIssue $tell)) "Machine-style wording passed: $tell" }
    foreach ($plain in 'the top has a rounded edge and a dark knot near the left side. legs flare out at the floor.', 'nice shape', 'love the round edges, kinda nice') { Assert (-not (Get-ReviewStyleIssue $plain)) "Plain wording wrongly flagged: $plain" }
    $range = Get-ReviewWordRange 'one two three four five six seven eight nine ten'
    Assert ($range.Words -eq 10 -and $range.Min -eq 6 -and $range.Max -eq 15) 'Word range does not follow the sample length.'
    Assert (-not (Get-ReviewLengthIssue 'one two three four five six seven eight' $range)) 'Draft of similar length rejected.'
    Assert ([bool](Get-ReviewLengthIssue (('word ') * 30) $range) -and [bool](Get-ReviewLengthIssue 'word' $range)) 'Draft far longer or shorter than the sample passed.'

    $script:Config = @{ ReviewSamples=@($samples[0]); WritingStyle=(Get-WritingStyle (Join-Path $root 'data/writing-style.json')) }
    $script:Batch = @{Logs=$tempDir}
    $script:Calls = 0; $script:Mode = 'empty'
    function Invoke-AI($PromptText, $Images, $ResultFile) {
        $script:Calls++
        Assert ($PromptText -match 'Style reference, one random review' -and $PromptText -match 'curved legs') 'Actual review sample missing from prompt.'
        Assert ($PromptText -match 'No exclamation marks' -and $PromptText -notmatch 'Optional writing nudge|Writing style direction|Aim for|review-samples.jsonl|preset style') 'Preset style, exclamatory guidance or selection details leaked into prompt.'
        Assert ($PromptText -notmatch 'I like|I love' -and $PromptText -match 'Match its casualness and rhythm' -and $PromptText -match 'LENGTH: the reference has \d+ words') 'Prompt primed a stock first-person opener instead of using the reference.'
        Assert ($PromptText -match 'Only the photo supplies content' -and $PromptText -match 'untrusted text' -and $PromptText -match 'Do not copy its wording') 'Style reference must not supply product facts or wording.'
        Assert ($PromptText -match 'No required opening' -and $PromptText -match 'minor spelling or grammar slips are fine' -and $PromptText -notmatch 'Do not open with') 'Flexible writing guidance missing or contradicted.'
        if ($script:Mode -eq 'always-bad') { return '' }
        if ($script:Calls -eq 1) {
            if ($script:Mode -eq 'copy') { return $samples[0].body }
            if ($script:Mode -eq 'exclamation') { return 'nice rounded edge!' }
            return ''
        }
        Assert ($PromptText -match 'Inspection found:') 'Repair must include the concrete failure.'
        # Each call is a fresh run or chat: the repair must carry the failed draft itself.
        if ($script:Mode -eq 'exclamation') { Assert ($PromptText -match 'Your previous draft.*nice rounded edge!' -and $PromptText -match 'Rewrite that draft') 'Repair must include the failed draft.' }
        if ($script:Mode -eq 'empty') { Assert ($PromptText -match 'previous reply was empty' -and $PromptText -notmatch 'Your previous draft') 'An empty reply has no draft to rewrite.' }
        return 'The pale grain is easy to see across the broad top.'
    }
    $draft = New-Review 'photo.png' '001-table' $context
    Assert ($script:Calls -eq 2 -and $draft -match '^The pale grain') 'Empty draft was not repaired.'
    $evidence = Get-Content (Join-Path $tempDir '001-table-review-sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert (@($evidence).Count -eq 1 -and $evidence[0].body -eq $samples[0].body -and ($evidence[0].PSObject.Properties.Name -join ',') -eq 'body') 'Selected writing text was not saved cleanly.'
    $script:Calls=0; $script:Mode='copy'
    New-Review 'photo.png' '001-table' $context | Out-Null
    Assert ($script:Calls -eq 2) 'Copied review was not repaired.'
    $script:Calls=0; $script:Mode='exclamation'
    New-Review 'photo.png' '001-table' $context | Out-Null
    Assert ($script:Calls -eq 2) 'Exclamation was not repaired.'
    $script:Calls=0; $script:Mode='always-bad'; $failed=$false
    try { New-Review 'photo.png' '001-table' $context | Out-Null } catch {
        if ($_.Exception.Message -notlike 'Review quality check failed:*') { throw }; $failed=$true
    }
    Assert ($failed -and $script:Calls -eq 2) 'Repeatedly invalid drafts must stop after one repair.'
    Write-Host 'PASS: body-only shared corpus, random sample, saved text, informal wording, bounded empty/copy/exclamation repair.' -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($tempDir)
    $allowed = [IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'review-writing-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
