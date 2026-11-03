# Content MXH: hướng dẫn và bài học của dự án

Áp dụng cho tool Content MXH (`apps/fb-content/`) trong Tools Hub. Đọc trước khi sửa luồng, prompt, giao diện hoặc dữ liệu thương hiệu. Yêu cầu mới nhất của người dùng có ưu tiên cao nhất; cập nhật quy tắc cũ khi yêu cầu thay đổi, không giữ chỉ dẫn mâu thuẫn. Hướng dẫn chung của repo ở `AGENTS.md` gốc.

## 1. Mô hình dữ liệu và luồng chạy

**Sản phẩm → màu → ảnh cảnh → góc máy.** Mỗi sản phẩm có tên, thương hiệu, link, hashtag và một hoặc nhiều **màu**. Mỗi màu có một ảnh sản phẩm và tùy chọn nhiều **ảnh cảnh** (phòng để đặt sản phẩm vào). Mỗi ảnh cảnh có các **góc máy** chọn từ thư viện (nút "N góc" dưới ảnh, tối đa 25, mỗi góc một ảnh, mỗi ảnh vài phút; trên 12 ảnh thì hỏi lại trước khi chạy). Màu không có ảnh cảnh thì dùng chính ảnh sản phẩm làm cảnh (sản phẩm đã đứng trong phòng). Không có ô "điểm nổi bật".

Một lượt chạy làm lần lượt từng sản phẩm:

1. **Đọc ảnh** (`workflow/prepare-product.ps1`): mỗi màu, một AI chữ mô tả sản phẩm trong ảnh sản phẩm (hình dạng, chân, màu từng bộ phận, chất liệu) bằng prompt `src/domain/product-details.ps1`. Lỗi bước này chỉ là cảnh báo; ảnh vẫn là căn cứ.
2. **Tạo ảnh** (`workflow/create-images.ps1`): mỗi góc là một yêu cầu riêng, cùng một căn phòng; phòng, ánh sáng, đồ vật và cách bố trí giữ nguyên, chỉ vị trí và hướng máy đổi; không sang phòng khác. Quy tắc giữ đúng sản phẩm là bộ lõi của tool, `src/domain/product-rules.ps1` (`Get-ContentProductRules`, quy tắc 5 ảnh sạch và nét); ánh sáng và chất lượng ở STEP cuối (ánh sáng chụp nội thất chuyên nghiệp, không HDR, không bóng nhựa).
   - Ảnh sản phẩm làm cảnh: gửi một ảnh.
   - **AI tạo ảnh của tool này chỉ là Codex** (`Test-ContentJob` từ chối AI khác); Google Flow chỉ dùng cho Product Review.
   - Ảnh cảnh riêng: **mọi góc dựng thẳng từ hai ảnh thật** (ảnh sản phẩm gốc là ảnh 1, ảnh cảnh gốc là ảnh 2), không còn ảnh nền làm trước và không ảnh do AI vẽ nào làm đầu vào cho ảnh khác (người dùng yêu cầu, vì ảnh nền sai thì mọi góc sai theo).
   - **Dọn phòng trước** khi ảnh cảnh đã có đồ cùng loại với sản phẩm (`workflow/prepare-product.ps1` `Resolve-SceneNote`: một AI chữ nhìn ảnh cảnh và nêu món đó; `workflow/verify-images.ps1` `New-CleanRoom`: AI ảnh xóa món đó khỏi ảnh cảnh thật, AI chữ nhìn lại xem còn không, tối đa 3 lần, mỗi lần đòi mạnh hơn). Không dọn được thì dùng ảnh cảnh thật, prompt nêu đích danh món cần bỏ, và có một cảnh báo. Ảnh cảnh đã dọn là ảnh do AI chỉnh nhưng chỉ làm một lần cho mỗi cảnh, không phải đầu vào dây chuyền giữa các góc.
   - **Kiểm tra trước khi hiện** (`verify`, mặc định bật, tắt bằng `verify: "false"` trong job): sau mỗi ảnh, AI chữ so sản phẩm trong ảnh mới với ảnh sản phẩm gốc (mặt bàn, chân đế, màu gỗ, có bàn thứ hai không). Lệch thì tạo lại một lần kèm lý do; lệch lần hai vẫn giữ ảnh và báo cảnh báo. Kiểm tra không đọc được thì không chặn.
   - **Đóng dấu logo** (công tắc trong giao diện, mặc định tắt): sau mỗi ảnh tạo xong, code ghép logo thương hiệu lên một bản sao `anh-…-logo.png`; ảnh không logo vẫn giữ, giao diện hiển thị bản có logo, và các góc sau vẫn dựng từ ảnh nền không logo. AI không bao giờ vẽ logo (prompt cấm logo và chữ vì AI ảnh có thể từ chối prompt về thương hiệu). Thương hiệu chưa có logo thì giữ ảnh thường và báo một lần.
3. **Viết bài** (`workflow/write-posts.ps1`): mỗi nền tảng một bài từ sản phẩm, màu, gói thương hiệu, quy tắc nền tảng, giọng văn và lời nhắn. Link và hashtag do code đặt lại sau khi AI viết (`Format-PostText`), không để phụ thuộc AI.
4. Lưu kết quả ở `<hub>/workspace/fb-content/output/<thời điểm>/<STT>-<tên>/`: `anh-<màu>-<cảnh>-<góc>-<mã góc>.png`, `bai-<nền tảng>.txt`, `snapshot.json` (hash ảnh, góc, mô tả từng màu, giọng), `logs/` (prompt từng ảnh, phản hồi AI). `results.json` ở cấp lượt chạy.

Mọi prompt cùng bố cục `TASK` rồi các `STEP` đánh số. Mọi đầu vào của AI nằm trong prompt và ảnh đính kèm; AI không tự đọc file (xem `AGENTS.md` gốc).

## 2. Dữ liệu, không phải code

- `data/brands/<id>/brand.json`: giọng, sự thật cần giữ, điều cần tránh, khẩu hiệu, hashtag mặc định, một bài đã duyệt làm mẫu nhịp (không sao chép). Thương hiệu chọn ở ô Thương hiệu (danh sách từ thư mục này, hoặc "Khác…" gõ tên: tên lạ dùng gói chung; tìm theo id, tên hoặc alias, không phân biệt hoa thường, dấu, khoảng trắng). Thêm web mới = thêm một thư mục, không sửa code. Không để chữ của thương hiệu này vào prompt của thương hiệu khác (có test).
- Logo đóng dấu của thương hiệu: `logo.svg` (nguồn), `watermark.png` (vòng tròn logo làm chữ G, theo sau là chữ RENHEIM, màu trắng trên thanh bo góc màu xanh chủ đạo của thương hiệu hơi trong suốt, bóng mờ, nền trong suốt; một file nên giống hệt ở mọi ảnh) và khối `watermark` trong `brand.json` (`file`, `content_box` vùng nhìn thấy trong PNG, `position` mặc định góc trên phải, `size` 0,13 chiều rộng ảnh, `margin` 0,03) và màu chủ đạo ở `colors.primary`. Ô Thương hiệu trong hộp "Xem / sửa" có khung xem trước: logo đặt đúng vị trí và cỡ cấu hình trên chính ảnh sản phẩm (nền mẫu nếu chưa có ảnh); tên gõ vào "Khác…" khớp một thương hiệu thì cũng hiện, tên lạ báo chưa có logo. Một kiểu cố định, không đổi màu theo nền: chữ trắng trên thanh xanh luôn có độ tương phản trên ảnh sáng hay tối (chữ trắng chỉ có bóng đã thử và khó đọc trên tường sáng). Dựng lại file: `node scripts/build-brand-watermark.mjs apps/fb-content/data/brands/<id>` (cần Chrome; SVG phải cùng cấu trúc với logo GRENHEIM). Việc ghép logo là `src/infrastructure/watermark.mjs` (Node thuần, chỉ dùng `node:zlib`, đọc và ghi PNG) nên chạy y hệt trên Windows và macOS, không cần cài thêm gì; PowerShell gọi vào qua `Add-ImageWatermark` trong `src/infrastructure/watermark.ps1`; test lõi ở `tests/watermark-core.test.mjs`. Chỉ ghép được ảnh PNG không xen kẽ (ảnh Codex lưu ra là PNG); file khác thì giữ ảnh thường và báo lý do.
- `data/platforms.json`: giới hạn ký tự, số hashtag, link trong bài hay ở bio, độ dài từ, cách trình bày. `data/tones.json`: giọng văn. `data/post-rules.json`: bộ quy tắc bài đăng đánh số (FACTS, VOICE, OPENING, WORDS, STRUCTURE, OUTPUT). Thư viện góc máy dùng chung ở `hub/image/angles.json` (Grok Video cũng đọc).
- Thư viện góc (`data/angles.json`; Grok Video giữ bản riêng, hai bên không đồng bộ) lấy từ `C:\hoangpq\GRENHEIM-content\03-thu-vien-goc-chup\catalog.json` (02/11/2026): 24 góc chia 6 nhóm (hướng quanh sản phẩm 7, độ cao và góc chúc 4, cỡ cảnh 5, bố cục 6, góc theo vị trí 1, vai trò ảnh 1), cộng "Giữ góc ảnh gốc" là nhãn của ứng dụng. Mỗi góc có mã ổn định, tên Việt/Anh, mô tả và câu lệnh máy bằng tiếng Anh viết theo quy tắc của thư viện: máy ở phía nào, cao bao nhiêu, nhìn vào đâu, thấy mặt nào, phần nào nằm ngoài khung; trái/phải theo người đứng trước sản phẩm; góc dùng đồ có sẵn (tiền cảnh, khung trong khung, đường dẫn) không được thêm đồ. Mặt sau và nghiêng phía sau gắn cảnh báo vì ảnh không cho biết kết cấu phía sau (`hidden_side`). Bộ 5 ảnh studio nội thất (chủ đạo, hình khối, góc sống, mặt trên, chi tiết) là bộ chọn nhanh do GRENHEIM tổng hợp, không phải chuẩn ngành. Muốn thêm hoặc sửa góc: sửa thư viện gốc rồi cập nhật tệp này, giữ mã góc; không thêm câu rời vào prompt.
- Quy tắc mới đi vào đúng tệp dữ liệu hoặc đúng STEP, không thêm câu rời vào prompt.

## 3. Kiểm tra bản nháp

- Bài: dấu chấm than, gạch trong câu, emoji, từ bóng bẩy hoặc bán hàng, mẫu câu kiểu máy (not just…but, overall), độ dài theo nền tảng. Vi phạm thì gửi viết lại một lần kèm lý do và bản nháp; sau đó vẫn nhận bài nhưng ghi cảnh báo. Vượt giới hạn ký tự của nền tảng thì báo lỗi, không cắt bài.
- Ảnh: một lỗi kết nối, hết giờ hoặc bận được thử lại một lần sau khi tìm ảnh đã về; lỗi đăng nhập, hạn mức hoặc cầu nối dừng cả lượt; từ chối theo chính sách chỉ mất đúng ảnh đó.
- Ảnh chỉ được tạo lại tối đa một lần và chỉ khi AI chữ thấy sai sản phẩm (xem mục Kiểm tra trước khi hiện); không tạo lại để đẹp hơn, không đánh dấu duyệt thay người dùng.

## 4. Giao diện và máy chủ

- `ui/index.html` do `src/server.mjs` phục vụ (tool.json `mac`); cổng riêng từ thư mục cài, tìm bằng `/api/root`. Cập nhật, Cấu hình, Tải lại là của hub.
- Hộp "Xem / sửa" theo kiểu Product Review: mỗi màu một dòng (ảnh sản phẩm, ô tên màu, các ảnh cảnh, nút "+ Máy", "Dán"), kéo thả hoặc Ctrl+V vào dòng đang chọn thì thành ảnh cảnh, vào chỗ trống thì thành màu mới. Mọi ô chọn dùng cùng kiểu `select` của hub. Chưa chọn nền tảng nào mặc định; bấm Bắt đầu mà chưa chọn thì báo. Dữ liệu của bản cũ (ảnh kèm số góc) tự chuyển thành mỗi ảnh một màu.
- Giao diện chỉ gom đầu vào và theo dõi lượt chạy: máy chủ chạy `src/run-content.ps1`, các dòng `@@EVENT {json}` thành sự kiện (`start`, `product`, `image`, `post`, `warning`, `product-done`, `done`, `fatal`) mà trang hỏi lại mỗi 1,5 giây; tải lại trang vẫn thấy lượt đang chạy.
- Ảnh tải lên lưu ở `<hub>/workspace/fb-content/temp/uploads`; máy chủ chỉ trả lại ảnh nằm trong thư mục workspace của tool.
- Tỷ lệ khung ảnh do Codex tự chọn, chưa điều khiển được. Tỷ lệ theo từng nền tảng (4:5, 9:16) chưa làm.

## 5. Kiểm tra

`tests/run.ps1` (Windows PowerShell 5.1; không gọi AI thật): `prompts` (thư viện góc 24+1 theo nhóm, chọn góc theo mã, prompt ảnh một và hai ảnh, prompt bài, gói thương hiệu không lẫn nhau, kiểm tra lượt chạy), `posts` (trình bày theo nền tảng, kiểm tra bản nháp), `content-run` (cả lượt chạy với AI giả: nhiều góc, nhiều màu, ảnh cảnh riêng dựng từ hai ảnh thật, bốn nền tảng, sửa bài, thử lại ảnh, dừng khi hết hạn mức, từ chối chính sách, một ảnh lỗi không chặn ảnh khác). Báo riêng: code đã sửa, kiểm tra offline, ảnh và bài đã tạo thật.

## 6. Trạng thái và bài học

**Việc chờ làm (người dùng yêu cầu 03/11/2026):** tool này tạo ảnh chỉ bằng Codex; Flow đã gỡ khỏi Content MXH (lựa chọn, kiểm tra job, bước gỡ dấu sao, các chế độ thử). Luồng tạo ảnh bằng Codex chưa được tối ưu và chưa chạy thật: cần triển khai lại và thử. Hạn mức ảnh của Codex có lúc hết (lần thử 02/11 báo còn khoảng 3,5 giờ).

**Việc chưa làm:** tỷ lệ khung theo nền tảng; nhiều bản mỗi góc để chọn; đẩy kết quả lên Drive cần deploy Worker (route `POST /api/tool-files`).

**Drive:** sau mỗi sản phẩm, ảnh, bài và snapshot được đẩy lên `Tools Hub/Content MXH/Ảnh đã tạo/<lần chạy>/<sản phẩm>/` đúng cấu trúc folder trên máy (không đẩy `logs/`); cuối lần chạy đẩy thêm `results.json`. Dùng đăng nhập Drive chung (`hub/setup/drive.ps1`); chưa đăng nhập hoặc Worker từ chối thì chỉ lưu máy và báo một lần. File lỗi được báo, các file khác vẫn đẩy.

**Khác Product Review:** bên review giữ nguyên ảnh nền từng vật; Content MXH chỉnh bối cảnh cho hợp sản phẩm (bước FIT THE SCENE: đúng kích thước thật, đặt đúng chỗ và dọn chỗ đó, chỉnh thảm, thêm ít đồ trang trí hợp phong cách, không lấn sản phẩm). Chỉ kiến trúc và ánh sáng của phòng giữ cố định. Prompt chỉ có sản phẩm có tên là sản phẩm; ghế, ly, đĩa của ảnh sản phẩm không được chép.

**Bài học từ lần thử với Google Flow (02/11/2026), để tham khảo khi làm với Codex, chưa chắc đúng với Codex:**
- Ảnh cảnh đã có sẵn bàn hoặc ghế cùng loại với sản phẩm là nguyên nhân ảnh sai. Flow neo vào ảnh cảnh và giữ luôn cái bàn đó bất kể prompt, kể cả prompt viết lại từ đầu, prompt ngắn kiểu gõ tay, đổi thứ tự ảnh, gọi bằng tên ảnh. Gọi tên bàn cũ trong prompt cũng không đủ. Chỉ cách dọn bàn khỏi ảnh cảnh trước rồi kiểm tra cho kết quả đúng sản phẩm ở hai bộ ảnh thử (bàn ăn xoắn, bàn trà khảm xà cừ). Kết quả khác nhau mỗi lần nên cần kiểm tra và tạo lại.
- Với hai ảnh, ảnh cắt cận hay lấy nền của ảnh sản phẩm thay vì phòng; prompt giữ các câu chặn (ảnh 2 là phòng duy nhất, không dùng bối cảnh của ảnh 1).
- Các góc xoay quanh sản phẩm hoặc đổi độ cao từ một ảnh: Flow gần như không di chuyển máy; các góc cỡ cảnh (đặc tả, cận, trung cảnh) hoạt động tốt. Muốn xoay thật cần ảnh tham chiếu thứ hai của mặt cần thấy hoặc prompt viết tay.
- Màu mặt gỗ có thể đậm cam hơn ảnh gốc một chút.
- Content MXH chỉ tạo ảnh bằng Codex nên không có dấu sao 4 cánh của Google (chỉ ảnh Flow có). Bộ gỡ dấu sao (`unsparkle.mjs`, gỡ lớp phủ bằng phép trừ, đã so với `GargantuaX/gemini-watermark-remover` và thử dựng hình sao đo từ ảnh thật: không tốt hơn công thức) đã gỡ khỏi hub khi mỗi tool tách riêng; cần lại cho tool dùng Flow thì lấy từ lịch sử Git (`git show 93cd646:hub/image/unsparkle.mjs`, `unsparkle.ps1` và `hub/tests/unsparkle.test.mjs` cùng commit).
