# Archive the exact image inputs, independently of the reusable sample library.
function Save-ProductReferenceBundle($Item, [string]$ItemId, $Context, $Request, [int]$ReferenceCount) {
    if ($ItemId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Invalid reference archive item ID.' }
    $folder = Join-Path $script:Batch.Refs $ItemId
    if (Test-Path -LiteralPath (Join-Path $folder 'manifest.json')) { throw 'Reference bundle already exists; its saved inputs must not be overwritten.' }
    New-Item -ItemType Directory -Force $folder | Out-Null
    $catalog = Get-SourceCatalog $script:Config.SourceDir
    $paths = New-Object Collections.Generic.List[string]
    $entries = @()
    $productPath = ''
    for ($index = 0; $index -lt $Request.Images.Count; $index++) {
        $original = [IO.Path]::GetFullPath($Request.Images[$index])
        $role = 'style'; $label = 'Hướng dẫn phong cách'
        if ($index -lt $ReferenceCount) {
            $isPerson = $index -eq 0 -and (-not $Context.presentation -or $Context.presentation -eq 'worn')
            $role = if ($isPerson) { 'subject' } else { 'scene' }
            $label = if ($isPerson) { 'Người và bối cảnh tham khảo' } elseif ($Request.SceneBase -and $index -eq 0) { 'Ảnh review gốc dùng để ghép sản phẩm' } else { 'Bối cảnh tham khảo' }
        } elseif ($index -eq $ReferenceCount) { $role = 'product'; $label = 'Sản phẩm gốc' }
        $extension = [IO.Path]::GetExtension($original).ToLowerInvariant()
        if ($extension -notmatch '^\.[a-z0-9]+$') { throw 'Invalid image extension for reference archive.' }
        $file = '{0:D2}-{1}{2}' -f ($index + 1), $role, $extension
        $destination = Join-Path $folder $file
        $hash = Get-BytesHash ([IO.File]::ReadAllBytes($original))
        Copy-Item -LiteralPath $original -Destination $destination -Force
        if ((Get-BytesHash ([IO.File]::ReadAllBytes($destination))) -ne $hash) { throw 'Reference archive copy does not match source.' }
        $entry = $catalog[$original]
        $manualSource = $role -in @('scene','subject') -and @($script:Config.ManualReferences.entries | ForEach-Object { Get-ManualScenes $_ } | Where-Object file -eq $original).Count -gt 0
        $manualProduct = $role -eq 'product' -and @($script:Config.ManualReferences.entries | Where-Object product_url -eq $Item.Url | ForEach-Object { Get-ManualProducts $_ } | Where-Object sha256 -eq $hash).Count -gt 0
        $sourcePage = if ($role -eq 'product') { $Item.Url } elseif ($entry) { $entry.source_page } else { '' }
        $entries += [pscustomobject][ordered]@{
            index = $index + 1; role = $role; label = $label; file = $file
            sha256 = $hash; original_path = $original; source_page = $sourcePage
            download_url = $(if ($entry) { $entry.download_url } else { '' })
            source_kind = $(if ($manualProduct) { 'user_product' } elseif ($manualSource) { 'user_reference' } elseif ($entry) { $entry.source_kind } elseif ($role -eq 'product') { 'product' } elseif ($role -eq 'style') { 'style_only' } else { 'local' })
            category = $(if ($entry) { $entry.category } elseif ($manualSource) { @($Context.source_categories)[0] } else { '' })
            rights_status = $(if ($entry) { $entry.rights_status } else { '' })
        }
        $paths.Add($destination)
        if ($role -eq 'product') { $productPath = $destination }
    }
    if (-not $productPath) { throw 'Product image is missing from reference bundle.' }
    $manifest = [ordered]@{
        schema_version = 1; item_id = $ItemId; product = $Context.product
        product_url = $Item.Url; reference_count = $ReferenceCount
        product_context = $Context
        image_mode = 'direct_image_output'
        archived_at = [DateTime]::UtcNow.ToString('o')
        output = "../../images/$ItemId.png"; images = $entries
    }
    [IO.File]::WriteAllText((Join-Path $folder 'manifest.json'), ($manifest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    # The generator consumes these copies, so the archive matches its actual inputs.
    $Request.Images = $paths.ToArray()
    if ($Request.SceneBase) { $Request.SceneBase = $Request.Images[0] }
    return [pscustomobject]@{ Folder = $folder; ProductPath = $productPath }
}
