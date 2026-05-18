// SessionSource.js — write + build a typeful Calypso session module.
//
// Given the composition pane's source text, write it to
// purerl-tidal/src/Calypso/Generated/Session.purs, run
//   purs compile (with cached glob)
//   purs-backend-erl --filter Calypso.Generated.Session
//   erlc the changed Session .erl
// then send `reload-baseline` over WS so the BEAM picks up the new
// Session module.  Currently-playing voices keep their captured
// Pattern funs; calls inside those funs late-bind to the new Session
// via BEAM's code server, so audible state may pick up new bodies
// without re-arming.  Re-arming guarantees a clean swap.
//
// Shares helpers with Arm.js conceptually but kept separate for now;
// extract to a SessionBuild helper module if a third caller appears.

import {
  writeFileSync,
  readFileSync,
  existsSync,
  statSync,
  mkdirSync,
  rmSync,
} from "node:fs";
import { spawn, execFile } from "node:child_process";
import { join, resolve } from "node:path";

// Buffer-vs-disk divergence logger.  Surfaces to server stderr when the
// incoming fire-typeful POST is about to overwrite disk content the
// browser was never shown — the stale-buffer-clobbers-correct-disk
// footgun from 2026-05-17.  Inlined (vs shared module) because purs
// compile copies FFI .js into per-module output dirs, breaking
// relative-import resolution.
function logDivergence(diskPath, incomingSource, label) {
  if (!existsSync(diskPath)) return;
  let onDisk;
  try { onDisk = readFileSync(diskPath, "utf-8"); } catch (_) { return; }
  if (onDisk === incomingSource) return;
  const dl = onDisk.split("\n");
  const il = incomingSource.split("\n");
  const dset = new Set(dl);
  const iset = new Set(il);
  const added   = il.filter((l) => !dset.has(l));
  const removed = dl.filter((l) => !iset.has(l));
  if (added.length === 0 && removed.length === 0) return;
  const head = (xs) => xs.slice(0, 5).map((l) => `  ${l}`).join("\n");
  const more = (xs) => xs.length > 5 ? `\n  … (${xs.length - 5} more)` : "";
  console.error(
    `[divergence] ${label}: incoming POST differs from disk ` +
    `(+${added.length} / -${removed.length} unique lines). ` +
    `Stale browser buffer about to clobber out-of-band edits?\n` +
    (removed.length > 0 ? `  --- on disk, NOT in incoming ---\n${head(removed)}${more(removed)}\n` : "") +
    (added.length   > 0 ? `  --- in incoming, NOT on disk ---\n${head(added)}${more(added)}\n` : "")
  );
}

const PURERL_TIDAL_WS_URL = "ws://localhost:3012/ws";
const WS_TIMEOUT_MS = 10000;

function purerlTidalRoot() {
  if (process.env.PURERL_TIDAL_ROOT) {
    return resolve(process.env.PURERL_TIDAL_ROOT);
  }
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

function sendReloadBaseline() {
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
      ws.send("reload-baseline");
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
    pursErrorsJson: "",
    timings: { write: 0, purs: 0, be: 0, erlc: 0, ws: 0, total: 0 },
  };
}

async function runBuild({ source }) {
  const t0 = Date.now();
  const root = purerlTidalRoot();
  if (!existsSync(root)) {
    return emptyResult(`purerl-tidal root not found: ${root}`);
  }

  if (!source || !source.includes("module ")) {
    // Cheap pre-flight: a typeful session is a PureScript module, so
    // it MUST contain a `module ...` declaration. Catching this here
    // saves a full purs round-trip when the user fires Level-2 text.
    return emptyResult(
      "source is empty or missing a `module ...` declaration — " +
      "the composition pane must be a PureScript module for the " +
      "typeful path (try `module CalypsoSession where`)");
  }

  // 1. Write the session file. The on-disk module name is fixed:
  //    Calypso.Generated.Session. We don't validate that the source
  //    declares this name — purs will, and the error is more useful
  //    from there than from a string-match here.
  const sessionPsPath = join(
    root, "src", "Calypso", "Generated", "Session.purs");
  const sessionErlBase = "calypso_generated_session@ps";
  const sessionErlPath = join(
    root, "output-erl", "Calypso.Generated.Session", `${sessionErlBase}.erl`);
  const buildTxt = join(root, "output-erl", "build.txt");
  const beamOut = join(root, "ebin");

  // Buffer-vs-disk divergence guard: surface to server logs when the
  // browser is about to overwrite disk content it never saw.  This is
  // the silent footgun from 2026-05-17 — the user's stale buffer
  // clobbered correct disk content because fire-typeful is unconditional.
  logDivergence(sessionPsPath, source, "Session.purs");

  const tWrite0 = Date.now();
  try {
    writeFileSync(sessionPsPath, source);
  } catch (e) {
    return emptyResult(`writing session module: ${e.message}`);
  }
  const tWrite = Date.now() - tWrite0;

  // 2. purs compile (cached glob).
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
    // Always surface the raw compiler output.  In principle the spago-
    // derived glob passes --json-errors and we get a JSON envelope, but
    // in practice some failure modes (parse errors before --json takes
    // effect, plain-text warnings-as-errors, etc.) emerge as plain
    // text and we'd rather show those than nothing.  Field name lies
    // a bit for legacy reasons; treat it as "compiler-error details".
    const details = ((pursR.stderr || "") + (pursR.stdout || "")).trim();
    return {
      ok: false,
      reply: "",
      error: "purs compile failed",
      pursErrorsJson: details,
      timings: {
        write: tWrite,
        purs: Date.now() - tPurs0,
        be: 0,
        erlc: 0,
        ws: 0,
        total: Date.now() - t0,
      },
    };
  }
  const tPurs = Date.now() - tPurs0;

  // 3. backend-erl --filter on Calypso.Generated.Session — emits
  //    Session.erl + its forward deps (Prelude, Tidal.Pattern.*).
  //    Dependents (bridge modules) are NOT re-emitted here; they get
  //    rebuilt on next /arm via their own --filter pass.
  const tBe0 = Date.now();
  try { rmSync(buildTxt); } catch (_) {}
  const beR = await spawnP(
    "node_modules/.bin/purs-backend-erl",
    ["--filter", "Calypso.Generated.Session"],
    { cwd: root },
  );
  if (beR.code !== 0) {
    return {
      ok: false,
      reply: "",
      error: `backend-erl failed: ${beR.stderr || beR.stdout}`,
      pursErrorsJson: "",
      timings: {
        write: tWrite,
        purs: tPurs,
        be: Date.now() - tBe0,
        erlc: 0,
        ws: 0,
        total: Date.now() - t0,
      },
    };
  }
  const tBe = Date.now() - tBe0;

  // 4. erlc Session .erl → ebin/calypso_generated_session@ps.beam.
  if (!existsSync(sessionErlPath)) {
    return emptyResult(`session .erl not found after build: ${sessionErlPath}`);
  }
  mkdirSync(beamOut, { recursive: true });
  const sessionBeamPath = join(beamOut, `${sessionErlBase}.beam`);
  const erlMtime = statSync(sessionErlPath).mtimeMs;
  const tErlc0 = Date.now();
  const erlcR = await new Promise((resolve) => {
    execFile(
      "erlc",
      ["-disable-feature", "maybe_expr", "-o", beamOut, sessionErlPath],
      { cwd: root },
      (err, stdout, stderr) => resolve({ code: err ? (err.code ?? -1) : 0, stdout, stderr }),
    );
  });
  if (erlcR.code !== 0) {
    return {
      ok: false,
      reply: "",
      error: `erlc failed: ${erlcR.stderr || erlcR.stdout}`,
      pursErrorsJson: "",
      timings: {
        write: tWrite,
        purs: tPurs,
        be: tBe,
        erlc: Date.now() - tErlc0,
        ws: 0,
        total: Date.now() - t0,
      },
    };
  }
  // Post-check: see StudioSource.js for the rationale.  We hit a silent
  // erlc skip on 2026-05-17 where the .erl was updated but the .beam was
  // stale by hours; reload-baseline happily loaded the stale code.
  if (!existsSync(sessionBeamPath)) {
    return {
      ok: false,
      reply: "",
      error:
        `erlc reported success but ${sessionBeamPath} does not exist — ` +
        `toolchain produced no output. ` +
        (erlcR.stderr || erlcR.stdout || ""),
      pursErrorsJson: "",
      timings: {
        write: tWrite, purs: tPurs, be: tBe,
        erlc: Date.now() - tErlc0, ws: 0, total: Date.now() - t0,
      },
    };
  }
  const beamMtime = statSync(sessionBeamPath).mtimeMs;
  if (beamMtime < erlMtime) {
    return {
      ok: false,
      reply: "",
      error:
        `erlc reported success but ${sessionBeamPath} (mtime ${new Date(beamMtime).toISOString()}) ` +
        `is older than ${sessionErlPath} (mtime ${new Date(erlMtime).toISOString()}) — ` +
        `the toolchain silently skipped.  Restart calypso-api to refresh PATH, or run ` +
        `erlc manually from purerl-tidal/. ` +
        (erlcR.stderr || erlcR.stdout || ""),
      pursErrorsJson: "",
      timings: {
        write: tWrite, purs: tPurs, be: tBe,
        erlc: Date.now() - tErlc0, ws: 0, total: Date.now() - t0,
      },
    };
  }
  const tErlc = Date.now() - tErlc0;

  // 5. WS: reload-baseline — BEAM picks up the new Session.beam.
  const tWs0 = Date.now();
  const wsR = await sendReloadBaseline();
  const tWs = Date.now() - tWs0;

  return {
    ok: wsR.ok,
    reply: wsR.reply,
    error: wsR.error || "",
    pursErrorsJson: "",
    timings: {
      write: tWrite,
      purs: tPurs,
      be: tBe,
      erlc: tErlc,
      ws: tWs,
      total: Date.now() - t0,
    },
  };
}

export const buildSessionImpl = (req) => () => runBuild(req);
