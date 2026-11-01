# One product: steps 1-5. BatchWorkflow runs steps 6-7 after workers finish.
function Invoke-ProductItem($Item, [string]$ItemId, $Brands) {
    $script:Config.ActiveProductUrl = $Item.Url
    $script:Config.ActiveScene = if ($Item.PSObject.Properties['Scene']) { $Item.Scene } else { $null }
    $cached=Read-DeliveryCache $Item
    if($cached){
        Write-Host '  [DRIVE-RESUME] Reusing saved image and review; no AI generation.' -ForegroundColor Cyan
        $row=Restore-DeliveryCache $cached $ItemId
        Save-DeliveryCache $Item $ItemId $row
        return $row
    }
    $product = Read-ProductInput $Item $ItemId
    $download = $product.Reference
    try {
        $picked = @(Select-ProductReferences $product.Reference $Item.Handle $ItemId $product.Context)
        $request = New-ProductImageRequest $product.Reference $ItemId $product.Context $picked $Brands
        $bundle = Save-ProductReferenceBundle $Item $ItemId $product.Context $request $picked.Count
        $product.Reference = $bundle.ProductPath
        $reply = Complete-ProductImage $request $product.Context $ItemId
    } finally {
        # The downloaded original is archived as refs/<item>/NN-product; drop the loose copy.
        if ((Split-Path $download -Parent) -eq $script:Batch.Refs -and (Test-Path -LiteralPath $download)) { Remove-Item -LiteralPath $download -Force }
    }
    if ($reply -match '(?im)^BRAND:\s*(.+)$' -and $Matches[1].Trim() -notmatch '^(?i)none$') { [void]$Brands.Add($Matches[1].Trim()) }
    $body = New-Review $Item.Url $Item.Handle $request.Output $ItemId $product.Context
    # Local paths never stand in for failed uploads.
    $row=[pscustomobject][ordered]@{
        product_handle = $Item.Handle
        rating = ''
        author = ''
        email = ''
        body = $body
        created_at = ''
        verified_purchase = 'true'
        photo_url = $(if($script:Config.Drive -or $script:Config.DriveRequired){''}else{$request.Output -replace '\\','/'})
        photo_path = ($request.Output -replace '\\', '/')
    }
    Save-DeliveryCache $Item $ItemId $row
    return $row
}
