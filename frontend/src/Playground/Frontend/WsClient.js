export const _connect = (url, callbacks) => {
  const ws = new WebSocket(url);
  ws.addEventListener("open", () => callbacks.onOpen());
  ws.addEventListener("message", (ev) => {
    if (typeof ev.data === "string") {
      callbacks.onMessage(ev.data)();
    }
    // binary frames intentionally ignored — Atelier only exchanges JSON
  });
  ws.addEventListener("close", (ev) => {
    callbacks.onClose(ev.code)(ev.reason)();
  });
  ws.addEventListener("error", () => callbacks.onError());
  return ws;
};

export const _send = (ws, data) => {
  if (ws.readyState === 1) {
    ws.send(data);
  }
};

export const _close = (ws) => {
  try { ws.close(); } catch (_) { /* already closed */ }
};
