# Step 02: the review photo the user attached to this product (from the computer or the Drive library).
# Nothing is picked or checked by AI: the user chooses the photo and reviews the result.

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

function Select-ProductReferences([string]$Reference, [string]$Handle, [string]$ItemId, $Context) {
    $entry=@($script:Config.ManualReferences.entries|Where-Object product_url -eq $script:Config.ActiveProductUrl)
    $scene=if($script:Config.ActiveScene){$script:Config.ActiveScene}elseif($entry.Count){@(Get-ManualScenes $entry[0])[0]}
    if($scene){
        $photo=$scene.file
        if(-not (Test-Path -LiteralPath $photo) -or (Get-BytesHash ([IO.File]::ReadAllBytes($photo))) -ine $scene.sha256){throw '[CAUSE:PRODUCT_INPUT] Ảnh review đã gắn bị thiếu hoặc thay đổi. Hãy gắn lại ảnh.'}
        $role=if($Context.presentation -and $Context.presentation -ne 'worn'){'Scene'}else{'Subject'}
        Write-Host '  [MANUAL-REFERENCE] Using the image attached to this product URL; user performs visual review.' -ForegroundColor Cyan
        $verdict='USER_SELECTED'
        Write-FeedbackJson (Join-Path $script:Batch.Logs "$ItemId-manual-reference.json") ([ordered]@{product_url=$script:Config.ActiveProductUrl;photo=$photo;sha256=$scene.sha256;role=$role;verdict=$verdict;origin='user_reference'})
        return $photo
    }
    # A missing review photo is an input error to fix by attaching one.
    throw '[CAUSE:PRODUCT_INPUT] Ảnh gốc chưa gắn ảnh review. Hãy gắn ảnh review.'
}
