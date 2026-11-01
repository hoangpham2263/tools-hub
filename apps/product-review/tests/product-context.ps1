. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
$tempDir = Join-Path $TestWorkspaceRoot ('product-context-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$script:Config = @{ ProductContexts = @(Get-ProductContexts (Join-Path $root 'data/product-contexts.json')); ReviewStyles = @() }
$script:Batch = @{ Dir = $tempDir; Images = $tempDir; Logs = $tempDir; Refs = (Join-Path $tempDir "refs") }
$script:Config.SourceDir = $tempDir
$script:Config.WritingStyle = Get-WritingStyle (Join-Path $root 'data/writing-style.json')
'product' | Set-Content (Join-Path $tempDir 'actual-product.png')
'person' | Set-Content (Join-Path $tempDir 'person.png')
function Get-Reference($Url, $ItemId) { return (Join-Path $tempDir 'actual-product.png') }
# The review photo the user attached to this product.
function Select-ProductReferences($Reference, $Handle, $ItemId, $Context) { return (Join-Path $tempDir 'person.png') }
function Invoke-AI($PromptText, $Images, $ResultFile, $Sandbox) {
    if ($ResultFile -like '*-context.txt') {
        if($script:Classification){return $script:Classification}
        return '{"category_key":"apron","existing_profile":"apron","product":"bib apron","presentation":"worn","setting":"cafe","details":"Black bib, neck strap and front pockets","reject":"decorative gate","search_query":"apron cafe real photos"}'
    }
    if ($ResultFile -like '*-quality-*.txt') { throw 'Image QA must not run.' }
    if ($ResultFile -like '*-review.txt') {
        if ($PromptText -notmatch 'reviewed product is: bib apron' -or $PromptText -notmatch 'not the white T-shirt underneath') { throw 'Review is not focused on the apron.' }
        return 'The black bib keeps the simple front pockets easy to see.'
    }
    $script:ImageCalls++
    if ($PromptText -notmatch 'Scene guidance: Show one ordinary moment') { throw 'Missing natural scene guidance.' }
    if ($Images.Count -ne 2 -or $PromptText -notmatch 'Image 1 also supplies the real setting' -or $PromptText -notmatch 'Image 2 is the PRODUCT reference') { throw 'Scene fallback changed reference roles incorrectly.' }
    if ($PromptText -notmatch 'Never add GOLF' -or $PromptText -notmatch 'cafe service counter') { throw 'Apron context rules were not included.' }
    if ($PromptText -notmatch 'SINGLE-PASS DELIVERY') { throw 'Single-pass generation contract is missing.' }
    if ($PromptText -notmatch '(?m)^Save a new PNG at this exact path: (.+)$') { throw 'Missing output path.' }
    $imagePath=$Matches[1].Trim();New-TestPng $imagePath
    return 'BRAND: Cedar Kitchen'
}
try {
    if ((Get-ProductContext 'custom-bib-apron').id -ne 'apron' -or (Get-ProductContext 'bulk-polo-shirt').id -ne 'polo' -or (Get-ProductContext 'golf-polo').id -ne 'golf') { throw 'Incorrect product classification.' }
    $item = [pscustomobject]@{ Handle = 'custom-bib-apron'; Url = 'https://example.test/apron' }
    $brands = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    $script:QualityCalls = 0; $script:ImageCalls = 0; $script:AlwaysFail = $false
    $result = Invoke-ProductItem $item '001-apron' $brands
    if ($script:ImageCalls -ne 1 -or $script:QualityCalls -ne 0 -or $result.body -notmatch 'front pockets') { throw 'Single-pass image delivery or product review failed.' }
    $status=Get-Content (Join-Path $tempDir '001-apron-review-status.json') -Raw|ConvertFrom-Json
    if($status.status -ne 'awaiting_user_review' -or $status.ai_image_qa_performed){throw 'User review was misrepresented as AI approval.'}
    $script:Classification='{"category_key":"polo-shirts","existing_profile":"polo","product":"Striped polo shirt","presentation":"placed","setting":"Laid flat on a wooden table","details":"Back print and stripes visible; front fastening not visible","reject":"Do not introduce a wearer"}'
    $polo=Resolve-ProductContext 'polo' (Join-Path $tempDir 'actual-product.png') 'flat-polo'
    $request=New-ProductImageRequest (Join-Path $tempDir 'actual-product.png') 'flat-polo' $polo @((Join-Path $tempDir 'person.png')) $brands
    if($polo.presentation -ne 'worn' -or $request.Prompt -match 'IMMUTABLE BASE|wooden table|Do not introduce a wearer' -or $request.Prompt -notmatch 'REPLACE THE EXISTING GARMENT' -or $polo.details -notmatch 'front fastening not visible'){throw 'Flat apparel source still routes into a furniture scene or loses limits of visible design.'}
    $script:Classification='{"category_key":"coffee-table","existing_profile":"custom","product":"Low wooden table","presentation":"placed","setting":"Living room","details":"Low wood slab and legs","reject":"High dining chairs"}'
    $table=Resolve-ProductContext 'table' (Join-Path $tempDir 'actual-product.png') 'real-table'
    if($table.presentation -ne 'placed'){throw 'Apparel correction changed the presentation of actual furniture.'}
    Write-Host 'PASS: product contexts, single-pass delivery without visual QA, attached review photo and apron-focused reviews.' -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($tempDir)
    $allowed = [IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'product-context-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
