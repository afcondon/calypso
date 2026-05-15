// Arm.js — orchestrator port of purerl-tidal/scripts/arm-cue.mjs into
// the Calypso server.
//
// Given (tvoice, cueName), synthesise a bridge module
// Tidal.Generated.M<tvoice> that extracts the body from <cueName>'s
// typeful Cue value, build it via purs + `purs-backend-erl --filter`,
// erlc the resulting .erl, then send `play-armed <tvoice> M<tvoice>`
// over WS to purerl-tidal.
//
// Differs from the standalone arm-cue.mjs: does NOT send the
// defensive `midi-device` + `bind` lines. Those were one-shot test
// setup for the bass1 demo. In production the session's devices and
// bindings are managed elsewhere (cells, future SetSession path), and
// /arm assumes the binding for <tvoice> already exists.
//
// Resolves purerl-tidal's location via $PURERL_TIDAL_ROOT, falling
// back to a sibling directory of Calypso's CWD (canonical layout:
// music/live-coding/{calypso,purerl-tidal}).

import {
  writeFileSync,
  readFileSync,
  existsSync,
  statSync,
  mkdirSync,
  rmSync,
} from "node:fs";
import { spawn, execFile } from "node:child_process";
import { dirname, join, resolve } from "node:path";

const PURERL_TIDAL_WS_URL = "ws://localhost:3012/ws";
const WS_TIMEOUT_MS = 10000;

function purerlTidalRoot() {
  if (process.env.PURERL_TIDAL_ROOT) {
    return resolve(process.env.PURERL_TIDAL_ROOT);
  }
  // Calypso runs from .../music/live-coding/calypso; sibling is
  // .../music/live-coding/purerl-tidal.
  return resolve(process.cwd(), "..", "purerl-tidal");
}

function spawnP(cmd, args, opts) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], ...opts });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d.toString(); });
    child.stderr.on("data", (d) => { stderr += d.toString(); });
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
    child.on("error", (e) => resolve({ code: -1, stdout, stderr: stderr + e.message }));
  });
}

// Derive the purs source-file glob the same way arm-cue.mjs does:
// invoke `spago build --verbose` once and pull the `purs compile …`
// line out of the trace. Cached under .arm-cue/purs-glob.txt;
// invalidated when spago.yaml is newer than the cache.
async function getPursGlob(root) {
  const cacheDir = join(root, ".arm-cue");
  const cachePath = join(cacheDir, "purs-glob.txt");
  const spagoYaml = join(root, "spago.yaml");
  mkdirSync(cacheDir, { recursive: true });

  const cacheStale =
    !existsSync(cachePath) ||
    statSync(cachePath).mtimeMs < statSync(spagoYaml).mtimeMs;

  if (!cacheStale) {
    return readFileSync(cachePath, "utf-8").trim();
  }

  const r = await spawnP("spago", ["build", "--verbose"], { cwd: root });
  const lines = (r.stdout + r.stderr).split("\n");
  for (const line of lines) {
    const i = line.indexOf("purs compile ");
    if (i >= 0) {
      const glob = line.slice(i + "purs compile ".length).trim();
      writeFileSync(cachePath, glob);
      return glob;
    }
  }
  throw new Error("could not extract purs glob from `spago build --verbose`");
}

function sendPlayArmed(tvoice, wireModule) {
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
      ws.send(`play-armed ${tvoice} ${wireModule}`);
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

function emptyResult(error) {
  return {
    ok: false,
    reply: "",
    error,
    timings: { total: 0, purs: 0, be: 0, erlc: 0, ws: 0 },
  };
}

async function runArm({ tvoice, cueName }) {
  const t0 = Date.now();
  const root = purerlTidalRoot();
  if (!existsSync(root)) {
    return emptyResult(`purerl-tidal root not found: ${root}`);
  }

  // PS module convention: leading M is the per-cell-compile prefix; the
  // tail must be all-lowercase. purs-backend-erl lowercases the .erl
  // FILE name but preserves source caps in the -module() decl, so any
  // uppercase char causes a filename/module mismatch at erlc time.
  const tvoiceTail = tvoice.toLowerCase().replace(/[^a-z0-9]/g, "");
  if (!tvoiceTail) {
    return emptyResult(`invalid tvoice: ${tvoice}`);
  }
  // Validate cueName looks like a PS identifier before we write any
  // file — otherwise a body like `mini "x ~"` lands in the bridge as
  // an import-list element, fails purs, and leaves a poisoned .purs
  // on disk that breaks ALL subsequent builds until it's removed.
  if (!/^[a-zA-Z_][a-zA-Z0-9_']*$/.test(cueName)) {
    return emptyResult(
      `cueName "${cueName}" is not a PureScript identifier — ` +
      `set the card body to a typed cue name (e.g. bass1A), ` +
      `not a pattern expression`);
  }

  const bridgeModule = `Tidal.Generated.M${tvoiceTail}`;
  const sessionModule = "Calypso.Generated.Session";
  const bridgePsPath = join(root, "src", "Tidal", "Generated", `M${tvoiceTail}.purs`);
  const bridgeErlBase = `tidal_generated_m${tvoiceTail}@ps`;
  const bridgeErlPath = join(root, "output-erl", bridgeModule, `${bridgeErlBase}.erl`);
  const buildTxt = join(root, "output-erl", "build.txt");
  const beamOut = join(root, "ebin");

  // 1. Bridge module.
  const bridgeSrc = `-- | Generated by Calypso.Server.Arm at ${new Date().toISOString()}
-- | tvoice: ${tvoice}  armed cue: ${cueName}
module ${bridgeModule} where

import Tidal.Pattern.Types (Pattern)
import Calypso.Prelude (Cue(..))
import ${sessionModule} (${cueName})

pattern :: Pattern String
pattern = case ${cueName} of
  Cue r -> r.body
`;
  try {
    writeFileSync(bridgePsPath, bridgeSrc);
  } catch (e) {
    return emptyResult(`writing bridge module: ${e.message}`);
  }

  // 2. purs compile via cached glob — much faster than `spago build`.
  let pursGlob;
  try {
    pursGlob = await getPursGlob(root);
  } catch (e) {
    return emptyResult(e.message);
  }

  const tPurs0 = Date.now();
  const pursR = await spawnP(
    "bash",
    ["-O", "globstar", "-c", `purs compile ${pursGlob}`],
    { cwd: root },
  );
  if (pursR.code !== 0) {
    return emptyResult(`purs compile failed: ${pursR.stderr || pursR.stdout}`);
  }
  const tPurs = Date.now() - tPurs0;

  // 3. Invalidate backend-erl cache; scoped emit via --filter.
  const tBe0 = Date.now();
  try { rmSync(buildTxt); } catch (_) { /* may not exist */ }
  const beR = await spawnP(
    "node_modules/.bin/purs-backend-erl",
    ["--filter", bridgeModule],
    { cwd: root },
  );
  if (beR.code !== 0) {
    return emptyResult(`backend-erl failed: ${beR.stderr || beR.stdout}`);
  }
  const tBe = Date.now() - tBe0;

  // 4. erlc bridge .erl → ebin/<bridgeErlBase>.beam.
  if (!existsSync(bridgeErlPath)) {
    return emptyResult(`bridge .erl not found after build: ${bridgeErlPath}`);
  }
  const tErlc0 = Date.now();
  const erlcR = await new Promise((resolve) => {
    execFile(
      "erlc",
      ["-disable-feature", "maybe_expr", "-o", beamOut, bridgeErlPath],
      { cwd: root },
      (err, stdout, stderr) => resolve({ code: err ? (err.code ?? -1) : 0, stdout, stderr }),
    );
  });
  if (erlcR.code !== 0) {
    return emptyResult(`erlc failed: ${erlcR.stderr || erlcR.stdout}`);
  }
  const tErlc = Date.now() - tErlc0;

  // 5. WS round-trip: ship play-armed; purerl-tidal's handler does
  //    code:load_file before dispatching to the voice gen_server.
  const tWs0 = Date.now();
  const wireModule = `M${tvoiceTail}`;
  const wsR = await sendPlayArmed(tvoice, wireModule);
  const tWs = Date.now() - tWs0;

  return {
    ok: wsR.ok,
    reply: wsR.reply,
    error: wsR.error || "",
    timings: {
      total: Date.now() - t0,
      purs: tPurs,
      be: tBe,
      erlc: tErlc,
      ws: tWs,
    },
  };
}

export const armCueImpl = (req) => () => runArm(req);
