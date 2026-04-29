// PurerlTidalWS adapter — connects to a running purerl-tidal over
// WebSocket, sends one cell's text, awaits one reply, returns it
// shaped as the BuildResult that Compile.purs decodes. Stays within
// the existing Adapter wire contract until step 4 introduces a
// Tidal-shaped response type.
//
// Uses Node's built-in WebSocket (Node ≥ 21).

const PURERL_TIDAL_WS_URL = "ws://localhost:3012/ws";
const TIMEOUT_MS = 5000;

// Shaped to satisfy Compile.purs's `buildResultCodec` decoder:
//   { js, warnings, errors, cellIds, emits }
const okResult = (reply) => ({
  js: null,
  warnings: [],
  errors: [],
  cellIds: [],
  emits: [],
  // Stash the raw reply so the frontend can surface it once it learns
  // to inspect Tidal results. Atelier's BuildResult ignores extra
  // fields on decode (codec-argonaut object decoders are width-loose
  // by default), so this round-trips through the wire safely.
  reply: reply,
});

const errResult = (reply) => ({
  js: null,
  warnings: [],
  errors: [
    {
      code: "TidalError",
      filename: null,
      position: null,
      message: reply,
    },
  ],
  cellIds: [],
  emits: [],
  reply: reply,
});

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
      onSuccess(isErr ? errResult(reply) : okResult(reply))();
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
