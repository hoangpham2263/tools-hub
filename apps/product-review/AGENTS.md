# Hướng dẫn và bài học của dự án

Áp dụng cho tool Product Review (`apps/product-review/`) trong Tools Hub. Đọc trước khi sửa workflow, prompt, giao diện hoặc dữ liệu mẫu. Yêu cầu mới nhất của người dùng có ưu tiên cao nhất; cập nhật quy tắc cũ khi yêu cầu thay đổi, không giữ chỉ dẫn mâu thuẫn.

## 1. Workflow hiện tại

1. Nhận URL và ảnh tham khảo gắn riêng cho từng sản phẩm; kiểm tra link trùng, ảnh thiếu và file/hash trước khi gọi AI.
2. Nếu người dùng gắn ảnh sản phẩm gốc, kiểm tra file/hash rồi dùng trực tiếp, không truy cập web kể cả link chưa public; nếu không có ảnh gốc thì tải từ URL. Nhận diện từ ảnh thực tế. Ảnh bối cảnh là đầu vào riêng, không nhầm với ảnh sản phẩm. Ảnh review luôn do người dùng chọn (từ máy hoặc kho Drive); app không tự tìm trong kho.
3. Lưu snapshot đầu vào và nguồn vào kết quả của lượt đang chạy. Đọc các bài học còn bật, khớp URL hoặc danh mục từ mục Bài học đã lưu bên dưới; áp dụng yêu cầu sửa hiện tại sau cùng.
4. Tạo một ảnh hoàn chỉnh, kiểm tra PNG đọc được rồi xuất nguyên file AI tạo. Không chấm chất lượng bằng AI sau tạo, không tự sửa hoặc lặp tạo để cải thiện thẩm mỹ.
5. Viết review mẫu theo ảnh hiện tại, học cách diễn đạt từ kho review tham khảo chung rồi xuất ảnh và CSV. Giữ URL chưa hoàn tất để thử lại. Có ảnh xuất chưa có nghĩa người dùng đã duyệt.
6. Người dùng duyệt từng ảnh (Giữ/Bỏ) rồi xuất file Loox; app không có bước làm lại ảnh.

Chỉ tự thử lại lỗi kết nối/timeout khi chưa nhận đủ file, tối đa 3 lượt gửi với cùng đầu vào. Phải xác nhận tiến trình cũ đã dừng, tìm ảnh đã lưu trước khi gửi lại; có ảnh thì xuất, không tạo trùng. Lỗi đăng nhập, hết hạn mức hoặc đầu vào sai không tự thử lại. Không chạy lại ảnh hay test khi người dùng đã yêu cầu bỏ qua.

CLI exit 0 không xác nhận công cụ tạo ảnh thành công. Giữ console/tool log đến khi PNG được xác minh; thiếu/hỏng PNG phải đọc lỗi công cụ, ưu tiên payload có cấu trúc. `usage_limit_reached` báo `QUOTA`, giữ HTTP status, thông báo và reset do dịch vụ trả về, không retry. Không có bằng chứng lỗi thì báo thiếu/hỏng output, nguyên nhân chưa rõ. Quota không đọc được là chưa xác định; hạn mức Codex hiển thị không chứng minh công cụ tạo ảnh còn lượt.

## 2. Đúng sản phẩm và từng chi tiết

- Ảnh sản phẩm quyết định thiết kế, cấu tạo, vật liệu, màu, vân và các thành phần bán kèm. Đọc ảnh đầu vào hiện tại, không chỉ suy luận từ tên hoặc handle.
- Chú ý chi tiết, không chỉ giống tổng thể. Với áo: hình cổ, mép viền, thứ tự màu, số/độ rộng sọc, đường may, nút, nẹp, mảng phối và vị trí logo. Với nội thất: hình dáng, cạnh, độ dày, vân, chân đỡ, lưng/mặt ghế và tỉ lệ. Đưa đặc điểm nhìn thấy cụ thể vào yêu cầu tạo ngay từ đầu.
- Không thêm/bớt hoặc đơn giản hóa chi tiết để ảnh trông đẹp hơn. Không lấy thiết kế sản phẩm từ áo của người mẫu hay đồ trong phòng tham khảo. Góc nhìn và ánh sáng có thể đổi cách hiển thị, không đổi cấu tạo.
- Xác định bàn riêng hay cả bộ từ nguồn; không mặc định có ghế bán kèm hoặc luôn có 12 ghế. Ghi nhận giới hạn của ảnh nguồn; không bịa chi tiết bị che khuất.
- Không hứa giữ chính xác 100% hình dáng/vân chỉ vì prompt có yêu cầu. Khi được yêu cầu kiểm tra ảnh, đối chiếu thực tế và nêu rõ phần chưa xác minh.

## 3. Bối cảnh tự nhiên và ghế đi kèm

- Ảnh tham khảo cung cấp người, không gian, góc máy và ánh sáng; không thay thế thiết kế sản phẩm.
- Với nội thất, dùng ảnh phòng có sẵn làm nền chỉnh sửa. Giữ canvas, góc máy, tường, sàn, cửa, cửa sổ và đồ không liên quan. Chỉ đổi sản phẩm, vùng nền nhỏ lộ ra khi bỏ đồ cũ và bóng tiếp xúc cần thiết.
- Không có trong ảnh gốc thì không tự thêm để dàn cảnh: giữ mặt bàn trống nếu vốn trống, không mang bát đĩa, cây, sách, người hay đồ trang trí từ ảnh sản phẩm sang phòng. Gợi ý trang trí do AI viết trong context không phải yêu cầu người dùng.
- Nếu bán cả bộ, thay đủ bàn và ghế theo nguồn; không chỉ đổi mặt bàn rồi giữ ghế cũ sai kiểu. Theo yêu cầu người dùng, các chỗ ngồi hiện có ngay quanh bàn cũng cần đồng bộ phong cách và chiều cao sử dụng, kể cả khi chỉ bán bàn; không suy ra chúng được bán kèm.
- Bàn trà thấp cần chỗ ngồi phù hợp, không giữ ghế ăn cao chỉ vì có sẵn. Dùng kiểu ghế được nguồn hiện tại hỗ trợ; không áp ghế gỗ cong/mặt đan của một mẫu cho mọi sản phẩm. Không tự thêm số chỗ ngồi hoặc đổi toàn phòng.
- Giữ chân ghế, thanh nối và phần đỡ nhìn thấy liền mạch, hợp phối cảnh và tiếp xúc sàn. Không để sót đồ cũ giao nhau với sản phẩm mới.
- Màu sản phẩm chưa hòa với phòng mặc định cần chỉnh ánh sáng cục bộ, phơi sáng, cân bằng trắng và bóng; giữ màu vật liệu, lớp hoàn thiện và vân. Không đổi màu gỗ cho giống tủ/ghế hoặc làm nhạt vân, trừ khi người dùng yêu cầu đổi màu rõ ràng.

## 4. Logo và chữ

- Chỉ thay thương hiệu khi logo thực sự in, khắc, thêu hoặc gắn trên sản phẩm; giữ vị trí và cách thể hiện vật lý đó. Không có logo vật lý thì không thêm logo, chữ góc ảnh hoặc biển tên trên tường.
- Watermark, logo cửa hàng góc ảnh và địa chỉ web là lớp phủ, không phải logo sản phẩm. Không biến chúng thành thương hiệu giả hoặc đồ vật trong cảnh; tránh chọn ảnh nền có watermark.
- Thương hiệu giả phải hoàn chỉnh, không giữ chữ hướng dẫn như “put your brand on it”, “your logo”, “your brand” hoặc lời nhắc điền tên.

## 5. Giao diện và kho ảnh

- Danh sách bên trái, nút thao tác bên phải, Bắt đầu/Dừng bên dưới. Thêm/sửa trong popup; lưu xong mỗi sản phẩm một dòng nhỏ có thumbnail/trạng thái, bấm để xem lại đúng link/ảnh. Hạn chế chữ đậm, hỗ trợ danh sách lớn.
- Khi chạy, giữ nguyên nhãn các nút và chỉ đổi trạng thái enabled/disabled; hiệu ứng chạy chỉ xuất hiện ở dòng trạng thái bên phải. Nút Dừng vẫn dùng được để hủy lượt đang chạy.
- Màn duyệt kết quả hiển thị mỗi đánh giá một dòng, kể cả cùng sản phẩm. Giữ/Bỏ chỉ tác động dòng đó; bấm thumbnail xem ảnh lớn và ảnh gốc đối chiếu. CSV cuối chỉ gồm các đánh giá được giữ. Không gộp mảng kết quả thành một mục khi đọc JSON trên Windows PowerShell.
- Dán clipboard, chọn file hoặc kéo thả ảnh cho từng URL. Đổi URL không mang ảnh cũ sang. Hủy popup không thay dữ liệu. Lưu snapshot/hash; không dùng ảnh của URL khác hoặc âm thầm thay ảnh chỉ định bằng ảnh trong kho.
- Khi chạy song song hoặc phục hồi, gắn đường dẫn, file ảnh và kết quả với đúng ItemId và snapshot của lượt đó; không nhận hoặc chép ảnh từ lượt khác. Nếu hai sản phẩm khác nhau có cùng hash ảnh xuất, báo nghi vấn và giữ lại để kiểm tra, không đánh dấu hoàn tất; hash trùng là bằng chứng ảnh giống nhau, chưa xác định nguyên nhân lẫn file.
- Hai đầu vào riêng: ảnh sản phẩm gốc quyết định thiết kế; ảnh bối cảnh quyết định người/phòng cần chỉnh. Web chưa public vẫn dùng ảnh gốc trực tiếp; có đủ ảnh thì không cần link thật. Khi thiếu/hỏng ảnh đã chỉ định phải báo lỗi, không âm thầm tải web hoặc đổi ảnh khác.
- “Một ảnh = một sản phẩm” nói về ảnh review: mỗi ảnh review tạo một kết quả riêng, dùng cùng ảnh sản phẩm gốc của URL đó. Không gộp hai ảnh review trong một lượt, không bỏ ô ảnh sản phẩm gốc hoặc coi ảnh review là ảnh gốc. Mỗi lượt mới dùng một ảnh review và một ảnh sản phẩm gốc; không thêm ảnh phong cách thứ ba.
- Ảnh review cung cấp cách trình bày, người và bối cảnh đang có. Nếu ảnh review chỉ có áo gấp/đặt trên bàn, giữ cách trình bày đó, không yêu cầu thêm ảnh người hoặc tự bịa người mẫu. Áo gốc chụp phẳng/gấp vẫn thuộc luồng quần áo, không phân loại thành đồ nội thất hoặc ép ảnh review phải có bàn.
- Ảnh người dùng gắn được dùng trực tiếp, không chặn vì kích thước tối thiểu hay chấm chất lượng/độ phù hợp. Không thêm lại thông báo “Reference image is too small” hoặc bước xét ảnh trước khi tạo. Giữ đúng cặp ảnh đã chọn và hash đầu vào.
- Kho dùng tên tiếng Việt có dấu theo nhóm hàng chung như `Áo`, `Nội thất`; không chia theo website, không gọi kho áo là kho cả quần áo. Giữ nhóm khác để dùng về sau. `source_group` là nhóm thư mục; `category` là mã danh mục chi tiết để chọn ảnh và áp dụng bài học.
- Chuyển kho phải cập nhật đường dẫn, giữ nguồn, hash và lịch sử sử dụng. Kiểm tra inventory thực tế trong catalog, không coi số đếm trong tài liệu là luôn cập nhật.
- (Hàm chọn ảnh từ kho cũ chỉ còn cho test, app không gọi.) Khi chọn, đúng danh mục, góc ghép, độ nét và diện tích thay thế tương đương; phòng bàn nhỏ hoặc bàn tiệc quá dài không mặc nhiên hợp sản phẩm khác. Không kéo dài sản phẩm để lấp đồ cũ. Tránh CGI, collage, ảnh cận hoặc bị che vùng ghép.
- Luân phiên ảnh phù hợp theo lịch sử. Có một ảnh đạt thì dừng tìm, không cần đủ số ảnh tối đa. FIT/NOFIT đã lưu chỉ áp dụng khi khớp cả URL sản phẩm và hash ảnh; FIT chỉ nói về bối cảnh, không xác nhận chất lượng kết quả.
- Dữ liệu bổ sung cần file thật, nguồn, SHA256, kích thước và ghi nhận kiểm tra. Phân biệt gallery khách hàng, ảnh nhà sản xuất và ảnh review; không gắn nhãn Judge.me cho nguồn khác.
- Có review chữ không có nghĩa có ảnh phù hợp. Khi cần dùng kho mà không có ảnh đạt, lưu missing-data và giữ URL; không tự tạo phòng thay thế.

## 6. Review mẫu và báo cáo

- Rating mẫu random độc lập từng review: 55% cho 5 sao, 45% cho 4 sao; batch nhỏ không bắt buộc đúng tỉ lệ tuyệt đối.
- Kho tên nam/nữ dùng dạng tên riêng + chữ cái đầu của họ, ví dụ `Josh K.`; mỗi tên riêng một dòng, không nhân từng tên với họ A–Z. Xáo trộn, dùng hết kho trước khi lặp; đây là tên cho dữ liệu mẫu.
- Dùng toàn bộ `review-samples.jsonl` làm một kho cách viết chung, không lọc theo danh mục hoặc phụ thuộc kho ảnh. Mỗi dòng chỉ giữ `body`, bỏ ID, URL nguồn và metadata sản phẩm; chuẩn hóa khoảng trắng, bỏ dòng rỗng và nội dung trùng trên toàn kho. Mỗi review chọn ngẫu nhiên một mẫu để học cách diễn đạt, nhịp và độ dài, lưu lại đúng đoạn mẫu đã dùng.
- Nội dung review phải theo ảnh sản phẩm hiện tại; không lấy đặc điểm sản phẩm, tuyên bố hoặc trải nghiệm từ mẫu. Không áp bộ kiểu viết định sẵn hoặc gợi ý một cụm mở đầu cố định cho mọi review.
- Không viết câu cảm thán, dấu chấm than hoặc thán từ phấn khích, kể cả mẫu tham khảo có dùng; diễn đạt nhận xét bằng câu bình thường.
- Review mẫu viết như bình luận nhanh về điều nhìn thấy; không ép mở đầu bằng chi tiết sản phẩm hoặc lặp khuôn “The…”. Cho phép phản ứng cá nhân, câu cụt, viết thường, dấu câu thoải mái và lỗi chính tả/ngữ pháp nhỏ; không cố rải lỗi hay thay bằng một khuôn mở đầu khác.
- Không bắt buộc hoặc cấm tuyệt đối “I like”, “I love”, “tôi thích”; dùng tự nhiên và đa dạng. Không bịa trải nghiệm mua hàng, giao hàng hay sử dụng. Đây là dữ liệu mẫu được tạo, không phải lời chứng thực khách thật.
- Phân biệt thời gian một lượt AI với tổng thời gian sản phẩm; giữ timeout, tiến độ, số lượt thử và lý do lỗi. Không tắt tiến trình không thuộc lượt workflow.
- Báo riêng code đã sửa, kiểm tra offline, ảnh đã tạo thật và ảnh đã xem đối chiếu. Không dùng mock để khẳng định chất lượng ảnh đã đạt. Ghi bài học không có nghĩa lỗi đã được sửa và kiểm chứng.
- Chỉ nói đã cập nhật Git sau commit/push thành công. Kiểm tra diff, giữ thay đổi đang có và không đưa output tạm vào repository.
- CSV Loox: giữ đúng 8 tên cột theo template tải trực tiếp của Loox, header không có dấu nháy hoặc BOM; xuất UTF-8, ngày `YYYY-MM-DD` và boolean viết hoa. Khi Loox báo lỗi cột, kiểm tra đúng file người dùng đã upload trước khi quy lỗi cho việc chọn nhầm file. Khác biệt định dạng chỉ là giả thuyết cho đến khi import thực tế được xác nhận.
- Bàn giao Drive: kiểm tra kết nối trước khi tạo; upload tuần tự và chỉ ghi link HTTPS công khai vào CSV. Upload lỗi không được âm thầm thay bằng đường dẫn local hay đánh dấu hoàn tất. Giữ ảnh, nội dung và snapshot để thử lại upload, không tạo ảnh lại; giữ cả các cảnh đã thành công của cùng URL đến khi toàn bộ URL hoàn tất.

## 7. Cách ghi bài học

- Quy tắc chung ở các mục trên dành cho người/agent sửa dự án. Các bài học theo URL/danh mục mà luồng tạo ảnh đọc nằm trong các mục gạch đầu dòng bên dưới. Không chỉ thêm văn xuôi rồi coi như app đã nhận bài học theo phạm vi.
- Agent phải đúc kết mỗi bài học thành 1–3 gạch đầu dòng ngắn: nguyên tắc cần giữ, điều cần tránh và phạm vi nếu cần. Không bê nguyên lời người dùng, kể lịch sử xử lý hoặc lặp một ý thành đoạn văn dài. Thêm dấu gạch trước bản chép nguyên văn chưa phải đúc kết.
- Viết tiếng Việt, tự đủ nghĩa khi clone source mới. Không yêu cầu ảnh, log hoặc batch cũ trong `workspace` để hiểu bài học; đường dẫn lịch sử chỉ là bằng chứng phụ. Ảnh hiện tại không rõ thì ghi nhận chưa xác minh.
- Giữ `id` khi làm rõ bài học cũ để liên kết bật/tắt còn đúng. Cập nhật mục trùng thay vì chép lặp; lỗi riêng của một mẫu không biến thành thiết kế bắt buộc cho cả danh mục. Không tự biến lời AI thành yêu cầu người dùng.
- Khi cập nhật bài học, agent phải hiểu ngữ cảnh rồi rút ra quy tắc áp dụng lại được; giữ đúng ý người dùng, không tự thêm yêu cầu hay đánh dấu ảnh đã duyệt. Ví dụ “màu chưa hợp” được đúc kết thành “Hòa ánh sáng và bóng cục bộ; giữ màu vật liệu và vân gốc”.

## 8. Vị trí cần đọc khi sửa

- `src/application/agent-lessons.ps1`: đọc khối bài học trong file này.
- `src/application/image-feedback.ps1`: lọc bài học theo URL/danh mục để đưa vào prompt.
- `src/workflow/steps/02-select-references.ps1`: chọn ảnh tham khảo và lịch sử dùng kho.
- `src/workflow/steps/03-create-image.ps1`: vai trò ảnh đầu vào và yêu cầu tạo ảnh.
- `src/workflow/steps/04-complete-image.ps1`, `src/infrastructure/image-output.ps1`: xuất PNG và phục hồi lỗi kết nối.
- `src/application/reference-archive.ps1`: snapshot, nguồn và hash đầu vào.
- `data/source-photos/catalog.json`: inventory và thông tin nguồn ảnh. Ảnh nằm trên Drive (tab Nguồn ảnh của trang quản lý), app tải theo nhóm về `data/source-photos/<nhóm>/`; không commit ảnh kho vào Git.
- `hub/extension/` (extension Tools Hub trong Chrome chính, dùng chung), `hub/bridge/`, `src/infrastructure/browser-bridge.ps1`: tạo ảnh qua tab Google Flow / ChatGPT, viết chữ qua Gemini web (ô Viết review / Tạo ảnh cạnh Bắt đầu → `-TextBackend` / `-ImageBackend`; Gemini thay Codex ở mọi bước chữ trong `Invoke-AI`). Không dùng API key; Gemini CLI không còn đăng nhập Google được. CLI dùng Antigravity (`agy`, `src/infrastructure/antigravity.ps1`): prompt và ảnh vào một thư mục riêng vì agy chỉ nhận prompt qua `-p`. Không tự đổi AI: chạy lỗi với AI khác thì hỏi người dùng có chạy lại bằng Codex không. Chạy trong Chrome chính của máy (tab riêng, nhóm Tools Hub). Tab nền hay cửa sổ bị che thì trang không chạy: mỗi việc đưa tab của nó lên trước. Flow chỉ nhận cú bấm thật (`chrome.debugger`); sau khi tải ảnh tham khảo Flow vẽ lại ô nhập, phải tìm lại.
- `tests/run.ps1`: chạy suite liên quan bằng Windows PowerShell khi được phép.
- `workspace/output/`: kết quả và log cục bộ, Git bỏ qua.

<!-- app-lessons:start -->
## Bài học đã đúc kết

Bài học được đúc kết thành nguyên tắc ngắn để áp dụng lần sau, không chép lời phản hồi hoặc kể lịch sử xử lý. Chỉ áp dụng đúng URL/danh mục; yêu cầu mới nhất của người dùng có ưu tiên cao nhất. Comment giữ mã và phạm vi để app đọc, bật/tắt bài học.

### Giữ cấu tạo ghế đầy đủ
<!-- app-lesson: {"id":"2b459eefc9514ffa999909bbc85d42ea","scope":"product","product_url":"https://bangometay.com/p/ban-go-tu-nhien-chan-tang-nguyen-khoi-tu-nhien-2m8x85x6-5cm/","category":"dining-tables","created_at":"2026-10-26T07:04:24.644366Z"} -->
Áp dụng: https://bangometay.com/p/ban-go-tu-nhien-chan-tang-nguyen-khoi-tu-nhien-2m8x85x6-5cm/.

- Giữ chân ghế, thanh nối, lưng và mặt ghế nhìn thấy liền mạch, đúng phối cảnh và tiếp xúc sàn.
- Không để chân bị cụt, đứt hoặc xuyên đồ vật; không đoán phần bị che.

### Đồng bộ bàn và ghế theo nguồn
<!-- app-lesson: {"id":"f84798614e0d45a1a9d46ec91a0b33ca","scope":"product","product_url":"https://bangometay.com/p/ban-go-tu-nhien-chan-tang-nguyen-khoi-tu-nhien-2m8x85x6-5cm/","category":"dining-tables","created_at":"2026-10-26T07:12:01.185526Z"} -->
Áp dụng: https://bangometay.com/p/ban-go-tu-nhien-chan-tang-nguyen-khoi-tu-nhien-2m8x85x6-5cm/.

- Bộ bàn ghế phải giữ đúng thiết kế cả bộ; không chỉ thay bàn rồi giữ ghế sai kiểu.
- Nếu chỉ bán bàn, phối các ghế hiện có theo yêu cầu; không tự thêm ghế hoặc coi ghế là hàng bán kèm.

### Hòa ánh sáng, giữ màu vật liệu
<!-- app-lesson: {"id":"7aeb3fcd590741439c8b449ca7d36cc3","scope":"product","product_url":"https://bangometay.com/p/ban-go-tu-nhien-chan-tang-nguyen-khoi-tu-nhien-2m8x85x6-5cm/","category":"dining-tables","created_at":"2026-10-26T07:36:05.4286701Z"} -->
Áp dụng: https://bangometay.com/p/ban-go-tu-nhien-chan-tang-nguyen-khoi-tu-nhien-2m8x85x6-5cm/.

- Sản phẩm chưa hòa với phòng: chỉnh ánh sáng cục bộ, cân bằng trắng và bóng tiếp xúc.
- Giữ màu vật liệu, lớp hoàn thiện và vân; chỉ đổi màu vật liệu khi người dùng yêu cầu rõ.

### Ghế cho bàn ăn
<!-- app-lesson: {"id":"table-seating-dining-tables","scope":"category","product_url":"","category":"dining-tables","created_at":"2026-10-27T06:48:09.3468036Z"} -->
Áp dụng: danh mục `dining-tables`.

- Ghế quanh bàn ăn phải hợp phong cách và chiều cao sử dụng; bán cả bộ thì dùng đúng ghế của bộ. Mặt bàn là mặt phẳng cứng ngang theo sàn: không chúi về người xem hoặc lệch ngang về một hàng ghế; cạnh vẫn thu theo phối cảnh, không ép ngang khung ảnh. Giữ tỉ lệ, độ dày và chân theo nguồn, không kế thừa chân bàn cũ.
- Chỉ bán bàn thì phối ghế hiện có theo yêu cầu, không coi ghế là hàng bán kèm. Khoảng từ MẶT ĐỆM GHẾ đến MẶT DƯỚI BÀN phải thoáng rõ, đủ để đùi, đầu gối và chân; không tính khoảng hở tới mặt trên hoặc che chỗ chật bằng mép bàn.
- Cho phép chỉnh cục bộ vị trí và tỉ lệ toàn ghế khi cần, giữ kiểu ghế, số chỗ ngồi và chân chạm sàn. Không bóp thấp/kéo giãn bàn, tăng độ dày mặt hoặc đổi chân để khớp ghế; không bịa kích thước, thêm ghế hay đổi kiến trúc phòng.

### Chỗ ngồi cho bàn trà
<!-- app-lesson: {"id":"table-seating-coffee-table","scope":"category","product_url":"","category":"coffee-table","created_at":"2026-10-27T06:48:09.3592337Z"} -->
Áp dụng: danh mục `coffee-table`.

- Bàn trà thấp cần chỗ ngồi phù hợp chiều cao và phong cách; không giữ ghế ăn cao từ phòng mẫu.
- Chỉnh các chỗ ngồi liên quan đang có; không tự thêm ghế hoặc đổi toàn bộ căn phòng.

### Viền cổ mẫu polo xanh phối vai trắng
<!-- app-lesson: {"id":"polo-shoulder-block-collar-edge-20261027","scope":"product","product_url":"https://forteraapparel.com/products/work-polo-shirt-logo-shoulder-block","category":"polo-shirts","created_at":"2026-10-27T16:03:29.9593975+07:00"} -->
Áp dụng: https://forteraapparel.com/products/work-polo-shirt-logo-shoulder-block.

- Viền đúng từ trong ra ngoài: nền xanh navy → một viền trắng → mép ngoài cổ.
- Không thêm dải xanh ngoài viền trắng; giữ vị trí và độ rộng tương đối ở cả hai bên cổ.
- Chỉ áp dụng thiết kế này cho URL chỉ định; đối chiếu ảnh đầu vào hiện tại, không đoán phần không thấy.

### Chú ý chi tiết áo, không chỉ tổng thể
<!-- app-lesson: {"id":"polo-detail-fidelity-20261027","scope":"category","product_url":"","category":"polo-shirts","created_at":"2026-10-27T16:04:20.7937109+07:00"} -->
Áp dụng: danh mục `polo-shirts`.

- Đọc kỹ hình cổ, mép viền, thứ tự màu, số và độ rộng sọc, đường may, nút, nẹp, mảng phối và vị trí logo trước khi tạo.
- Giữ đúng chi tiết của mẫu hiện tại; không thêm bớt, đơn giản hóa hoặc lấy chi tiết áo người mẫu tham khảo.
- Chỉ thay thương hiệu theo quy tắc chung; ghi nhận phần bị che là chưa xác minh.

### Giữ đúng cấu tạo chân và thanh giằng
<!-- app-lesson: {"id":"coffee-table-support-topology","scope":"category","product_url":"","category":"coffee-table","created_at":"2026-10-28T10:45:54.5790622+07:00"} -->
Áp dụng: danh mục `coffee-table`.

- Giữ đúng số lượng, hướng và điểm nối của chân/thanh giằng theo ảnh sản phẩm; không tự thêm nhánh gỗ, thanh chéo hoặc đầu gỗ cụt.
- Thanh giằng phải nối hợp lý giữa các chân; không được chìa ra thành khúc gỗ không có chức năng hoặc giao xuyên nhau.
- Nếu ảnh sản phẩm có dải đỡ cong mảnh, giữ độ dày, đường cong, điểm nối và khoảng trống nhìn thấy; không biến thành khối đặc hoặc lòng chảo. Không lấy cấu tạo từ đồ cũ hay đoán phần bị che.

### Thay áo đang mặc, không đặt thêm áo vào cảnh
<!-- app-lesson: {"id":"polo-replace-worn-garment-no-extra-prop-20261028","scope":"category","product_url":"","category":"polo-shirts","created_at":"2026-10-28T08:28:26Z"} -->
Áp dụng: danh mục `polo-shirts`.

- Thay áo đang mặc bằng áo sản phẩm gốc; nếu nhóm người chính cùng mặc polo thì thay trên từng người, giữ người, tư thế, vật đang cầm và bối cảnh.
- Không giữ áo cũ rồi đặt thêm áo sản phẩm lên xe, ghế hoặc nền; không dán ảnh cắt rời, ô ảnh phụ hay thêm áo làm đạo cụ.
- Ảnh áo gốc chụp phẳng/gấp chỉ cung cấp thiết kế; cách mặc hoặc đặt áo phải theo ảnh review hiện tại.

### Tỉ lệ bàn trà trong phòng
<!-- app-lesson: {"id":"coffee-table-room-scale-proportions-20261029","scope":"category","product_url":"","category":"coffee-table","created_at":"2026-10-29T15:05:52+07:00"} -->
Áp dụng: danh mục `coffee-table`.

- Giữ dáng và tỉ lệ dài, rộng, cao của bàn theo ảnh sản phẩm; đặt bàn đúng phối cảnh, cân đối với ghế và khoảng trống hiện có trong ảnh review.
- Không phóng bàn quá lớn để lấp chỗ hoặc làm bàn ngắn, bè hơn mẫu; không suy ra kích thước thực khi nguồn không cho biết.

<!-- app-lessons:end -->
- Bridge từng do lần chạy bật (`Start-Process node`) với stdout là ống của lần chạy đó (giờ `hub/bridge/ensure.mjs` bật tách riêng); lần chạy xong ống đóng, dòng in tiếp theo làm bridge chết (EPIPE) và lần chạy sau bị "Response ended" rồi "Connection refused". Bridge bỏ qua lỗi ghi stdout/stderr, ghi lý do dừng vào `workspace/logs/bridge-exit.log`; gọi bridge lỗi mà bridge không trả lời thì `Restore-ImageBridge` bật lại trước lần thử sau.
