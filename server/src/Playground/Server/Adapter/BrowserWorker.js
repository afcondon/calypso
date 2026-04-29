import { execFile } from 'child_process';
import { mkdir, readFile, writeFile } from 'fs/promises';
import { dirname, resolve as pathResolve } from 'path';

// Per-call workspace paths are derived from the absolute workspace dir
// passed in via FFI. The adapter is workspace-agnostic now; all state
// lives under <workspaceDir>/src/ and <workspaceDir>/output/.
//
// Spago is invoked with cwd=`<workspaceDir>/../..` (the
// `runtime-workspace/` root that owns the self-contained spago
// workspace containing every Playground runtime package), and
// `--output` / `--outfile` redirect per-package output under the
// individual workspace. Running spago from the package dir was
// previously viable but stopped working once the outer repo workspace
// started seeing two `playground-runtime`-shaped packages (duplicate
// module errors + lockfile regen path breakage) — an inner workspace
// isolates us from both.
function pathsFor(workspaceDir) {
  return {
    mainPath: pathResolve(workspaceDir, 'src', 'Main.purs'),
    userPath: pathResolve(workspaceDir, 'src', 'Playground', 'User.purs'),
    outputDir: pathResolve(workspaceDir, 'output'),
    bundlePath: pathResolve(workspaceDir, 'output', 'bundle.js'),
    spagoCwd: pathResolve(workspaceDir, '..', '..'),
  };
}

// ---- spago invocations ----

function runBuildJsonErrors(workspaceDir, packageName) {
  const { outputDir, spagoCwd } = pathsFor(workspaceDir);
  return new Promise((resolve) => {
    execFile(
      'spago',
      ['build', '-p', packageName, '--json-errors', '--output', outputDir],
      { cwd: spagoCwd, maxBuffer: 16 * 1024 * 1024 },
      (_err, stdout, stderr) => {
        const jsonLine = stdout
          .split('\n')
          .find((l) => l.startsWith('{') && l.includes('"errors"'));
        if (!jsonLine) {
          const trimmed = (stderr || '').trim();
          if (trimmed) {
            return resolve({
              errors: [transportError(trimmed)],
              warnings: [],
              clean: false,
            });
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

// Drop all warnings that live in the synthesised Main.purs. Reasons:
//   - preamble warnings are synthesis artefacts,
//   - mirrored user imports would generate duplicates of warnings
//     the user already sees from Playground/User.purs,
//   - MissingTypeDeclaration on cell_<id> bindings is inherent to
//     the synthesis (we don't know the type until inference).
// The user's own warnings still flow through from User.purs. If we
// later want fine-grained cell-specific warnings we'll thread cellLines
// in and keep warnings that fall inside a cell's range.
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

function runBundle(workspaceDir, packageName) {
  const { outputDir, bundlePath, spagoCwd } = pathsFor(workspaceDir);
  return new Promise((resolve) => {
    execFile(
      'spago',
      [
        'bundle',
        '-p', packageName,
        '--output', outputDir,
        '--outfile', bundlePath,
      ],
      { cwd: spagoCwd, maxBuffer: 16 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) return resolve({ ok: false, message: formatBundleFailure(err, stdout, stderr) });
        resolve({ ok: true });
      }
    );
  });
}

function formatBundleFailure(err, stdout, stderr) {
  const parts = [];
  const serr = (stderr || '').trim();
  const sout = (stdout || '').trim();
  if (serr) parts.push('stderr:\n' + serr);
  if (sout) parts.push('stdout:\n' + sout);
  if (!parts.length) parts.push(err.message);
  return parts.join('\n\n');
}

function extractCellIds(mainSource) {
  const ids = [];
  const re = /^cell_([A-Za-z0-9_]+)\s*=/gm;
  let m;
  while ((m = re.exec(mainSource)) !== null) {
    ids.push(m[1]);
  }
  return ids;
}

// ---- public FFI ----

// Per-workspace queue: serialises _bundle invocations against the same
// workspace dir (two concurrent calls in one workspace stomp each
// other's src/ and output/). Distinct workspaces run in parallel.
const bundleQueues = new Map();

function enqueueForWorkspace(workspaceDir, task) {
  const prev = bundleQueues.get(workspaceDir) || Promise.resolve();
  const next = prev.then(task);
  // Swallow errors in the queue's view so one rejection doesn't poison
  // subsequent calls for the same workspace; callers see their own task.
  bundleQueues.set(workspaceDir, next.catch(() => {}));
  return next;
}

export const _bundle = (workspaceDir) => (packageName) => (userSource) => (mainSource) => () =>
  enqueueForWorkspace(workspaceDir, () =>
    runBundlePipeline(workspaceDir, packageName, userSource, mainSource));

function runBundlePipeline(workspaceDir, packageName, userSource, mainSource) {
  const { mainPath, userPath, bundlePath } = pathsFor(workspaceDir);
  return new Promise(async (resolve) => {
    const empty = { js: null, warnings: [], errors: [], cellIds: [], emits: [] };

    try {
      await mkdir(dirname(userPath), { recursive: true });
      await Promise.all([
        writeFile(userPath, userSource, 'utf8'),
        writeFile(mainPath, mainSource, 'utf8'),
      ]);
    } catch (e) {
      return resolve({
        ...empty,
        errors: [transportError(`writeFile failed: ${e.message}`)],
      });
    }

    const diag = await runBuildJsonErrors(workspaceDir, packageName);
    if (!diag.clean) {
      return resolve({
        js: null,
        warnings: diag.warnings,
        errors: diag.errors,
        cellIds: [],
        emits: [],
      });
    }

    const bundle = await runBundle(workspaceDir, packageName);
    if (!bundle.ok) {
      return resolve({
        js: null,
        warnings: diag.warnings,
        errors: [transportError(`bundle failed: ${bundle.message}`)],
        cellIds: [],
        emits: [],
      });
    }

    let js;
    try {
      js = await readFile(bundlePath, 'utf8');
    } catch (e) {
      return resolve({
        js: null,
        warnings: diag.warnings,
        errors: [transportError(`bundle read failed: ${e.message}`)],
        cellIds: [],
        emits: [],
      });
    }
    resolve({
      js,
      warnings: diag.warnings,
      errors: [],
      cellIds: extractCellIds(mainSource),
      emits: [],
    });
  });
}
