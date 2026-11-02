# Step 1: check the job, then read what each color of a product looks like. A product has colors; a color has its product
# photo and, optionally, scene photos (rooms to place it in); every scene has the camera angles to shoot it from. A color
# with no scene photo uses its own product photo as the scene (the product already stands in a room). The product photo
# is the only source of the product's look, so a text AI describes it once per color (shape, supports, color per part)
# and that note rides with the image prompts. A failed description is a warning, not a stop.

# The scenes of a color: its scene photos, or its own product photo when it has none.
function Get-ColorScenes($Color) {
    $scenes = @($Color.scenes | Where-Object { $_ })
    if ($scenes.Count) {
        return @($scenes | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; path = [string]$_.path; angles = @($_.angles | ForEach-Object { [string]$_ }); self = $false } })
    }
    @([pscustomobject]@{ name = [string]$Color.product.name; path = [string]$Color.product.path; angles = @($Color.angles | ForEach-Object { [string]$_ }); self = $true })
}

function Test-ContentJob($Job) {
    $imageAis = @(Get-HubAIChoices 'image' | ForEach-Object id)
    $textAis = @(Get-HubAIChoices 'text' | ForEach-Object id)
    if ($Job.imageBackend -notin $imageAis) { throw "Image AI must be one of: $($imageAis -join ', ')." }
    if ($Job.textBackend -notin $textAis) { throw "Text AI must be one of: $($textAis -join ', ')." }
    [void](Get-PostTone ([string]$Job.tone))
    if (-not @($Job.platforms).Count) { throw 'Choose at least one platform.' }
    foreach ($id in @($Job.platforms)) { [void](Get-PostPlatform ([string]$id)) }
    if (-not @($Job.products).Count) { throw 'Add at least one product.' }
    $n = 0
    foreach ($product in @($Job.products)) {
        $n++
        if (-not ([string]$product.name).Trim()) { throw "Product #$n has no name." }
        if (-not @($product.colors).Count) { throw "Product #$n has no product photo." }
        $c = 0
        foreach ($color in @($product.colors)) {
            $c++
            $where = "Product #${n}, color #${c}"
            if (-not (Test-ImageFile ([string]$color.product.path))) { throw "${where}: the product photo $($color.product.name) is missing or not a readable image." }
            foreach ($scene in @(Get-ColorScenes $color)) {
                if (-not (Test-ImageFile $scene.path)) { throw "${where}: the photo $($scene.name) is missing or not a readable image." }
                try { [void](Get-ContentAngles $scene.angles) }
                catch { throw "${where}: $($scene.name): $($_.Exception.Message)" }
            }
        }
    }
}

# What the product in this color's photo looks like, as the image rules' text note.
function Resolve-ProductDetails($Product, $Color, [int]$ColorNo, [string]$Folder) {
    Write-Host "  [DETAILS] Reading the product photo of color $ColorNo..." -ForegroundColor Cyan
    try {
        $raw = Invoke-AI (Get-HubImageDetailsPrompt ([string]$Product.name)) @([string]$Color.product.path) (Join-Path $Folder "logs/details-$ColorNo.txt")
        $json = [regex]::Match([string]$raw, '\{[\s\S]*\}').Value
        $result = $json | ConvertFrom-Json
        if ($result.error -or -not $result.details) { throw 'The photo does not show an identifiable product.' }
        return [string]$result.details
    } catch {
        Write-Host "  [DETAILS] Skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        Send-Event @{ kind = 'warning'; product = $Product.id; message = "Chưa đọc được chi tiết sản phẩm từ ảnh màu ${ColorNo}: $($_.Exception.Message)" }
        return ''
    }
}

# What a scene photo already holds of the product's kind (the item to be replaced), in words, so the image prompt can name it:
# the image AI keeps a room's own table unless it is told which one to delete. Returns '' when the room has none or the
# photo could not be read (a warning, never a stop).
function Resolve-SceneNote($Product, $Scene, [int]$SceneNo, [string]$Folder) {
    Write-Host "  [SCENE] Reading the scene photo $SceneNo..." -ForegroundColor Cyan
    $prompt = @"
TASK: Look at the room photograph in image 1. A "$([string]$Product.name)" will be placed in this room in place of the furniture of the same kind.
STEP 1 - Find the furniture in the photograph that is the same kind as a "$([string]$Product.name)", and the chairs or seats grouped with it.
STEP 2 - For each item give its type, the shape of its top or seat, the shape of its base or legs, its color, and where it stands in the photograph. Name only what is visible.
STEP 3 - If the room has no furniture of that kind, the answer is none.
Reply with JSON only: {"old_items": "one or two sentences, or none"}
"@
    try {
        $raw = Invoke-AI $prompt @([string]$Scene.path) (Join-Path $Folder "logs/canh-$SceneNo-note.txt")
        $items = ([string]([regex]::Match([string]$raw, '\{[\s\S]*\}').Value | ConvertFrom-Json).old_items).Trim()
        if (-not $items -or $items -match '^(none|no\b|không)') { return '' }
        return $items
    } catch {
        Write-Host "  [SCENE] Skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        return ''
    }
}
