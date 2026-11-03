# Nhập hàng loạt: many products at once from one folder (docs/import.md): products.csv with its images in images/,
# which the table names by file name. Each row is one product image of a link with its review images; several rows with the same link
# give that link several product images. Plain links, one per line, still work and only add the links.
$script:ImportColumns = @('product_url', 'product_image', 'review_images')

# Rows of the table, or the problems found in it (with line numbers) so nothing is half imported by mistake.
# $Folder is the folder of the table: image names are files in its images/ folder.
function ConvertFrom-ProductBatch([string]$Text, [string]$Folder = '') {
    $lines = @($Text -replace '^\uFEFF', '' -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    if (-not $lines.Count) { return @{ Rows = @(); Errors = @('Chưa có dòng nào.') } }
    $header = $lines[0].Trim()
    $errors = [Collections.Generic.List[string]]::new()
    $rows = [Collections.Generic.List[object]]::new()
    if ($header -notmatch 'product_url') {
        # Plain links: one per line, nothing to attach.
        for ($i = 0; $i -lt $lines.Count; $i++) { $rows.Add([pscustomobject]@{ Line = $i + 1; Url = $lines[$i].Trim(); Product = ''; Reviews = @() }) }
    } else {
        if (-not $Folder) { return @{ Rows = @(); Errors = @('Bấm Chọn file… và chọn products.csv trong thư mục ảnh.') } }
        $names = @($header -split ',' | ForEach-Object { $_.Trim().Trim('"').ToLowerInvariant() })
        foreach ($name in $names) { if ($name -and $name -notin $script:ImportColumns) { $errors.Add("Dòng 1: cột lạ '$name'. Chỉ dùng: $($script:ImportColumns -join ', ').") } }
        $records = @($lines | ConvertFrom-Csv)
        for ($i = 0; $i -lt $records.Count; $i++) {
            $r = $records[$i]
            $get = { param($n) $p = $r.PSObject.Properties | Where-Object { $_.Name.Trim().ToLowerInvariant() -eq $n } | Select-Object -First 1; if ($p) { ([string]$p.Value).Trim() } else { '' } }
            $reviews = @((& $get 'review_images') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $rows.Add([pscustomobject]@{ Line = $i + 2; Url = (& $get 'product_url'); Product = (& $get 'product_image'); Reviews = $reviews })
        }
    }
    $images = if ($Folder) { Join-Path $Folder 'images' } else { '' }
    foreach ($row in $rows) {
        if (-not (Test-ImportLink $row.Url)) { $errors.Add("Dòng $($row.Line): link sản phẩm không hợp lệ '$($row.Url)'.") }
        $row.Product = if ($row.Product) { Join-Path $images $row.Product } else { '' }
        $row.Reviews = @($row.Reviews | ForEach-Object { Join-Path $images $_ })
        foreach ($image in @(@($row.Product) + @($row.Reviews) | Where-Object { $_ })) {
            if (-not (Test-Path -LiteralPath $image -PathType Leaf)) { $errors.Add("Dòng $($row.Line): không có ảnh '$(Split-Path -Leaf $image)' trong thư mục images.") }
        }
    }
    return @{ Rows = $rows.ToArray(); Errors = $errors.ToArray() }
}

# A packed product-import folder (.zip like the sample, .rar or .7z) unpacks into $Temp with the system tar
# (bsdtar on macOS and Windows 10+); returns the folder that holds its products.csv.
function Expand-ProductBatchArchive([string]$Archive, [string]$Temp) {
    $dest = Join-Path $Temp ('import-archive-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    & tar -xf $Archive -C $dest 2>$null
    if ($LASTEXITCODE -and $Archive -match '\.zip$') { try { Expand-Archive -LiteralPath $Archive -DestinationPath $dest -Force; $global:LASTEXITCODE = 0 } catch {} }
    if ($LASTEXITCODE) { throw "Không giải nén được $([IO.Path]::GetFileName($Archive)). Thử nén lại bằng zip." }
    $csv = Get-ChildItem -LiteralPath $dest -Filter *.csv -File -Recurse -Depth 1 | Where-Object { $_.FullName -notmatch '__MACOSX' } |
        Sort-Object { $_.Name -ne 'products.csv' } | Select-Object -First 1
    if (-not $csv) { throw 'File nén chưa có products.csv.' }
    return $csv.DirectoryName
}

function Test-ImportLink([string]$Value) {
    $uri = $null
    return [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')
}

# An image file from the import folder, copied as a JPEG/PNG file into $Folder (the app attaches only these).
function Get-ImportImage([string]$Source, [string]$Folder) {
    $path = Join-Path $Folder ([Guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $Source -Destination $path
    $size = (Get-Item -LiteralPath $path).Length
    $head = [byte[]]::new(8)
    $stream = [IO.File]::OpenRead($path); try { [void]$stream.Read($head, 0, 8) } finally { $stream.Dispose() }
    $extension = if ($head[0] -eq 0xFF -and $head[1] -eq 0xD8) { '.jpg' } elseif ($head[0] -eq 0x89 -and $head[1] -eq 0x50 -and $head[2] -eq 0x4E -and $head[3] -eq 0x47) { '.png' } else { '' }
    if (-not $extension -or $size -gt 25MB) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw $(if ($size -gt 25MB) { 'ảnh quá 25 MB' } else { 'không phải ảnh JPG hoặc PNG' })
    }
    Rename-Item -LiteralPath $path -NewName ([IO.Path]::GetFileName($path) + $extension)
    return $path + $extension
}

# Attaches every row's images to its link. $OnProgress gets (images done, images in all). A row whose product image
# fails keeps none of its reviews, so a review never lands on another product image.
function Import-ProductBatch([string]$ProjectRoot, $Rows, [scriptblock]$OnProgress) {
    $temp = Join-Path $ProjectRoot ('workspace/temp/import-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $mapPath = Join-Path $ProjectRoot 'workspace/reference-inputs/references.json'
    $total = [int](@($Rows | ForEach-Object { @(@($_.Product) + @($_.Reviews) | Where-Object { $_ }).Count }) | Measure-Object -Sum).Sum
    $result = [ordered]@{ links = @(); products = 0; reviews = 0; failed = @() }
    $done = 0
    $step = { if ($OnProgress) { & $OnProgress $done $total } }
    try {
        foreach ($row in $Rows) {
            if ($row.Url -notin $result.links) { $result.links += $row.Url }
            $target = -1
            if ($row.Product) {
                try {
                    $file = Get-ImportImage $row.Product $temp
                    [void](Save-ManualReference $ProjectRoot $row.Url $file Product)
                    $hash = Get-BytesHash ([IO.File]::ReadAllBytes($file))
                    $saved = @(Get-ManualProducts @((Read-ManualReferenceMap $mapPath).entries | Where-Object product_url -eq $row.Url)[0])
                    for ($i = 0; $i -lt $saved.Count; $i++) { if ($saved[$i].sha256 -eq $hash) { $target = $i } }
                    $result.products++
                } catch {
                    $result.failed += [ordered]@{ line = $row.Line; image = $row.Product; reason = "ảnh sản phẩm: $($_.Exception.Message)" }
                    $done += 1 + @($row.Reviews).Count; & $step
                    continue
                }
                $done++; & $step
            }
            foreach ($review in @($row.Reviews)) {
                try {
                    [void](Save-ManualReference $ProjectRoot $row.Url (Get-ImportImage $review $temp) Scene $target)
                    $result.reviews++
                } catch { $result.failed += [ordered]@{ line = $row.Line; image = $review; reason = $_.Exception.Message } }
                $done++; & $step
            }
        }
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    return $result
}
