# Tools Hub layout: hub/ is shared, each tool is apps/<id>/ with its tool.json, src/, data/, AGENTS.md and workspace/.
# The hub's own state (installed version, update backups) is in workspace/ at the root.

function Get-HubTools([string]$Root) {
    $apps = Join-Path $Root 'apps'
    if (-not (Test-Path -LiteralPath $apps)) { return @() }
    $tools = @(foreach ($file in @(Get-ChildItem -LiteralPath $apps -Filter tool.json -Recurse -Depth 1 -File | Sort-Object FullName)) {
        $tool = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $tool | Add-Member -NotePropertyName Root -NotePropertyValue $file.DirectoryName -Force
        $tool
    })
    # "order" in tool.json sets the picker's order; tools without it follow, by folder name.
    return @($tools | Sort-Object { if ($null -ne $_.order) { [int]$_.order } else { 99 } }, Root)
}

# Before Tools Hub the app lived at the root (src/, data/, AGENTS.md, workspace/). An install updated from such a
# version gets the new files beside the old ones; this moves its data into apps/product-review/ and removes the old
# files. Kept at the root: src/gui.ps1 and src/mac/server.mjs, which old shortcuts and the old updater still open.
# A git checkout is never touched.
function Move-LegacyLayout([string]$Root) {
    $app = Join-Path $Root 'apps/product-review'
    if ((Test-Path -LiteralPath (Join-Path $Root '.git')) -or -not (Test-Path -LiteralPath (Join-Path $app 'tool.json'))) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'src/ui/main-window.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $Root 'data'))) { return }
    $move = {
        param($From, $To)
        if (-not (Test-Path -LiteralPath $From)) { return }
        if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Force -Path (Split-Path $To -Parent) | Out-Null; Move-Item -LiteralPath $From -Destination $To; return }
        if ((Test-Path -LiteralPath $From -PathType Container) -and (Test-Path -LiteralPath $To -PathType Container)) {
            foreach ($child in @(Get-ChildItem -LiteralPath $From -Force)) { & $move $child.FullName (Join-Path $To $child.Name) }
            if (-not @(Get-ChildItem -LiteralPath $From -Force).Count) { Remove-Item -LiteralPath $From -Force }
        }
    }
    # The tool's data, login and logs; the version stays with the hub.
    $workspace = Join-Path $Root 'workspace'
    if (Test-Path -LiteralPath $workspace) {
        foreach ($child in @(Get-ChildItem -LiteralPath $workspace -Force | Where-Object Name -notin @('version.txt', 'backups'))) { & $move $child.FullName (Join-Path $app "workspace/$($child.Name)") }
    }
    # This machine's lessons: the old root AGENTS.md is merged into the tool's, as an update would.
    $oldAgents = Join-Path $Root 'AGENTS.md'
    if ((Test-Path -LiteralPath $oldAgents) -and ([IO.File]::ReadAllText($oldAgents)).Contains('<!-- app-lessons:start -->')) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('tools-hub-lessons-' + [Guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path $temp | Out-Null
            Copy-Item -LiteralPath (Join-Path $app 'AGENTS.md') -Destination (Join-Path $temp 'AGENTS.md')
            Copy-Item -LiteralPath $oldAgents -Destination (Join-Path $app 'AGENTS.md') -Force
            Merge-AgentInstructions $temp $app
            Remove-Item -LiteralPath $oldAgents -Force
        } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Downloaded sample photos and the installed bridge, so neither has to be fetched again.
    $photos = Join-Path $Root 'data/source-photos'
    if (Test-Path -LiteralPath $photos) {
        foreach ($group in @(Get-ChildItem -LiteralPath $photos -Directory -Force)) { & $move $group.FullName (Join-Path $app "data/source-photos/$($group.Name)") }
    }
    & $move (Join-Path $Root 'bridge/node_modules') (Join-Path $Root 'hub/bridge/node_modules')
    foreach ($old in @('data', 'tests', 'tools', 'bridge', 'extension', 'test.cmd', 'test.sh', 'setup.cmd', 'setup.command')) {
        Remove-Item -LiteralPath (Join-Path $Root $old) -Recurse -Force -ErrorAction SilentlyContinue
    }
    $keep = @('gui.ps1', 'mac/server.mjs')
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring((Join-Path $Root 'src').Length + 1) -replace '\\', '/'
        if ($relative -notin $keep) { Remove-Item -LiteralPath $file.FullName -Force }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not @(Get-ChildItem -LiteralPath $dir.FullName -Force).Count) { Remove-Item -LiteralPath $dir.FullName -Force }
    }
}

# The bridge and the Chrome extension were each tool's (apps/<id>/bridge, apps/<id>/extension) before they became the
# hub's (hub/bridge, hub/extension), shared by every tool. An install updated from then: the installed package moves to
# hub/bridge (not fetched again) and the tool's copies go. A git checkout is never touched.
function Move-SharedBrowserParts([string]$Root) {
    if ((Test-Path -LiteralPath (Join-Path $Root '.git')) -or -not (Test-Path -LiteralPath (Join-Path $Root 'hub/bridge/package.json'))) { return }
    foreach ($tool in @(Get-ChildItem -LiteralPath (Join-Path $Root 'apps') -Directory -ErrorAction SilentlyContinue)) {
        $modules = Join-Path $tool.FullName 'bridge/node_modules'
        if ((Test-Path -LiteralPath $modules) -and -not (Test-Path -LiteralPath (Join-Path $Root 'hub/bridge/node_modules'))) { Move-Item -LiteralPath $modules -Destination (Join-Path $Root 'hub/bridge/node_modules') }
        Remove-Item -LiteralPath (Join-Path $tool.FullName 'bridge') -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath (Join-Path $Root 'hub/extension/manifest.json')) { Remove-Item -LiteralPath (Join-Path $tool.FullName 'extension') -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Files of an older layout that Cập nhật does not bring any more (it only adds and replaces): the AI calls moved from
# Product Review to hub/ai, the extension's site scripts to hub/extension/sites. A git checkout is never touched.
$script:MovedFiles = @(
    'hub/extension/popup.js'
    'apps/product-review/src/infrastructure/codex.ps1'
    'apps/product-review/src/infrastructure/browser-bridge.ps1'
    'apps/product-review/src/infrastructure/antigravity.ps1'
    'apps/product-review/src/infrastructure/platform.ps1'
    'apps/product-review/src/application/missing-data.ps1'
    'apps/product-review/tests/scene-selection.ps1'
    'apps/product-review/src/workflow/steps/01-load-product.ps1'
    'apps/product-review/src/workflow/steps/02-select-references.ps1'
    'apps/product-review/src/workflow/steps/03-create-image.ps1'
    'apps/product-review/src/workflow/steps/04-complete-image.ps1'
    'apps/product-review/src/workflow/steps/05-write-review.ps1'
    'apps/product-review/src/workflow/steps/06-complete-metadata.ps1'
    'apps/product-review/src/workflow/steps/07-export-results.ps1'
    'apps/product-review/data/review-style.json'
    'hub/extension/content-common.js'
    'hub/extension/content-chatgpt.js'
    'hub/extension/content-flow.js'
    'hub/extension/content-gemini.js'
    # Grok Video Prompt became Grok Video: its prompt library is gone.
    'apps/grok-video-prompt/data/prompts.js'
    'apps/grok-video-prompt/data/demo-prompts.js'
    # Each tool owns its image rules, angle library and watermark now (hub/image is gone).
    'hub/image/angles.json'
    'hub/image/product-details.ps1'
    'hub/image/product-rules.ps1'
    'hub/image/unsparkle.mjs'
    'hub/image/unsparkle.ps1'
    'hub/image/watermark.mjs'
    'hub/image/watermark.ps1'
    'hub/media/ffmpeg.ps1'
    'hub/tests/watermark.test.mjs'
    'hub/tests/unsparkle.test.mjs'
)
function Remove-MovedFiles([string]$Root) {
    if ((Test-Path -LiteralPath (Join-Path $Root '.git')) -or -not (Test-Path -LiteralPath (Join-Path $Root 'hub/ai/ai.ps1'))) { return }
    foreach ($file in $script:MovedFiles) { Remove-Item -LiteralPath (Join-Path $Root $file) -Force -ErrorAction SilentlyContinue }
}
