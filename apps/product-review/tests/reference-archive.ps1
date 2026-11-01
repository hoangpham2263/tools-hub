. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'src/bootstrap.ps1')
$fixture = Join-Path $TestWorkspaceRoot ('reference archive ' + [Guid]::NewGuid().ToString('N'))
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $sources = Join-Path $fixture 'data/source-photos'
    $source = Join-Path $sources 'aprons/person.png'
    New-Item -ItemType Directory -Force (Split-Path $source -Parent) | Out-Null
    [IO.File]::WriteAllBytes($source, [byte[]](1,2,3))
    $hash = Get-BytesHash ([IO.File]::ReadAllBytes($source))
    @{ schema_version = 1; photos = @(@{ file = 'aprons/person.png'; category = 'aprons'; source_kind = 'web_listing'; source_page = 'https://example.test/gallery'; sha256 = $hash }) } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $sources 'catalog.json') -Encoding UTF8
    $product = Join-Path $fixture 'product.png'
    [IO.File]::WriteAllBytes($product, [byte[]](4,5,6))
    $script:Config = @{ SourceDir = $sources }
    $script:Batch = New-Batch (Join-Path $fixture 'output')
    $request = [pscustomobject]@{ Images = @($source, $product); Output = Join-Path $script:Batch.Images '001-apron.png' }
    $item = [pscustomobject]@{ Url = 'https://example.test/product' }
    $context = [pscustomobject]@{ product = 'Apron <script>alert(1)</script>'; presentation = 'worn' }
    $bundle = Save-ProductReferenceBundle $item '001-apron' $context $request
    $manifest = Get-Content (Join-Path $bundle.Folder 'manifest.json') -Raw | ConvertFrom-Json
    Assert (($manifest.images.role -join ',') -eq 'subject,product') 'Archived input roles or order changed.'
    Assert ($manifest.images[0].source_page -eq 'https://example.test/gallery') 'Source provenance was lost.'
    Assert ($request.Images.Count -eq 2 -and $request.Images[1] -eq $bundle.ProductPath) 'Generation did not switch to archived inputs.'
    foreach ($entry in $manifest.images) {
        $copy = Join-Path $bundle.Folder $entry.file
        Assert ((Get-BytesHash ([IO.File]::ReadAllBytes($copy))) -eq $entry.sha256) 'Archived bytes differ from recorded input.'
    }
    # Later changes in the reusable library must not change the batch archive.
    [IO.File]::WriteAllBytes($source, [byte[]](0,0,0))
    Assert ((Get-BytesHash ([IO.File]::ReadAllBytes($request.Images[0]))) -eq $hash) 'Archive depends on mutable library files.'
    [IO.File]::WriteAllBytes($request.Output, [byte[]](9,9,9))
    Assert (-not @(Get-ChildItem $script:Batch.Dir -Recurse -Filter '*.html')) 'Batch must not contain HTML galleries.'
    $blocked = $false
    try { Save-ProductReferenceBundle $item '001-apron' $context $request | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Existing snapshots were overwritten.'
    Write-Host 'PASS: exact archived inputs, input roles, source provenance, immutable copies and no HTML output.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'reference archive *') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
