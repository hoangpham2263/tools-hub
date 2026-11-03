# Files, hashes and the event lines the window reads. Everything a run writes goes under the tool's workspace folder, output/<stamp>/.

function Get-ToolRoot { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# One workspace folder for every tool: <hub>/workspace/fb-content/ (Git ignores that single folder); outside an install a tool keeps its
# own workspace/. server.mjs moves what an older install kept in apps/fb-content/workspace/.
function Get-ToolWorkspace {
    $root = Get-ToolRoot
    $hub = Split-Path (Split-Path $root -Parent) -Parent
    if (Test-Path -LiteralPath (Join-Path $hub 'hub/update.ps1')) { return (Join-Path $hub 'workspace/fb-content') }
    Join-Path $root 'workspace'
}

# One line the server turns into an event for the window: @@EVENT {json}. Human log lines stay as they are.
function Send-Event([hashtable]$Event) {
    Write-Host ('@@EVENT ' + (ConvertTo-Json -InputObject $Event -Compress -Depth 8))
}

function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# A folder name from a product name: lowercase ASCII, words joined by dashes (Vietnamese marks removed).
function ConvertTo-Slug([string]$Text) {
    $plain = ($Text.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace 'đ', 'd' -replace 'Đ', 'D'
    $slug = ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50).Trim('-') }
    if ($slug) { $slug } else { 'san-pham' }
}

function New-RunFolder([string]$OutRoot) {
    $folder = Join-Path $OutRoot ([DateTime]::Now.ToString("yyyy-MM-dd_HH'h'mm'm'ss's'"))
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $folder
}

function Test-ImageFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $info = Get-ImageSize ([IO.File]::ReadAllBytes($Path))
    [bool]($info -and $info.Width -gt 0 -and $info.Height -gt 0)
}

function Read-JsonFile([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
