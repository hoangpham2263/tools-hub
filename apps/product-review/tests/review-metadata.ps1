. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/workflow/steps/04-complete-metadata.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$ratings = @(0..99 | ForEach-Object { Get-SampleReviewRating -Draw $_ })
Assert (@($ratings | Where-Object { $_ -eq 5 }).Count -eq 55) 'Expected 55 draws out of 100 to yield five stars.'
Assert (@($ratings | Where-Object { $_ -eq 4 }).Count -eq 45) 'Expected 45 draws out of 100 to yield four stars.'
$namesPath = Join-Path $root 'data/names.txt'
$names = @(Get-Content -LiteralPath $namesPath -Encoding UTF8)
Assert (@($names | Select-Object -Unique).Count -eq $names.Count) 'Duplicate display names.'
Assert (@($names | Where-Object { $_ -cnotmatch '^[A-Z][a-z]+ [A-Z]\.$' }).Count -eq 0) 'Expected given name followed by one surname initial.'
$byGiven = @{}
foreach ($name in $names) {
    $given = ($name -split ' ')[0]
    Assert (-not $byGiven.ContainsKey($given)) "Given name repeated: $given"
    $byGiven[$given] = $name
}
Assert ($names.Count -ge 4000) 'Expanded inventory should contain thousands of distinct names.'
$nameSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $names) { [void]$nameSet.Add($name) }
$rows = @(1..($names.Count * 2) | ForEach-Object {
    [pscustomobject]@{ rating = ''; author = ''; email = ''; created_at = ''; verified_purchase = '' }
})
Complete-ReviewMetadata $rows $namesPath
foreach ($start in @(0, $names.Count)) {
    $cycle = @($rows[$start..($start + $names.Count - 1)].author)
    Assert (@($cycle | Select-Object -Unique).Count -eq $names.Count) 'Name repeated before the pool was exhausted.'
    Assert (@($cycle | Where-Object { -not $nameSet.Contains($_) }).Count -eq 0) 'Unexpected name.'
}
Assert ($rows[$names.Count - 1].author -ne $rows[$names.Count].author) 'Adjacent repeat at shuffle boundary.'
Assert (@($rows | Where-Object { $_.rating -notin @(4, 5) }).Count -eq 0) 'Invalid rating.'
Complete-ReviewMetadata @($rows[0]) (Join-Path $TestWorkspaceRoot 'absent-names-file.txt')
Assert ($rows[0].author -cmatch '^[A-Z][a-z]+ [A-Z]\.$') 'Fallback should use the same surname-initial format.'
Write-Host 'PASS: rating boundaries, curated names, shuffle cycles and fallback.'
