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
    Assert (@(Get-HubAIChoices image | ForEach-Object id) -join ',' -eq 'codex,flow,chatgpt') 'Image AIs are listed from the registry.'
    $unsupported = try { Invoke-HubAI -Kind image -Ai gemini -Prompt 'x' -Output (Join-Path $temp 'x.png'); '' } catch { $_.Exception.Message }
    Assert ($unsupported -match '\[CAUSE:UNSUPPORTED\]') 'An AI is only asked for work it can do.'
    # Codex file-delivery lines never reach the browser tab.
    $clean=ConvertTo-BrowserPrompt "Create one photo.`nSave a new PNG at this exact path: C:\x.png`nDo not modify any input file.`nEnd your reply with a line: BRAND: <name>"
    Assert ($clean -eq 'Create one photo.') 'Browser prompt kept Codex delivery lines.'
    # Flow refuses watermark removal and brand swapping: that block becomes one neutral line.
    $branded=ConvertTo-BrowserPrompt "Edit the room.`nBranding: Replace only a brand...`nRemove all photographic watermarks.`nIf it has no logo or brand mark, add none.`nThe BRAND: line is reply metadata only.`nKeep the light."
    Assert ($branded -eq "Edit the room.`n$script:BrowserBrandingLine`nKeep the light.") "Branding block was not replaced: $branded"

    $script:Batch=@{Logs=$temp;Images=$temp}
    $script:Config=@{ImageBackend='flow'}
    $output=Join-Path $temp '001-tee.png'
    $request=[pscustomobject]@{Images=@('ref.png','product.png');Prompt='Create one photo.';Output=$output}
    function Invoke-AI{throw 'Codex must not run for a browser backend.'}
    function Invoke-BrowserImage($Platform,$Prompt,$Images,$Output){
        Assert ($Platform -eq 'flow' -and $Images.Count -eq 2) 'Backend or reference images were not forwarded.'
        [IO.File]::WriteAllBytes($Output,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
        [pscustomobject]@{source='https://flow.google.com/project/x';bytes=1}
    }
    $reply=Invoke-ImageGeneration $request '001-tee' 1 ''
    Assert ($reply -eq 'BRAND: none' -and (Test-Path $output)) 'Browser backend did not deliver the image.'
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
