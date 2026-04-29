// Path resolves from the bundled output location (output/Playground.Frontend.RenderView/foreign.js),
// not the source tree. spago copies this file there before esbuild runs.
import { runAtelierForce } from "../Playground.Frontend.ForceSim/index.js";

const SVG_NS = "http://www.w3.org/2000/svg";

// Monotonic container ids so hylograph-simulation's CSS selector
// addressing scopes correctly when multiple ForceRender cells share
// the page.
let containerSeq = 0;

// Active force simulations keyed by their container element, so we can
// stop the previous one before mounting a new render into the same slot.
const sims = new WeakMap();

function stopSim(el) {
  const cleanup = sims.get(el);
  if (cleanup) {
    cleanup();
    sims.delete(el);
  }
}

export const _renderInto = (el) => (rawJson) => () => {
  stopSim(el);

  if (!rawJson || rawJson.trim() === "") {
    el.innerHTML = "";
    return;
  }

  let v;
  try {
    v = JSON.parse(rawJson);
  } catch (_e) {
    el.innerHTML = "";
    return;
  }

  // Static SVG string (PVString starting with <svg or <?xml)
  if (typeof v === "string") {
    const trimmed = v.trimStart();
    if (trimmed.startsWith("<svg") || trimmed.startsWith("<?xml")) {
      el.innerHTML = v;
      return;
    }
    el.innerHTML = "";
    return;
  }

  // ForceRender: { $ctor: "ForceRender", args: [ { $record: { nodes, links, width, height } } ] }
  if (
    v &&
    v.$ctor === "ForceRender" &&
    Array.isArray(v.args) &&
    v.args[0] &&
    v.args[0].$record
  ) {
    renderForce(el, v.args[0].$record);
    return;
  }

  // Unrecognised shape — leave blank so the column stays honest about
  // which cells have a visual rendering vs. which don't.
  el.innerHTML = "";
};

export const _cleanup = (el) => () => {
  stopSim(el);
  el.innerHTML = "";
};

// Records nested inside a PVCtor come through wrapped in `$record`;
// constructor values come through as { $ctor, args: [...] }. Unwrap
// one level in either direction.
const unwrapRecord = (r) => (r && r.$record) ? r.$record : r;

// Flatten one AtelierForceSpec-shaped envelope into the record the
// PureScript `ForceSim.runAtelierForce` expects. Returns null when
// the envelope is malformed; the caller filters those out. Absent
// numeric params come through as `null`, which PS reads as
// `Nullable Number` and falls back to the force's default.
function flattenForce(spec) {
  if (!spec || !spec.$ctor || !Array.isArray(spec.args) || !spec.args[0]) return null;
  const cfg = unwrapRecord(spec.args[0]);
  const num = (k) => (typeof cfg[k] === "number" ? cfg[k] : null);
  return {
    kind: spec.$ctor,
    name: cfg.name ?? spec.$ctor,
    strength: num("strength"),
    radius: num("radius"),
    distance: num("distance"),
    x: num("x"),
    y: num("y"),
  };
}

function renderForce(container, spec) {
  const nodes = (spec.nodes || []).map((n) => unwrapRecord(n));
  const links = (spec.links || []).map((l) => unwrapRecord(l));
  const forces = (spec.forces || []).map(flattenForce).filter((f) => f !== null);
  const width = typeof spec.width === "number" ? spec.width : 400;
  const height = typeof spec.height === "number" ? spec.height : 400;

  // Unique selector per render row so hylograph-simulation's D3
  // engine can scope its internal selections without cross-row
  // collisions.
  containerSeq += 1;
  const rowId = `atelier-force-${containerSeq}`;
  container.id = rowId;

  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
  svg.setAttribute("class", "render-force-svg");

  const linkG = document.createElementNS(SVG_NS, "g");
  linkG.setAttribute("class", "render-force-links");
  svg.appendChild(linkG);
  // Keyed by stringified "source|target" so the tick callback can
  // index back without relying on array ordering (the PS layer is
  // authoritative over link identity).
  const linkKey = (l) => `${l.source}|${l.target}`;
  const linkEls = new Map();
  for (const l of links) {
    const line = document.createElementNS(SVG_NS, "line");
    line.setAttribute("stroke", "#bbb");
    line.setAttribute("stroke-width", "1");
    linkG.appendChild(line);
    linkEls.set(linkKey(l), line);
  }

  const nodeG = document.createElementNS(SVG_NS, "g");
  nodeG.setAttribute("class", "render-force-nodes");
  svg.appendChild(nodeG);
  // Keyed by string id — the PS tick callback emits { id, x, y }.
  const nodeEls = new Map();
  for (const n of nodes) {
    const circle = document.createElementNS(SVG_NS, "circle");
    circle.setAttribute("r", n.radius ?? 3);
    circle.setAttribute("fill", n.fill || "#69b3a2");
    circle.setAttribute("fill-opacity", "0.8");
    circle.setAttribute("stroke", "#333");
    circle.setAttribute("stroke-width", "0.5");
    const title = document.createElementNS(SVG_NS, "title");
    title.textContent = n.label || n.id;
    circle.appendChild(title);
    nodeG.appendChild(circle);
    nodeEls.set(n.id, circle);
  }

  container.innerHTML = "";
  container.appendChild(svg);

  // Latest position table, used by the tick callback to also
  // resolve link endpoints (links carry node ids, not coordinates).
  const positions = new Map();
  const onTick = (tickPositions) => {
    for (const p of tickPositions) {
      positions.set(p.id, p);
      const el = nodeEls.get(p.id);
      if (el) {
        el.setAttribute("cx", p.x);
        el.setAttribute("cy", p.y);
      }
    }
    for (const l of links) {
      const line = linkEls.get(linkKey(l));
      const s = positions.get(l.source);
      const t = positions.get(l.target);
      if (line && s && t) {
        line.setAttribute("x1", s.x);
        line.setAttribute("y1", s.y);
        line.setAttribute("x2", t.x);
        line.setAttribute("y2", t.y);
      }
    }
  };

  // runAtelierForce is compiled from Playground.Frontend.ForceSim via
  // EffectFn5, so JS calls it as a plain 5-arg function and receives
  // the cleanup Effect as `() => undefined`.
  const cleanup = runAtelierForce(nodes, links, forces, `#${rowId}`, onTick);
  sims.set(container, cleanup);
}
