import { execFile, spawn } from 'child_process';
import { mkdir, readdir, writeFile } from 'fs/promises';
import { dirname, resolve as pathResolve, join } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// <repo>/output/Playground.Server.Adapter.PurerlBEAM/foreign.js
//  → repo root is 2 levels up.
const REPO_ROOT = pathResolve(__dirname, '..', '..');
const WORKSPACE = pathResolve(REPO_ROOT, 'runtime-workspace-purerl');
const MAIN_PATH = pathResolve(WORKSPACE, 'src', 'Main.purs');
const USER_PATH = pathResolve(WORKSPACE, 'src', 'Playground', 'User.purs');
const ERL_OUT = pathResolve(WORKSPACE, 'output-erl');
const EBIN = pathResolve(ERL_OUT, 'ebin');

// ---- spago + erlc ----

function runBuildJsonErrors() {
  return new Promise((resolve) => {
    execFile(
      'spago',
      ['build', '--json-errors'],
      { cwd: WORKSPACE, maxBuffer: 16 * 1024 * 1024 },
      (_err, stdout, stderr) => {
        const jsonLine = stdout
          .split('\n')
          .find((l) => l.startsWith('{') && l.includes('"errors"'));
        if (!jsonLine) {
          const trimmed = (stderr || '').trim();
          if (trimmed) {
            return resolve({ errors: [transportError(trimmed)], warnings: [], clean: false });
          }
          return resolve({ errors: [], warnings: [], clean: true });
        }
        try {
          const parsed = JSON.parse(jsonLine);
          const errors = (parsed.errors || []).map(toStructured);
          const warnings = (parsed.warnings || [])
            .map(toStructured)
            .filter(keepWarning);
          resolve({ errors, warnings, clean: errors.length === 0 });
        } catch (e) {
          resolve({
            errors: [transportError(`failed to parse --json-errors: ${e.message}`)],
            warnings: [],
            clean: false,
          });
        }
      }
    );
  });
}

function keepWarning(w) {
  if (w.filename && w.filename.endsWith('Main.purs')) return false;
  return true;
}

function toStructured(pe) {
  const pos = pe.position
    ? {
        startLine: pe.position.startLine,
        startColumn: pe.position.startColumn,
        endLine: pe.position.endLine,
        endColumn: pe.position.endColumn,
      }
    : null;
  return {
    code: pe.errorCode || 'Unknown',
    filename: pe.filename || null,
    position: pos,
    message: (pe.message || '').trim(),
  };
}

function transportError(msg) {
  return { code: 'Transport', filename: null, position: null, message: msg };
}

// Recursively find .erl files under ERL_OUT (excluding ebin/).
async function findErlFiles() {
  const out = [];
  async function walk(dir) {
    let entries = [];
    try { entries = await readdir(dir, { withFileTypes: true }); }
    catch (_) { return; }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) {
        if (e.name !== 'ebin') await walk(p);
      } else if (e.name.endsWith('.erl')) {
        out.push(p);
      }
    }
  }
  await walk(ERL_OUT);
  return out;
}

function erlcCompile(files) {
  return new Promise((resolve) => {
    execFile(
      'erlc',
      // -disable-feature maybe_expr: OTP 25+ reserved `maybe` as a
      //  block keyword, which collides with Data.Maybe's `maybe/3`
      //  function in purs-backend-erl output.
      ['-disable-feature', 'maybe_expr', '-o', EBIN, ...files],
      { maxBuffer: 32 * 1024 * 1024 },
      (err, _stdout, stderr) => {
        if (err) return resolve({ ok: false, message: stderr || err.message });
        resolve({ ok: true });
      }
    );
  });
}

function runInErl() {
  return new Promise((resolve) => {
    const child = spawn(
      'erl',
      ['-pa', EBIN, '-noshell', '-eval', '(main@ps:main())(), init:stop().'],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );
    const emits = [];
    let stderrBuf = '';
    let stdoutBuf = '';
    let runtimeError = null;

    child.stdout.on('data', (chunk) => {
      stdoutBuf += chunk;
      let nl;
      while ((nl = stdoutBuf.indexOf('\n')) !== -1) {
        const line = stdoutBuf.slice(0, nl).trim();
        stdoutBuf = stdoutBuf.slice(nl + 1);
        if (!line) continue;
        try {
          const msg = JSON.parse(line);
          if (msg.type === 'emit') emits.push({ id: msg.id, value: msg.value });
          else if (msg.type === 'error') runtimeError = msg.message;
          // 'done' messages are advisory; we watch for process exit.
        } catch (_) { /* ignore non-JSON lines (Erlang chatter) */ }
      }
    });
    child.stderr.on('data', (chunk) => { stderrBuf += chunk; });
    child.on('error', (e) => {
      if (!runtimeError) runtimeError = `failed to spawn erl: ${e.message}`;
      resolve({ emits, runtimeError });
    });
    child.on('exit', (code) => {
      if (code !== 0 && !runtimeError) {
        runtimeError = `erl exited ${code}; stderr: ${stderrBuf.trim()}`;
      }
      resolve({ emits, runtimeError });
    });

    const killTimer = setTimeout(() => {
      try { child.kill('SIGTERM'); } catch (_) {}
      if (!runtimeError) runtimeError = 'erl runtime exceeded 10s';
    }, 10_000);
    child.on('exit', () => clearTimeout(killTimer));
  });
}

function extractCellIds(mainSource) {
  const ids = [];
  const re = /^cell_([A-Za-z0-9_]+)\s*=/gm;
  let m;
  while ((m = re.exec(mainSource)) !== null) ids.push(m[1]);
  return ids;
}

// ---- public FFI ----

// Phase 1 note: PurerlBEAM still uses its own fixed top-level workspace
// (`runtime-workspace-purerl`) and isn't multi-workspace-aware yet. The
// `_workspaceDir` and `_packageName` arguments are accepted for signature
// parity with the JS-target adapters and ignored here.
export const _bundle = (_workspaceDir) => (_packageName) => (userSource) => (mainSource) => () =>
  new Promise(async (resolve) => {
    const empty = { js: null, warnings: [], errors: [], cellIds: [], emits: [] };

    try {
      await mkdir(dirname(USER_PATH), { recursive: true });
      await Promise.all([
        writeFile(USER_PATH, userSource, 'utf8'),
        writeFile(MAIN_PATH, mainSource, 'utf8'),
      ]);
    } catch (e) {
      return resolve({
        ...empty,
        errors: [transportError(`writeFile failed: ${e.message}`)],
      });
    }

    const diag = await runBuildJsonErrors();
    if (!diag.clean) {
      return resolve({
        js: null,
        warnings: diag.warnings,
        errors: diag.errors,
        cellIds: [],
        emits: [],
      });
    }

    // Compile .erl → .beam. Ensure ebin exists.
    try {
      await mkdir(EBIN, { recursive: true });
    } catch (e) {
      return resolve({
        ...empty,
        errors: [transportError(`mkdir ebin: ${e.message}`)],
        warnings: diag.warnings,
      });
    }
    const erlFiles = await findErlFiles();
    if (erlFiles.length === 0) {
      return resolve({
        ...empty,
        errors: [transportError('no .erl files produced by purs-backend-erl')],
        warnings: diag.warnings,
      });
    }
    const compile = await erlcCompile(erlFiles);
    if (!compile.ok) {
      return resolve({
        ...empty,
        errors: [transportError(`erlc failed: ${compile.message}`)],
        warnings: diag.warnings,
      });
    }

    const { emits, runtimeError } = await runInErl();
    const runtimeErrors = runtimeError
      ? [{ code: 'Runtime', filename: null, position: null, message: runtimeError }]
      : [];

    resolve({
      js: null,
      warnings: diag.warnings,
      errors: runtimeErrors,
      cellIds: extractCellIds(mainSource),
      emits,
    });
  });
