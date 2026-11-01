# Batch pipeline: one product URL per line in urls.txt. Each run creates a timestamped batch.
# For every URL: load product, select subject/scene references, create one photo, write a review.
# URLs are processed in parallel (-ThrottleLimit); results are committed one by one in the main thread.
param(
    [Alias('UrlList')][string]$List = (Join-Path (Split-Path $PSScriptRoot -Parent) 'workspace/urls.txt'),
    [Alias('InputDir')][string]$SourceDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/source-photos'),
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'workspace/output'),
    [int]$MaxTries = 5,
    [Alias('ReferencePhotosPerImage')][int]$PhotosPerImage = 2,
    [ValidateRange(1, 4)][int]$ThrottleLimit = 2,
    [string]$Model = '',
    [string]$ReferenceMapFile = '',
    [switch]$LocalOnly,
    # codex: Codex CLI; chatgpt / flow: the signed-in browser tab through bridge/ + hub/extension/.
    [ValidateSet('codex', 'chatgpt', 'flow')][string]$ImageBackend = $(if ($env:PIB_IMAGE_BACKEND) { $env:PIB_IMAGE_BACKEND } else { 'codex' }),
    # Every text step (product, checks, review): codex: Codex CLI; gemini: Gemini web in the tools' own Chrome;
    # antigravity: the Antigravity CLI (agy), signed in with Google.
    [ValidateSet('codex', 'gemini', 'antigravity')][string]$TextBackend = 'codex'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $OutputEncoding
[Console]::OutputEncoding = $OutputEncoding
if ($MaxTries -lt 1) { throw 'MaxTries must be positive.' }
if ($PhotosPerImage -lt 1) { throw 'PhotosPerImage must be positive.' }
if ($ThrottleLimit -lt 1) { throw 'ThrottleLimit must be positive.' }
foreach ($variableName in @('List', 'SourceDir', 'OutDir')) {
    Set-Variable $variableName ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Get-Variable $variableName -ValueOnly)))
}

$ProjectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'bootstrap.ps1')
# Model AI from Cấu hình, unless -Model is given.
$ai = Get-AiSettings $ProjectRoot
if (-not $Model) { $Model = $ai.model }
$script:Config = New-WorkflowConfiguration $ProjectRoot $SourceDir $MaxTries $PhotosPerImage $Model
$script:Config.ReasoningEffort = $ai.effort
$script:Config.DriveRequired = -not $LocalOnly
if($LocalOnly){$script:Config.Drive=$null}
if($script:Config.DriveRequired){
    try{Assert-DriveReady}
    catch{Write-Warning ("Failed; "+$_.Exception.Message);throw}
}
$script:Config.ImageBackend = $ImageBackend
$script:Config.TextBackend = $TextBackend
if ($ImageBackend -ne 'codex' -or $TextBackend -eq 'gemini') { Start-ImageBridge -NewSession }
if($ReferenceMapFile){$script:Config.ManualReferences=Read-ManualReferenceMap $ReferenceMapFile}
# What each step runs on; the Codex model only matters where Codex is used.
$name = { param($Id) if ($Id -eq 'codex') { "Codex ($(Get-AiModelSummary $ProjectRoot))" } else { (Get-HubAIProvider $Id).Name } }
Write-Host "Viết review: $(& $name $TextBackend) | Tạo ảnh: $(& $name $ImageBackend)"
try {
    Invoke-BatchWorkflow $ProjectRoot $List $OutDir $ThrottleLimit $script:WorkflowModuleFiles
} catch {
    throw
}
