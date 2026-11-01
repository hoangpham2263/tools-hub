. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('image-tool-errors-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $product=Join-Path $temp 'product.png';$review=Join-Path $temp 'review.png'
    New-TestPng $product 4 4 ([byte[]](128,0,0));New-TestPng $review 4 4 ([byte[]](0,128,0))
    $url='https://private.example/products/shirt'
    $mapPath=Save-ManualReference $temp $url $product Product
    [void](Save-ManualReference $temp $url $review)
    $fixture=Join-Path $temp 'fixture.ps1'
    @'
function Resolve-ProductContext {return [pscustomobject]@{product='polo';presentation='worn';details='red collar';source_categories=@('polo-shirts')}}
function New-Review {return 'The red collar frames the neckline.'}
function Invoke-CodexProcess($PromptText,$CommandArgs,$Trace){
    Add-Content -LiteralPath $script:Config.TestCalls -Value 'call'
    if('--json' -notin $CommandArgs){throw 'Structured CLI events were not requested.'}
    $reply=$CommandArgs[([Array]::IndexOf($CommandArgs,'-o')+1)]
    [IO.File]::WriteAllText($reply,$(if($script:Config.TestCase -eq 'valid'){'Image saved.'}else{''}))
    $errorText='HTTP 429 Too Many Requests'+"`n"+'{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","resets_at":1793241250,"resets_in_seconds":67531}}'
    $traceText=if($script:Config.TestCase -in @('quota','corrupt')){
        @{type='item.completed';item=@{type='mcp_tool_call';status='completed';result=@{isError=$true;content=@(@{type='text';text=$errorText})}}}|ConvertTo-Json -Depth 12 -Compress
    }elseif($script:Config.TestCase -eq 'other-error'){
        @{type='item.completed';item=@{type='mcp_tool_call';status='failed';error=@{message='Input image could not be decoded'}}}|ConvertTo-Json -Depth 12 -Compress
    }else{'{"type":"item.completed","item":{"type":"agent_message","text":"No image created; perhaps usage_limit_reached or quota."}}'}
    [IO.File]::WriteAllText($Trace,$traceText,[Text.UTF8Encoding]::new($false))
    if($PromptText -notmatch '(?m)^Save a new PNG at this exact path: (.+)$'){throw 'Output path missing.'}
    $output=$Matches[1].Trim()
    if($script:Config.TestCase -eq 'valid'){Copy-Item -LiteralPath $script:Config.TestPng -Destination $output}
    if($script:Config.TestCase -eq 'corrupt'){[IO.File]::WriteAllText($output,'not a PNG')}
    return [pscustomobject]@{ExitCode=0;Cause='';StopConfirmed=$true}
}
'@|Set-Content -LiteralPath $fixture -Encoding UTF8
    foreach($case in @('quota','corrupt','missing','empty-reply','other-error','valid')){
        $caseDir=Join-Path $temp $case;New-Item -ItemType Directory -Path $caseDir|Out-Null
        $queue=Join-Path $caseDir 'urls.txt';$url|Set-Content -LiteralPath $queue
        $script:Config=@{ManualReferences=(Read-ManualReferenceMap $mapPath);SourceDir=$temp;SourceCatalog=@{};Model='';AiRetryDelaySeconds=0;TestCase=$case;TestPng=$product;TestCalls=(Join-Path $caseDir 'calls.txt')}
        $errorMessage=''
        try{Invoke-BatchWorkflow $root $queue (Join-Path $caseDir 'out') 1 (@($script:WorkflowModuleFiles)+@($fixture))}
        catch{$errorMessage=$_.Exception.Message}
        Assert (@(Get-Content -LiteralPath $script:Config.TestCalls).Count -eq 1) 'A permanent or unknown tool failure was retried.'
        $batch=Get-ChildItem -LiteralPath (Join-Path $caseDir 'out') -Directory|Select-Object -First 1
        $trace=@(Get-ChildItem -LiteralPath $batch.FullName -Recurse -Filter '*.console.log')
        $manifest=Get-ChildItem -LiteralPath $batch.FullName -Recurse -Filter manifest.json|Select-Object -First 1
        $saved=Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8|ConvertFrom-Json
        Assert ($saved.images.Count -eq 2 -and $saved.images[1].role -eq 'product') 'Input snapshots lost their roles.'
        if($case -eq 'valid'){
            Assert (-not $errorMessage -and -not ([IO.File]::ReadAllText($queue).Trim()) -and $trace.Count -eq 0) 'Valid delivery failed or logs were cleaned before PNG validation.'
            Assert (@(Import-BatchRows $batch.FullName).Count -eq 1) 'Valid image was not exported.'
        }else{
            Assert ($errorMessage -like 'Batch incomplete*' -and ([IO.File]::ReadAllText($queue).Trim()) -eq $url -and $trace.Count -eq 1) 'Failure lost the queue or tool log.'
            $diagnostic=Get-Content -LiteralPath (Get-ChildItem -LiteralPath $batch.FullName -Recurse -Filter '*-error.txt'|Select-Object -First 1).FullName -Raw -Encoding UTF8
            $diagnostic=$diagnostic -replace '\s+',' '
            if($case -in @('quota','corrupt')){
                Assert ($diagnostic -match '\[CAUSE:QUOTA\]' -and $diagnostic -match 'HTTP 429' -and $diagnostic -match 'The usage limit has been reached' -and $diagnostic -match '09:34:10 29/10/2026') 'Tool quota evidence was masked by a missing/corrupt image error.'
            }elseif($case -in @('missing','empty-reply')){
                Assert ($diagnostic -match 'OUTPUT_MISSING' -and $diagnostic -match 'nguyên nhân chưa rõ' -and $diagnostic -notmatch '\[CAUSE:QUOTA\]') 'Missing PNG was guessed to be a quota error from assistant text.'
            }else{Assert ($diagnostic -match 'TOOL_ERROR' -and $diagnostic -match 'Input image could not be decoded') 'Non-quota tool error was hidden.'}
        }
    }
    # Old plain traces retain exact service evidence, but structured argument text is not evidence.
    $plain=Join-Path $temp 'plain.log'
    'HTTP 429 Too Many Requests {"error":{"type":"usage_limit_reached","message":"Limit reached","resets_at":1793241250}}'|Set-Content $plain
    Assert ((Get-CodexToolFailure $plain).Detail -match 'HTTP 429.*Limit reached.*09:34:10') 'Plain tool trace was not parsed.'
    '{"type":"item.completed","item":{"type":"command_execution","command":"echo usage_limit_reached","aggregated_output":"HTTP 429 example"}}'|Set-Content $plain
    Assert (-not (Get-CodexToolFailure $plain)) 'Tool arguments or shell output were mistaken for service errors.'
    Write-Host 'PASS: CLI exit 0 tool quota, no retry, logs/snapshots/queue retention, unknown output, corrupt PNG, valid export and evidence boundaries.'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'image-tool-errors-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
