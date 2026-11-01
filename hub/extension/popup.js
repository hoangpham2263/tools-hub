chrome.runtime.sendMessage({ type: "status" }, (status) => {
  const state = document.getElementById("state");
  state.textContent = status?.connected ? "Đã kết nối app local" : "Chưa kết nối app local (bridge chưa chạy)";
  state.className = status?.connected ? "ok" : "off";
});
