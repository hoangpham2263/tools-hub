# Tải về máy, run in the background by the app (Windows and macOS): downloads one or more Drive danh mục into
# data/source-photos/<group>. -Group takes names separated by "|". Progress goes to -StatusFile as UTF-8 JSON after
# every batch, which the main window shows in its header while the user keeps working.
param([Parameter(Mandatory)][string]$Group, [string]$StatusFile = '')
$ErrorActionPreference = 'Stop'
# The app reads this output as UTF-8 (paths may hold Vietnamese folder names).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'application/workspace.ps1')
. (Join-Path $PSScriptRoot '../../../hub/ai/common.ps1')
. (Join-Path $PSScriptRoot 'infrastructure/drive-storage.ps1')
. (Join-Path $PSScriptRoot 'infrastructure/source-catalog.ps1')
. (Join-Path $PSScriptRoot 'infrastructure/source-sync.ps1')
$groups = @($Group -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$status = [ordered]@{ groups = $groups; index = 0; group = ''; done = 0; missing = 0; total = 0; downloaded = 0; removed = 0; failed = @(); finished = $false }
$save = { if ($StatusFile) { [IO.File]::WriteAllText($StatusFile, (ConvertTo-Json -InputObject $status -Compress), [Text.UTF8Encoding]::new($false)) } }
$drive = Get-DriveConfig (Join-Path $root 'workspace')
for ($i = 0; $i -lt $groups.Count; $i++) {
    $status.index = $i + 1; $status.group = $groups[$i]; $status.done = 0; $status.missing = 0; & $save
    try {
        if (-not $drive) { throw 'Chưa đăng nhập mật khẩu app.' }
        $result = Sync-SourceGroup $drive (Join-Path $root 'data/source-photos') $groups[$i] { param($Done, $Missing) $status.done = $Done; $status.missing = $Missing; & $save }
        $status.total += $result.Total; $status.downloaded += $result.Downloaded; $status.removed += $result.Removed
        Write-Output ("{0}|{1}|{2}" -f $result.Total, $result.Downloaded, $result.Removed)
    } catch { $status.failed += $groups[$i]; Write-Warning "$($groups[$i]): $($_.Exception.Message)" }
}
$status.finished = $true; & $save
