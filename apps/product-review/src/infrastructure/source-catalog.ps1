# Local sample library: content hashes and catalog entries.
function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# The catalog is the single index of local sample photos and their categories.
function Get-SampleCatalogEntries([string]$SourceDir) {
    $path = Join-Path $SourceDir 'catalog.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.schema_version -ne 1) { throw "Invalid source catalog: $path" }
    foreach ($entry in $data.photos) { $entry | Add-Member NoteProperty _root $SourceDir -Force; $entry }
}

function Resolve-SourcePhotoGroup([string]$Group) {
    $names=@{'shirts'='Áo';'furniture'='Nội thất';'drinkware'='Cốc và bình';'home-decor'='Trang trí nhà cửa';'accessories'='Phụ kiện';'hats'='Mũ';'kitchen'='Đồ bếp';'outdoor-sports'='Thể thao ngoài trời';'pet-supplies'='Đồ thú cưng';'shorts'='Quần đùi';'underwear'='Đồ lót';'uniforms'='Đồng phục'}
    if($names.ContainsKey($Group)){return $names[$Group]}
    return $Group
}

function Get-SourcePhotoGroups([string]$SourceDir) {
    $groups=@(if(Test-Path -LiteralPath $SourceDir){Get-ChildItem -LiteralPath $SourceDir -Directory|ForEach-Object Name})
    if(-not $groups.Count){$groups=@('Áo','Nội thất')}
    $groups|Sort-Object @{Expression={if($_ -eq 'Áo'){0}elseif($_ -eq 'Nội thất'){1}else{2}}},@{Expression={$_}}
}

function Get-SourcePhotoDirectory([string]$SourceDir,[string]$Group) {
    if($Group -notmatch '^[\p{L}\p{N}][\p{L}\p{N} -]*$'){throw 'Invalid local photo group.'}
    $root=[IO.Path]::GetFullPath($SourceDir).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $SourceDir $Group))
    if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Local photo group escapes the library.'}
    New-Item -ItemType Directory -Path $path -Force|Out-Null
    return $path
}

# The Drive library on this machine (for the library picker and the reference archive).
function Get-SourceCatalog([string]$SourceDir) {
    $catalog = @{}
    $hashes = @{}
    foreach ($entry in @(Get-SampleCatalogEntries $SourceDir)) {
        $root = [IO.Path]::GetFullPath($entry._root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

        $full = [IO.Path]::GetFullPath((Join-Path $entry._root $entry.file))
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid source catalog path.' }
        if ($catalog.ContainsKey($full)) {
            throw 'Conflicting source catalog path.'
        }
        # Only the groups downloaded from Drive are on this machine.
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        if ($entry.sha256 -and $hashes.ContainsKey($entry.sha256)) { continue }
        if ($entry.sha256) { $hashes[$entry.sha256] = $true }
        $catalog[$full] = $entry
    }
    return $catalog
}
