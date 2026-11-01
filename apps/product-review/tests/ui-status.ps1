# How run-images.ps1 output lines read in the app's log (ConvertTo-UiEvent): plain Vietnamese, no technical details.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/application/progress.ps1')
if ((ConvertTo-UiEvent '  [RETRY] AI busy; attempt 2/3 in 3s...  (#1)').Text -notmatch 'tự thử lại') { throw 'Retry guidance missing.' }
foreach ($case in @(@('PRODUCT_TIMEOUT','quá chậm'), @('PRODUCT_NETWORK','Kiểm tra mạng'), @('PRODUCT_ACCESS','chặn truy cập'), @('PRODUCT_NOT_FOUND','không tìm thấy'), @('PRODUCT_DOWNLOAD','chưa tải được'), @('STORE_LOCKED','cửa hàng có mật khẩu'), @('AUTH','đăng nhập'), @('QUOTA','hết hạn mức'), @('NETWORK','Mất mạng'), @('BUSY','thử lại sau'), @('POLICY','từ chối tạo ảnh'), @('DRIVE_UPLOAD','không tạo ảnh mới'), @('DRIVE_AUTH','Đăng nhập lại'), @('DRIVE_CONFIG','Đăng nhập lại'))) {
    $event = ConvertTo-UiEvent "WARNING: [ITEM 1] Failed; URL and source kept for retry. AI failed. Details: C:\private\error.log [CAUSE:$($case[0])]"
    if ($event.Text -notmatch $case[1] -or $event.Text -match 'CAUSE|C:\\|Details') { throw 'Account/network errors leaked technical text or lacked user guidance.' }
}
if ((ConvertTo-UiEvent '  [DOWNLOAD-RETRY] Attempt 2/3...  (#1)').Text -notmatch 'Đang tự thử tải lại') { throw 'Product download retry was hidden from the user.' }
$flowSetup = (ConvertTo-UiEvent 'WARNING: [ITEM 1] Failed; [CAUSE:BRIDGE] URL and source kept for retry. [CAUSE:BRIDGE] flow không tạo được ảnh. Google Flow của tài khoản đang chọn đang bật Tác nhân, không tạo ảnh. Mở Cấu hình, bấm Mở Flow, vào một dự án, tắt Tác nhân và chọn mô hình ảnh Nano Banana rồi chạy lại.').Text
if ($flowSetup -notmatch 'tắt Tác nhân' -or $flowSetup -match 'CAUSE') { throw 'A Flow account that needs setting up must say what to do.' }
if ((ConvertTo-UiEvent '[AI-CONNECTION] Connection interrupted').Text -notmatch '60 giây') { throw 'Live connection interruption is hidden.' }
if ((ConvertTo-UiEvent '[AI-WAIT] 90/480s elapsed.').Stage -notmatch '90/480') { throw 'AI waiting time is hidden.' }
if ((ConvertTo-UiEvent '[IMAGE-RETRY] AI_TIMEOUT 2/3').Text -notmatch '2/3') { throw 'Automatic image retry count is hidden.' }
if ((ConvertTo-UiEvent '[IMAGE-ATTEMPT] 3/3').Stage -notmatch '3/3') { throw 'Current image attempt is hidden.' }
if ((ConvertTo-UiEvent '[IMAGE-RECOVERED] Saved image found').Stage -notmatch 'kiểm tra ảnh đã lưu') { throw 'Recovered image validation is hidden.' }
if ((ConvertTo-UiEvent 'WARNING: [ITEM 1] Failed; [CAUSE:AI_TIMEOUT] AI failed').Text -notmatch 'quá thời gian chờ') { throw 'AI deadline must be explained.' }
$quotaEvent=ConvertTo-UiEvent 'WARNING: [ITEM 1] Failed; [CAUSE:QUOTA] usage_limit_reached; HTTP 429; Message: The usage limit has been reached; Reset: 09:34:10 29/10/2026 (UTC+7); Details: C:\private\trace.log'
if($quotaEvent.Text -notmatch 'HTTP 429' -or $quotaEvent.Text -notmatch '09:34:10 29/10/2026' -or $quotaEvent.Text -notmatch 'The usage limit has been reached' -or $quotaEvent.Text -match 'private'){throw 'UI hid service quota details or leaked local diagnostic paths.'}
$missingEvent=ConvertTo-UiEvent 'WARNING: [ITEM 1] Failed; [CAUSE:OUTPUT_MISSING] Output image not found'
if($missingEvent.Text -notmatch 'nguyên nhân chưa rõ' -or $missingEvent.Text -match 'hết hạn mức'){throw 'Missing output was incorrectly labeled quota exhaustion.'}
$questionEvent=ConvertTo-UiEvent 'WARNING: [ITEM 1] Failed; [CAUSE:OUTPUT_MISSING] AI_REPLY: Should I replace their worn polos?; Details: C:\private\trace.log'
if($questionEvent.Text -notmatch 'Should I replace their worn polos' -or $questionEvent.Text -match 'private'){throw 'AI question was hidden behind an unknown PNG error.'}
foreach($legacy in @('[QUALITY] Checking','[REFINE] Improving','[QUALITY-REASON] FAIL: obsolete')){if(ConvertTo-UiEvent $legacy){throw 'Retired visual QA events are still active.'}}
Write-Host 'PASS: user messages, retry guidance and diagnostic filtering.' -ForegroundColor Green
