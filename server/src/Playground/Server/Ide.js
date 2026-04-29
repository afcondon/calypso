import { spawn } from 'child_process';
import { resolve as pathResolve } from 'path';
import { dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = pathResolve(__dirname, '..', '..');
const OUTPUT_DIR = pathResolve(REPO_ROOT, 'output');

// Single long-lived purs ide server, shared by every consumer of this
// module (compile-time type queries, hover, completion, future Claude
// tools). First query pays the ~2s warm-up; subsequent ones ~50ms.
let ideServerProc = null;
let ideServerReady = null;

export function startIdeServer() {
  if (ideServerProc) return;
  ideServerProc = spawn(
    'purs',
    ['ide', 'server', '--output-directory', OUTPUT_DIR],
    { stdio: ['ignore', 'pipe', 'pipe'] }
  );
  ideServerProc.on('exit', () => {
    ideServerProc = null;
    ideServerReady = null;
  });
  ideServerReady = pollUntilReady();
  const killSidecar = () => {
    if (ideServerProc) {
      try { ideServerProc.kill('SIGTERM'); } catch (_) {}
    }
  };
  process.once('exit', killSidecar);
  process.once('SIGINT', () => { killSidecar(); process.exit(130); });
  process.once('SIGTERM', () => { killSidecar(); process.exit(143); });
}

async function pollUntilReady() {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      const r = await clientCall({ command: 'cwd' });
      if (r && r.resultType === 'success') return;
    } catch (_) { /* retry */ }
    await sleep(100);
  }
  throw new Error('purs ide server did not become ready within 10s');
}

// Timeout bounds how long we wait for the purs ide server via a
// client subprocess. A warm ide server answers in ~50ms; 5s is
// *very* generous but short enough that a wedged server doesn't
// hold the session mutex indefinitely. On timeout we SIGKILL the
// client, then SIGTERM the ide server too — its exit handler nulls
// our cached reference, so the next query respawns a fresh one.
const IDE_CLIENT_TIMEOUT_MS = 5000;

export function clientCall(cmd) {
  return new Promise((resolve, reject) => {
    const proc = spawn('purs', ['ide', 'client'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const settle = (fn) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      try { proc.kill('SIGKILL'); } catch (_) {}
      // The ide server is the shared piece of state that gets
      // wedged; killing it forces a fresh spawn on the next call.
      if (ideServerProc) {
        try { ideServerProc.kill('SIGTERM'); } catch (_) {}
      }
      settle(() => reject(new Error(
        `purs ide client timed out after ${IDE_CLIENT_TIMEOUT_MS}ms — killed server for respawn`
      )));
    }, IDE_CLIENT_TIMEOUT_MS);
    proc.stdout.on('data', (d) => { stdout += d; });
    proc.stderr.on('data', (d) => { stderr += d; });
    proc.on('error', (e) => settle(() => reject(e)));
    proc.on('exit', (code) => {
      if (code !== 0) {
        settle(() => reject(new Error(`purs ide client exit ${code}: ${stderr.trim()}`)));
        return;
      }
      try {
        const parsed = JSON.parse(stdout);
        settle(() => resolve(parsed));
      } catch (e) {
        settle(() => reject(new Error(`purs ide client: invalid JSON response: ${stdout}`)));
      }
    });
    proc.stdin.write(JSON.stringify(cmd) + '\n');
    proc.stdin.end();
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

export async function ensureReady() {
  startIdeServer();
  await ideServerReady;
}

function normaliseHit(h) {
  return {
    identifier: h.identifier || '',
    moduleName: h.module || '',
    typeSignature: h.type || '',
  };
}

// ---- Public FFI for PureScript consumers ----

export const _queryType = (query) => async () => {
  await ensureReady();
  const r = await clientCall({
    command: 'type',
    params: { search: query, filters: [] },
  });
  const hits = (r && r.result) || [];
  return hits.map(normaliseHit);
};

export const _queryComplete = (query) => async () => {
  await ensureReady();
  const r = await clientCall({
    command: 'complete',
    params: {
      filters: [
        { filter: 'prefix', params: { search: query } },
      ],
    },
  });
  const hits = (r && r.result) || [];
  return hits.map(normaliseHit);
};

export const _querySearch = (query) => async () => {
  await ensureReady();
  // purs-ide's `complete` with no filters is the closest thing to a
  // free-text search across the loaded externs. For type-signature
  // search specifically, the `type` filter narrows by exact match;
  // we use `complete` with the free-text query and let the caller
  // eyeball the hits. A real `:search type` is a future upgrade.
  const r = await clientCall({
    command: 'complete',
    params: {
      filters: [
        { filter: 'prefix', params: { search: query } },
      ],
      matcher: { matcher: 'flex', params: { search: query } },
    },
  });
  const hits = (r && r.result) || [];
  return hits.map(normaliseHit);
};

// Batch helper used by Compile after each successful build.
// Calls `load` once then `type` per cell id, prefers Main-module hits
// so a cell_c1 doesn't collide with an unrelated library binding.
export const _queryCellTypes = (cellIdsJson) => async () => {
  const ids = JSON.parse(cellIdsJson);
  if (ids.length === 0) return [];
  try {
    await ensureReady();
    await clientCall({ command: 'load' });
    const results = [];
    for (const id of ids) {
      try {
        const r = await clientCall({
          command: 'type',
          params: { search: 'cell_' + id, filters: [] },
        });
        const hits = (r && r.result) || [];
        const hit = hits.find((h) => h.module === 'Main') || hits[0];
        if (hit && hit.type) {
          results.push({ id, signature: hit.type });
        }
      } catch (_) { /* skip */ }
    }
    return results;
  } catch (_) {
    return [];
  }
};
