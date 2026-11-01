# Translate known pipeline milestones into user-facing events. Unknown/raw diagnostics stay in log files.
function ConvertTo-UiEvent([string]$Line, [int]$CurrentIndex = 0) {
    $line = ($Line -replace '\x1b\[[0-9;]*m', '').Trim()
    if (-not $line) { return }
    $event = [pscustomobject]@{ Kind = ''; Text = ''; Stage = ''; Index = $CurrentIndex; Total = 0; Done = 0; Seconds = 0; Path = ''; Rows = @(); TokensIn = 0; TokensCached = 0; TokensOut = 0; Backend = '' }
    if ($line -match '\(#(\d+)\)\s*$') { $event.Index = [int]$Matches[1] }
    if ($line -match '^Starting: (\d+) URLs') {
        $event.Kind = 'Start'; $event.Total = [int]$Matches[1]
        $event.Text = "Bắt đầu tạo $($event.Total) ảnh."
    } elseif ($line -match '^\[(\d+)/(\d+)\] ') {
        $event.Kind = 'Item'; $event.Index = [int]$Matches[1]; $event.Total = [int]$Matches[2]; $event.Stage = 'Đang chuẩn bị'
    } elseif ($line -match '^Rows: ([\d,]+)$') {
        $event.Kind = 'Rows'; $event.Rows = @($Matches[1] -split ',' | ForEach-Object { [int]$_ })
    } elseif ($line -match '^Batch:\s*(.+)') {
        $event.Kind = 'Output'; $event.Path = $Matches[1].Trim()
    } elseif ($line -match '^\[TOKENS\] in=(\d+) cached=(\d+) out=(\d+)') {
        $event.Kind = 'Tokens'; $event.TokensIn = [long]$Matches[1]; $event.TokensCached = [long]$Matches[2]; $event.TokensOut = [long]$Matches[3]
    } elseif ($line -match '^\[AI-CALL\] (\S+)') {
        $event.Kind = 'Call'; $event.Backend = $Matches[1]
    } elseif ($line -match '^(Model AI|Viết review): (.+)$') {
        $event.Kind = 'Info'; $event.Text = $line.Trim()
    } elseif ($line -match '^Missing data: (\d+)') {
        $event.Kind = 'Info'
        $event.Text = "$($Matches[1]) sản phẩm thiếu ảnh mẫu (xem missing-data.csv)."
    } elseif ($line -match '^\[PRODUCT\]') {
        $event.Kind = 'Stage'; $event.Stage = 'Đang chuẩn bị'
    } elseif ($line -match '^\[CLASSIFY\]') {
        $event.Kind = 'Stage'; $event.Stage = 'Đang nhận diện sản phẩm'
    } elseif ($line -match '^\[REFERENCE-COUNT\] Using (\d+)') {
        $event.Kind = 'Stage'; $event.Stage = 'Đã chọn ảnh mẫu phù hợp'
    } elseif ($line -match '^\[SELECT\] Subject') {
        $event.Kind = 'Stage'; $event.Stage = 'Đang chọn người mẫu'
    } elseif ($line -match '^\[SELECT\] Scene') {
        $event.Kind = 'Stage'; $event.Stage = 'Đang chọn bối cảnh'
    } elseif ($line -match '^\[MANUAL-REFERENCE\]') {
        $event.Kind='Stage';$event.Stage='Đã nhận ảnh bạn gắn'
    } elseif ($line -match '^\[IMAGE\]') {
        $event.Kind = 'Stage'; $event.Stage = 'Đang tạo ảnh'
    } elseif ($line -match '^\[REVIEW\]') {
        $event.Kind = 'Stage'; $event.Stage = 'Đang viết đánh giá'
    } elseif ($line -match '^\[IMAGE-ATTEMPT\]\s*(\d+)/(\d+)') {
        $event.Kind='Stage';$event.Stage="Đang tạo ảnh, lượt gửi $($Matches[1])/$($Matches[2])"
    } elseif ($line -match '^\[IMAGE-RETRY\]\s*(\S+)\s+(\d+)/(\d+)') {
        $event.Kind='Retry';$event.Stage="Đang tự thử lại lượt $($Matches[2])/$($Matches[3])"
        $event.Text="Sản phẩm $($event.Index): bị gián đoạn, thử lại $($Matches[2])/$($Matches[3])."
    } elseif ($line -match '^\[IMAGE-RECOVERED\]') {
        $event.Kind='Stage';$event.Stage='Đang kiểm tra ảnh đã lưu'
    } elseif ($line -match '^\[AWAITING-REVIEW\]') {
        $event.Kind='Stage';$event.Stage='Ảnh đã tạo'
    } elseif ($line -match '^\[DOWNLOAD-RETRY\]') {
        $event.Kind = 'Retry'; $event.Stage = 'Đang thử tải lại sản phẩm'
        $event.Text = "Sản phẩm $($event.Index): trang chậm, đang tự thử tải lại."
    } elseif ($line -match '^\[AI-CONNECTION\]') {
        $event.Kind = 'Retry'; $event.Stage = 'Kết nối gián đoạn'
        $event.Text = 'Mất kết nối AI, chờ tối đa 60 giây.'
    } elseif ($line -match '^\[AI-RESUMED\]') {
        $event.Kind = 'Retry'; $event.Stage = 'AI đã phản hồi trở lại'
    } elseif ($line -match '^\[AI-WAIT\] (\d+)/(\d+)s') {
        $event.Kind = 'Stage'; $event.Stage = "Đang chờ AI $($Matches[1])/$($Matches[2]) giây"
    } elseif ($line -match '^\[RETRY\]') {
        $event.Kind = 'Retry'; $event.Stage = 'Đang chờ dịch vụ'
        $event.Text = 'Dịch vụ bận, đang tự thử lại.'
    } elseif ($line -match '^\[DRIVE-(UPLOAD|RETRY)\]') {
        $event.Kind='Stage';$event.Stage='Đang tải ảnh lên Drive';$event.Text='Đang tải ảnh lên Drive; CSV chỉ nhận ảnh đã tải thành công.'
    } elseif ($line -match '^\[DRIVE-RESUME\]') {
        $event.Kind='Stage';$event.Stage='Tiếp tục bàn giao ảnh đã lưu';$event.Text='Dùng lại ảnh và nội dung đã lưu, không gọi AI tạo lại.'
    } elseif ($line -match '^\[METADATA\]') {
        $event.Kind = 'Saving'; $event.Stage = 'Đang lưu kết quả'
    } elseif ($line -match '^\[OK\]') {
        if ($line -match '\[ITEM (\d+)\]') { $event.Index = [int]$Matches[1] }
        $event.Kind = 'Completed'; $event.Stage = 'Đã xong'
        $event.Text = "Sản phẩm $($event.Index): xong."
    } elseif ($line -match '^WARNING:\s*(?:\[ITEM (\d+)\]\s*)?Failed;') {
        if ($Matches[1]) { $event.Index = [int]$Matches[1] }
        $event.Kind = 'Failed'; $event.Stage = 'Chưa hoàn tất'
        $event.Text = "Sản phẩm $($event.Index): lỗi, link được giữ để chạy lại."
        if ($line -match '\[CAUSE:DRIVE_(CONFIG|AUTH)\]') {
            $event.Text='Chưa kết nối được Drive. Đăng nhập lại; chưa bàn giao CSV có đường dẫn local.'
        } elseif ($line -match '\[CAUSE:DRIVE_UPLOAD\]') {
            $event.Text='Ảnh đã lưu nhưng chưa tải được lên Drive. Thử bàn giao lại để tiếp tục upload, không tạo ảnh mới.'
        } elseif ($line -match '\[CAUSE:PRODUCT_INPUT\]') {
            $event.Text = "Sản phẩm $($event.Index): ảnh đã gắn (ảnh gốc hoặc ảnh review) bị thiếu hoặc thay đổi, hãy gắn lại."
        } elseif ($line -match '\[CAUSE:PRODUCT_TIMEOUT\]') {
            $event.Text = "Sản phẩm $($event.Index): trang quá chậm, thử lại sau."
        } elseif ($line -match '\[CAUSE:PRODUCT_NETWORK\]') {
            $event.Text = "Sản phẩm $($event.Index): không vào được trang, kiểm tra mạng."
        } elseif ($line -match '\[CAUSE:PRODUCT_ACCESS\]') {
            $event.Text = "Sản phẩm $($event.Index): trang chặn truy cập, hãy gắn ảnh sản phẩm."
        } elseif ($line -match '\[CAUSE:PRODUCT_NOT_FOUND\]') {
            $event.Text = "Sản phẩm $($event.Index): không tìm thấy sản phẩm, kiểm tra link."
        } elseif ($line -match '\[CAUSE:MISSING_DATA\]') {
            $event.Text = "Sản phẩm $($event.Index): thiếu ảnh mẫu cho loại này."
        } elseif ($line -match '\[CAUSE:PRODUCT_DOWNLOAD\]') {
            $event.Text = "Sản phẩm $($event.Index): chưa tải được trang, thử lại sau."
        } elseif ($line -match '\[CAUSE:BRIDGE\].*(Google Flow của tài khoản đang chọn[^\r\n]*)') {
            # The Flow account still needs setting up once (hub/extension/sites/flow.js says what to do).
            $event.Text = "Sản phẩm $($event.Index): $($Matches[1])"
        } elseif ($line -match '\[CAUSE:BRIDGE\]') {
            $event.Text = "Sản phẩm $($event.Index): chưa nối được ChatGPT/Flow, mở Chrome có extension."
        } elseif ($line -match '\[CAUSE:POLICY\]') {
            $event.Text = "Sản phẩm $($event.Index): AI từ chối tạo ảnh này (có thể vi phạm chính sách, không bị tính lượt). Đổi ảnh tham khảo, ví dụ ảnh có logo hay chữ thương hiệu thật, rồi chạy lại hoặc dùng Codex."
        } elseif ($line -match '\[CAUSE:STORE_LOCKED\]') {
            $event.Text = "Sản phẩm $($event.Index): cửa hàng có mật khẩu, hãy gắn ảnh sản phẩm."
        } elseif ($line -match '\[CAUSE:AUTH\]') {
            $event.Text = 'Chưa đăng nhập ChatGPT, bấm Cấu hình.'
        } elseif ($line -match '\[CAUSE:QUOTA\]') {
            $event.Text = 'Hết hạn mức, chờ được cấp lại.'
            if($line -match 'HTTP\s+(\d{3})'){$event.Text+=" HTTP $($Matches[1])."}
            if($line -match 'Message:\s*([^;]+)'){$event.Text+=" $($Matches[1].Trim())"}
            if($line -match 'Reset:\s*([^;]+)'){$event.Text+=" Đặt lại: $($Matches[1].Trim())."}
        } elseif ($line -match '\[CAUSE:OUTPUT_MISSING\]') {
            $event.Text = 'Chưa nhận được ảnh PNG; nguyên nhân chưa rõ. Đã giữ log và link để kiểm tra.'
            if($line -match 'AI_REPLY:\s*(.+?); Details:'){$event.Text='AI chưa tạo ảnh. Phản hồi AI: '+$Matches[1]}
        } elseif ($line -match '\[CAUSE:OUTPUT_INVALID\]') {
            $event.Text = 'File PNG bị lỗi; nguyên nhân chưa rõ. Đã giữ log và link để kiểm tra.'
        } elseif ($line -match '\[CAUSE:TOOL_ERROR\]') {
            $event.Text = 'Công cụ tạo ảnh báo lỗi. Đã giữ nguyên lỗi gốc trong log, link được giữ để chạy lại.'
        } elseif ($line -match '\[CAUSE:AI_TIMEOUT\]') {
            $event.Text = 'AI quá thời gian chờ, link được giữ để chạy lại.'
        } elseif ($line -match '\[CAUSE:PROCESS_ACTIVE\]') {
            $event.Text = 'Lượt AI cũ chưa dừng, giữ link để tránh tạo trùng.'
        } elseif ($line -match '\[CAUSE:NETWORK\]') {
            $event.Text = 'Mất mạng, kiểm tra Internet rồi chạy lại.'
        } elseif ($line -match '\[CAUSE:BUSY\]') {
            $event.Text = 'Dịch vụ bận, thử lại sau.'
        } elseif ($line -match 'No product reference found|Invalid reference image URL') {
            $event.Text = "Sản phẩm $($event.Index): không đọc được ảnh sản phẩm, kiểm tra link."
        } elseif ($line -match 'Image technical validation failed') {
            $event.Text="Sản phẩm $($event.Index): file ảnh lỗi, link được giữ để chạy lại."
        } elseif ($line -match 'No suitable real scene reference|No suitable source photo found') {
            $event.Text = "Sản phẩm $($event.Index): chưa tìm được ảnh mẫu thực tế phù hợp."
        }
    } elseif ($line -match '^Done: (\d+)/(\d+) exported in (\d+)s') {
        $event.Kind = 'Summary'; $event.Done = [int]$Matches[1]; $event.Total = [int]$Matches[2]; $event.Seconds = [int]$Matches[3]
        $event.Text = "Xong $($event.Done)/$($event.Total) ảnh."
    } elseif ($line -match '^WARNING: Invalid') {
        $event.Kind = 'Warning'; $event.Text = 'Có link không hợp lệ.'
    } elseif ($line -match '^No product URLs') {
        $event.Kind = 'Warning'; $event.Text = 'Chưa có link sản phẩm để xử lý.'
    }
    if ($event.Kind) { return $event }
}
