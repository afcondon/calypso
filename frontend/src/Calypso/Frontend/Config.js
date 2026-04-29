// Resolve the backend URL from the current page's origin so the same
// bundle works whether it's loaded from http://localhost:3051 or from
// a Tailscale hostname (phone/other device on the tailnet) or a
// production hostname later on. Backend port is still :3050 for now.
export const backendUrl =
  typeof window !== 'undefined' && window.location && window.location.hostname
    ? `http://${window.location.hostname}:3050`
    : 'http://localhost:3050';

// Match backendUrl's host/port but with ws:// / wss:// per page protocol.
export const wsBackendUrl =
  typeof window !== 'undefined' && window.location && window.location.hostname
    ? `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.hostname}:3050`
    : 'ws://localhost:3050';

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
