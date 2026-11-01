// Gemini (gemini.google.com): attach the images, type the prompt, send, then return the reply's text once it has
// finished. Used for the workflow's text steps (Viết review: Gemini web); a plain click sends here.
function geminiReplyText(markdown) {
  // Code blocks carry a language label and buttons; keep only their code.
  const copy = markdown.cloneNode(true);
  for (const block of copy.querySelectorAll("code-block, .code-block")) {
    const code = block.querySelector("code");
    block.replaceWith(document.createTextNode(`\n${code ? code.textContent : block.textContent}\n`));
  }
  document.body.append(copy);
  Object.assign(copy.style, { position: "fixed", left: "-10000px", top: "0", width: "800px" });
  const text = copy.innerText;
  copy.remove();
  return text.trim();
}

async function generateGemini(job) {
  const editor = await waitFor(() => document.querySelector('.ql-editor[contenteditable="true"]'), 30000, "ô nhập Gemini (đã đăng nhập Google chưa?)");
  const before = document.querySelectorAll("model-response").length;
  const files = filesFromJob(job);
  await pasteFiles(editor, files);
  typePrompt(editor, job.prompt);
  // The send button stays off while attachments upload.
  const send = await waitFor(() => {
    // The send control is a gem-icon-button.send-button: "submit" with text to send, "stop" while answering.
    const button = document.querySelector(".send-button.submit button");
    return button && !button.disabled && button.getAttribute("aria-disabled") !== "true" ? button : null;
  }, 180000, "tải ảnh đính kèm lên Gemini");
  send.click();

  // Finished: a new reply, no stop button, not busy, and its text unchanged for two checks in a row.
  let last = "";
  const markdown = await waitFor(() => {
    const replies = document.querySelectorAll("model-response");
    if (replies.length <= before) return null;
    const md = replies[replies.length - 1].querySelector(".markdown");
    if (!md || md.getAttribute("aria-busy") === "true" || document.querySelector(".send-button.stop")) return null;
    const text = md.innerText.trim();
    if (!text || text !== last) { last = text; return null; }
    return md;
  }, (job.timeoutSec || 300) * 1000, "Gemini trả lời");
  return { text: geminiReplyText(markdown), source: location.href };
}

onJob(generateGemini);
