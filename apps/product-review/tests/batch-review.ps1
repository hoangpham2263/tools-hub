. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('batch-review-'+[Guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path (Join-Path $temp 'images') -Force|Out-Null
    $rows=@(foreach($n in 1..3){
        $image=Join-Path $temp "images/00$n-tee.png";New-TestPng $image 1 1 ([byte[]](10,0,0))
        $refs=Join-Path $temp "refs/00$n-tee";New-Item -ItemType Directory -Path $refs -Force|Out-Null
        $original=Join-Path $refs 'product.png';New-TestPng $original 4 4 ([byte[]](0,100,0))
        New-TestPng (Join-Path $refs 'scene.png') 4 4 ([byte[]](0,0,100))
        Write-FeedbackJson (Join-Path $refs 'manifest.json') @{item_id="00$n-tee";product_url='https://example.test/products/tee';images=@(@{role='scene';file='scene.png'},@{role='product';file='product.png'})}
        [pscustomobject]@{product_handle='tee';rating='5';author='A';email='';body="b$n";created_at='2026-10-28';verified_purchase='true';photo_url="https://x.test/img/$n.png";photo_path=($image -replace '\\','/')}
    })
    Save-BatchResults $rows $temp
    $items=@(Get-BatchReview $temp)
    Assert ($items.Count -eq 3 -and -not $items[0].Decision) "Every result must be listed, undecided. Rows=$($rows.Count) Items=$($items.Count) Decision=$($items[0].Decision)"
    Assert ((Split-Path $items[0].ProductPath -Leaf) -eq 'product.png' -and (Split-Path $items[0].ScenePath -Leaf) -eq 'scene.png') 'Each result must know its product photo and the review photo it was made from.'
    $project=Join-Path $temp 'project';$rejected=Join-Path $project 'workspace/rejected'
    Set-BatchReviewDecision $temp '001-tee' ok $rejected
    Set-BatchReviewDecision $temp '002-tee' bad $rejected
    # A review marked Bỏ is noted with its text and reason, and goes out with the next Gửi lỗi.
    $sample=Join-Path $rejected ((Split-Path $temp -Leaf)+'__002-tee')
    Assert (@(Get-ChildItem -LiteralPath $sample -File).Name -join ',' -eq 'sample.json' -and (Get-Content -LiteralPath (Join-Path $sample 'sample.json') -Raw -Encoding UTF8|ConvertFrom-Json).body -eq 'b2') 'A rejected review is noted with its text only, no image copies.'
    Set-BatchReviewDecision $temp '002-tee' ok $rejected
    Assert (-not (Test-Path -LiteralPath $sample)) 'Changing a Bỏ before it is sent must drop the kept copy.'
    Set-BatchReviewDecision $temp '002-tee' bad $rejected -Reason ' sai màu áo '
    $unsent=@(Get-UnsentRejectedSamples $project)
    Assert ($unsent.Count -eq 1) 'Only unsent rejected samples belong to a report.'
    $note=Get-Content -LiteralPath (Join-Path $unsent[0].FullName 'sample.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($note.id -eq '002-tee' -and $note.reason -eq 'sai màu áo') 'The AI must be able to read the saved rejection reason.'
    # support-report.mjs marks a sent sample with .sent.
    [IO.File]::WriteAllText((Join-Path $unsent[0].FullName '.sent'), (Get-Date).ToString('o'))
    Assert (-not @(Get-UnsentRejectedSamples $project).Count) 'Samples sent once must not be sent again.'
    Set-BatchReviewDecision $temp '002-tee' bad $rejected
    Assert (-not (Test-Path (Join-Path $temp 'loox_import.csv'))) 'No Loox file may exist before the review is done.'
    $failed=$false;try{Export-ReviewedCsv $temp|Out-Null}catch{$failed=$_.Exception.Message -match 'chưa duyệt'}
    Assert $failed 'The final file must wait until every image is checked.'
    Set-BatchReviewDecision $temp '003-tee' ok $rejected
    Set-BatchReviewDecision $temp '003-tee' '' $rejected
    Assert (-not @(Get-BatchReview $temp)[2].Decision) 'Clicking a decision again must clear it.'
    Set-BatchReviewDecision $temp '003-tee' ok $rejected
    $exported=Export-ReviewedCsv $temp
    Assert ((Split-Path $exported -Leaf) -eq 'loox_import.csv' -and -not (Test-Path (Join-Path $temp 'loox_import_final.csv'))) 'The reviewed export is the one Loox file.'
    $csv=@(Import-Csv $exported)
    Assert ($csv.Count -eq 2 -and ($csv.body -join ',') -eq 'b1,b3' -and @($csv|Where-Object product_handle -eq 'tee').Count -eq 2) 'Rejecting one review removed other reviews of the same product.'
}finally{
    Get-ChildItem -LiteralPath (Join-Path (Split-Path (Split-Path ([IO.Path]::GetFullPath($temp)) -Parent) -Parent) 'rejected') -Directory -Filter ((Split-Path $temp -Leaf)+'__*') -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force
    $resolved=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'batch-review-*'){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Host 'PASS: every result is checked before the final CSV, which keeps only accepted images.'
