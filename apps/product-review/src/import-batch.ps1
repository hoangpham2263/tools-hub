# Nhập hàng loạt, run in the background by the app (Windows and macOS): reads products.csv (docs/import.md) and attaches
# every row's images, files in -Folder/images, to its link. Progress goes to -StatusFile as UTF-8 JSON; the import dialog shows it and, when
# finished, adds the links to the list.
param([Parameter(Mandatory)][string]$File, [string]$Folder = '', [string]$StatusFile = '')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot '../../../hub/ai/common.ps1')
. (Join-Path $PSScriptRoot 'infrastructure/source-catalog.ps1')
. (Join-Path $PSScriptRoot 'application/image-feedback.ps1')
. (Join-Path $PSScriptRoot 'application/manual-references.ps1')
. (Join-Path $PSScriptRoot 'application/batch-import.ps1')
$status = [ordered]@{ done = 0; total = 0; links = @(); products = 0; reviews = 0; failed = @(); errors = @(); finished = $false }
$save = { if ($StatusFile) { [IO.File]::WriteAllText($StatusFile, (ConvertTo-Json -InputObject $status -Depth 4 -Compress), [Text.UTF8Encoding]::new($false)) } }
try {
    $parsed = ConvertFrom-ProductBatch ([IO.File]::ReadAllText($File)) $Folder
    if (@($parsed.Errors).Count) { $status.errors = @($parsed.Errors) }
    else {
        $result = Import-ProductBatch $root $parsed.Rows { param($Done, $Total) $status.done = $Done; $status.total = $Total; & $save }
        foreach ($key in 'links', 'products', 'reviews', 'failed') { $status[$key] = $result[$key] }
    }
} catch { $status.errors = @("Chưa nhập được: $($_.Exception.Message)") }
$status.finished = $true; & $save
