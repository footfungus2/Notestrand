// Loaded first so library load failures reach the app (Safari's inspector can't attach to this build).
window.onerror = function (msg, src, line) {
  try {
    window.webkit.messageHandlers.lh.postMessage({ type: "error", message: String(msg) + " (" + String(src).split("/").pop() + ":" + line + ")" });
  } catch (e) {}
};
