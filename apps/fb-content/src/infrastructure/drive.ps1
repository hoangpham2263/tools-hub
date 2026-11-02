# Results go to Google Drive as they are made: Tools Hub/Content MXH/Ảnh đã tạo/<run>/<product>/<file>, the same folders as on
# this machine. The login is the one every tool shares (hub/setup/drive.ps1); without it the run keeps local files only.
. (Join-Path $PSScriptRoot '../../../../hub/setup/drive.ps1')
$script:DriveTool = 'Content MXH'

function Get-ContentDrive {
    try { Get-DriveConfig (Join-Path (Get-ToolRoot) 'workspace') } catch { $null }
}

# Every picture and text of a folder (not logs/), sent with its path under the run's parent folder. Returns the number sent;
# throws the first failure after trying the rest, so one bad file never stops the others.
# Why Drive refused, in words: 401/403 is the password (or a Worker that has not been updated with the results route yet),
# 404 is a Worker without the route. Neither is fixed by sending the next file, so the run stops trying (see Publish-FolderToDrive).
function Get-DriveRefusal([string]$Message) {
    if ($Message -match 'HTTP (401|403)') { return 'Drive từ chối (mật khẩu app sai hoặc máy chủ Drive chưa được cập nhật để nhận kết quả Content MXH).' }
    if ($Message -match 'HTTP 404') { return 'Máy chủ Drive chưa có chỗ nhận kết quả Content MXH (cần cập nhật Worker).' }
    ''
}

# Every picture and text of a folder (not logs/), sent with its path under the run's parent folder. Returns the number sent.
# A refusal that sending more files cannot fix (Get-DriveRefusal) stops at the first file and marks Drive as unavailable for
# the rest of the run ($script:Run.DriveOff), so one cause is reported once, not once per file and per product.
function Publish-FolderToDrive($Drive, [string]$RunFolder, [string]$Folder) {
    $base = (Split-Path $RunFolder -Parent).TrimEnd('\', '/')
    $sent = 0; $failed = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Recurse | Where-Object { $_.Extension -match '^\.(png|jpe?g|webp|txt|json)$' -and $_.FullName -notmatch '[\\/]logs[\\/]' })) {
        $relative = $file.FullName.Substring($base.Length + 1) -replace '\\', '/'
        try { Send-DriveToolFile $Drive $script:DriveTool $relative $file.FullName | Out-Null; $sent++ }
        catch {
            $refusal = Get-DriveRefusal $_.Exception.Message
            if ($refusal) { $script:Run.DriveOff = $true; Write-Host "  [DRIVE] $refusal" -ForegroundColor Yellow; throw "Drive: $refusal Kết quả vẫn lưu trên máy, chưa đẩy lên Drive." }
            $failed += "$relative ($($_.Exception.Message))"
        }
    }
    Write-Host "  [DRIVE] $sent file(s) sent" -ForegroundColor Cyan
    if ($failed.Count) { throw "Drive: $($failed.Count) file chưa đẩy lên được, bản trên máy vẫn còn: $($failed[0])" }
    $sent
}
