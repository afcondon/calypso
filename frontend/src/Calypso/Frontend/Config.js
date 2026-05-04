// Resolve the backend URL from the current page's origin so the same
// bundle works whether it's loaded from http://localhost:3061 or from
// a Tailscale hostname (phone/other device on the tailnet) or a
// production hostname later on.  Backend listens on :3060.
export const backendUrl =
  typeof window !== 'undefined' && window.location && window.location.hostname
    ? `http://${window.location.hostname}:3060`
    : 'http://localhost:3060';

// Match backendUrl's host/port but with ws:// / wss:// per page protocol.
export const wsBackendUrl =
  typeof window !== 'undefined' && window.location && window.location.hostname
    ? `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.hostname}:3060`
    : 'ws://localhost:3060';

export const nowMs = () => Date.now();

export const readHideParam = () => {
  if (typeof window === 'undefined' || !window.location) return '';
  const params = new URLSearchParams(window.location.search);
  return params.get('hide') || '';
};

export const writeHideParam = (value) => () => {
  if (typeof window === 'undefined' || !window.history || !window.location) return;
  const url = new URL(window.location.href);
  if (value === '') {
    url.searchParams.delete('hide');
  } else {
    url.searchParams.set('hide', value);
  }
  window.history.replaceState(null, '', url.toString());
};

// Pretty-print JSON.  Returns the input verbatim if it doesn't parse
// (e.g. an "ERR: ..." reply from purerl-tidal, or an empty boot-window
// snapshot).  Indentation is 2 spaces — readable in a 0.85rem mono pane.
export const prettyPrintJson = (s) => {
  try {
    return JSON.stringify(JSON.parse(s), null, 2);
  } catch (_) {
    return s;
  }
};

// Format a Number — JS native String() produces the short-form a user
// expects ("120", "119.5") rather than PureScript's purerl scientific
// notation. Used for the topbar BPM widget.
export const formatNumber = (n) => String(n);
