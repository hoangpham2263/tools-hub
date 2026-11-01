. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src/bootstrap.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('repair-evidence-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $room=Join-Path $temp 'original.png';$raw=Join-Path $temp 'raw.png'
    New-TestPng $room 20 20 ([byte[]](139,69,19));New-TestPng $raw 20 20 ([byte[]](255,255,255))
    $script:Batch=@{Logs=$temp;Images=$temp}
    $script:Config=@{ActiveProductUrl='https://example.test/table';FeedbackRoot=''}
    $context=[pscustomobject]@{product='table';presentation='placed';setting='bare room';details='solid slab legs';reject='new props';branding='none';source_categories=@('dining-tables')}
    $request=New-ProductImageRequest $raw '001-table' $context @($room) ([Collections.ArrayList]::new())
    Assert ($request.Prompt -match 'SINGLE-PASS DELIVERY' -and $request.Prompt -match 'DIRECT IMAGE DELIVERY') 'Direct image delivery instructions are missing.'
    Assert (($request.PSObject.Properties.Name -join ',') -eq 'Images,Prompt,Output,SceneBase') 'Unexpected delivery request fields.'
    Copy-Item -LiteralPath $raw -Destination (Join-Path $temp '001-table-attempt-1-generated.png')
    Copy-Item -LiteralPath $raw -Destination $request.Output
    'FAIL: old bench foot must be removed'|Set-Content (Join-Path $temp '001-table-quality-1.txt') -Encoding UTF8
    function Invoke-AI($PromptText,$Images,$ResultFile,$Sandbox){
        Assert ($Images.Count -eq 3 -and $Images[0] -eq $room -and $Images[1] -eq $raw) 'Retry lost original image roles or failed evidence.'
        Assert ($Images[2] -like '*attempt-1-generated.png') 'Retry did not receive the saved image.'
        Assert ($PromptText -match 'transport retry, not a visual rejection' -and $PromptText -notmatch 'Earlier QA 1') 'Transport retry must not become a visual repair.'
        Assert (-not (Test-Path $request.Output)) 'A stale output can masquerade as a fresh delivery.'
        Copy-Item -LiteralPath $raw -Destination $request.Output
        return 'BRAND: none'
    }
    [void](Invoke-ImageGeneration $request '001-table' 2 'FAIL: restored bench fragments')
    Assert ($request.Images.Count -eq 2 -and (Get-BytesHash ([IO.File]::ReadAllBytes($request.Output))) -eq (Get-BytesHash ([IO.File]::ReadAllBytes($raw)))) 'Direct image delivery mutated reference roles or could not reuse good raw bytes.'
    function Invoke-AI{return 'No output written'}
    $blocked=$false;try{Invoke-ImageGeneration $request '001-table' 2 'Connection interrupted'|Out-Null}catch{$blocked=$_.Exception.Message -like 'Output image not found*'}
    Assert $blocked 'No-op retry accepted a stale output.'
    # Recover delivered files on timeout without making a duplicate generation request.
    function Invoke-AI{
        Copy-Item -LiteralPath $raw -Destination $request.Output
        throw 'AI failed [CAUSE:AI_TIMEOUT]'
    }
    Assert ((Invoke-ImageGeneration $request '001-table' 1 '') -eq 'BRAND: none') 'A completed image was discarded just because the final CLI reply timed out.'
    function Invoke-AI{throw 'AI failed [CAUSE:PROCESS_ACTIVE]'}
    $blocked=$false;try{Invoke-ImageGeneration $request '001-table' 1 ''|Out-Null}catch{$blocked=$_.Exception.Message -match 'PROCESS_ACTIVE'}
    Assert $blocked 'Recovery concealed an unconfirmed running process.'
    $script:Config.AiRetryDelaySeconds=0;$script:Calls=0;$script:Mode='recover'
    function Invoke-ImageGeneration{
        $script:Calls++
        if($script:Mode -eq 'auth'){throw 'AI failed [CAUSE:AUTH]'}
        if($script:Mode -eq 'timeout' -or $script:Calls -lt 3){throw 'AI failed [CAUSE:AI_TIMEOUT]'}
        Copy-Item -LiteralPath $raw -Destination $request.Output
        return 'BRAND: none'
    }
    Assert ((Complete-ProductImage $request $context '002-table') -eq 'BRAND: none' -and $script:Calls -eq 3) 'Two interrupted generations were not retried to success.'
    Assert ((Get-BytesHash ([IO.File]::ReadAllBytes($request.Output))) -eq (Get-BytesHash ([IO.File]::ReadAllBytes($raw)))) 'Export changed the image tool output bytes.'
    foreach($mode in @('timeout','auth')){
        $script:Mode=$mode;$script:Calls=0;$blocked=$false
        try{Complete-ProductImage $request $context '003-table'|Out-Null}catch{$blocked=$true}
        $expected=if($mode -eq 'auth'){1}else{3}
        Assert ($blocked -and $script:Calls -eq $expected) 'Image retries exceeded their budget or retried a permanent failure.'
    }
    Write-Host 'PASS: unaltered image delivery, single-pass delivery, bounded transport recovery and stale-output rejection.' -ForegroundColor Green
}finally{
    $resolved=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'repair-evidence-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
