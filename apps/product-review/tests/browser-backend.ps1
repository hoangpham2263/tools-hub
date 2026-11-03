. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src/bootstrap.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('browser-backend-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    # The shared bridge is found from the hub's AI core.
    Assert (Test-Path (Join-Path $script:BridgeHubRoot 'hub/bridge/ensure.mjs')) 'The AI core does not find hub/bridge.'
    $imageAis = @(Get-HubAIChoices image | ForEach-Object id | Sort-Object)
    Assert (($imageAis -contains 'codex') -and ($imageAis -contains 'flow') -and ($imageAis -notcontains 'gemini')) 'Image AIs are listed from the registry.'
    $unsupported = try { Invoke-HubAI -Kind image -Ai gemini -Prompt 'x' -Output (Join-Path $temp 'x.png'); '' } catch { $_.Exception.Message }
    Assert ($unsupported -match '\[CAUSE:UNSUPPORTED\]') 'An AI is only asked for work it can do.'
    # Every image AI gets the same request: Codex alone is also told where to save the file (hub/ai).
    $request=[pscustomobject]@{Images=@('ref.png','product.png');Prompt='Create one photo.';Output=(Join-Path $temp 'shared.png')}
    function Invoke-CodexExec($PromptText){ $script:CodexPrompt=$PromptText; 'done' }
    Invoke-HubAI -Kind image -Ai codex -Prompt $request.Prompt -Images $request.Images -Output $request.Output -Options @{WorkDir=$temp}|Out-Null
    Assert ($script:CodexPrompt.StartsWith('Create one photo.') -and $script:CodexPrompt -match [regex]::Escape("Save a new PNG at this exact path: $($request.Output)")) 'Codex did not get the shared request plus its delivery lines.'

    $script:Batch=@{Logs=$temp;Images=$temp}
    $script:Config=@{ImageBackend='flow'}
    $output=Join-Path $temp '001-tee.png'
    $request=[pscustomobject]@{Images=@('ref.png','product.png');Prompt='Create one photo.';Output=$output}
    function Invoke-CodexExec{throw 'Codex must not run for a browser backend.'}
    function Invoke-BrowserImage($Platform,$Prompt,$Images,$Output){
        Assert ($Platform -eq 'flow' -and $Images.Count -eq 2 -and $Prompt -eq 'Create one photo.') 'The web AI did not get the shared request as it is.'
        [IO.File]::WriteAllBytes($Output,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
        [pscustomobject]@{source='https://flow.google.com/project/x';bytes=1}
    }
    Invoke-ImageGeneration $request '001-tee' 1|Out-Null
    Assert (Test-Path $output) 'Browser backend did not deliver the image.'
    Assert ((Get-Content (Join-Path $temp '001-tee-image.txt') -Raw) -match 'backend: flow') 'Backend log is missing.'

    # PNG output is kept byte-for-byte; JPEG/WebP conversion needs Windows GDI+ and is covered there.
    $before=[IO.File]::ReadAllBytes($output);ConvertTo-PngFile $output
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) -eq [Convert]::ToBase64String($before)) 'PNG output was rewritten.'
    if($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop'){
        Add-Type -AssemblyName System.Drawing
        $jpeg=Join-Path $temp 'flow.png'
        $bitmap=[Drawing.Bitmap]::new(4,4);try{$bitmap.Save($jpeg,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$bitmap.Dispose()}
        ConvertTo-PngFile $jpeg
        $bytes=[IO.File]::ReadAllBytes($jpeg)
        Assert ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) 'Non-PNG output was not converted.'
    }
    Write-Host 'PASS: browser backends forward references, skip Codex, log the source and store PNG.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
