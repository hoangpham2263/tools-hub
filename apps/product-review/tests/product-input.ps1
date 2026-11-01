$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/workflow/steps/01-load-inputs.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$script:Downloads = 0
$script:TestHtml = '<link href="https://shop.example/password" rel="canonical"><meta property="og:image" content="https://shop.example/logo.jpg">'
function Invoke-WebRequest($Uri, [switch]$UseBasicParsing, $TimeoutSec, $OutFile) {
    if ($OutFile) { $script:Downloads++; return }
    return @{ Content = $script:TestHtml }
}
$script:Batch = @{ Refs = 'unused' }
$blocked = $false
try { Get-Reference 'https://shop.example/products/table' '001' | Out-Null }
catch { if ($_.Exception.Message -notmatch '\[CAUSE:STORE_LOCKED\]') { throw }; $blocked = $true }
Assert ($blocked -and $script:Downloads -eq 0) 'Password page logo was used as product image.'
Assert (Test-StorefrontPasswordPage '<main data-page-type="password">' 'https://shop.example/') 'Shopify password marker missed.'
Assert (Test-StorefrontPasswordPage '' 'https://shop.example/password?return_url=product') 'Password redirect missed.'
Assert (-not (Test-StorefrontPasswordPage '<a href="/password">Admin</a><input type="password">' 'https://shop.example/products/table')) 'Ordinary password text blocked a product.'
$script:TestHtml = '<meta content="//cdn.example/table.jpg" property="og:image">'
$reference = Get-Reference 'https://shop.example/products/table' '001'
Assert ($script:Downloads -eq 1 -and $reference -like '*001.jpg') 'Public product stopped loading.'
$script:TestHtml = '<html><title>Product without photo</title></html>'
$missing = $false
try { Get-Reference 'https://shop.example/products/table' '001' | Out-Null } catch { $missing = $_.Exception.Message -like 'No product reference found:*' }
Assert $missing 'Missing product image was confused with store password.'
Write-Host 'PASS: Shopify password gates, redirect/HTML detection, no logo download, public product loading and missing-image distinction.'
# Page and CDN timeouts both retry; permanent failures stop without extra requests.
$script:RequestCalls = 0
$script:FailuresLeft = 1
$script:Permanent = $false
function Start-Sleep($Seconds) {}
function Invoke-WebRequest($Uri, [switch]$UseBasicParsing, $TimeoutSec, $OutFile) {
    $script:RequestCalls++
    Assert ($TimeoutSec -eq 30) 'Product request timeout is not configured.'
    if ($script:Permanent) { throw [InvalidOperationException]::new('Bad response') }
    if ($script:FailuresLeft -gt 0) { $script:FailuresLeft--; throw [TimeoutException]::new('The operation has timed out.') }
    return @{ Content = '<meta property="og:image" content="https://cdn.example/table.jpg">' }
}
$page = Get-ProductResource 'https://shop.example/products/table'
Assert ($script:RequestCalls -eq 2 -and $page.Content) 'Transient page failure was not recovered.'
$script:RequestCalls = 0; $script:FailuresLeft = 1
Get-ProductResource 'https://cdn.example/table.jpg' 'unused.jpg' | Out-Null
Assert ($script:RequestCalls -eq 2) 'Transient image failure was not recovered.'
$script:RequestCalls = 0; $script:FailuresLeft = 5
$failed = $false
try { Get-ProductResource 'https://shop.example/products/table' | Out-Null }
catch { $failed = $_.Exception.Message -match '\[CAUSE:PRODUCT_TIMEOUT\]' }
Assert ($failed -and $script:RequestCalls -eq 3) 'Timeout retries were not bounded or lacked a user-facing cause.'
$script:RequestCalls = 0; $script:Permanent = $true
$failed = $false
try { Get-ProductResource 'https://shop.example/products/table' | Out-Null }
catch { $failed = $_.Exception.Message -match '\[CAUSE:PRODUCT_DOWNLOAD\]' }
Assert ($failed -and $script:RequestCalls -eq 1) 'Permanent download failure was retried.'
Write-Host 'PASS: transient product page/image retries, 30-second timeout, bounded failure and permanent errors.'
