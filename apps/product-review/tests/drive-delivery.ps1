. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('drive-delivery-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $url='https://shop.test/products/table'
    $script:Config=@{Drive=@{ApiUrl='https://api.test';AdminKey='test'};DriveRequired=$true;DeliveryRoot=(Join-Path $temp 'pending')}
    $script:Batch=New-Batch (Join-Path $temp 'outputs')
    $image=Join-Path $script:Batch.Images '001-table.png';New-TestPng $image 2 2
    $refs=Join-Path $script:Batch.Refs '001-table';New-Item -ItemType Directory -Path $refs|Out-Null
    Copy-Item -LiteralPath $image -Destination (Join-Path $refs '01-product.png')
    Write-FeedbackJson (Join-Path $refs 'manifest.json') ([ordered]@{item_id='001-table';product_url=$url;output='../../images/001-table.png';images=@(@{file='01-product.png';role='product';sha256=(Get-BytesHash ([IO.File]::ReadAllBytes($image)))})})
    $item=[pscustomobject]@{Url=$url;Handle='table'}
    $row=[pscustomobject]@{product_handle='table';rating='';author='';email='';body='Saved review text';created_at='';verified_purchase='false';photo_url='';photo_path=$image}
    Save-DeliveryCache $item '001-table' $row
    function Publish-ImageToDrive {throw '[CAUSE:DRIVE_UPLOAD] simulated failure'}
    $blocked=$false;try{Complete-DriveDelivery $row|Out-Null}catch{$blocked=$true}
    Assert $blocked 'Upload error was swallowed.'
    $results=[Collections.Generic.List[object]]::new();$done=[Collections.Generic.List[string]]::new()
    $list=Join-Path $temp 'urls.txt';[IO.File]::WriteAllLines($list,[string[]]@($url))
    $blocked=$false;try{Save-ProductCheckpoint $results $row $done $item $list}catch{$blocked=$true}
    Assert ($blocked -and $results.Count -eq 0 -and (Get-Content $list) -eq $url) 'Unuploaded result reached the CSV or consumed its URL.'
    # The next run must recover the same bytes/text before any AI work.
    $script:Batch=New-Batch (Join-Path $temp 'outputs')
    function Read-ProductInput {throw 'AI/product loading must not run during upload recovery.'}
    function New-Review {throw 'Review text must not be regenerated.'}
    $resumed=Invoke-ProductItem $item '002-table'
    Assert ($resumed.body -eq 'Saved review text' -and (Test-Path $resumed.photo_path)) 'Saved image or review was lost.'
    Assert ((Get-BytesHash ([IO.File]::ReadAllBytes($resumed.photo_path))) -eq (Get-BytesHash ([IO.File]::ReadAllBytes($image)))) 'Recovery changed image bytes.'
    function Publish-ImageToDrive {return 'https://api.test/img/final.png'}
    $resumed=Complete-DriveDelivery $resumed
    Save-ProductCheckpoint $results $resumed $done $item $list $false
    Assert (@(Get-ChildItem $script:Config.DeliveryRoot -Filter '*.json').Count -eq 1) 'Successful scene was forgotten before its URL finished.'
    # Reopening this success must reuse its URL without uploading again.
    $script:Batch=New-Batch (Join-Path $temp 'outputs')
    function Publish-ImageToDrive {throw 'Already uploaded images must not be uploaded again.'}
    $again=Complete-DriveDelivery (Invoke-ProductItem $item '003-table')
    Save-ProductCheckpoint $results $again $done $item $list $true
    Assert (@(Get-ChildItem $script:Config.DeliveryRoot -Filter '*.json').Count -eq 0 -and -not (Get-Content $list)) 'Finished URL did not clear its delivery cache and queue.'
    $csv=@(Import-BatchRows $script:Batch.Dir)
    Assert (@($csv|Where-Object photo_url -notmatch '^https://').Count -eq 0) 'Local path leaked into the handover CSV.'
    $script:Config.Drive=$null
    $blocked=$false;try{Complete-DriveDelivery $row|Out-Null}catch{$blocked=$_.Exception.Message -match 'DRIVE_CONFIG'}
    Assert $blocked 'Required Drive configuration silently fell back to local.'
    # Exercise the real parallel coordinator: one scene fails upload, then retry
    # must reuse both finished scenes and upload only the pending one.
    $integration=Join-Path $temp 'coordinator';New-Item -ItemType Directory -Path $integration|Out-Null
    $a=Join-Path $integration 'a.png';$b=Join-Path $integration 'b.png'
    New-TestPng $a 2 2 ([byte[]](1,0,0));New-TestPng $b 2 2 ([byte[]](0,1,0))
    $scenes=@(@{file=$a;sha256=(Get-BytesHash ([IO.File]::ReadAllBytes($a)))},@{file=$b;sha256=(Get-BytesHash ([IO.File]::ReadAllBytes($b)))})
    $script:Config=@{Drive=@{ApiUrl='https://api.test';AdminKey='test'};DriveRequired=$true;DeliveryRoot=(Join-Path $integration 'pending');ManualReferences=@{entries=@([pscustomobject]@{product_url=$url;scenes=$scenes})}}
    $fixture=Join-Path $integration 'worker.ps1'
    $code=@'
function Invoke-ProductItem($Item,[string]$ItemId){
    $saved=Read-DeliveryCache $Item
    if($saved){$row=Restore-DeliveryCache $saved $ItemId;Save-DeliveryCache $Item $ItemId $row;return $row}
    $image=Join-Path $script:Batch.Images "$ItemId.png"
    Copy-Item -LiteralPath $Item.Scene.file -Destination $image
    $refs=Join-Path $script:Batch.Refs $ItemId;New-Item -ItemType Directory -Path $refs|Out-Null
    Copy-Item -LiteralPath $Item.Scene.file -Destination (Join-Path $refs '01-product.png')
    Write-FeedbackJson (Join-Path $refs 'manifest.json') @{product_url=$Item.Url;item_id=$ItemId;output="../../images/$ItemId.png";images=@(@{file='01-product.png';sha256=$Item.Scene.sha256;role='product'})}
    New-Item -ItemType Directory -Path $script:Config.DeliveryRoot -Force|Out-Null
    Add-Content -LiteralPath (Join-Path $script:Config.DeliveryRoot ($Item.Scene.sha256+'.generated')) -Value 'generation'
    $row=[pscustomobject]@{product_handle=$Item.Handle;rating='';author='';email='';body='Cached review';created_at='';verified_purchase='false';photo_url='';photo_path=$image}
    Save-DeliveryCache $Item $ItemId $row
    return $row
}
'@
    [IO.File]::WriteAllText($fixture,$code,[Text.UTF8Encoding]::new($true))
    $script:UploadCalls=0;$script:FailSecond=$true
    function Publish-ImageToDrive($Path){
        $script:UploadCalls++
        if($script:FailSecond -and [IO.Path]::GetFileName($Path) -like '002-*'){throw '[CAUSE:DRIVE_UPLOAD] simulated coordinator failure'}
        return 'https://api.test/img/'+[IO.Path]::GetFileName($Path)
    }
    $list=Join-Path $integration 'queue.txt';[IO.File]::WriteAllLines($list,[string[]]@($url))
    $modules=@($script:WorkflowModuleFiles)+@($fixture)
    $failed=$false;try{Invoke-BatchWorkflow $integration $list (Join-Path $integration 'out') 2 $modules}catch{$failed=$_.Exception.Message -match 'Batch incomplete'}
    Assert ($failed -and (Get-Content $list) -eq $url) 'Partial upload consumed its multi-scene URL.'
    Assert (@(Import-BatchRows $script:Batch.Dir).Count -eq 1) 'Failed upload was included in the CSV.'
    $script:FailSecond=$false
    Invoke-BatchWorkflow $integration $list (Join-Path $integration 'out') 2 $modules
    Assert ($script:UploadCalls -eq 3) 'Retry uploaded an already delivered scene again.'
    $exported=@(Import-BatchRows $script:Batch.Dir)
    Assert ($exported.Count -eq 2 -and @($exported|Where-Object photo_url -notmatch '^https://').Count -eq 0) 'Retried batch did not deliver two public image links.'
    foreach($file in @(Get-ChildItem $script:Config.DeliveryRoot -Filter '*.generated')){Assert (@(Get-Content $file.FullName).Count -eq 1) 'Retry regenerated a previously completed image.'}
    Write-Host 'PASS: failed uploads block CSV/queue, recovery skips AI, multi-scene successes retain public links, and missing Drive cannot fall back.'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'drive-delivery-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
