# Entry of a run. The job is the JSON the window sends (server.mjs writes it to workspace/temp); the work is
# Invoke-ContentRun (workflow/run-job.ps1).
param(
    [Parameter(Mandatory)][string]$JobFile,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $OutputEncoding
[Console]::OutputEncoding = $OutputEncoding

. (Join-Path $PSScriptRoot 'bootstrap.ps1')
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'workspace/output' }
exit (Invoke-ContentRun (Read-JsonFile $JobFile) $OutDir)
