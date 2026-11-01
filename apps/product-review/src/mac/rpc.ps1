# App backend on macOS and Windows: the local web UI (src/mac/server.mjs) calls the application functions here.
# One JSON request per stdin line; each answer is one stdout line prefixed '@@RPC '.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$srcDir = Split-Path $PSScriptRoot -Parent
$root = Split-Path $srcDir -Parent
. (Join-Path $srcDir 'application/workspace.ps1')
. (Join-Path $srcDir '../../../hub/setup/ai-settings.ps1')
. (Join-Path $srcDir '../../../hub/ai/common.ps1')
. (Join-Path $srcDir 'infrastructure/drive-storage.ps1')
$workspace = Initialize-ProjectWorkspace $root
. (Join-Path $srcDir 'infrastructure/source-catalog.ps1')
. (Join-Path $srcDir 'infrastructure/source-sync.ps1')
. (Join-Path $srcDir 'application/agent-lessons.ps1')
. (Join-Path $srcDir 'application/image-feedback.ps1')
. (Join-Path $srcDir 'application/manual-references.ps1')
. (Join-Path $srcDir 'application/batch-import.ps1')
. (Join-Path $srcDir 'infrastructure/csv.ps1')
. (Join-Path $srcDir 'application/batch-review.ps1')
. (Join-Path $srcDir 'application/progress.ps1')
$mapPath = Join-Path $workspace.Root 'reference-inputs/references.json'
$libraryRoot = Join-Path $root 'data/source-photos'

function Test-HttpUrl([string]$Url) { $uri = $null; [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https') }
function Get-EntryInfo([string]$MapFile, [string]$Url) {
    $entry = @((Read-ManualReferenceMap $MapFile).entries | Where-Object product_url -eq $Url)
    $image = { param($file) [pscustomobject]@{ file = [string]$file; ok = [bool]($file -and (Test-Path -LiteralPath $file)) } }
    $products = @(if ($entry.Count) { Get-ManualProducts $entry[0] | ForEach-Object { [pscustomobject]@{ file = $_.file; ok = (& $image $_.file).ok; scenes = @($_.scenes | ForEach-Object { & $image $_.file }) } } })
    [pscustomobject]@{ url = $Url; products = $products; scenes = @($products | ForEach-Object { @($_.scenes) }) }
}
function Assert-DraftRoot([string]$Path) {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $Path -or -not [IO.Path]::GetFullPath($Path).StartsWith($temp) -or (Split-Path $Path -Leaf) -notmatch '^product-reference-[0-9a-f]{32}$') { throw 'Invalid draft.' }
}

function Invoke-Rpc([string]$Cmd, $A) {
    switch ($Cmd) {
        'state' {
            $map = Read-ManualReferenceMap $mapPath
            $urls = @(if (Test-Path $workspace.Queue) { Get-Content $workspace.Queue -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique })
            $version = try { Get-AppVersion $root } catch { '' }
            return [pscustomobject]@{
                rows = @($urls | ForEach-Object { Get-EntryInfo $mapPath $_ }); group = $map.preferred_source_group
                drive = [bool](Test-Path -LiteralPath (Get-SharedConfigPath $workspace.Root 'drive.json'))
                version = $version; output = $workspace.Output; codex = [bool](Get-Command codex -ErrorAction SilentlyContinue)
            }
        }
        'rows' { return @(@($A.urls) | ForEach-Object { Get-EntryInfo $mapPath ([string]$_) }) }
        'groups' { return @(if ($A.local) { Get-SourcePhotoGroups $libraryRoot } else { Get-SourceGroupChoices $root }) }
        'sourceFiles' { return (Get-SourcePickerFiles (Get-DriveConfig $workspace.Root) $libraryRoot ([string]$A.group)) }
        'quotaSummary' { . (Join-Path $srcDir '../../../hub/setup/quota.ps1'); return (Get-QuotaSummary) }
        'aiModels' { return [pscustomobject]@{ settings = (Get-AiSettings $root); models = @(Get-AiModels) } }
        'aiSettingsSet' { Set-AiSettings $root ([string]$A.model) ([string]$A.effort); return $true }
        'sourceDefault' { return (Get-DefaultSourceGroup $root) }
        'sourceDefaultSet' { Set-DefaultSourceGroup $root ([string]$A.group); return $true }
        'sourceIndexedFiles' { return @(Get-SourceIndexedFiles $libraryRoot ([string]$A.group)) }
        'sourcePick' { return @(Save-SourceGroupFiles $libraryRoot ([string]$A.group) @($A.files)) }
        'sourceLocalFiles' { return @(Get-LocalSourceFiles $libraryRoot ([string]$A.group)) }
        'reviewFolder' {
            # "+ Máy" opens this app's own library: the group used last, else data/source-photos.
            $group = if ($A.group) { Join-Path $libraryRoot ([string]$A.group).Normalize([Text.NormalizationForm]::FormC) } else { '' }
            return $(if ($group -and (Test-Path -LiteralPath $group)) { $group } else { $libraryRoot })
        }
        'sourceDir' { return (Get-SourcePhotoDirectory $libraryRoot ([string]$A.group)) }
        'draftOpen' {
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('product-reference-' + [Guid]::NewGuid().ToString('N'))
            $draftMap = Join-Path $temp 'workspace/reference-inputs/references.json'
            New-Item -ItemType Directory -Path (Split-Path $draftMap -Parent) -Force | Out-Null
            Write-FeedbackJson $draftMap (Read-ManualReferenceMap $mapPath)
            return $temp
        }
        'draftInfo' { Assert-DraftRoot $A.root; return (Get-EntryInfo (Join-Path $A.root 'workspace/reference-inputs/references.json') ([string]$A.url)) }
        'draftAttach' {
            Assert-DraftRoot $A.root
            $url = [string]$A.url
            if ($A.role -eq 'Product' -and -not $url) { $url = 'https://local.invalid/products/manual-' + [Guid]::NewGuid().ToString('N') }
            if (-not (Test-HttpUrl $url)) { throw 'Dán link hợp lệ trước khi thêm ảnh.' }
            $productIndex = if ($null -ne $A.productIndex) { [int]$A.productIndex } else { -1 }
            foreach ($path in @($A.paths)) { [void](Save-ManualReference $A.root $url ([string]$path) $(if ($A.role -eq 'Product') { 'Product' } else { 'Scene' }) $productIndex) }
            return $url
        }
        'draftRemoveScene' { Assert-DraftRoot $A.root; Remove-ManualScene (Join-Path $A.root 'workspace/reference-inputs/references.json') ([string]$A.url) ([int]$A.index) ([int]$A.productIndex); return $true }
        'draftRemoveProduct' { Assert-DraftRoot $A.root; Remove-ManualProduct (Join-Path $A.root 'workspace/reference-inputs/references.json') ([string]$A.url) ([int]$A.productIndex); return $true }
        'draftSave' {
            # Same rules as Save-ProductQueueDraft in the Windows window.
            Assert-DraftRoot $A.root
            $url = ([string]$A.url).Trim()
            if (-not (Test-HttpUrl $url)) { throw 'Link sản phẩm không hợp lệ.' }
            if ($url -in @($A.others)) { throw 'Link này đã có trong danh sách.' }
            $entry = @((Read-ManualReferenceMap (Join-Path $A.root 'workspace/reference-inputs/references.json')).entries | Where-Object product_url -eq $url)
            $map = Read-ManualReferenceMap $mapPath; $map.entries = @($map.entries | Where-Object product_url -ne $url)
            New-Item -ItemType Directory -Path (Split-Path $mapPath -Parent) -Force | Out-Null
            Write-FeedbackJson $mapPath $map
            if ($entry.Count) { Copy-ManualEntry $root $url $entry[0] }
            Remove-Item -LiteralPath $A.root -Recurse -Force -ErrorAction SilentlyContinue
            return (Get-EntryInfo $mapPath $url)
        }
        'draftDiscard' { Assert-DraftRoot $A.root; Remove-Item -LiteralPath $A.root -Recurse -Force -ErrorAction SilentlyContinue; return $true }
        'queueSave' {
            # Same rules as Save-ProductQueueEditor in the Windows window.
            $all = @(@($A.urls) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            $duplicates = @($all | Group-Object | Where-Object Count -gt 1)
            if ($duplicates.Count) { throw "Link bị trùng ở nhiều dòng: $($duplicates[0].Name). Mỗi link chỉ nên có một dòng." }
            $urls = @($all | Select-Object -Unique)
            foreach ($url in $urls) { if (-not (Test-HttpUrl $url)) { throw "Link không hợp lệ: $url" } }
            $map = Read-ManualReferenceMap $mapPath; $map.allow_library_fallback = $false
            if ($A.requireReady) {
                foreach ($url in $urls) {
                    $entry = @($map.entries | Where-Object product_url -eq $url)
                    $scenes = @(if ($entry.Count) { Get-ManualScenes $entry[0] })
                    if (-not $scenes.Count) { throw "Chưa có ảnh review: $url" }
                    if (@(Get-ManualProducts $entry[0] | Where-Object { -not @($_.scenes).Count }).Count) { throw "Có ảnh gốc chưa gắn ảnh review: $url" }
                    foreach ($scene in $scenes) {
                        if (-not (Test-Path -LiteralPath $scene.file)) { throw "Chưa có ảnh bối cảnh: $url" }
                        if ((Get-BytesHash ([IO.File]::ReadAllBytes($scene.file))) -ine $scene.sha256) { throw "Ảnh đã thay đổi; hãy gắn lại cho link: $url" }
                    }
                }
            }
            New-Item -ItemType Directory -Path (Split-Path $mapPath -Parent) -Force | Out-Null
            Write-FeedbackJson $mapPath $map
            [IO.File]::WriteAllLines($workspace.Queue, [string[]]$urls, [Text.UTF8Encoding]::new($true))
            return $urls.Count
        }
        'rejectedCount' { return @(Get-UnsentRejectedSamples $root).Count }
        'pruneMap' { Remove-ManualEntriesExcept $mapPath @(if (Test-Path $workspace.Queue) { Get-Content $workspace.Queue -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ } }); return $true }
        # Nhập hàng loạt: problems by line, the links, and whether any row brings images (then src/import-batch.ps1 runs).
        'importParse' {
            $parsed = ConvertFrom-ProductBatch ([string]$A.text) ([string]$A.folder)
            return @{ errors = @($parsed.Errors); links = @($parsed.Rows | ForEach-Object Url | Select-Object -Unique); images = [bool]@($parsed.Rows | Where-Object { $_.Product -or @($_.Reviews).Count }).Count }
        }
        'importArchive' { $folder = Expand-ProductBatchArchive ([string]$A.path) (Split-Path -Parent ([string]$A.path)); $csv = Get-ChildItem -LiteralPath $folder -Filter *.csv -File | Sort-Object { $_.Name -ne 'products.csv' } | Select-Object -First 1; return @{ folder = $folder; text = [IO.File]::ReadAllText($csv.FullName) } }
        'importFile' { return [IO.File]::ReadAllText([string]$A.path) }
        'parseLinks' {
            $urls = @(([string]$A.text) -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique)
            foreach ($url in $urls) { if (-not (Test-HttpUrl $url)) { throw "Link không hợp lệ: $url" } }
            return $urls
        }
        'pending' { return (Get-PendingReviewCount ([string]$A.batch)) }
        'reviewBatches' {
            if (-not (Test-Path -LiteralPath $workspace.Output)) { return @() }
            return @(Get-ChildItem -LiteralPath $workspace.Output -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'results.json') } | Sort-Object Name -Descending | Select-Object -First 30 | ForEach-Object {
                    [pscustomobject]@{ label = $_.Name + $(if (Test-Path -LiteralPath (Join-Path $_.FullName 'loox_import.csv')) { '  • đã xuất' } else { '' }); path = $_.FullName }
                })
        }
        'reviewItems' {
            return @(Get-BatchReview ([string]$A.batch) | ForEach-Object {
                    [pscustomobject]@{ id = $_.Id; handle = [string]$_.Row.product_handle; body = [string]$_.Row.body; image = $_.ImagePath; product = $_.ProductPath; scene = $_.ScenePath; decision = $_.Decision }
                })
        }
        'reviewDecide' { Set-BatchReviewDecision ([string]$A.batch) ([string]$A.id) ([string]$A.decision) -Reason ([string]$A.reason); return $true }
        'reviewExport' { return (Export-ReviewedCsv ([string]$A.batch)) }
        'driveLogin' { Connect-DriveAccount $workspace.Root ([string]$A.password); return $true }
        'driveLogout' { Disconnect-DriveAccount $workspace.Root; return $true }
        'event' { return (ConvertTo-UiEvent ([string]$A.line) ([int]$A.index)) }
        'updateCheck' { return (& (Join-Path (Get-HubRoot $root) 'hub/update.ps1') -Root (Get-HubRoot $root) -Check) }
        'openPath' { $p = [string]$A.path; New-Item -ItemType Directory -Force $p -ErrorAction SilentlyContinue | Out-Null; Open-SystemPath $p; return $true }
        'revealPath' { if ($script:OnWindows) { Start-Process explorer.exe -ArgumentList ('/select,"' + [string]$A.path + '"') } else { & open -R ([string]$A.path) }; return $true }
        default { throw "Unknown command: $Cmd" }
    }
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    $request = $line | ConvertFrom-Json
    try { $answer = @{ id = $request.id; ok = $true; result = (Invoke-Rpc $request.cmd $request.args) } }
    catch { Write-AppError $workspace.Logs "Mac rpc $($request.cmd)" $_; $answer = @{ id = $request.id; ok = $false; error = $_.Exception.Message } }
    [Console]::Out.WriteLine('@@RPC ' + ($answer | ConvertTo-Json -Depth 8 -Compress))
    [Console]::Out.Flush()
}
