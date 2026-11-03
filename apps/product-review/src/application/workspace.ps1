# All project runtime state belongs to this ignored directory.
function Initialize-ProjectWorkspace([string]$ProjectRoot) {
    $root = Join-Path ([IO.Path]::GetFullPath($ProjectRoot)) 'workspace'
    $paths = @{
        Root = $root
        Output = Join-Path $root 'output'
        Logs = Join-Path $root 'logs'
        Temp = Join-Path $root 'temp'
        Tests = Join-Path $root 'tests'
        Queue = Join-Path $root 'urls.txt'
    }
    New-Item -ItemType Directory -Force $paths.Root, $paths.Logs, $paths.Temp, $paths.Tests | Out-Null
    if (-not (Test-Path -LiteralPath $paths.Queue)) { [IO.File]::WriteAllText($paths.Queue, "", [Text.UTF8Encoding]::new($true)) }
    $env:TEMP = $paths.Temp
    $env:TMP = $paths.Temp
    return $paths
}

# Tools Hub root: this tool is apps/<id>/ inside it.
function Get-HubRoot([string]$ProjectRoot) { return [IO.Path]::GetFullPath((Join-Path $ProjectRoot '../..')) }

# Installed release (the hub's workspace/version.txt, written by the updater); a git checkout shows its latest tag.
function Get-AppVersion([string]$ProjectRoot) {
    $ProjectRoot = Get-HubRoot $ProjectRoot
    $file = Join-Path $ProjectRoot 'workspace/version.txt'
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw).Trim() }
    if ((Test-Path -LiteralPath (Join-Path $ProjectRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $tag = git -C $ProjectRoot describe --tags --abbrev=0 2>$null
        if ($tag) { return [string]$tag }
    }
    return ''
}

# Errors the user would otherwise only see in a dialog, or never: workspace/logs/app-errors.log, rolled over to
# app-errors.old.log past 1 MB. Gửi lỗi sends both. Writing the log must never raise another error.
function Write-AppError([string]$LogDir, [string]$Where, $ErrorObject) {
    try {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $path = Join-Path $LogDir 'app-errors.log'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) { Move-Item -LiteralPath $path -Destination (Join-Path $LogDir 'app-errors.old.log') -Force }
        $record = if ($ErrorObject -is [Management.Automation.ErrorRecord]) { $ErrorObject } elseif ($ErrorObject -is [Management.Automation.IContainsErrorRecord]) { $ErrorObject.ErrorRecord } else { $null }
        $exception = if ($ErrorObject -is [Exception]) { $ErrorObject } elseif ($record) { $record.Exception } else { $null }
        $lines = @("[$((Get-Date).ToString('o'))] $Where", "  $(if ($exception) { $exception.GetType().FullName + ': ' + $exception.Message } else { [string]$ErrorObject })")
        if ($record -and $record.InvocationInfo -and $record.InvocationInfo.PositionMessage) { $lines += '  ' + ($record.InvocationInfo.PositionMessage -replace '\r?\n', "`n  ") }
        if ($record -and $record.ScriptStackTrace) { $lines += '  ' + ($record.ScriptStackTrace -replace '\r?\n', "`n  ") }
        $inner = if ($exception) { $exception.InnerException } else { $null }
        while ($inner) { $lines += "  inner: $($inner.GetType().FullName): $($inner.Message)"; $inner = $inner.InnerException }
        [IO.File]::AppendAllText($path, ($lines -join "`n") + "`n`n", [Text.UTF8Encoding]::new($false))
    } catch { Write-Verbose $_ }
}
