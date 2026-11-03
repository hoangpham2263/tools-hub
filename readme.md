# Tools Hub

A set of e-commerce tools for Windows and macOS, opened from one shared launcher. Each tool lives in `apps/<tool>/`.

| Tool | Purpose |
|---|---|
| [Product Review](apps/product-review/) | Places products into review images, writes sample reviews and exports a Loox CSV |
| [Grok Video](apps/grok-video-prompt/) | From one product image (and a model image), Grok on the web creates a video of about 1 minute moving around the product, with connected scenes |
| [Content MXH](apps/fb-content/) | Drafts Facebook, Instagram, Threads and TikTok posts from product information (temporary interface and logic) |

Opening the app shows a tool picker, with one icon per tool. Web tools (`"web"` in `tool.json`) open in the browser and need no extra installation.

## Product Review

Creates product review images by placing the real product into a reference scene, writes sample review content, then exports a CSV to import into Loox. It runs on Windows and macOS with the same interface.

The generated images and reviews are sample data, not real customer experiences.

## Installation

1. [Download the latest version](https://github.com/hoangpham2263/tools-hub/releases/latest/download/tools-hub.zip) and extract it.
2. Open the app: `start-app.cmd` (Windows) or `start-app.command` (Mac).
3. Click **Cấu hình** (Settings), then click **Cài** (Install) or **Đăng nhập** (Sign in) for any step that is not ready: app password, Node.js, Codex, ChatGPT sign-in.

When a new version is available, the **Cập nhật** (Update) button turns green; the app updates only when you click it. `workspace/` and your own lessons in `AGENTS.md` are kept. For a new machine, see [setup.txt](setup.txt).

## Features

- **Add products:** paste a link and attach original product images and review images (from your machine, the Drive library or Ctrl/Cmd+V). One link can have several original images, and each original image several review images.
- **Bulk import:** choose `products.csv` (with images in an `images/` folder next to it); the app attaches the right images to each product ([folder standard](docs/import.md)).
- **Image generation:** each pair of original and review images produces one result image and keeps the exact product; products appear unbranded with no added text; every AI uses the same prompt.
- **Review writing:** content is based on the image and learns its style from sample reviews in the same category; names, stars, emails and dates are randomly generated.
- **Approval and export:** Keep or Remove each image, then create `loox_import.csv` (choose **Custom File** when importing into Loox).
- **Monitoring:** tokens used and the ChatGPT quota appear live during a run; choose the AI model and reasoning level in Settings.
- **Drive image library:** sample images are grouped by category (Áo, Nội thất and so on); pick images in the app or use **Tải về máy** (Download to machine) in the background.
- **Error reports:** send one error file (AI summarizes the cause and fix, with the reasons for removed reviews; see the [standard](apps/product-review/docs/error-report.md)); no images or passwords are included.

Processing uses 2 threads by default, up to 4. Failed links are kept so the run can continue, and finished images are not generated again.

## Admin page

[hoangpham.is-a.dev/tools-hub](https://hoangpham.is-a.dev/tools-hub/) (sign in with the admin password):

- **Generated images:** filter, review, copy links, download the list.
- **Image sources:** create categories, upload images, choose which categories show in the app.
- **User logs:** download or delete logs sent by the app.
- **API:** documentation for AI and time-limited **temporary codes** that let AI upload images to the library ([docs/api.md](docs/api.md)).
- **Bulk import:** import file standard and sample file, available without signing in.

## Passwords

- **App password:** entered in the app; used to upload result images, use the image library and send logs.
- **Admin password:** only for the admin page; do not give it to app users.
- **Temporary code:** created on the API page; it can only view and add images to the library, and it expires automatically.

## Output of each run

```
apps/product-review/workspace/output/<timestamp>/
  images/            result images
  refs/              copies of input images with source and SHA256
  logs/              AI logs and per-product errors
  results.json       results awaiting approval
  loox_import.csv    created after approval
```

On Drive, each tool has a folder in `Tools Hub/`; Product Review uses `Tools Hub/Product Review/`: `Ảnh đã tạo/` (generated images), `Nguồn ảnh/` (image sources), `Logs/`.

## Structure

```
start-app.cmd / start-app.command   opens Tools Hub
hub/                launcher (tool picker), updates, cleanup of the old layout
apps/<tool>/        one tool: tool.json, src/, data/, tests/, docs/, AGENTS.md, workspace/ (not in Git)
hub/extension       Tools Hub extension for the machine's Chrome: works in Google Flow, Gemini and ChatGPT tabs
hub/bridge          local bridge between tools and the extension (started by ensure.mjs), runs in parallel within per-site limits
hub/ai              shared AI core (Invoke-HubAI): Codex, Gemini, Flow, ChatGPT, Antigravity
hub/browser.mjs     Chrome for Testing for the app window on macOS
worker/             Cloudflare Worker tools-hub-api (Drive); legacy-redirect/ keeps the old addresses
docs/               admin page (GitHub Pages) and API documentation
scripts/            tools for preparing data and uploading images to the library
workspace/          hub state (version, backups), not in Git
```

To add a tool, create `apps/<id>/tool.json` (`id`, `name`, `description`, `icon`, and `windows` + `mac` or `web`) with `icon.svg` and `icon.png`; the launcher shows it automatically. Web interfaces share `hub/assets/tool.css`.
Product Review tests: `apps/product-review/test.cmd` (Windows), `apps/product-review/test.sh` (Mac). Workflow details: [apps/product-review/docs/workflow.txt](apps/product-review/docs/workflow.txt); AI guidance: [AGENTS.md](AGENTS.md) and [apps/product-review/AGENTS.md](apps/product-review/AGENTS.md).

## Releases

```bash
git tag v1.0.x && git push origin v1.0.x
```

GitHub Actions creates the Release; users click **Cập nhật** (Update) in the app.

## Credits

The name list in `apps/product-review/data/names.txt` uses Names Corpus 1.3 (Mark Kantrowitz, with additions by Bill Ross); terms are in [data/names-LICENSE.txt](apps/product-review/data/names-LICENSE.txt).
