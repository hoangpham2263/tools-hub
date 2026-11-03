. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
. (Join-Path $root 'src/application/batch-import.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('batch-import-'+[Guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Force -Path "$temp/images","$temp/project/workspace" | Out-Null
    $png=[byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A);$jpg=[byte[]](0xFF,0xD8,0xFF,0xE0)
    $make={param($Name,$Head,$Seed)[IO.File]::WriteAllBytes("$temp/images/$Name",[byte[]]($Head+[byte[]][Text.Encoding]::UTF8.GetBytes($Seed)));"$temp/images/$Name"}
    $p1=& $make 'p1.png' $png 'p1';$p2=& $make 'p2.jpg' $jpg 'p2';$r1=& $make 'r1.jpg' $jpg 'r1';$r2=& $make 'r2.png' $png 'r2';$r3=& $make 'r3.jpg' $jpg 'r3'
    $bad=& $make 'bad.jpg' ([byte[]](0x3C,0x68,0x74,0x6D)) 'html'

    # Plain links still work: one per line, nothing attached.
    $plain=ConvertFrom-ProductBatch "https://shop.test/a`n# note`nhttps://shop.test/b"
    Assert (@($plain.Rows).Count -eq 2 -and -not @($plain.Errors).Count -and -not $plain.Rows[0].Product) 'Plain links must parse as links without images.'

    # The folder: products.csv names its images by file name; one row per product image, two rows of one link give it two
    # product images, several review images in one cell are separated by commas. Images live in images/.
    $img="$temp"
    $csv="product_url,product_image,review_images`nhttps://shop.test/a,p1.png,`"r1.jpg,r2.png`"`nhttps://shop.test/a,p2.jpg,r3.jpg`nhttps://shop.test/b,,r1.jpg"
    $parsed=ConvertFrom-ProductBatch $csv $img
    Assert (-not @($parsed.Errors).Count -and @($parsed.Rows).Count -eq 3 -and $parsed.Rows[0].Product -eq (Join-Path $img 'images/p1.png') -and @($parsed.Rows[0].Reviews).Count -eq 2) 'The table must parse with its images as files of the folder.'
    Assert (@((ConvertFrom-ProductBatch $csv '').Errors|Where-Object{$_ -match 'Chọn file'}).Count) 'A table without its folder must ask for the file.'
    Assert (@((ConvertFrom-ProductBatch "product_url,product_image,review_images`nhttps://shop.test/a,missing.jpg," $img).Errors|Where-Object{$_ -match "^Dòng 2: không có ảnh 'missing.jpg'"}).Count) 'A missing image must be named with its line.'
    # The sample zip unpacks to its product-import folder and reads without errors.
    $zipFolder=Expand-ProductBatchArchive (Join-Path $root '../../docs/product-import-sample.zip') $temp
    $sample=ConvertFrom-ProductBatch ([IO.File]::ReadAllText((Join-Path $zipFolder 'products.csv'))) $zipFolder
    Assert ((Split-Path -Leaf $zipFolder) -eq 'product-import-sample' -and -not @($sample.Errors).Count -and @($sample.Rows).Count -eq 3) 'The sample zip must unpack and read as a product-import folder.'
    # .7z too (when this tar can write one to test with).
    $seven=Join-Path $temp 'sample.7z'
    Push-Location (Split-Path $zipFolder -Parent);try{& tar --format 7zip -cf $seven (Split-Path -Leaf $zipFolder) 2>$null}finally{Pop-Location}
    if(-not $LASTEXITCODE -and (Test-Path $seven)){
        $sevenFolder=Expand-ProductBatchArchive $seven $temp
        Assert ((Split-Path -Leaf $sevenFolder) -eq 'product-import-sample' -and (Test-Path (Join-Path $sevenFolder 'images/polo-shirt-navy.jpg'))) 'A .7z of the folder must unpack the same way.'
    }
    $wrong=ConvertFrom-ProductBatch "product_url,image`nnot-a-link,,x" $img
    Assert (@($wrong.Errors|Where-Object{$_ -match '^Dòng 1: cột lạ'}).Count -and @($wrong.Errors|Where-Object{$_ -match '^Dòng 2: link'}).Count) 'Problems must name their line.'

    $seen=@()
    $result=Import-ProductBatch "$temp/project" $parsed.Rows {param($Done,$Total)$script:seen+="$Done/$Total"}
    $map=Read-ManualReferenceMap "$temp/project/workspace/reference-inputs/references.json"
    $a=@(Get-ManualProducts @($map.entries|Where-Object product_url -eq 'https://shop.test/a')[0])
    Assert ($a.Count -eq 2 -and @($a[0].scenes).Count -eq 2 -and @($a[1].scenes).Count -eq 1) 'Each product image must get its own reviews.'
    Assert ($a[1].sha256 -eq (Get-BytesHash ([IO.File]::ReadAllBytes($p2))) -and $a[1].scenes[0].sha256 -eq (Get-BytesHash ([IO.File]::ReadAllBytes($r3)))) 'Reviews must stay with the product image of their row.'
    Assert (@(Get-ManualScenes @($map.entries|Where-Object product_url -eq 'https://shop.test/b')[0]).Count -eq 1) 'A row without a product image still adds its reviews.'
    Assert ($result.products -eq 2 -and $result.reviews -eq 4 -and -not @($result.failed).Count -and ($result.links -join ',') -eq 'https://shop.test/a,https://shop.test/b') 'The summary must count what was added.'
    Assert ($script:seen[-1] -eq '6/6') 'Progress must reach every image.'

    # A product image that is not a picture skips its row's reviews; a bad review is reported on its own.
    $broken=ConvertFrom-ProductBatch "product_url,product_image,review_images`nhttps://shop.test/c,bad.jpg,r1.jpg`nhttps://shop.test/d,p1.png,`"bad.jpg,r2.png`"" $img
    $result=Import-ProductBatch "$temp/project" $broken.Rows $null
    $map=Read-ManualReferenceMap "$temp/project/workspace/reference-inputs/references.json"
    Assert (-not @($map.entries|Where-Object product_url -eq 'https://shop.test/c').Count) 'Reviews of a failed product image must not be attached elsewhere.'
    Assert (@($result.failed).Count -eq 2 -and $result.failed[0].line -eq 2 -and $result.failed[0].reason -match 'ảnh sản phẩm' -and $result.reviews -eq 1) 'Each failure must name its line and reason.'

    # The install folder moved (renamed, Tools Hub layout): saved absolute paths go stale, images are found beside the map.
    $mapFile="$temp/project/workspace/reference-inputs/references.json"
    $text=Get-Content -LiteralPath $mapFile -Raw -Encoding UTF8
    $stale=$text.Replace(((Resolve-Path "$temp/project").Path -replace '\\','\\\\'),'/old-install/product-review-batch')
    Assert ($stale -ne $text) 'The test must make the saved paths stale.'
    [IO.File]::WriteAllText($mapFile,$stale,[Text.UTF8Encoding]::new($false))
    $map=Read-ManualReferenceMap $mapFile
    Assert (-not @($map.entries|ForEach-Object{Get-ManualProducts $_}|ForEach-Object{@($_.file)+@($_.scenes.file)}|Where-Object{$_ -and -not (Test-Path -LiteralPath $_)}).Count) 'Images of a moved install must be found beside the map.'

    # The background script writes its result to the status file.
    $file="$temp/batch.csv";$status="$temp/status.json"
    [IO.File]::WriteAllText($file,"product_url,product_image,review_images`nhttps://shop.test/e,p2.jpg,r3.jpg")
    # Laid out like an install (apps/<tool> beside hub/), so the script finds the hub's shared helpers.
    $copy="$temp/install/apps/product-review";New-Item -ItemType Directory -Force -Path "$copy/workspace","$temp/install/hub"|Out-Null;Copy-Item -Recurse (Join-Path $root 'src') "$copy/src"
    Copy-Item -Recurse (Join-Path $root '../../hub/ai') "$temp/install/hub/ai"
    Copy-Item -Recurse (Join-Path $root '../../hub/image') "$temp/install/hub/image"
    $shell=(Get-Command powershell.exe,pwsh -ErrorAction SilentlyContinue|Select-Object -First 1).Source
    & $shell -NoProfile -File "$copy/src/import-batch.ps1" -File $file -Folder $img -StatusFile $status 2>&1 | Write-Host
    $s=Get-Content $status -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($s.finished -and $s.products -eq 1 -and $s.reviews -eq 1 -and @($s.links)[0] -eq 'https://shop.test/e') 'The import script must report what it added.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host 'PASS: Nhập hàng loạt reads links or the table, attaches each row''s images to its product image and reports failures by line.'
