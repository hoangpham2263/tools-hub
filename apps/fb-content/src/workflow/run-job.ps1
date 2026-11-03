# One run: for every product in the job, read its photo, make the angles asked for, write a post per platform.
# Results go under <OutDir>/<stamp>/, one folder per product; the window follows the @@EVENT lines this prints.
# Returns the exit code: 0 when at least one product gave an image or a post.

function Invoke-ContentRun($Job, [string]$OutDir) {
    Test-ContentJob $Job
    # Verify: every picture is checked against the product photo and made again once when it is not the same product.
    $script:Config = @{ ImageBackend = [string]$Job.imageBackend; TextBackend = [string]$Job.textBackend; Verify = ([string]$Job.verify -ne 'false') }
    $folder = New-RunFolder $OutDir
    $script:Run = @{ Dir = $folder; Abort = $false; Watermark = [bool]$Job.watermark }
    $drive = Get-ContentDrive
    if (-not $drive) { Send-Event @{ kind = 'warning'; product = ''; message = 'Chưa đăng nhập Google Drive (nút Cấu hình) nên kết quả chỉ lưu trên máy.' } }
    $total = @($Job.products).Count
    Send-Event @{ kind = 'start'; folder = $folder; products = $total }

    $results = @()
    $index = 0
    foreach ($product in @($Job.products)) {
        if ($script:Run.Abort) { break }
        $index++
        $productFolder = Join-Path $folder ('{0:00}-{1}' -f $index, (ConvertTo-Slug ([string]$product.name)))
        New-Item -ItemType Directory -Force -Path (Join-Path $productFolder 'logs') | Out-Null
        Send-Event @{ kind = 'product'; id = $product.id; index = $index; name = $product.name; folder = $productFolder }
        Write-Host "[$index/$total] $($product.name)"
        $result = [ordered]@{ id = $product.id; name = $product.name; folder = $productFolder; images = @(); posts = [ordered]@{}; errors = @() }
        try {
            $pack = Get-BrandPack ([string]$product.brand)
            $detailsByColor = @{}
            $colorNo = 0
            foreach ($color in @($product.colors)) { $colorNo++; $detailsByColor[$colorNo] = Resolve-ProductDetails $product $color $colorNo $productFolder }
            $details = [string]$detailsByColor[1]
            $result.images = @(New-ContentImages $product $productFolder $detailsByColor)
            foreach ($shot in $result.images) { if (-not $shot.ok) { $result.errors += "Ảnh $($shot.color)-$($shot.scene)-$($shot.angle) ($($shot.angle_id)): $($shot.message)" } }
            foreach ($platformId in @($Job.platforms)) {
                try {
                    $post = Write-ProductPost $product $details $pack ([string]$platformId) ([string]$Job.tone) ([string]$Job.note) $productFolder
                    $file = Join-Path $productFolder "bai-$platformId.txt"
                    Write-Utf8 $file $post.text
                    $result.posts[[string]$platformId] = [ordered]@{ file = $file; text = $post.text; warnings = @($post.warnings) }
                    Send-Event @{ kind = 'post'; product = $product.id; platform = [string]$platformId; file = $file; text = $post.text; warnings = @($post.warnings) }
                } catch {
                    $result.errors += "Bài ${platformId}: $($_.Exception.Message)"
                    Send-Event @{ kind = 'post'; product = $product.id; platform = [string]$platformId; file = ''; text = ''; warnings = @(); error = $_.Exception.Message }
                }
            }
            $snapshot = [ordered]@{
                product = $product.name; brand = $product.brand; link = $product.link; tags = $product.tags
                tone = $Job.tone; note = $Job.note; platforms = @($Job.platforms)
                colors = @($product.colors | ForEach-Object {
                    $c = $_
                    [ordered]@{
                        name = $c.name; details = [string]$detailsByColor[[array]::IndexOf(@($product.colors), $c) + 1]
                        product = [ordered]@{ name = $c.product.name; bytes = (Get-Item -LiteralPath $c.product.path).Length; sha256 = (Get-FileSha256 $c.product.path) }
                        scenes = @(Get-ColorScenes $c | ForEach-Object { [ordered]@{ name = $_.name; self = $_.self; angles = @($_.angles); bytes = (Get-Item -LiteralPath $_.path).Length; sha256 = (Get-FileSha256 $_.path) } })
                    }
                })
            }
            Write-Utf8 (Join-Path $productFolder 'snapshot.json') (ConvertTo-Json -InputObject $snapshot -Depth 6)
        } catch {
            $result.errors += $_.Exception.Message
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
        if ($drive -and -not $script:Run.DriveOff) {
            try { Publish-FolderToDrive $drive $folder $productFolder | Out-Null }
            catch { $result.errors += $_.Exception.Message; Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red }
        }
        $result.ok = (@($result.images | Where-Object { $_.ok }).Count -gt 0) -or ($result.posts.Count -gt 0)
        $results += $result
        Send-Event @{ kind = 'product-done'; id = $product.id; ok = $result.ok; errors = @($result.errors) }
    }

    Write-Utf8 (Join-Path $folder 'results.json') (ConvertTo-Json -InputObject @($results) -Depth 8)
    if ($drive -and -not $script:Run.DriveOff) { try { Send-DriveToolFile $drive $script:DriveTool ((Split-Path $folder -Leaf) + '/results.json') (Join-Path $folder 'results.json') | Out-Null } catch { Write-Host "  [ERROR] Drive: results.json: $($_.Exception.Message)" -ForegroundColor Red } }
    $okCount = @($results | Where-Object { $_.ok }).Count
    Send-Event @{ kind = 'done'; folder = $folder; ok = $okCount; failed = ($total - $okCount); aborted = [bool]$script:Run.Abort }
    Write-Host "Done: $okCount/$total products. Results: $folder"
    if ($okCount -eq 0) { return 1 }
    return 0
}
