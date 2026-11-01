. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
# Photos live on Drive and are downloaded per group; the catalog alone is versioned. Each check
# runs on a copy of the catalog with placeholder files, as after a Drive sync.
$dir = Join-Path $TestWorkspaceRoot ('source-data-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'data/source-photos/catalog.json') -Destination $dir
$entries=@(Get-SampleCatalogEntries $dir)
# The library only grows (new photos are added from Drive); the 3111 regrouped photos must all stay.
if ($entries.Count -lt 3111) { throw 'The regrouped library must preserve all 3111 photos.' }
if ((Get-SourceCatalog $dir).Count) { throw 'Groups not downloaded yet must be skipped, not listed.' }
$groups=@($entries | ForEach-Object { ($_.file -split '/')[0] } | Sort-Object -Unique)
if ($groups.Count -ne 12 -or 'Áo' -notin $groups -or 'Nội thất' -notin $groups) { throw 'Shared merchandise folders are missing.' }
if ((Get-SourcePhotoDirectory $dir 'Nội thất') -ne [IO.Path]::GetFullPath((Join-Path $dir 'Nội thất'))) { throw 'The file picker opens the wrong local folder.' }
foreach($entry in $entries){
    # Regrouped photos keep their old name; photos added later carry their own source instead.
    if(($entry.file -split '/')[0] -ne $entry.source_group -or -not ($entry.previous_file -or $entry.source_page -or $entry.download_url)){throw 'Folder grouping lost category or migration provenance.'}
    if ($entry.file -notmatch '^[\p{L}\p{N}][\p{L}\p{N} -]*/[^/]+\.jpg$') { throw 'Photo is outside product categories or not a library JPEG.' }
    # Identical photos may repeat in the catalog; Get-SourceCatalog keeps the first.
    if ($entry.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Missing photo hash.' }
    # Placeholder files for the categories the selection check and dining evidence need.
    if ($entry.category -in @('polo-shirts', 'tees-hoodies', 'dining-tables')) {
        New-Item -ItemType File -Force -Path (Join-Path $dir $entry.file) | Out-Null
    }
}
$catalog = Get-SourceCatalog $dir
if ((@(Get-SourcePhotoGroups $dir))[0] -ne 'Áo') { throw 'Local folders are ordered incorrectly.' }
# The picker lists only the groups switched on in the management page; offline it keeps the last list.
$project = Join-Path $dir 'project'
New-Item -ItemType Directory -Force -Path (Join-Path $project 'workspace') | Out-Null
if ((@(Get-SourceGroupChoices $project) -join '|') -ne 'Áo|Nội thất') { throw 'Without the app password the picker starts with Áo and Nội thất.' }
'{"apiUrl":"https://api.test","adminKey":"k"}' | Set-Content -LiteralPath (Join-Path $project 'workspace/drive.json') -Encoding UTF8
function Invoke-RestMethod { [pscustomobject]@{ groups = @([pscustomobject]@{ name = 'Áo'; enabled = $true }, [pscustomobject]@{ name = 'Đồ bếp'; enabled = $false }) } }
if ((@(Get-RemoteSourceGroups @{ ApiUrl = 'https://api.test'; AdminKey = 'k' }) -join '|') -ne 'Áo') { throw 'With the admin password the app must still hide switched-off groups.' }
Remove-Item Function:\Invoke-RestMethod
function Get-RemoteSourceGroups($Drive) { @('Mũ', 'Nội thất'.Normalize([Text.NormalizationForm]::FormD), 'Áo') }
if ((@(Get-SourceGroupChoices $project) -join '|') -ne 'Áo|Nội thất|Mũ') { throw 'The picker must show exactly the switched-on groups.' }
# Mặc định: the picker opens on the saved danh mục; clearing it brings back the empty choice.
Set-DefaultSourceGroup $project ('Nội thất'.Normalize([Text.NormalizationForm]::FormD))
if ((Get-DefaultSourceGroup $project) -ne 'Nội thất') { throw 'The default danh mục must be saved (as NFC).' }
Set-DefaultSourceGroup $project ''
if (Get-DefaultSourceGroup $project) { throw 'Unticking Mặc định must clear the default danh mục.' }
function Get-RemoteSourceGroups($Drive) { throw 'offline' }
if ((@(Get-SourceGroupChoices $project) -join '|') -ne 'Áo|Nội thất|Mũ') { throw 'Offline, the picker must keep the last switched-on groups.' }
function Get-RemoteSourceGroups($Drive) { @() }
if (@(Get-SourceGroupChoices $project).Count) { throw 'With every group switched off the picker must be empty.' }
# The picker says why it shows only this machine's photos: no app password, or Drive out of reach.
$listing = Get-SourcePickerFiles $null $dir 'Áo'
if ($listing.Error -notmatch 'Chưa đăng nhập mật khẩu app' -or -not @($listing.Files).Count -or @($listing.Files | Where-Object { -not $_.local }).Count) { throw 'Without the app password the picker must list local photos and say to sign in.' }
function Get-SourceGroupFiles { throw 'offline' }
$listing = Get-SourcePickerFiles @{ ApiUrl = 'https://api.test'; AdminKey = 'k' } $dir 'Áo'
if ($listing.Error -notmatch 'Không kết nối được Drive' -or -not @($listing.Files).Count) { throw 'When Drive is out of reach the picker must say so and fall back to local photos.' }
Remove-Item Function:\Get-SourceGroupFiles
. (Join-Path $root 'src/infrastructure/source-sync.ps1')
# The picker first shows the copies the sync index knows, then marks the Drive listing against them.
$known = @(Get-LocalSourceFiles $dir 'Áo')[0]
@{ ([IO.Path]::GetFileName($known)) = 'm1' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'Áo/.drive-sync.json') -Encoding UTF8
$indexed = @(Get-SourceIndexedFiles $dir 'Áo')
if ($indexed.Count -ne 1 -or $indexed[0].local -ne $known) { throw 'Only the photos the sync index knows are shown before the Drive listing.' }
$listed = @(ConvertTo-SourceGroupFiles ([pscustomobject]@{ files = @([pscustomobject]@{ name = $indexed[0].name; md5 = 'm1'; url = 'u1' }, [pscustomobject]@{ name = 'new.jpg'; md5 = 'm2'; url = 'u2' }) }) $dir 'Áo')
if ($listed[0].local -ne $known -or $listed[1].local) { throw 'The Drive listing must keep local copies and mark new photos as not on this machine.' }
Remove-Item -LiteralPath (Join-Path $dir 'Áo/.drive-sync.json') -Force
$blocked=$false;try{Get-SourcePhotoDirectory $dir '../outside'|Out-Null}catch{$blocked=$true}
if(-not $blocked){throw 'Local group navigation escaped the library.'}
$expansionPath = Join-Path $root 'data/dining-gallery-expansion.json'
if (Test-Path -LiteralPath $expansionPath) {
    $expansion = Get-Content -LiteralPath $expansionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $newPhotos = @($catalog.Values | Where-Object collection_id -eq $expansion.collection_id)
    if ($newPhotos.Count -ne $expansion.photos_added -or @($newPhotos | Where-Object { -not $_.visual_checked -or [Math]::Min($_.width, $_.height) -lt 600 }).Count) { throw 'Dining expansion is incomplete or contains unchecked/undersized photos.' }
    foreach ($check in $expansion.fit_checks) {
        $photo = $catalog[[IO.Path]::GetFullPath((Join-Path $dir $check.file))]
        if (-not $photo -or -not @($photo.fit_checks | Where-Object { $_.product_sha256 -eq $check.product_sha256 -and $_.verdict -eq $check.verdict }).Count) { throw 'Dining fit evidence does not match the library.' }
    }
    if (@($expansion.fit_checks | Where-Object verdict -eq FIT).Count -lt 6) { throw 'Missing checked room alternatives for the twelve-chair product.' }
}
Remove-Item -LiteralPath $dir -Recurse -Force
Write-Host "PASS: $($entries.Count) catalogued photos, downloaded groups only, and provenance hashes."
