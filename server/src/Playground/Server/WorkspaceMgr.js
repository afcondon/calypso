import { mkdir, readdir, readFile, rm, copyFile, writeFile } from 'fs/promises';
import {
  copyFileSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from 'fs';
import { resolve as pathResolve, join as pathJoin } from 'path';

// Files copied verbatim from the template workspace into a new one.
// `spago.yaml` and `package.json` are copied+rewritten (see
// `rewriteForPackage` below) because the package name must differ
// between workspaces so `spago build -p <name>` disambiguates them
// inside the outer workspace. Main.purs and Playground/User.purs are
// seeded fresh (see SEED_* constants) — they're the parts that get
// rewritten per compile / hold user state respectively.
const TEMPLATE_COPY_PATHS = [
  'src/Playground/Runtime.purs',
  'src/Playground/Runtime.js',
];

const REWRITE_PATHS = ['spago.yaml', 'package.json'];

const SEED_MAIN_PURS = 'module Main where\n';
const SEED_USER_PURS = 'module Playground.User where\n\nimport Prelude\n';

export const _listWorkspaceDirs = (rootDir) => () =>
  readdir(rootDir, { withFileTypes: true })
    .then((entries) =>
      entries.filter((e) => e.isDirectory()).map((e) => e.name),
    )
    .catch((e) => {
      if (e && e.code === 'ENOENT') return [];
      throw e;
    });

// Synchronous variant used during boot, where we need the workspace
// map populated before the HTTP listener starts accepting requests.
export const _listWorkspaceDirsSync = (rootDir) => () => {
  try {
    return readdirSync(rootDir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch (e) {
    if (e && e.code === 'ENOENT') return [];
    throw e;
  }
};

export const _createWorkspaceDir =
  (rootDir) => (templateDir) => (packageName) => (id) => () =>
    createWorkspace(rootDir, templateDir, packageName, id);

export const _deleteWorkspaceDir = (rootDir) => (id) => () =>
  rm(pathJoin(rootDir, id), { recursive: true, force: true });

async function createWorkspace(rootDir, templateDir, packageName, id) {
  const workspaceDir = pathJoin(rootDir, id);
  await mkdir(pathJoin(workspaceDir, 'src', 'Playground'), { recursive: true });

  // Copy verbatim.
  for (const rel of TEMPLATE_COPY_PATHS) {
    const src = pathResolve(templateDir, rel);
    const dst = pathResolve(workspaceDir, rel);
    await copyFile(src, dst);
  }

  // Read + rewrite package-identifying fields, then write.
  for (const rel of REWRITE_PATHS) {
    const src = pathResolve(templateDir, rel);
    const dst = pathResolve(workspaceDir, rel);
    const raw = await readFile(src, 'utf8');
    await writeFile(dst, rewriteForPackage(rel, raw, packageName), 'utf8');
  }

  await Promise.all([
    writeFile(pathJoin(workspaceDir, 'src', 'Main.purs'), SEED_MAIN_PURS, 'utf8'),
    writeFile(
      pathJoin(workspaceDir, 'src', 'Playground', 'User.purs'),
      SEED_USER_PURS,
      'utf8',
    ),
  ]);
}

// Synchronous variant used during boot (same purpose as
// _listWorkspaceDirsSync): we need the `eval-scratch` workspace
// available in the map before the HTTP listener accepts requests,
// and the only callers are eager setup paths in `main`.
export const _createWorkspaceDirSync =
  (rootDir) => (templateDir) => (packageName) => (id) => () => {
    const workspaceDir = pathJoin(rootDir, id);
    mkdirSync(pathJoin(workspaceDir, 'src', 'Playground'), { recursive: true });
    for (const rel of TEMPLATE_COPY_PATHS) {
      copyFileSync(pathResolve(templateDir, rel), pathResolve(workspaceDir, rel));
    }
    for (const rel of REWRITE_PATHS) {
      const raw = readFileSync(pathResolve(templateDir, rel), 'utf8');
      writeFileSync(
        pathResolve(workspaceDir, rel),
        rewriteForPackage(rel, raw, packageName),
        'utf8',
      );
    }
    writeFileSync(pathJoin(workspaceDir, 'src', 'Main.purs'), SEED_MAIN_PURS, 'utf8');
    writeFileSync(
      pathJoin(workspaceDir, 'src', 'Playground', 'User.purs'),
      SEED_USER_PURS,
      'utf8',
    );
  };

// Narrow rewrite that only touches the package-name field. We target:
//   * spago.yaml: the single top-level `name:` line inside `package:`
//     (indented two spaces; yaml dependencies are array items like
//     `  - aff` which don't match).
//   * package.json: the single `"name": "..."` pair. JSON.parse/stringify
//     would lose formatting, so a regex replace is preferred.
function rewriteForPackage(rel, raw, packageName) {
  if (rel === 'spago.yaml') {
    return raw.replace(/^(  name:\s*)\S+/m, `$1${packageName}`);
  }
  if (rel === 'package.json') {
    return raw.replace(/"name":\s*"[^"]+"/, `"name": "${packageName}"`);
  }
  return raw;
}
