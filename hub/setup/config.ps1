# Settings every tool shares (the app password for Drive, Model AI) live once per install in
# <hub>/workspace/config/<name>. Before the hub had them, each was in a tool's own workspace/; the first read moves it.
# Outside a Tools Hub install (a tool's tests in a temp folder) a file stays in the workspace it is asked for.
function Get-SharedConfigPath([string]$WorkspaceRoot, [string]$Name) {
    $hub = @((Split-Path $WorkspaceRoot -Parent), (Split-Path (Split-Path (Split-Path $WorkspaceRoot -Parent) -Parent) -Parent)) |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'hub/update.ps1')) } | Select-Object -First 1
    if (-not $hub) { return (Join-Path $WorkspaceRoot $Name) }
    $path = Join-Path $hub "workspace/config/$Name"
    if (-not (Test-Path -LiteralPath $path)) {
        $old = @(Get-ChildItem -LiteralPath (Join-Path $hub 'apps') -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName "workspace/$Name" } | Where-Object { Test-Path -LiteralPath $_ })
        if ($old.Count) {
            New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
            Move-Item -LiteralPath $old[0] -Destination $path
        }
    }
    return $path
}
