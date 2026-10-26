// Aura Island Bridge — content script.
// Reads the page's own Media Session (title/artist/playback state) plus the
// media element position, reports it to the Mac app, and polls for
// play/pause commands aimed at this tab.

const APP = "http://127.0.0.1:48123";
let tabId = null;

// Handshake: the background worker knows our tab id.
chrome.runtime.sendMessage({ type: "aura-hello" }, (res) => {
  if (res && res.tabId) tabId = res.tabId;
});

function mediaElement() {
  return document.querySelector("video") || document.querySelector("audio");
}

function currentState() {
  const md = navigator.mediaSession ? navigator.mediaSession.metadata : null;
  const el = mediaElement();
  return {
    title: (md && md.title) || document.title.replace(/\s*-\s*YouTube\s*$/, ""),
    artist: (md && md.artist) || "",
    playbackState:
      navigator.mediaSession && navigator.mediaSession.playbackState
        ? navigator.mediaSession.playbackState
        : el && !el.paused
          ? "playing"
          : "paused",
    position: el ? el.currentTime : 0,
    duration: el && isFinite(el.duration) ? el.duration : 0,
  };
}

async function report() {
  if (tabId === null) return;
  const s = currentState();
  if (!s.title) return;
  try {
    await fetch(APP + "/tab", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tabId: String(tabId),
        title: s.title,
        artist: s.artist,
        host: location.hostname,
        playbackState: s.playbackState,
        position: s.position,
        duration: s.duration,
      }),
    });
  } catch (e) {
    // App not running; retry on the next tick.
  }
}

async function pollCommands() {
  if (tabId === null) return;
  try {
    const res = await fetch(APP + "/commands?tabId=" + encodeURIComponent(tabId));
    const data = await res.json();
    if (data.command === "playpause") {
      const el = mediaElement();
      if (el) {
        if (el.paused) await el.play();
        else el.pause();
      }
    }
  } catch (e) {
    // App not running; retry on the next tick.
  }
}

setInterval(report, 1000);
setInterval(pollCommands, 1000);
report();
