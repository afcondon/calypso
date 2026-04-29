// PurerlTidalWS adapter — connects to a running purerl-tidal over
// WebSocket, sends one cell's text, awaits one reply, returns
// `{ok: boolean, reply: string}` for the typed `sendCell` decoder.
//
// Uses Node's built-in WebSocket (Node ≥ 21).

const PURERL_TIDAL_WS_URL = "ws://localhost:3012/ws";
const TIMEOUT_MS = 5000;

const result = (ok, reply) => ({ ok, reply });

export const sendCellImpl = (cellText) => (onError) => (onSuccess) => () => {
  const ws = new WebSocket(PURERL_TIDAL_WS_URL);
  let resolved = false;

  const settle = (fn) => {
    if (resolved) return;
    resolved = true;
    try { ws.close(); } catch (_) { /* fine */ }
    fn();
  };

  const timer = setTimeout(() => {
    settle(() => onError(new Error(
      `purerl-tidal WS timeout (no reply in ${TIMEOUT_MS}ms at ${PURERL_TIDAL_WS_URL})`
    ))());
  }, TIMEOUT_MS);

  ws.addEventListener("open", () => {
    ws.send(cellText);
  });

  ws.addEventListener("message", (event) => {
    clearTimeout(timer);
    const reply = typeof event.data === "string"
      ? event.data
      : (event.data?.toString?.("utf8") ?? String(event.data));
    settle(() => {
      // Heuristic: purerl-tidal replies start with "OK", "ERROR", or
      // "ERR". The wire format is informal; see Handler.erl for the
      // (text-only) reply envelopes per verb.
      const isErr = reply.startsWith("ERR") || reply.startsWith("ERROR");
      onSuccess(result(!isErr, reply))();
    });
  });

  ws.addEventListener("error", (event) => {
    clearTimeout(timer);
    settle(() => {
      const message = event?.message
        ?? event?.error?.message
        ?? `WebSocket error connecting to ${PURERL_TIDAL_WS_URL}`;
      onError(new Error(message))();
    });
  });
};
