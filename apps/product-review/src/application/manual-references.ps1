function Read-ManualReferenceMap([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)){return [pscustomobject]@{schema_version=1;allow_library_fallback=$false;preferred_source_group='Áo';source_library='drive';entries=@()}}
    $map=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    if($map.schema_version -ne 1){throw 'Invalid manual reference map.'}
    if(-not $map.PSObject.Properties['preferred_source_group']){$map|Add-Member NoteProperty preferred_source_group 'Áo'}
    $map.preferred_source_group=Resolve-SourcePhotoGroup $map.preferred_source_group
    # drive: download the chosen group before a run; local: use only data/source-photos as it is.
    if(-not $map.PSObject.Properties['source_library'] -or $map.source_library -notin @('drive','local')){$map|Add-Member NoteProperty source_library 'drive' -Force}
    $seen=@{}
    foreach($entry in @($map.entries)){
        # A link holds one or more product images, each with its own review images; every
        # product + review pair becomes one generated image. Older maps (one product_file plus
        # scenes) load as a single product.
        $products=@(Get-ManualProducts $entry)
        $folder=Split-Path $Path -Parent
        foreach($product in $products){
            $product.file=Repair-ManualImagePath $product.file $folder
            foreach($scene in @($product.scenes)){$scene.file=Repair-ManualImagePath $scene.file $folder}
        }
        Set-ManualProducts $entry $products
        $scenes=@(Get-ManualScenes $entry)
        $uri=$null
        if(-not [Uri]::TryCreate($entry.product_url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or (-not $scenes.Count -and -not @($products|Where-Object file).Count) -or @($scenes|Where-Object{-not $_.file -or $_.sha256 -notmatch '^[a-f0-9]{64}$'}).Count -or @($products|Where-Object{$_.file -and $_.sha256 -notmatch '^[a-f0-9]{64}$'}).Count -or $seen.ContainsKey($entry.product_url)){throw 'Invalid or duplicate manual reference entry.'}
        $seen[$entry.product_url]=$true
    }
    return $map
}

# Images are saved next to the map with absolute paths; after the install folder moves (rename, the
# Tools Hub layout) those paths are stale, so an image missing at its path is looked up beside the map.
function Repair-ManualImagePath([string]$File,[string]$Folder) {
    if(-not $File -or (Test-Path -LiteralPath $File)){return $File}
    $local=Join-Path $Folder (Split-Path $File -Leaf)
    if(Test-Path -LiteralPath $local){return $local}
    return $File
}

# Product images of a link: { file (may be empty: product read from the page), sha256, scenes[] }.
function Get-ManualProducts($Entry) {
    if(-not $Entry){return @()}
    $copyScenes={param($list) @($list|Where-Object{$_}|ForEach-Object{[pscustomobject]@{file=$_.file;sha256=$_.sha256}})}
    if($Entry.PSObject.Properties['products'] -and @($Entry.products).Count){
        return @($Entry.products|ForEach-Object{[pscustomobject]@{file=[string]$_.file;sha256=[string]$_.sha256;scenes=@(& $copyScenes $_.scenes)}})
    }
    $scenes=@(if($Entry.PSObject.Properties['scenes'] -and @($Entry.scenes).Count){& $copyScenes $Entry.scenes}elseif($Entry.file){[pscustomobject]@{file=$Entry.file;sha256=$Entry.sha256}})
    if(-not $Entry.product_file -and -not $scenes.Count){return @()}
    return @([pscustomobject]@{file=[string]$Entry.product_file;sha256=[string]$Entry.product_sha256;scenes=$scenes})
}

# Stores products and mirrors the first product (product_file) and all review images (scenes, file)
# in the older fields, so earlier app versions still read a link.
function Set-ManualProducts($Entry,$Products) {
    $Products=@($Products|Where-Object{$_.file -or @($_.scenes).Count})
    $Entry|Add-Member NoteProperty products $Products -Force
    $first=@($Products|Where-Object file)|Select-Object -First 1
    if($first){$Entry|Add-Member NoteProperty product_file $first.file -Force;$Entry|Add-Member NoteProperty product_sha256 $first.sha256 -Force}
    else{foreach($name in 'product_file','product_sha256'){$Entry.PSObject.Properties.Remove($name)}}
    $scenes=@($Products|ForEach-Object{@($_.scenes)})
    $Entry|Add-Member NoteProperty scenes $scenes -Force
    if($scenes.Count){$Entry|Add-Member NoteProperty file $scenes[0].file -Force;$Entry|Add-Member NoteProperty sha256 $scenes[0].sha256 -Force}
    else{foreach($name in 'file','sha256'){$Entry.PSObject.Properties.Remove($name)}}
}

# Every review image of a link, across its product images.
function Get-ManualScenes($Entry) {
    return @(Get-ManualProducts $Entry|ForEach-Object{@($_.scenes)}|Where-Object{$_})
}

function Save-ManualMapEntry([string]$MapPath,$Map,$Entry) {
    $Map.entries=@($Map.entries|Where-Object{$_.product_url -ne $Entry.product_url -and (@(Get-ManualScenes $_).Count -or $_.product_file)})
    if(@(Get-ManualProducts $Entry).Count){$Map.entries=@($Map.entries)+@($Entry)}
    New-Item -ItemType Directory -Path (Split-Path $MapPath -Parent) -Force|Out-Null
    Write-FeedbackJson $MapPath $Map
}

# Removes one review image. ProductIndex picks the product image; -1 counts across the whole link.
function Remove-ManualScene([string]$MapPath,[string]$Url,[int]$Index,[int]$ProductIndex=-1) {
    $map=Read-ManualReferenceMap $MapPath
    foreach($entry in @($map.entries|Where-Object product_url -eq $Url)){
        $products=@(Get-ManualProducts $entry)
        $n=0
        for($p=0;$p -lt $products.Count;$p++){
            $kept=@()
            for($i=0;$i -lt @($products[$p].scenes).Count;$i++){
                $hit=if($ProductIndex -ge 0){$p -eq $ProductIndex -and $i -eq $Index}else{$n -eq $Index}
                if(-not $hit){$kept+=$products[$p].scenes[$i]}
                $n++
            }
            $products[$p].scenes=$kept
        }
        Set-ManualProducts $entry $products
        Save-ManualMapEntry $MapPath $map $entry
        return
    }
}

# Removes a product image together with its review images.
function Remove-ManualProduct([string]$MapPath,[string]$Url,[int]$ProductIndex) {
    $map=Read-ManualReferenceMap $MapPath
    foreach($entry in @($map.entries|Where-Object product_url -eq $Url)){
        $products=@(Get-ManualProducts $entry)
        Set-ManualProducts $entry @(for($p=0;$p -lt $products.Count;$p++){if($p -ne $ProductIndex){$products[$p]}})
        Save-ManualMapEntry $MapPath $map $entry
    }
}

# Product adds a product image; Scene adds a review image to product ProductIndex (-1: the last one).
function Save-ManualReference([string]$ProjectRoot,[string]$Url,[string]$ImagePath,[ValidateSet('Scene','Product')][string]$Role='Scene',[int]$ProductIndex=-1) {
    $uri=$null
    if(-not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https')){throw 'Invalid product URL.'}
    $extension=[IO.Path]::GetExtension($ImagePath).ToLowerInvariant()
    if($extension -notin @('.png','.jpg','.jpeg')){throw 'Choose a PNG or JPEG reference.'}
    $folder=Join-Path $ProjectRoot 'workspace/reference-inputs'
    New-Item -ItemType Directory -Path $folder -Force|Out-Null
    $mapPath=Join-Path $folder 'references.json'
    $map=Read-ManualReferenceMap $mapPath
    $dest=Join-Path $folder ([Guid]::NewGuid().ToString('N')+$extension)
    Copy-Item -LiteralPath $ImagePath -Destination $dest
    $existing=@($map.entries|Where-Object product_url -eq $Url)
    $entry=if($existing.Count){$existing[0]}else{[pscustomobject]@{product_url=$Url}}
    $products=[Collections.Generic.List[object]]::new();foreach($product in @(Get-ManualProducts $entry)){$products.Add($product)}
    $hash=Get-BytesHash ([IO.File]::ReadAllBytes($dest))
    # The same picture twice is kept once.
    if($Role -eq 'Product'){
        if(@($products|Where-Object sha256 -eq $hash).Count){Remove-Item -LiteralPath $dest -Force}
        else{$products.Add([pscustomobject]@{file=$dest;sha256=$hash;scenes=@()})}
    }else{
        if(-not $products.Count){$products.Add([pscustomobject]@{file='';sha256='';scenes=@()})}
        $target=if($ProductIndex -ge 0 -and $ProductIndex -lt $products.Count){$products[$ProductIndex]}else{$products[$products.Count-1]}
        if(@($target.scenes|Where-Object sha256 -eq $hash).Count){Remove-Item -LiteralPath $dest -Force}
        else{$target.scenes=@(@($target.scenes)+@([pscustomobject]@{file=$dest;sha256=$hash}))}
    }
    Set-ManualProducts $entry $products.ToArray()
    $entry|Add-Member NoteProperty origin 'user_reference' -Force
    $map.entries=@($map.entries|Where-Object product_url -ne $Url)+@($entry)
    Write-FeedbackJson $mapPath $map
    return $mapPath
}

# Copies a link's product and review images (from a draft map) into the project's map, in order.
function Copy-ManualEntry([string]$ProjectRoot,[string]$Url,$Entry) {
    $mapPath=Join-Path $ProjectRoot 'workspace/reference-inputs/references.json'
    foreach($product in @(Get-ManualProducts $Entry)){
        $target=-1
        if($product.file){
            [void](Save-ManualReference $ProjectRoot $Url $product.file Product)
            $saved=@(Get-ManualProducts @((Read-ManualReferenceMap $mapPath).entries|Where-Object product_url -eq $Url)[0])
            for($i=0;$i -lt $saved.Count;$i++){if($saved[$i].sha256 -eq $product.sha256){$target=$i}}
        }
        foreach($scene in @($product.scenes)){[void](Save-ManualReference $ProjectRoot $Url $scene.file Scene $target)}
    }
}

# After a run the queue keeps only unfinished links; drop the images of every link no longer queued
# so the list starts clean.
function Remove-ManualEntriesExcept([string]$MapPath,[string[]]$Urls) {
    if(-not (Test-Path -LiteralPath $MapPath)){return}
    $map=Read-ManualReferenceMap $MapPath
    $keep=@($map.entries|Where-Object{$_.product_url -in @($Urls)})
    if($keep.Count -eq @($map.entries).Count){return}
    $map.entries=$keep
    Write-FeedbackJson $MapPath $map
}

# A product link as the list shows it, short and readable: "shop.com › product-name" (the full link stays on hover).
function Format-ShortProductUrl([string]$Url) {
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $Url.Trim() }
    if ($uri.Host -eq 'local.invalid') { return 'Sản phẩm tự thêm (không có link)' }
    $site = $uri.Host -replace '^www\.', ''
    $slug = @($uri.AbsolutePath -split '/' | Where-Object { $_ })
    if (-not $slug.Count) { return $site }
    $name = [Uri]::UnescapeDataString($slug[-1]) -replace '\.(html?|php|aspx?)$', ''
    if ($name.Length -gt 48) { $name = $name.Substring(0, 47) + '…' }
    return "$site › $name"
}
