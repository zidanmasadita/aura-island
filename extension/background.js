// Aura Island Bridge — background service worker.
// Only two jobs: hand tab ids to content scripts, and report closed tabs
// to the Mac app so stale sessions disappear from the picker.

const APP = "http://127.0.0.1:48123";

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "aura-hello" && sender.tab && sender.tab.id !== undefined) {
    sendResponse({ tabId: sender.tab.id });
  }
  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  fetch(APP + "/tab-gone", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ tabId: String(tabId) }),
  }).catch(() => {});
});
