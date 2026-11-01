. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('manual-product-'+[Guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    $photo=Join-Path $temp 'product.png';New-TestPng $photo 1 1 ([byte[]](0,0,128))
    $url='https://private.example/products/draft-shirt'
    $path=Save-ManualReference $temp $url $photo Product
    $map=Read-ManualReferenceMap $path
    Assert ($map.entries.Count -eq 1 -and $map.entries[0].product_file -and -not $map.entries[0].file) 'Product-only mapping was rejected.'
    $review=Join-Path $temp 'review.png';New-TestPng $review 1 1 ([byte[]](128,0,0))
    [void](Save-ManualReference $temp $url $review)
    $script:Config=@{ManualReferences=(Read-ManualReferenceMap $path);ActiveProductUrl=$url;SourceDir=$temp}
    $script:Batch=@{Refs=$temp;Logs=$temp;Images=$temp}
    function Get-Reference {throw 'Unexpected network access for attached product.'}
    function Resolve-ProductContext($Handle,$Reference,$ItemId){
        Assert ((Get-BytesHash ([IO.File]::ReadAllBytes($Reference))) -eq $script:Config.ManualReferences.entries[0].product_sha256) 'Classification received the wrong image.'
        return [pscustomobject]@{presentation='worn'}
    }
    $item=[pscustomobject]@{Url=$url;Handle='draft-shirt'}
    $product=Read-ProductInput $item '001-draft'
    Assert ((Test-Path $product.Reference) -and $product.Reference -ne $photo) 'Manual product was not snapshotted.'
    $scene=@(Get-ReviewPhoto '001-draft' $product.Context)
    Assert ($scene.Count -eq 1 -and $scene[0] -eq $script:Config.ManualReferences.entries[0].file) 'Product and scene roles were confused.'
    $request=New-ProductImageRequest $product.Reference '001-draft' $product.Context $scene
    Assert ($request.Images.Count -eq 2 -and $request.Images[0] -eq $scene[0] -and $request.Images[1] -eq $product.Reference) 'Review, product and style inputs were mixed.'
    Assert ($request.Prompt -match 'If no person is visible' -and $request.Prompt -match 'Image 2 is the PRODUCT reference') 'Flat review photos must not require another person reference.'
    Assert ($request.Prompt -match 'REPLACE THE EXISTING GARMENT' -and $request.Prompt -match 'EVERY such subject' -and $request.Prompt -match 'Never paste a product cutout' -and $request.Prompt -notmatch 'background may change') 'Garment editing can still leave the old shirts and add a separate product prop.'
    $script:Config.AgentInstructionsPath=Join-Path $root 'AGENTS.md'
    $lesson=Get-ImageFeedbackGuidance ([pscustomobject]@{source_categories=@('polo-shirts')}) $url
    Assert ($lesson -match 'Thay áo đang mặc' -and $lesson -match 'Không giữ áo cũ') 'Scoped polo feedback does not reach image generation.'
    $bundle=Save-ProductReferenceBundle $item '001-archive' $product.Context $request
    $manifest=Get-Content (Join-Path $bundle.Folder 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($manifest.images[1].source_kind -eq 'user_product' -and $manifest.images[1].sha256 -eq $script:Config.ManualReferences.entries[0].product_sha256) 'Manual product provenance or snapshot hash was lost.'
    Assert ($manifest.images[0].sha256 -ne $manifest.images[1].sha256) 'Product and review snapshots must remain separate.'
    $secondReview=Join-Path $temp 'review-2.png';New-TestPng $secondReview 1 1 ([byte[]](0,128,0))
    [void](Save-ManualReference $temp $url $secondReview)
    $script:Config.ManualReferences=Read-ManualReferenceMap $path
    $jobs=@(Expand-SceneJobs @($item))
    Assert ($jobs.Count -eq 2) 'Each review photo must become its own job.'
    $index=0
    foreach($job in $jobs){
        $index++;$script:Config.ActiveScene=$job.Scene
        $loaded=Read-ProductInput $job ('multi-'+$index)
        $picked=@(Get-ReviewPhoto ('multi-'+$index) $loaded.Context)
        $pair=New-ProductImageRequest $loaded.Reference ('multi-'+$index) $loaded.Context $picked
        Assert ($pair.Images.Count -eq 2 -and (Get-BytesHash ([IO.File]::ReadAllBytes($pair.Images[0]))) -eq $job.Scene.sha256 -and (Get-BytesHash ([IO.File]::ReadAllBytes($pair.Images[1]))) -eq $map.entries[0].product_sha256) 'A job mixed review photos or replaced the actual product.'
    }
    $saved=$script:Config.ManualReferences.entries[0].product_file
    [IO.File]::WriteAllText($saved,'changed')
    $blocked=$false;try{Read-ProductInput $item '002-draft'|Out-Null}catch{$blocked=$_.Exception.Message -match 'PRODUCT_INPUT'}
    Assert $blocked 'Changed product input fell back to the website or AI.'
    Write-Host 'PASS: private product uses local image without HTTP; separate scene, snapshot and hash enforcement.'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'manual-product-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
