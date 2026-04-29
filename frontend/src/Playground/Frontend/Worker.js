// Inline Web Worker for running compiled PureScript bundles. The worker
// source is a small JS string assembled at module load; we spin up a fresh
// Blob URL per run so that each compile gets a clean global scope.

const WORKER_SRC = `
  self.addEventListener('message', (event) => {
    const { js } = event.data;
    globalThis.__playground_emit = (id, value) => {
      self.postMessage({ type: 'emit', id, value });
    };
    globalThis.__playground_done = () => {
      self.postMessage({ type: 'done' });
    };
    try {
      // Spago's bundle is an IIFE — evaluating it kicks off main()
      // which calls runAff_ with a done-callback. launchAff_ returns
      // synchronously; we do NOT send 'done' here because any Aff
      // computation (delay, setTimeout-based work) is still pending.
      // The synthesised main calls Playground.Runtime.done at the
      // end of its runAff_ continuation, which reaches us via the
      // __playground_done hook above.
      new Function(js)();
    } catch (e) {
      self.postMessage({ type: 'error', message: String(e && e.stack || e) });
    }
  });
`;

export const _spawnWorker = (onMessage) => () => {
  const blob = new Blob([WORKER_SRC], { type: 'application/javascript' });
  const url = URL.createObjectURL(blob);
  const worker = new Worker(url);
  // onMessage is an EffectFn1 (via mkEffectFn1 on the PS side), i.e. a
  // JS function (data) => Unit that synchronously runs the effect.
  // Call once, no trailing thunk.
  worker.addEventListener('message', (event) => {
    onMessage(event.data);
  });
  URL.revokeObjectURL(url);
  return worker;
};

export const _postJs = (worker) => (js) => () => {
  worker.postMessage({ js });
};

export const _terminate = (worker) => () => {
  worker.terminate();
};
