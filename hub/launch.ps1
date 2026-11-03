# Opens Tools Hub: tidies an install updated from before Tools Hub, then starts the menu (hub/picker.mjs, when there
# is more than one tool) or the only tool's own server. macOS and Windows show the same web pages from the same Node
# servers: start-app.command gets the Node entry to start printed (-Mac); on Windows this script starts it and shows
# it in one app window (WinForms with WebView2, hub/webview2): no browser or address bar, a tool opens as a page in it.
# -Migrate only tidies the layout.
param([switch]$Mac, [switch]$Migrate)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'update.ps1') -NoRun
try { Move-LegacyLayout $root } catch { Write-Warning "Không dọn được cấu trúc cũ: $($_.Exception.Message)" }
# Files an update no longer ships (the updater only adds and replaces): the old Windows web server and the Windows-only
# WinForms windows and dialogs, now the same pages as on macOS.
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    foreach ($old in @('hub/web-server.ps1', 'hub/native-window.ps1', 'apps/grok-video-prompt/src/gui.ps1', 'apps/grok-video-prompt/src/export-prompts.cjs', 'apps/fb-content/src/gui.ps1', 'apps/fb-content/src/model.ps1', 'apps/fb-content/assets',
            'hub/winforms.ps1', 'hub/update-dialog.ps1', 'hub/setup/setup-dialog.ps1', 'hub/setup/drive-login.ps1', 'apps/product-review/src/gui.ps1', 'apps/product-review/src/quota-status.ps1', 'apps/product-review/src/ui')) {
        Remove-Item -LiteralPath (Join-Path $root $old) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($Migrate) { return }

$tools = @(Get-HubTools $root)
if (-not $tools.Count) { throw 'Không tìm thấy tool nào trong apps/.' }
if ($Mac) {
    if ($tools.Count -gt 1) { return (Join-Path $PSScriptRoot 'picker.mjs') }
    if ($tools[0].web) {
        $url = ([Uri](Join-Path $tools[0].Root $tools[0].web)).AbsoluteUri
        & open -na 'Google Chrome' --args "--app=$url" '--window-size=1120,840'; if ($LASTEXITCODE) { & open $url }
        return
    }
    return (Join-Path $tools[0].Root $tools[0].mac)
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$logs = Join-Path $root 'workspace/logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
function Write-HubError([string]$Text) {
    try { Add-Content -LiteralPath (Join-Path $logs 'app-errors.log') -Encoding UTF8 -Value ("[{0:o}] Tools Hub`r`n  {1}`r`n" -f (Get-Date), $Text) } catch { }
}
function Show-HubMessage([string]$Text) { [void][Windows.Forms.MessageBox]::Show($Text, 'Tools Hub', 'OK', 'Warning') }

# Node runs the pages' servers; without it, the installer from Cấu hình (Node.js, Codex, sign-in) runs first.
function Find-Node {
    @((Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source), (Join-Path $env:ProgramFiles 'nodejs\node.exe')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
$node = Find-Node
if (-not $node) {
    if ([Windows.Forms.MessageBox]::Show("Tools Hub cần Node.js. Cài ngay?`r`n`r`nCửa sổ cài đặt sẽ mở; cài xong Tools Hub tự mở.", 'Tools Hub', 'OKCancel', 'Information') -ne 'OK') { return }
    Start-Process powershell.exe -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'setup/setup-install.ps1') + '"'))
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $node = Find-Node
    if (-not $node) { Show-HubMessage 'Chưa cài được Node.js. Mở Tools Hub lại để thử lần nữa.'; return }
}

# The server to start, on the port Node would pick for its folder (portFor in hub/picker.mjs), handed to it so the
# two never disagree: the menu, or the only tool's server ("mac" in tool.json).
function Get-HubPort([string]$Dir, [int]$Base) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hex = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    return $Base + ([Convert]::ToInt32($hex.Substring(0, 6), 16) % 1000)
}
if ($tools.Count -eq 1 -and $tools[0].mac) {
    $serverService = [string]$tools[0].id
    $entry = [IO.Path]::GetFullPath((Join-Path $tools[0].Root $tools[0].mac)); $serverRoot = $tools[0].Root; $port = Get-HubPort $serverRoot 47000
    $env:PR_PORT = [string]$port; $serverLogs = Join-Path $serverRoot 'workspace/logs'; $arguments = @(('"' + $entry + '"'), '--no-open')
} else {
    $serverService = 'tools-hub-picker'
    $entry = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'picker.mjs')); $serverRoot = $root; $port = Get-HubPort $root 46000
    $env:HUB_PICKER_PORT = [string]$port; $serverLogs = $logs; $arguments = @(('"' + $entry + '"'))
}
$env:HUB_NO_WINDOW = '1'
. (Join-Path $PSScriptRoot 'server-health.ps1')
$basePort = $port
$addressFile = Join-Path $logs '../server-address.json'
if (-not (Test-HubServer)) { Stop-LegacyHubServer }
$serverReady = $false
for ($attempt = 0; $attempt -lt 3 -and -not $serverReady; $attempt++) {
    $port = Select-HubServerPort $basePort $addressFile
    if ($serverService -eq 'tools-hub-picker') { $env:HUB_PICKER_PORT = [string]$port } else { $env:PR_PORT = [string]$port }
    if (Test-HubServer) { $serverReady = $true; break }
    New-Item -ItemType Directory -Force -Path $serverLogs | Out-Null
    $out = Join-Path $serverLogs "server-$port.log"; $err = Join-Path $serverLogs "server-$port.err.log"
    foreach ($file in @($out, $err)) { if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 1MB) { Move-Item -LiteralPath $file -Destination ($file -replace '\.log$', '.old.log') -Force } }
    $serverProcess = Start-Process $node -ArgumentList $arguments -WorkingDirectory $serverRoot -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    [void]$serverProcess.Handle
    try {
        $deadline = (Get-Date).AddSeconds(20)
        do {
            $serverReady = Test-HubServer
            if ($serverReady -or $serverProcess.HasExited) { break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
    } finally {
        # Only this launcher's own child; do not leave a failed startup running in the background.
        if (-not $serverReady -and -not $serverProcess.HasExited) { $serverProcess.Kill(); $serverProcess.WaitForExit() }
        $serverProcess.Dispose()
    }
    if (-not $serverReady) { Write-HubError "Server did not start: $entry (port $port); log: $err"; $basePort = $port + 1 }
}
if (-not $serverReady) { Show-HubMessage 'Không mở được Tools Hub. Xem workspace/logs/app-errors.log để biết tiến trình/cổng lỗi.'; return }
$addressTemp = "$addressFile.$PID.tmp"
@{root=$serverRoot;service=$serverService;port=$port} | ConvertTo-Json -Compress | Set-Content -LiteralPath $addressTemp -Encoding UTF8
Move-Item -LiteralPath $addressTemp -Destination $addressFile -Force
$startUrl = "http://127.0.0.1:$port/"

# The WebView2 SDK is loaded from a copy in workspace/, so an update can replace hub/webview2 while the window is open.
# Without the WebView2 Runtime (older Windows 10), the pages open in the default browser instead.
$sdkSource = Join-Path $PSScriptRoot 'webview2'
$sdk = Join-Path $root 'workspace/webview2/sdk'
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $sdkSource -Recurse -File -Filter *.dll)) {
        $to = Join-Path $sdk $file.FullName.Substring($sdkSource.Length + 1)
        $copy = Get-Item -LiteralPath $to -ErrorAction SilentlyContinue
        if (-not $copy -or $copy.Length -ne $file.Length -or $copy.LastWriteTimeUtc -ne $file.LastWriteTimeUtc) {
            New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
            try { Copy-Item -LiteralPath $file.FullName -Destination $to -Force } catch { }
        }
    }
    Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll'), (Join-Path $sdk 'Microsoft.Web.WebView2.WinForms.dll')
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'AMD64' { 'x64' } default { 'x86' } }
    [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath((Join-Path $sdk $arch))
    [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString([NullString]::Value)
    $webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2 -Property @{ Dock = 'Fill' }
    $webView.CreationProperties = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties -Property @{ UserDataFolder = (Join-Path $root 'workspace/webview2/data') }
} catch {
    Write-HubError "WebView2: $($_.Exception.Message)"
    Start-Process $startUrl
    return
}

$form = New-Object Windows.Forms.Form -Property @{ Text = 'Tools Hub'; Size = '1120,840'; MinimumSize = '640,480'; StartPosition = 'CenterScreen'; BackColor = [Drawing.Color]::FromArgb(240, 240, 240) }
$hubIcon = Join-Path $PSScriptRoot 'assets/icon.png'
if (Test-Path -LiteralPath $hubIcon) { $form.Icon = [Drawing.Icon]::FromHandle((New-Object Drawing.Bitmap($hubIcon)).GetHicon()) }
$form.Controls.Add($webView)
# The page's title is the window's. The menu and the tools' servers stay in the window; other links (a new window
# too) open in the default browser.
$isLocal = { param([string]$Uri) $Uri -match '^(http://127\.0\.0\.1:\d+/|about:|data:)' }
$webView.add_CoreWebView2InitializationCompleted({
        param($source, $ready)
        if (-not $ready.IsSuccess) { Write-HubError "WebView2: $($ready.InitializationException.Message)"; Start-Process $startUrl; $form.Close(); return }
        $core = $webView.CoreWebView2
        $core.Settings.IsStatusBarEnabled = $false
        $core.add_DocumentTitleChanged({ $form.Text = $webView.CoreWebView2.DocumentTitle })
        $core.add_NewWindowRequested({
                param($source, $request)
                $request.Handled = $true
                if (& $isLocal $request.Uri) { $webView.CoreWebView2.Navigate($request.Uri) } else { Start-Process $request.Uri }
            })
        $core.add_NavigationStarting({
                param($source, $navigation)
                if (-not (& $isLocal $navigation.Uri)) { $navigation.Cancel = $true; Start-Process $navigation.Uri }
            })
    })
# Closing the window stops the servers (the menu stops the tools'), after asking while a tool's run is still going.
$form.Add_FormClosing({
        param($source, $closing)
        try {
            $run = (New-Object Net.WebClient).DownloadString("http://127.0.0.1:$(([Uri]$webView.Source).Port)/api/run") | ConvertFrom-Json
            if ($run.running -and [Windows.Forms.MessageBox]::Show($form, 'Đang chạy. Đóng cửa sổ sẽ dừng lượt chạy này. Vẫn đóng?', 'Tools Hub', 'YesNo', 'Warning') -ne 'Yes') { $closing.Cancel = $true }
        } catch { }
    })
$form.Add_FormClosed({ try { [void](New-Object Net.WebClient).UploadString("http://127.0.0.1:$port/api/quit", '') } catch { } })
$webView.Source = [Uri]$startUrl
try { [Windows.Forms.Application]::Run($form) } finally { $webView.Dispose(); $form.Dispose() }
