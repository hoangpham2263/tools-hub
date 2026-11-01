. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) '../../hub/ai/common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) '../../hub/ai/providers/codex.ps1')
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$testArea=Join-Path $TestWorkspaceRoot ('cli-process-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testArea|Out-Null
try {
    $backendPath=Join-Path $testArea "fixture space's.ps1"
    @'
$mode=$args[0]; $dest=$args[1]
if($mode -eq 'success'){
    [Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
    $received=[Console]::In.ReadToEnd()
    [IO.File]::WriteAllText($dest,($args[2]+'|'+$received),[Text.UTF8Encoding]::new($true))
    for($n=0;$n -lt 250;$n++){[Console]::Out.WriteLine("out-$n");[Console]::Error.WriteLine("err-$n")}
    exit 0
}
if($mode -eq 'recover'){
    [Console]::Out.WriteLine('Reconnecting... 1/5')
    Start-Sleep -Milliseconds 150
    [Console]::Out.WriteLine('assistant')
    Start-Sleep -Milliseconds 1500
    exit 0
}
if($mode -eq 'auxiliary'){
    [Console]::Out.WriteLine('2026-10-27 WARN codex_analytics: error sending request for url analytics-events')
    [Console]::Out.WriteLine('2026-10-27 WARN codex_mcp: MCP startup reconnect failed; continuing with cached tools')
    [Console]::Out.WriteLine('    if ($line -match Reconnecting) { tool source text }')
    Start-Sleep -Milliseconds 1800
    exit 0
}
# A harmless local child lets the test detect process leaks on cancellation.
$child=if($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop'){Start-Process ping.exe -WindowStyle Hidden -PassThru -ArgumentList '127.0.0.1','-n','45'}else{Start-Process sleep -PassThru -ArgumentList '45'}
[IO.File]::WriteAllText($dest,$child.Id.ToString())
if($mode -eq 'network'){[Console]::Out.WriteLine('ERROR: Reconnecting... 1/5')}
Start-Sleep -Seconds 45
'@ | Set-Content $backendPath -Encoding UTF8
    $powershellPath=(Get-Command powershell.exe,pwsh -ErrorAction SilentlyContinue|Select-Object -First 1).Source
    $prefix=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$backendPath)
    $resultPath=Join-Path $testArea 'result.txt';$tracePath=Join-Path $testArea 'success.log'
    $execution=Invoke-CodexProcess 'plain prompt' ($prefix+@('success',$resultPath,"quote's & dollar`$ with a `"quote`" and slash\")) $tracePath 15 1 $powershellPath
    Assert ($execution.ExitCode -eq 0 -and -not $execution.Cause) 'Successful backend failed.'
    Assert ((Get-Content $resultPath -Raw -Encoding UTF8) -eq "quote's & dollar`$ with a `"quote`" and slash\|plain prompt") 'Argument quoting or stdin changed.'
    $content=Get-Content $tracePath -Raw -Encoding UTF8
    Assert ($content -match 'out-249' -and $content -match 'err-249') 'Stdout/stderr drain lost output or deadlocked.'
    $priorInputEncoding=[Console]::InputEncoding
    try {
        [Console]::InputEncoding=[Text.Encoding]::GetEncoding(1252)
        $unicodePrompt='m'+[char]0x00E0+'u g'+[char]0x1ED7+' '+[char]::ConvertFromUtf32(0x1F332)
        $execution=Invoke-CodexProcess $unicodePrompt ($prefix+@('success',$resultPath,'unicode')) (Join-Path $testArea 'unicode.log') 15 1 $powershellPath
        Assert ($execution.ExitCode -eq 0 -and (Get-Content $resultPath -Raw -Encoding UTF8) -ceq ('unicode|'+$unicodePrompt)) 'Vietnamese/Unicode stdin was corrupted by the system code page.'
    } finally { [Console]::InputEncoding=$priorInputEncoding }
    $execution=Invoke-CodexProcess 'prompt' ($prefix+@('recover',$resultPath)) (Join-Path $testArea 'recover.log') 10 1 $powershellPath
    Assert ($execution.ExitCode -eq 0 -and -not $execution.Cause) 'Recovered stream was terminated by a stale reconnect timer.'
    $execution=Invoke-CodexProcess 'prompt' ($prefix+@('auxiliary',$resultPath)) (Join-Path $testArea 'auxiliary.log') 10 1 $powershellPath
    Assert ($execution.ExitCode -eq 0 -and -not $execution.Cause) 'Auxiliary warnings/tool source were mistaken for a disconnected model stream.'
    foreach($mode in @('timeout','network')){
        $pidPath=Join-Path $testArea "$mode.pid"; $tracePath=Join-Path $testArea "$mode.log"
        $watcher=[Diagnostics.Stopwatch]::StartNew()
        # The deadline also covers a backend that never reads a large stdin prompt.
        $probePrompt=if($mode -eq 'timeout'){'x' * 1048576}else{'prompt'}
        $execution=Invoke-CodexProcess $probePrompt ($prefix+@($mode,$pidPath)) $tracePath 5 1 $powershellPath 1
        $expected=if($mode -eq 'timeout'){'AI_TIMEOUT'}else{'NETWORK'}
        Assert ($execution.Cause -eq $expected -and $execution.StopConfirmed -and $watcher.Elapsed.TotalSeconds -lt 15) 'Deadline did not terminate the invocation promptly and confirm cleanup.'
        Assert (Test-Path $pidPath) 'Fixture did not start its child.'
        $childId=[int](Get-Content $pidPath -Raw)
        Assert (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Timed-out child process was left running.'
        Assert ((Get-Content $tracePath -Raw) -match $expected) 'Termination cause was not saved.'
    }
    Write-Host 'PASS: direct process IO, quoted paths, reconnect recovery, deadlines and descendant cleanup.' -ForegroundColor Green
} finally {
    $resolved=[IO.Path]::GetFullPath($testArea);$allowed=[IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')+'\'
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'cli-process-test-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
