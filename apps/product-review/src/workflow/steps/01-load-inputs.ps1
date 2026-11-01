# Step 1: the inputs. The product image (attached, else the link's og:image) and its classification by the text AI,
# then the review photo the user attached.

# A successful HTTP response can still be Shopify's password gate, not the product.
function Test-StorefrontPasswordPage([string]$Html, [string]$FinalUrl) {
    $uri = $null
    if ([Uri]::TryCreate($FinalUrl, [UriKind]::Absolute, [ref]$uri) -and $uri.AbsolutePath.TrimEnd('/') -eq '/password') { return $true }
    if ($Html -match '(?i)data-page-type\s*=\s*["'']password["'']') { return $true }
    foreach ($tag in [regex]::Matches($Html, '(?is)<link\b[^>]*>')) {
        $attrs = @{}
        foreach ($attr in [regex]::Matches($tag.Value, '(?is)([\w:-]+)\s*=\s*["'']([^"'']*)["'']')) {
            $attrs[$attr.Groups[1].Value.ToLowerInvariant()] = [Net.WebUtility]::HtmlDecode($attr.Groups[2].Value)
        }
        if ($attrs.rel -eq 'canonical' -and $attrs.href) {
            try { $canonical = [Uri]::new([Uri]$FinalUrl, $attrs.href) } catch { continue }
            if ($canonical.AbsolutePath.TrimEnd('/') -eq '/password') { return $true }
        }
    }
    return $false
}
# Product reference image. Dot-sourced by run-images.ps1.
# Reads: $script:Batch.Refs

# Retry transient page/CDN failures without consuming an AI turn.
function Get-ProductResource([string]$Url, [string]$OutFile = '') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $request = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = 30; ErrorAction = 'Stop' }
            if ($OutFile) { $request.OutFile = $OutFile }
            return Invoke-WebRequest @request
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            }
            $networkStatus = [string]$_.Exception.Status
            $timeout = $_.Exception -is [TimeoutException] -or $networkStatus -eq 'Timeout' -or $_.Exception.Message -match '(?i)timed out|timeout'
            $network = $networkStatus -in @('ConnectFailure', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectionClosed', 'ReceiveFailure', 'SendFailure', 'KeepAliveFailure')
            $transient = $timeout -or $network -or $statusCode -in @(408, 429, 500, 502, 503, 504)
            if ($transient -and $attempt -lt 3) {
                Write-Host "  [DOWNLOAD-RETRY] Attempt $($attempt + 1)/3..." -ForegroundColor Cyan
                Start-Sleep -Seconds $attempt
                continue
            }
            $cause = if ($timeout -or $statusCode -eq 408 -or $statusCode -eq 504) { 'PRODUCT_TIMEOUT' }
                elseif ($statusCode -in @(401, 403)) { 'PRODUCT_ACCESS' }
                elseif ($statusCode -eq 404) { 'PRODUCT_NOT_FOUND' }
                elseif ($transient) { 'PRODUCT_NETWORK' } else { 'PRODUCT_DOWNLOAD' }
            throw "[CAUSE:$cause] Product page/image download failed. $($_.Exception.Message)"
        }
    }
}

# Download the product page's og:image into the batch refs folder. Returns the local path.
function Get-Reference([string]$Url, [string]$ItemId) {
    $page = Get-ProductResource $Url
    $html = [string]$page.Content
    $finalUrl = if ($page.BaseResponse.ResponseUri) { [string]$page.BaseResponse.ResponseUri } elseif ($page.BaseResponse.RequestMessage.RequestUri) { [string]$page.BaseResponse.RequestMessage.RequestUri } else { $Url }
    if (Test-StorefrontPasswordPage $html $finalUrl) {
        throw '[CAUSE:STORE_LOCKED] Storefront requires a password. Make the product publicly accessible before retrying.'
    }
    $imageUrl = ''
    foreach ($tag in [regex]::Matches($html, '(?is)<meta\b[^>]*>')) {
        if ($tag.Value -match '(?i)(?:property|name)\s*=\s*["'']og:image["'']' -and $tag.Value -match '(?i)content\s*=\s*["'']([^"'']+)["'']') {
            $imageUrl = [Net.WebUtility]::HtmlDecode($Matches[1]); break
        }
    }
    if (-not $imageUrl) { throw "No product reference found: $Url" }
    $resolved = [Uri]::new([Uri]$Url, $imageUrl)
    if ($resolved.Scheme -notin @('http', 'https')) { throw 'Invalid reference image URL.' }
    $reference = Join-Path $script:Batch.Refs "$ItemId.jpg"
    Get-ProductResource $resolved.AbsoluteUri $reference | Out-Null
    return $reference
}

function Read-ProductInput($Item, [string]$ItemId) {
    Write-Host '  [PRODUCT] Loading reference...' -ForegroundColor Cyan
    $manual=@($script:Config.ManualReferences.entries|Where-Object product_url -eq $Item.Url)
    # The product image of this job (one link can hold several), else the link's first one.
    $attached=if($Item.PSObject.Properties['Product']){$Item.Product}elseif($manual.Count){@(Get-ManualProducts $manual[0]|Where-Object file)|Select-Object -First 1}
    if($attached -and $attached.file){
        $source=$attached.file
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw '[CAUSE:PRODUCT_INPUT] Ảnh sản phẩm đã gắn bị thiếu. Hãy gắn lại ảnh.'}
        $bytes=[IO.File]::ReadAllBytes($source)
        if((Get-BytesHash $bytes) -ine $attached.sha256){throw '[CAUSE:PRODUCT_INPUT] Ảnh sản phẩm đã gắn bị thay đổi. Hãy gắn lại ảnh.'}
        $reference=Join-Path $script:Batch.Refs ($ItemId+'-manual-product'+[IO.Path]::GetExtension($source))
        [IO.File]::WriteAllBytes($reference,$bytes)
        Write-Host '  [PRODUCT-MANUAL] Using attached product image; no product URL request.' -ForegroundColor Cyan
    }else{
        if(([Uri]$Item.Url).Host -eq 'local.invalid'){throw '[CAUSE:PRODUCT_INPUT] Sản phẩm không có link cần được gắn ảnh sản phẩm gốc.'}
        $reference = Get-Reference $Item.Url $ItemId
    }
    [pscustomobject]@{
        Reference = $reference
        Context = Resolve-ProductContext $Item.Handle $reference $ItemId
    }
}

# The review photo the user attached to this link (computer, Drive library or clipboard), used as it is: no AI
# picks or checks it. A missing or changed one stops this link.
function Get-ReviewPhoto([string]$ItemId, $Context) {
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
