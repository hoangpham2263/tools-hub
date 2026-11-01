. (Join-Path $PSScriptRoot 'helpers.ps1')
# Offline integration test: real runspaces with mocked external AI/image IO.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# A copy laid out like an install (apps/<tool> beside hub/), so src finds the hub's shared setup scripts.
$tempHub = Join-Path $TestWorkspaceRoot ('review-pipeline-test-' + [Guid]::NewGuid().ToString('N'))
$tempRoot = Join-Path $tempHub 'apps/product-review'
New-Item -ItemType Directory -Path $tempRoot, (Join-Path $tempHub 'hub') | Out-Null
foreach ($shared in @('setup', 'ai')) { Copy-Item -LiteralPath (Join-Path $root "../../hub/$shared") -Destination (Join-Path $tempHub 'hub') -Recurse }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    Copy-Item -LiteralPath (Join-Path $root 'src') -Destination $tempRoot -Recurse
    $lib = Join-Path $tempRoot 'src'
    'function Get-Reference($Url, $ItemId) { $path = Join-Path $script:Batch.Refs "$ItemId.png"; "product" | Set-Content $path; return $path }' | Add-Content (Join-Path $lib 'workflow/steps/01-load-product.ps1')
    $sources = Join-Path $tempRoot 'data/source-photos/polo-shirts'
    New-Item -ItemType Directory -Path $sources -Force | Out-Null
    $stock = Join-Path $tempRoot 'data/source-photos/outdoor-sports'
    $mixed = Join-Path $tempRoot 'data/source-photos/mixed'
    New-Item -ItemType Directory -Path $stock, $mixed -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'data/review-style.json') -Destination (Join-Path $tempRoot 'data/review-style.json')
    Copy-Item -LiteralPath (Join-Path $root 'data/product-contexts.json') -Destination (Join-Path $tempRoot 'data/product-contexts.json')
    Copy-Item -LiteralPath (Join-Path $root 'data/writing-style.json') -Destination (Join-Path $tempRoot 'data/writing-style.json')
    @(
        '{"category":"polo-shirts","body":"The narrow collar trim stands out against the dark panels.","source_url":"https://example.test/polo"}'
        '{"category":"coffee-tables","body":"FURNITURE_STYLE_SAMPLE A few casual words about the shape."}'
    ) | Set-Content (Join-Path $tempRoot 'data/review-samples.jsonl') -Encoding UTF8
    $fixtureContexts = Get-Content (Join-Path $tempRoot 'data/product-contexts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixture = $fixtureContexts.profiles | Where-Object id -eq polo | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $fixture.id = 'fixture'; $fixture.pattern = '^(one|two|fail)$'
    $fixture.source_categories = @('polo-shirts', 'outdoor-sports')
    $fixtureContexts.profiles = @($fixture) + @($fixtureContexts.profiles)
    $fixtureContexts | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $tempRoot 'data/product-contexts.json') -Encoding UTF8
    'original one' | Set-Content (Join-Path $sources 'one.png')
    'stock two' | Set-Content (Join-Path $stock 'two.png')
    'mixed flat lay' | Set-Content (Join-Path $mixed 'flat.png')
    @{ schema_version = 1; photos = @(
        @{ file = 'polo-shirts/one.png'; category = 'polo-shirts'; source_kind = 'original' },
        @{ file = 'outdoor-sports/two.png'; category = 'outdoor-sports'; source_kind = 'stock' },
        @{ file = 'mixed/flat.png'; category = 'mixed'; source_kind = 'review' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $tempRoot 'data/source-photos/catalog.json')
    $sourceHashes = @(Get-ChildItem (Join-Path $tempRoot 'data/source-photos') -Recurse -File | Get-FileHash)
    @'
function Invoke-AI($PromptText, $Images, $ResultFile, $Sandbox) {
    $resultsJson = Join-Path $script:Batch.Dir 'results.json'
    $saved = if (Test-Path -LiteralPath $resultsJson) { @(Get-Content -LiteralPath $resultsJson -Raw -Encoding UTF8 | ConvertFrom-Json) } else { @() }
    if (@($saved | Where-Object { $_.rating -or $_.author -or $_.email -or $_.created_at }).Count) {
        throw 'Metadata was assigned before AI work ended.'
    }
    if ($ResultFile -like '*-context.txt') {
        return '{"category_key":"polo","existing_profile":"fixture","product":"polo shirt","presentation":"worn","setting":"patio","details":"Navy panels and collar trim","reject":"bedroom","search_query":"polo shirt real photos"}'
    }
    if ($ResultFile -like '*-fit-*.txt') {
        if ($Images[0] -like '*mixed*') { throw 'Unrelated review photos must not precede matching references.' }
        if ($ResultFile -like '*-p2-fit-*.txt' -and $PromptText -notmatch 'BACKGROUND/SCENE') { throw 'Second source must be evaluated for its scene, not its person.' }
        if ($ResultFile -like '*-p2-fit-*.txt' -and $Images.Count -ne 3) { throw 'Scene compatibility must include the selected person.' }
        'FIT' | Set-Content -LiteralPath $ResultFile; return 'FIT'
    }
    if ($ResultFile -like '*-quality-*.txt') { throw 'Image QA must not run.' }
    if ($ResultFile -like '*-review.txt') {
        if ($Images.Count -ne 1 -or -not (Test-Path -LiteralPath $Images[0])) { throw 'Review missing finished image.' }
        if ($PromptText -notmatch 'Randomly selected writing reference from review-samples.jsonl' -or $PromptText -match 'Optional writing nudge|Writing style direction') { throw 'Expected sample-based writing without preset profiles.' }
        if ($PromptText -notmatch 'No exclamatory sentences' -or $PromptText -notmatch 'Do not invent purchases') { throw 'Missing plain-comment rules or factual constraints.' }
        if ($PromptText -notmatch 'narrow collar trim|FURNITURE_STYLE_SAMPLE' -or $PromptText -notmatch 'only the current photo supplies review content') { throw 'Shared writing sample or product evidence boundary did not reach the parallel worker.' }
        if ($ResultFile -like '*-fail-review.txt' -and -not (Test-Path (Join-Path $script:Config.SourceDir 'allow-review-success.flag'))) { throw 'Simulated review failure' }
        Start-Sleep -Milliseconds 500
        "The navy pattern is subtle.`nIt looks good with the shorts." | Set-Content -LiteralPath $ResultFile
        return "The navy pattern is subtle.`nIt looks good with the shorts."
    }
    $fitPattern = $ResultFile -replace '-image.txt$', '-p*-fit-*.txt'
    if (@(Get-ChildItem -Path $fitPattern).Count -ne 1) { throw 'Exactly one review reference must be selected.' }
    if ($Images.Count -ne 2 -or $Images[0] -eq $Images[1]) { throw 'Expected one review image and one separate product image.' }
    if ($Images[1] -notlike '*-product.png') { throw 'Separate product reference order is incorrect.' }
    if ($PromptText -notmatch 'one continuous camera frame' -or $PromptText -notmatch 'Image 1 is the REVIEW reference' -or $PromptText -notmatch 'Image 2 is the PRODUCT reference') { throw 'Missing review/product reference roles.' }
    if ($PromptText -notmatch 'If it has one, replace it at the same position' -or $PromptText -notmatch 'If it has no logo or brand mark, add none' -or $PromptText -notmatch 'Choose a name that fits this product and this scene') { throw 'Logo must be replaced only when the product has one.' }
    if ($PromptText -notmatch 'Remove all template or customization text' -or $PromptText -notmatch 'put your brand on it' -or $PromptText -notmatch 'never retain it as product artwork' -or $PromptText -notmatch 'Do not add slogans, taglines' -or $PromptText -notmatch 'reply metadata only') { throw 'Generated branding must be a finished mark without template text or instructions.' }
    if ($PromptText -notmatch 'A photo watermark is not a product logo' -or $PromptText -notmatch 'Do not replace them with fictional branding' -or $PromptText -notmatch 'wall logo' -or $PromptText -notmatch 'return BRAND: none') { throw 'Generation must remove photo watermarks instead of inventing a replacement logo.' }
    if ($PromptText -notmatch '(?m)^Save a new PNG at this exact path: (.+)$') { throw 'Missing image output path.' }
    $imagePath=$Matches[1].Trim();[IO.File]::WriteAllBytes($imagePath,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
    'image call' | Set-Content -LiteralPath $ResultFile
    return 'BRAND: Demo'
}
'@ | Set-Content (Join-Path $lib 'infrastructure/ai.ps1')
    $queue = Join-Path $tempRoot 'workspace/urls.txt'
    New-Item -ItemType Directory -Force (Split-Path $queue -Parent) | Out-Null
    @('https://example.test/products/one', 'https://example.test/products/two', 'https://example.test/products/fail') | Set-Content $queue
    $batchFailed = $false
    try {
        & (Join-Path $tempRoot 'src/run-images.ps1') -ThrottleLimit 2 -PhotosPerImage 2 -LocalOnly
    } catch {
        if ($_.Exception.Message -notlike 'Batch incomplete:*') { throw }
        $batchFailed = $true
    }
    Assert $batchFailed 'Partial batches must report failure to the GUI.'
    $csv = Get-ChildItem (Join-Path $tempRoot 'workspace/output') -Filter results.json -Recurse | Select-Object -First 1
    $rows = @(Import-BatchRows $csv.FullName)
    if ($rows.Count -ne 2) { Get-ChildItem $csv.DirectoryName -Recurse -Filter '*-error.txt' | ForEach-Object { Get-Content $_.FullName | Write-Host } }
    Assert ($rows.Count -eq 2) 'Expected two successful reviews.'
    Assert (-not @(Get-ChildItem $csv.DirectoryName -Recurse -Filter '*.html')) 'Batch must not contain HTML galleries.'
    $bundles = @(Get-ChildItem (Join-Path $csv.DirectoryName 'refs') -Recurse -File -Filter 'manifest.json')
    Assert (-not @(Get-ChildItem (Join-Path $csv.DirectoryName 'refs') -File)) 'Product image must be stored once, inside refs/<item>/.'
    Assert ($bundles.Count -eq 3) 'Successful and failed products must retain their actual selected inputs.'
    foreach ($bundle in $bundles) {
        $manifest = Get-Content $bundle.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($manifest.images.Count -eq 2 -and $manifest.images[1].role -eq 'product') 'Expected separate review and product snapshots.'
    }
    $expected = 'product_handle,rating,author,email,body,created_at,photo_url,verified_purchase'
    Assert (($rows[0].PSObject.Properties.Name -join ',') -eq $expected) 'Incorrect import columns.'
    foreach ($row in $rows) {
        Assert ($row.rating -in @('4', '5')) 'Invalid rating.'
        Assert ($row.author -and $row.email -match '^[a-z0-9.]+@int$') 'Missing author/@int email.'
        Assert ($row.verified_purchase -ceq 'TRUE') 'verified_purchase must use Loox uppercase boolean format.'
        Assert ($row.body -eq 'The navy pattern is subtle. It looks good with the shorts.') 'Review whitespace was not normalized.'
        Assert (Test-Path -LiteralPath $row.photo_url) 'Missing final single-scene image.'
        $date = [DateTime]::ParseExact($row.created_at, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        Assert ($date.Year -eq [DateTime]::UtcNow.Year -and $date -le [DateTime]::UtcNow) 'Timestamp outside current year.'
    }
    Assert ((Get-Content $queue -Raw).Trim() -eq 'https://example.test/products/fail') 'Incorrect queue checkpoint.'
    foreach ($sourceHash in $sourceHashes) {
        Assert (Test-Path -LiteralPath $sourceHash.Path) 'Source photo was removed or moved.'
        Assert ((Get-FileHash -LiteralPath $sourceHash.Path).Hash -eq $sourceHash.Hash) 'Source photo was modified.'
    }
    Assert (-not (Test-Path (Join-Path $tempRoot 'used'))) 'The workflow must not create a used directory.'
    Assert (@(Get-Content (Join-Path $csv.DirectoryName 'urls.input.txt')).Count -eq 3) 'Input URL history must stay in the output batch.'
    Assert (@(Get-Content (Join-Path $csv.DirectoryName 'urls.completed.txt')).Count -eq 2) 'Completed URL checkpoint must stay in the output batch.'
    Assert (@(Get-ChildItem $csv.DirectoryName -Filter '*-image.txt' -Recurse).Count -eq 3) 'Expected one image AI call per product, not one per reference.'
    Assert (-not (Test-Path (Join-Path $csv.DirectoryName 'parts'))) 'Single-scene runs must not create a collage parts folder.'
    Assert (@(Get-ChildItem $csv.DirectoryName -Filter '*-review.txt' -Recurse).Count -eq 2) 'Unexpected review AI calls.'
    Assert (@(Get-ChildItem $csv.DirectoryName -Filter '*-quality-1.txt' -Recurse).Count -eq 0) 'Single-pass delivery unexpectedly ran AI visual QA.'
    Assert (@(Get-ChildItem $csv.DirectoryName -Filter '*-review-status.json' -Recurse).Count -eq 3) 'Delivered images must await user review.'
    # Resume the failed queue through the same public entry point.
    'allow success' | Set-Content (Join-Path $tempRoot 'data/source-photos/allow-review-success.flag')
    & (Join-Path $tempRoot 'src/run-images.ps1') -ThrottleLimit 2 -PhotosPerImage 2 -LocalOnly
    Assert (-not ([IO.File]::ReadAllText($queue).Trim())) 'Successful retry must empty the queue.'
    $retryCsv = Get-ChildItem (Join-Path $tempRoot 'workspace/output') -Filter results.json -Recurse | Where-Object FullName -ne $csv.FullName
    $retryRows = @(Import-BatchRows $retryCsv.FullName)
    Assert ($retryRows.Count -eq 1 -and $retryRows[0].product_handle -eq 'fail' -and $retryRows[0].author) 'Retry must export only the previously failed product with final metadata.'
    & (Join-Path $tempRoot 'src/run-images.ps1') -List $queue -LocalOnly
    Assert (@(Get-ChildItem (Join-Path $tempRoot 'workspace/output') -Directory).Count -eq 2) 'Empty queue must not create an extra batch.'
    . (Join-Path $root 'src/bootstrap.ps1')
    $profiles = @(Get-ReviewStyleProfiles (Join-Path $root 'data/review-style.json'))
    Assert ($profiles.Count -eq 8) 'Expected eight review style profiles.'
    $styleData = Get-Content (Join-Path $root 'data/review-style.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($styleData.statistics.reviews -eq $styleData.features.Count) 'Review feature count mismatch.'
    Assert (@($styleData.features.text_sha256 | Sort-Object -Unique).Count -eq $styleData.features.Count) 'Duplicate review writing records.'
    Assert (@($styleData.features | Where-Object { $_.source_url -isnot [string] -or $_.source_url -notmatch '^https://' -or -not $_.review_id }).Count -eq 0) 'Review feature provenance is invalid.'
    Assert (@(Get-ReviewStyleProfiles (Join-Path $tempRoot 'missing-style.json')).Count -eq 0) 'Missing style data should allow fallback.'
    $namesPath = Join-Path $tempRoot 'names.txt'
    @('Example Name', '测试') | Set-Content $namesPath -Encoding UTF8
    Complete-ReviewMetadata $rows $namesPath
    Assert (@($rows | Where-Object { $_.author -notin @('Example Name', '测试') }).Count -eq 0) 'Custom name pool ignored.'
    Assert (@($rows | Where-Object { $_.email -notmatch '^[a-z0-9.]+@int$' }).Count -eq 0) 'Invalid fallback email.'
    Save-Csv @() (Join-Path $tempRoot 'empty.csv')
    Assert ((Get-Content (Join-Path $tempRoot 'empty.csv')) -ceq $expected) 'Empty CSV header incorrect.'
    Write-Host 'PASS: parallel image/review pipeline, local final metadata, CSV, failed queue, name pools.' -ForegroundColor Green
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempHub)
    $sep = [IO.Path]::DirectorySeparatorChar
    $allowedParent = [IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd($sep) + $sep
    if ($resolvedTemp.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTemp -Leaf) -like 'review-pipeline-test-*') {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
