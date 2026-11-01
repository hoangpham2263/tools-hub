. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root '../../hub/update.ps1') -NoRun
$root=Split-Path $PSScriptRoot -Parent  # update.ps1's -Root param shares the name
. (Join-Path $root 'src/application/agent-lessons.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
$temp=Join-Path $TestWorkspaceRoot ('app-update-'+[Guid]::NewGuid().ToString('N'))
try{
    $new=Join-Path $temp 'new';$app=Join-Path $temp 'app'
    # Copy-AppUpdate works on the whole hub: each tool keeps its own AGENTS.md and workspace, the hub its workspace.
    $hubNew=Join-Path $temp 'hub-new';$hubOld=Join-Path $temp 'hub-old'
    foreach($p in @("$hubNew/apps/t/src/gui.ps1","$hubNew/apps/t/AGENTS.md","$hubNew/apps/t/workspace/drive.json","$hubNew/workspace/version.txt","$hubNew/hub/update.ps1","$hubOld/apps/t/src/gui.ps1","$hubOld/apps/t/AGENTS.md","$hubOld/apps/t/workspace/drive.json","$hubOld/workspace/version.txt")){New-Item -ItemType File -Force -Path $p|Out-Null}
    Set-Content "$hubNew/apps/t/src/gui.ps1" 'new';Set-Content "$hubNew/apps/t/src/added.ps1" 'added' -Force;Set-Content "$hubNew/hub/update.ps1" 'hub' -Force
    Set-Content "$hubNew/apps/t/AGENTS.md" 'upstream';Set-Content "$hubNew/apps/t/workspace/drive.json" 'upstream';Set-Content "$hubNew/workspace/version.txt" 'upstream'
    Set-Content "$hubOld/apps/t/AGENTS.md" 'my lessons';Set-Content "$hubOld/apps/t/workspace/drive.json" 'my login';Set-Content "$hubOld/workspace/version.txt" 'v1'
    Copy-AppUpdate $hubNew $hubOld
    Assert ((Get-Content "$hubOld/apps/t/src/gui.ps1") -eq 'new' -and (Test-Path "$hubOld/apps/t/src/added.ps1") -and (Test-Path "$hubOld/hub/update.ps1")) 'Hub and tool files must be updated and new files added.'
    Assert ((Get-Content "$hubOld/apps/t/AGENTS.md") -eq 'my lessons' -and (Get-Content "$hubOld/apps/t/workspace/drive.json") -eq 'my login' -and (Get-Content "$hubOld/workspace/version.txt") -eq 'v1') 'Lessons and workspaces must be kept.'
    foreach($p in @("$new/AGENTS.md","$app/AGENTS.md","$app/workspace/x")){New-Item -ItemType File -Force -Path $p|Out-Null}
    # AGENTS.md: the guide follows the release; this machine's lessons stay and the release's new ones are added once.
    $lesson={param($Id,$Text)"### $Id`n<!-- app-lesson: {`"id`":`"$Id`",`"scope`":`"category`",`"category`":`"x`"} -->`n- $Text`n`n"}
    $block={param($Items)"<!-- app-lessons:start -->`n## Bài học`n`nGhi chú.`n`n$($Items -join '')<!-- app-lessons:end -->`n"}
    Set-Content "$new/AGENTS.md" ("# Hướng dẫn mới`n`n"+(& $block @((& $lesson 'shared-a' 'chung a'),(& $lesson 'shared-b' 'chung b')))) -NoNewline
    Set-Content "$app/AGENTS.md" ("# Hướng dẫn cũ`n`n"+(& $block @((& $lesson 'shared-a' 'chung a, máy này sửa'),(& $lesson 'mine' 'riêng máy')))) -NoNewline
    Remove-Item "$app/workspace/agent-lessons-seen.txt" -ErrorAction SilentlyContinue
    Merge-AgentInstructions $new $app
    $merged=Get-Content "$app/AGENTS.md" -Raw
    Assert ($merged.Contains('# Hướng dẫn mới') -and -not $merged.Contains('# Hướng dẫn cũ')) 'The guide must follow the release.'
    Assert ($merged.Contains('chung a, máy này sửa') -and $merged -notmatch '(?m)^- chung a\r?$') "This machine's version of a lesson must be kept."
    Assert ($merged.Contains('riêng máy') -and $merged.Contains('chung b')) 'Own lessons stay and new release lessons are added.'
    Assert ((Read-AgentLessons "$app/AGENTS.md").Count -eq 3) 'The merged lessons must still read as valid lessons.'
    Assert (Test-Path "$app/workspace/backups/AGENTS-before-update.md") 'The previous AGENTS.md must be backed up.'
    # A release lesson removed on this machine is not brought back by the next update.
    Set-Content "$app/AGENTS.md" ("# Hướng dẫn mới`n`n"+(& $block @((& $lesson 'mine' 'riêng máy')))) -NoNewline
    Merge-AgentInstructions $new $app
    $again=Get-Content "$app/AGENTS.md" -Raw
    Assert (-not $again.Contains('shared-b') -and -not $again.Contains('shared-a')) 'Removed release lessons must stay removed.'
    # A lesson still as last shipped takes the release's new wording; one edited here keeps this machine's text.
    Set-Content "$app/AGENTS.md" ("# Hướng dẫn mới`n`n"+(& $block @((& $lesson 'shared-a' 'chung a'),(& $lesson 'shared-b' 'chung b, máy này sửa')))) -NoNewline
    Set-Content "$new/AGENTS.md" ("# Hướng dẫn mới`n`n"+(& $block @((& $lesson 'shared-a' 'chung a, bản mới'),(& $lesson 'shared-b' 'chung b, bản mới')))) -NoNewline
    Merge-AgentInstructions $new $app
    $refined=Get-Content "$app/AGENTS.md" -Raw
    Assert ($refined.Contains('chung a, bản mới') -and $refined.Contains('chung b, máy này sửa') -and -not $refined.Contains('chung b, bản mới')) 'Unchanged lessons take new wording; edited ones stay.'
    # A file without a readable lessons block is left as it is.
    Set-Content "$app/AGENTS.md" 'my lessons'
    Merge-AgentInstructions $new $app
    Assert ((Get-Content "$app/AGENTS.md") -eq 'my lessons') 'An unreadable AGENTS.md must be left untouched.'
    # The check names the new version for ZIP installs and git checkouts alike.
    function Get-LatestRelease { [pscustomobject]@{ tag_name = 'v1.0.15' } }
    Set-Content "$app/workspace/version.txt" 'v1.0.14'
    Assert ((Get-AppUpdate $app) -eq 'v1.0.15') 'A ZIP install must be offered the newer version by name.'
    Set-Content "$app/workspace/version.txt" 'v1.0.15'
    Assert (-not (Get-AppUpdate $app)) 'The newest version must not be offered again.'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $repo=Join-Path $temp 'checkout';New-Item -ItemType Directory -Force -Path $repo|Out-Null
        git -C $repo init --quiet;git -C $repo -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m init;git -C $repo tag v1.0.14
        Assert ((Get-AppUpdate $repo) -eq 'v1.0.15') 'A git checkout must be offered the newer version by name, not just told there is one.'
    }
    # Opening the app never updates it: only the Cập nhật dialog's button installs (it posts /api/update, to Product
    # Review's server or the hub menu's). Launchers and background checks only run -Check.
    $installers=@(Get-ChildItem -LiteralPath (Join-Path $root 'src'),(Join-Path $root '../../hub') -Recurse -File -Include *.ps1,*.mjs,*.js,*.cmd,*.command|Where-Object{$_.Name -ne 'update.ps1' -and (Get-Content -LiteralPath $_.FullName -Raw) -match "Update-App|'-Apply'|/api/update"}|ForEach-Object Name|Sort-Object -Unique)
    foreach($launcher in @('start-app.cmd','start-app.command')){Assert ((Get-Content -LiteralPath (Join-Path $root "../../$launcher") -Raw) -notmatch 'update') "$launcher must not update the app."}
    Assert (($installers -join ',') -eq 'app.js,hub.js,picker.mjs,server.mjs') "Only the Cập nhật dialog may install an update, found in: $($installers -join ', ')"
    $js=Get-Content -LiteralPath (Join-Path $root 'src/mac/ui/app.js') -Raw;$button=$js.IndexOf('go.onclick = async');$install=$js.IndexOf('fetch("/api/update"')
    Assert ([regex]::Matches($js,'/api/update').Count -eq 1 -and $button -ge 0 -and $install -gt $button -and $install - $button -lt 400) 'macOS installs only from the dialog button.'
    # An install updated from before Tools Hub: its data and lessons move into apps/product-review, old files go.
    $legacy=Join-Path $temp 'legacy';$tool="$legacy/apps/product-review"
    foreach($p in @("$legacy/src/ui/main-window.ps1","$legacy/src/gui.ps1","$legacy/src/mac/server.mjs","$legacy/data/names.txt","$legacy/data/source-photos/Áo/a.jpg","$legacy/bridge/node_modules/ws/index.js","$legacy/workspace/drive.json","$legacy/workspace/version.txt","$legacy/workspace/output/run1/results.json","$tool/tool.json","$tool/data/names.txt")){New-Item -ItemType File -Force -Path $p|Out-Null}
    Set-Content "$legacy/workspace/drive.json" 'my login';Set-Content "$legacy/workspace/version.txt" 'v2'
    Set-Content "$legacy/AGENTS.md" ("# Hướng dẫn cũ`n`n"+(& $block @((& $lesson 'mine' 'riêng máy')))) -NoNewline
    Set-Content "$tool/AGENTS.md" ("# Hướng dẫn tool`n`n"+(& $block @((& $lesson 'shared-a' 'chung a')))) -NoNewline
    Move-LegacyLayout $legacy
    Assert ((Get-Content "$tool/workspace/drive.json") -eq 'my login' -and (Test-Path "$tool/workspace/output/run1/results.json")) 'The login and runs must move into the tool.'
    Assert ((Get-Content "$legacy/workspace/version.txt") -eq 'v2') 'The installed version stays with the hub.'
    Assert ((Test-Path "$tool/data/source-photos/Áo/a.jpg") -and (Test-Path "$legacy/hub/bridge/node_modules/ws/index.js")) 'Downloaded photos and the bridge must move, not be fetched again.'
    $agents=Get-Content "$tool/AGENTS.md" -Raw
    Assert ($agents.Contains('# Hướng dẫn tool') -and $agents.Contains('riêng máy') -and $agents.Contains('chung a') -and -not (Test-Path "$legacy/AGENTS.md")) "This machine's lessons must join the tool's AGENTS.md."
    Assert (-not (Test-Path "$legacy/data") -and -not (Test-Path "$legacy/src/ui") -and -not (Test-Path "$legacy/bridge") -and (Test-Path "$legacy/src/gui.ps1") -and (Test-Path "$legacy/src/mac/server.mjs")) 'Old files go; the two entry points old installs open stay.'
    # The bridge and the extension moved from the tool to hub/: the tool's copies go, the installed package moves.
    $parts=Join-Path $temp 'parts'
    foreach($p in @("$parts/hub/bridge/package.json","$parts/hub/extension/manifest.json","$parts/apps/product-review/bridge/node_modules/ws/index.js","$parts/apps/product-review/bridge/server.mjs","$parts/apps/product-review/extension/manifest.json")){New-Item -ItemType File -Force -Path $p|Out-Null}
    Move-SharedBrowserParts $parts
    Assert ((Test-Path "$parts/hub/bridge/node_modules/ws/index.js") -and -not (Test-Path "$parts/apps/product-review/bridge") -and -not (Test-Path "$parts/apps/product-review/extension")) 'The bridge package moves to hub/bridge; the tool keeps no bridge or extension of its own.'
    New-Item -ItemType Directory -Force -Path "$legacy/.git","$legacy/data"|Out-Null
    Move-LegacyLayout $legacy
    Assert (Test-Path "$legacy/data") 'A git checkout must never be tidied.'
    # Every tool in this hub declares a name, its own icon and an entry that exists.
    $tools=@(Get-HubTools (Join-Path $root '../..'))
    Assert ($tools.Count -ge 3 -and @($tools|ForEach-Object id) -contains 'product-review') 'The hub must list its tools.'
    foreach($t in $tools){
        Assert ($t.name -and (Test-Path (Join-Path $t.Root $t.icon)) -and (Test-Path (Join-Path $t.Root ([IO.Path]::ChangeExtension($t.icon,'.png'))))) "$($t.id) needs a name and its own icon (SVG and PNG)."
        $entries=@(@($t.windows,$t.mac,$t.web)|Where-Object{$_})
        Assert ($entries.Count -and -not @($entries|Where-Object{-not (Test-Path (Join-Path $t.Root $_))}).Count) "$($t.id) entries must exist."
    }
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host 'PASS: updates replace app files and keep workspace and local lessons while adding new shared ones; the check names the new version.'
