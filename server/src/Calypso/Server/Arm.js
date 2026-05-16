// Arm.js — POST /arm endpoint orchestrator.
//
// Given (tvoice, cueName), open a WS to purerl-tidal and send
//   play-armed <tvoice> <cueName>
// The BEAM-side handler resolves the cue by calling
// calypso_generated_session@ps:<cueName>/0 and extracts the body
// Pattern from the newtype-elided Cue record.  No compilation
// happens here — that's what /session-source (▶ run) is for.
//
// Pre-2026-05-16 this orchestrated a per-arm bridge-module build
// (purs + purs-backend-erl + erlc + WS load).  That cost ~3s per arm
// for a one-line projection that the BEAM can do in microseconds.
// See git tag `interpreted-dsl-final-2026-05-16` for the bridge path.

const PURERL_TIDAL_WS_URL = "ws://localhost:3012/ws";
const WS_TIMEOUT_MS = 10000;

function sendPlayArmed(tvoice, cueName) {
  return new Promise((resolve) => {
    let resolved = false;
    const settle = (r) => {
      if (resolved) return;
      resolved = true;
      try { ws.close(); } catch (_) {}
      resolve(r);
    };
    const ws = new WebSocket(PURERL_TIDAL_WS_URL);
    const timer = setTimeout(() => {
      settle({ ok: false, reply: "", error: `WS timeout (${WS_TIMEOUT_MS}ms)` });
    }, WS_TIMEOUT_MS);

    ws.addEventListener("open", () => {
      ws.send(`play-armed ${tvoice} ${cueName}`);
    });
    ws.addEventListener("message", (evt) => {
      clearTimeout(timer);
      const text = typeof evt.data === "string"
        ? evt.data
        : (evt.data?.toString?.("utf8") ?? String(evt.data));
      const isErr = text.startsWith("ERR") || text.startsWith("ERROR");
      settle({ ok: !isErr, reply: text, error: isErr ? text : "" });
    });
    ws.addEventListener("error", () => {
      clearTimeout(timer);
      settle({ ok: false, reply: "", error: "WS error connecting to purerl-tidal" });
    });
  });
}

async function runArm({ tvoice, cueName }) {
  const t0 = Date.now();

  if (!/^[a-zA-Z_][a-zA-Z0-9_']*$/.test(cueName)) {
    return {
      ok: false,
      reply: "",
      error:
        `cueName "${cueName}" is not a PureScript identifier — ` +
        `set the card body to a typed cue name (e.g. bass1A), ` +
        `not a pattern expression`,
      timings: { total: 0, ws: 0 },
    };
  }

  const tWs0 = Date.now();
  const wsR = await sendPlayArmed(tvoice, cueName);
  const tWs = Date.now() - tWs0;

  return {
    ok: wsR.ok,
    reply: wsR.reply,
    error: wsR.error || "",
    timings: {
      total: Date.now() - t0,
      ws: tWs,
    },
  };
}

export const armCueImpl = (req) => () => runArm(req);
