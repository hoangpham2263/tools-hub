# Tools Hub

Bộ công cụ bán hàng chạy trên Windows và macOS, mở bằng một launcher chung. Mỗi tool nằm trong `apps/<tool>/`.

| Tool | Chức năng |
|---|---|
| [Product Review](apps/product-review/) | Ghép sản phẩm vào ảnh review, viết review mẫu, xuất CSV Loox |
| [Grok Video Prompt](apps/grok-video-prompt/) | Chọn thời lượng 6s/10s/15s và style, copy prompt video cho Grok (prompt tạm lấy từ tài liệu GRENHEIM) |
| [Content MXH](apps/fb-content/) | Soạn bài đăng cho Facebook, Instagram, Threads, TikTok từ thông tin sản phẩm (giao diện và logic tạm) |

Mở app hiện màn hình chọn tool, mỗi tool một icon. Tool dạng web (`"web"` trong `tool.json`) mở trong trình duyệt, không cần cài thêm.

## Product Review

App tạo ảnh review sản phẩm: ghép sản phẩm thật vào ảnh bối cảnh tham khảo, viết nội dung review mẫu, rồi xuất CSV để import vào Loox. Chạy trên Windows và macOS với giao diện giống nhau.

Ảnh và review tạo ra là dữ liệu mẫu, không phải trải nghiệm của khách thật.

## Cài đặt

1. [Tải bản mới nhất](https://github.com/hoangpham2263/tools-hub/releases/latest/download/tools-hub.zip) và giải nén.
2. Mở app: `start-app.cmd` (Windows) hoặc `start-app.command` (Mac).
3. Bấm **Cấu hình**, rồi bấm **Cài** / **Đăng nhập** ở bước nào chưa đạt: mật khẩu app, Node.js, Codex, đăng nhập ChatGPT.

Có bản mới thì nút **Cập nhật** chuyển xanh; app chỉ cập nhật khi bạn bấm. `workspace/` và bài học riêng trong `AGENTS.md` được giữ. Máy mới xem [setup.txt](setup.txt).

## Chức năng

- **Thêm sản phẩm:** dán link, gắn ảnh sản phẩm gốc và ảnh review (từ máy, kho Drive hoặc dán Ctrl/Cmd+V). Một link có thể có nhiều ảnh gốc, mỗi ảnh gốc nhiều ảnh review.
- **Nhập hàng loạt:** chọn `products.csv` (ảnh để trong thư mục `images/` cạnh nó); app gắn đúng ảnh cho từng sản phẩm ([chuẩn thư mục](docs/import.md)).
- **Tạo ảnh:** mỗi cặp ảnh gốc + ảnh review cho một ảnh kết quả, giữ đúng sản phẩm; logo thật được thay bằng brand giả, watermark bị xoá.
- **Viết review:** nội dung dựa trên ảnh, học cách viết từ kho review mẫu cùng danh mục; tên, sao, email và ngày được tạo ngẫu nhiên.
- **Duyệt & xuất file:** Giữ/Bỏ từng ảnh, xong thì tạo `loox_import.csv` (chọn **Custom File** khi import vào Loox).
- **Theo dõi:** số token đã dùng và hạn mức ChatGPT hiện trực tiếp khi chạy; chọn model AI và mức suy nghĩ trong Cấu hình.
- **Kho ảnh Drive:** ảnh mẫu chia theo danh mục (Áo, Nội thất…), chọn ảnh trong app hoặc **Tải về máy** chạy nền.
- **Gửi lỗi:** gửi một file lỗi duy nhất (AI tóm tắt nguyên nhân và cách sửa, kèm lý do các đánh giá đã Bỏ – [chuẩn](apps/product-review/docs/error-report.md)); không kèm ảnh hay mật khẩu.

Luồng xử lý mặc định 2, tối đa 4. Link lỗi được giữ lại để chạy tiếp, không tạo lại ảnh đã xong.

## Trang quản lý

[hoangpham.is-a.dev/tools-hub](https://hoangpham.is-a.dev/tools-hub/) (đăng nhập bằng mật khẩu admin):

- **Ảnh đã tạo:** lọc, duyệt, copy link, tải danh sách.
- **Nguồn ảnh:** tạo danh mục, tải ảnh lên, bật/tắt danh mục hiện trong app.
- **Log người dùng:** tải về hoặc xoá log app gửi lên.
- **API:** tài liệu cho AI và **mã tạm** có thời hạn để AI tự tải ảnh lên kho ([docs/api.md](docs/api.md)).
- **Nhập hàng loạt:** chuẩn file nhập và file mẫu, xem được không cần đăng nhập.

## Mật khẩu

- **Mật khẩu app:** nhập trong app; tải ảnh kết quả lên, dùng kho ảnh, gửi log.
- **Mật khẩu admin:** chỉ cho trang quản lý; không đưa cho người dùng app.
- **Mã tạm:** tạo ở trang API, chỉ xem và thêm ảnh vào kho, tự hết hạn.

## Kết quả mỗi lần chạy

```
apps/product-review/workspace/output/<thời-gian>/
  images/            ảnh kết quả
  refs/              bản sao ảnh đầu vào kèm nguồn và SHA256
  logs/              log AI và lỗi từng sản phẩm
  results.json       kết quả chờ duyệt
  loox_import.csv    có sau khi duyệt xong
  missing-data.csv   (nếu có) sản phẩm thiếu ảnh mẫu
```

Trên Drive, mỗi tool có một thư mục trong `Tools Hub/`; Product Review dùng `Tools Hub/Product Review/`: `Ảnh đã tạo/`, `Nguồn ảnh/`, `Logs/`.

## Cấu trúc

```
start-app.cmd / start-app.command   mở Tools Hub
hub/                launcher (chọn tool), cập nhật, dọn cấu trúc cũ
apps/<tool>/        một tool: tool.json, src/, data/, tests/, docs/, AGENTS.md, workspace/ (không lên Git)
hub/extension       extension Tools Hub (dùng chung): làm việc trong tab Google Flow, Gemini, ChatGPT
apps/product-review/bridge   cầu nối local giữa Product Review và extension
hub/browser.mjs     Chrome riêng của tool (workspace/browser): đăng nhập một lần từ Cấu hình, lúc chạy mở ẩn
worker/             Cloudflare Worker tools-hub-api (Drive); legacy-redirect/ giữ địa chỉ cũ
docs/               trang quản lý (GitHub Pages) và tài liệu API
scripts/            công cụ chuẩn bị dữ liệu, đẩy ảnh lên kho
workspace/          trạng thái của hub (phiên bản, bản sao lưu), không lên Git
```

Thêm tool mới: tạo `apps/<id>/tool.json` (`id`, `name`, `description`, `icon`, và `windows` + `mac` hoặc `web`) cùng `icon.svg` + `icon.png`; launcher tự hiện tool đó. Giao diện web dùng chung `hub/assets/tool.css`.
Kiểm thử Product Review: `apps/product-review/test.cmd` (Windows), `apps/product-review/test.sh` (Mac). Chi tiết workflow: [apps/product-review/docs/workflow.txt](apps/product-review/docs/workflow.txt); hướng dẫn cho AI: [AGENTS.md](AGENTS.md) và [apps/product-review/AGENTS.md](apps/product-review/AGENTS.md).

## Phát hành

```bash
git tag v1.0.x && git push origin v1.0.x
```

GitHub Actions tạo Release; người dùng bấm **Cập nhật** trong app.

## Ghi công

Danh sách tên trong `apps/product-review/data/names.txt` dùng Names Corpus 1.3 (Mark Kantrowitz, bổ sung bởi Bill Ross); điều khoản ở [data/names-LICENSE.txt](apps/product-review/data/names-LICENSE.txt).
