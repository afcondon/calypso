// StudioSource.js — write + build the Studio rig-declaration module.
//
// Mirror of SessionSource.js, but targets src/Studio.purs.  Same
// per-cell compile pipeline (purs --filter, backend-erl --filter,
// erlc one module), same `reload-baseline` over WS to make the walker
// pick up the new Studio module.
//
// Workstream 2 of docs/studio-pane-day-plan.md.  Replaces the
// 60-90s `make erl` + DeepStar restart cycle with ~700ms warm.

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

// Buffer-vs-disk divergence logger.  See SessionSource.js for context.
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
    return emptyResult(
      "source is empty or missing a `module ...` declaration — " +
      "Studio.purs must be a PureScript module declaring `module Studio where`");
  }

  // 1. Write the studio module.  The on-disk module name is fixed:
  //    `module Studio where`.  We don't validate that the source
  //    declares this — purs will, and the error is more useful from
  //    there.
  const studioPsPath  = join(root, "src", "Studio.purs");
  const studioErlBase = "studio@ps";
  const studioErlPath = join(
    root, "output-erl", "Studio", `${studioErlBase}.erl`);
  const buildTxt = join(root, "output-erl", "build.txt");
  const beamOut  = join(root, "ebin");

  // Buffer-vs-disk divergence guard.  See SessionSource.js for context.
  logDivergence(studioPsPath, source, "Studio.purs");

  const tWrite0 = Date.now();
  try {
    writeFileSync(studioPsPath, source);
  } catch (e) {
    return emptyResult(`writing Studio module: ${e.message}`);
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
    // Always surface the raw compiler output — JSON-shaped when purs
    // ran with --json, plain text otherwise.  Field name lies a bit
    // for legacy reasons; treat it as "compiler-error details".
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

  // 3. backend-erl --filter on Studio.
  const tBe0 = Date.now();
  try { rmSync(buildTxt); } catch (_) {}
  const beR = await spawnP(
    "node_modules/.bin/purs-backend-erl",
    ["--filter", "Studio"],
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

  // 4. erlc Studio .erl → ebin/studio@ps.beam.
  if (!existsSync(studioErlPath)) {
    return emptyResult(`Studio .erl not found after build: ${studioErlPath}`);
  }
  mkdirSync(beamOut, { recursive: true });
  const studioBeamPath = join(beamOut, `${studioErlBase}.beam`);
  // Capture the .erl mtime up front: any .beam older than the .erl after
  // erlc reportedly succeeded is the bug we hit on 2026-05-17.
  const erlMtime = statSync(studioErlPath).mtimeMs;
  const tErlc0 = Date.now();
  const erlcR = await new Promise((resolve) => {
    execFile(
      "erlc",
      ["-disable-feature", "maybe_expr", "-o", beamOut, studioErlPath],
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
  // Post-check: erlc claimed success — confirm the .beam actually got
  // written.  If the .beam is older than the .erl, erlc silently
  // skipped (stale toolchain on PATH, weird filesystem state, etc.)
  // and reload-baseline would happily load the old code.
  if (!existsSync(studioBeamPath)) {
    return {
      ok: false,
      reply: "",
      error:
        `erlc reported success but ${studioBeamPath} does not exist — ` +
        `toolchain produced no output. ` +
        (erlcR.stderr || erlcR.stdout || ""),
      pursErrorsJson: "",
      timings: {
        write: tWrite, purs: tPurs, be: tBe,
        erlc: Date.now() - tErlc0, ws: 0, total: Date.now() - t0,
      },
    };
  }
  const beamMtime = statSync(studioBeamPath).mtimeMs;
  if (beamMtime < erlMtime) {
    return {
      ok: false,
      reply: "",
      error:
        `erlc reported success but ${studioBeamPath} (mtime ${new Date(beamMtime).toISOString()}) ` +
        `is older than ${studioErlPath} (mtime ${new Date(erlMtime).toISOString()}) — ` +
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

  // 5. WS: reload-baseline — BEAM picks up the new Studio.beam and
  //    re-walks devices / instruments / drumkits / vmods.
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

export const buildStudioImpl = (req) => () => runBuild(req);

// GET /studio-source — read the current Studio.purs from disk so the
// frontend's edit pane can populate its textarea with what's actually
// running.  Returns an empty string + error message on failure.
async function fetchStudio() {
  const root = purerlTidalRoot();
  const studioPsPath = join(root, "src", "Studio.purs");
  if (!existsSync(studioPsPath)) {
    return { ok: false, source: "", error: `not found: ${studioPsPath}` };
  }
  try {
    const source = readFileSync(studioPsPath, "utf-8");
    return { ok: true, source, error: "" };
  } catch (e) {
    return { ok: false, source: "", error: e.message };
  }
}

export const fetchStudioImpl = () => fetchStudio();
