// PurerlTidalWS adapter — connects to a running purerl-tidal over
// WebSocket, sends one cell's text, awaits one reply, returns
// `{ok: boolean, reply: string}` for the typed `sendCell` decoder.
//
// Uses Node's built-in WebSocket (Node ≥ 21).

// Pin to 127.0.0.1 explicitly — `localhost` can resolve to ::1 on macOS
// and Node's WebSocket connect fails when the BEAM listens IPv4-only.
// CLI Node tests with Happy Eyeballs succeed; in-process behaviour
// here was hitting "WS error connecting" reliably (2026-05-24).
const PURERL_TIDAL_WS_URL = "ws://127.0.0.1:3012/ws";
// 30s — covers cold per-cell compiles (~7s today via spago build +
// purs-backend-erl re-emit; PR4's daemon path will drop this to
// ~100-300ms and we can pull the timeout back down then).  Most
// non-cue verbs round-trip in single-digit ms.
const TIMEOUT_MS = 30000;

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
