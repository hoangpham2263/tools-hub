# The app password for Drive, shared by every tool: workspace/config/drive.json (local, not in Git),
# { "apiUrl": "https://tools-hub-api....workers.dev", "adminKey": "..." }, checked with the tools-hub-api Worker.
. (Join-Path $PSScriptRoot 'config.ps1')
$script:DriveApiUrl = 'https://tools-hub-api.hoangpham2263.workers.dev'

function Get-DriveConfig([string]$WorkspaceRoot) {
    $path = Get-SharedConfigPath $WorkspaceRoot 'drive.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.apiUrl -or -not $config.adminKey) { throw "drive.json cần apiUrl và adminKey: $path" }
    # The Worker was product-images-api, then product-review-batch-api; a login saved before moves to the new address.
    if ([string]$config.apiUrl -match '//(product-images-api|product-review-batch-api)\.') {
        $config.apiUrl = ([string]$config.apiUrl) -replace '//(product-images-api|product-review-batch-api)\.', '//tools-hub-api.'
        try { [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)) } catch { Write-Verbose $_ }
    }
    return @{ ApiUrl = ([string]$config.apiUrl).TrimEnd('/'); AdminKey = [string]$config.adminKey }
}

# Log in once per machine: the password is checked with the Worker, then saved only in the shared drive.json.
function Connect-DriveAccount([string]$WorkspaceRoot, [string]$Password, [scriptblock]$Probe = {
        param($url, $key)
        try { (Invoke-WebRequest -Uri $url -Headers @{ 'x-admin-key' = $key } -UseBasicParsing -TimeoutSec 30).StatusCode }
        catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
    }) {
    if (-not $Password) { throw 'Nhập mật khẩu.' }
    $status = & $Probe "$script:DriveApiUrl/api/app-check" $Password
    if ($status -eq 401) { throw 'Sai mật khẩu.' }
    if ($status -ne 200) { throw "Không kết nối được máy chủ Drive ($status)." }
    $path = Get-SharedConfigPath $WorkspaceRoot 'drive.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    $json = @{ apiUrl = $script:DriveApiUrl; adminKey = $Password } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}

function Disconnect-DriveAccount([string]$WorkspaceRoot) {
    Remove-Item -LiteralPath (Get-SharedConfigPath $WorkspaceRoot 'drive.json') -Force -ErrorAction SilentlyContinue
}

# Send one result file to Tools Hub/<Tool>/<RelativePath> (folders as in RelativePath, '/' between them). The same path
# again replaces the file. Three tries; the last error is thrown with its HTTP code.
function Send-DriveToolFile($Drive, [string]$Tool, [string]$RelativePath, [string]$File) {
    $bytes = [IO.File]::ReadAllBytes($File)
    $type = switch ([IO.Path]::GetExtension($File).ToLowerInvariant()) { '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.webp' { 'image/webp' } '.json' { 'application/json' } default { 'text/plain; charset=utf-8' } }
    $uri = "$($Drive.ApiUrl)/api/tool-files?tool=$([Uri]::EscapeDataString($Tool))&path=$([Uri]::EscapeDataString($RelativePath))"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return (Invoke-RestMethod -Uri $uri -Method Post -ContentType $type -Headers @{ 'x-admin-key' = $Drive.AdminKey } -Body $bytes -TimeoutSec 120) }
        catch {
            $code = 0
            if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { Write-Verbose $_ } }
            if ($attempt -eq 3 -or ($code -ge 400 -and $code -lt 500 -and $code -notin @(408, 429))) { throw "HTTP $code $($_.Exception.Message)" }
            Start-Sleep -Seconds $attempt
        }
    }
}
