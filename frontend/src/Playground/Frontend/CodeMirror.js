import { EditorView, keymap, lineNumbers, drawSelection, hoverTooltip, Decoration } from '@codemirror/view';
import { EditorState, StateField, StateEffect, Annotation, Compartment } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import {
  bracketMatching, indentOnInput, StreamLanguage,
  syntaxHighlighting, HighlightStyle,
} from '@codemirror/language';
import { haskell } from '@codemirror/legacy-modes/mode/haskell';
import { tags as t } from '@lezer/highlight';

// Marks transactions we originate from PureScript (setContent /
// setErrors) so the updateListener below can distinguish them from
// user input. Without this, _setContent fires updateListener, which
// calls onChange, which raises back up to the parent, which may
// re-render with stale state and call _setContent again — a classic
// CM6/parent-state ping-pong.
const programmaticAnnotation = Annotation.define();

// Compartment wrapping the EditorView.editable facet so we can
// reconfigure the editor between editable/read-only at runtime
// without rebuilding the whole state. A single Compartment identity
// is shared across all views — it acts as a key that CM uses to
// find the compartment within each view's own state.
const editableCompartment = new Compartment();

// Light syntax-highlight theme keyed to the page palette.
// Swiss-style: a small, muted set of hues that carry meaning without
// shouting. Keywords and operators in petrol, types in teal,
// comments in slate, strings in terracotta, numbers in the body
// colour so they stand out as literals.
const playgroundHighlightStyle = HighlightStyle.define([
  { tag: t.comment,       color: '#6b7a8a', fontStyle: 'italic' },
  { tag: t.lineComment,   color: '#6b7a8a', fontStyle: 'italic' },
  { tag: t.blockComment,  color: '#6b7a8a', fontStyle: 'italic' },
  { tag: t.keyword,       color: '#2b5f75', fontWeight: '600' },
  { tag: t.controlKeyword,color: '#2b5f75', fontWeight: '600' },
  { tag: t.definitionKeyword, color: '#2b5f75', fontWeight: '600' },
  { tag: t.operatorKeyword,color: '#2b5f75' },
  { tag: t.operator,      color: '#1d1d1b' },
  { tag: t.string,        color: '#9e5a3c' },
  { tag: t.number,        color: '#1d1d1b' },
  { tag: t.bool,          color: '#6b4c8a', fontWeight: '600' },
  { tag: t.null,          color: '#6b4c8a', fontStyle: 'italic' },
  { tag: t.className,     color: '#3d7a72', fontWeight: '600' },
  { tag: t.typeName,      color: '#3d7a72', fontWeight: '600' },
  { tag: t.variableName,  color: '#1d1d1b' },
  { tag: t.function(t.variableName), color: '#1d1d1b' },
  { tag: t.propertyName,  color: '#1d1d1b' },
  { tag: t.labelName,     color: '#8a6a2b' },
  { tag: t.meta,          color: '#6b7a8a' },
  { tag: t.punctuation,   color: '#6b6b66' },
  { tag: t.bracket,       color: '#6b6b66' },
  { tag: t.namespace,     color: '#3d7a72' },
]);

// Backend origin is derived from window.location at bundle-load time
// so the same bundle works from localhost and over Tailscale.
const BACKEND_URL =
  typeof window !== 'undefined' && window.location && window.location.hostname
    ? `http://${window.location.hostname}:3050`
    : 'http://localhost:3050';
const IDE_TYPE_URL = `${BACKEND_URL}/ide/type`;

// Characters that are part of a PureScript identifier (word or operator).
// We stay conservative: only plain word chars — operator tooltips can
// come later once the grammar we're using disambiguates them reliably.
function isWordChar(ch) {
  return /[A-Za-z0-9_']/.test(ch);
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// --- Inline error decoration -----------------------------------
// Errors are fed in as an Array of { startLine, startColumn, endLine,
// endColumn, message } records (1-based line/col, matching the
// `Position` we thread through from the compiler). We convert to
// CM6 offsets, build Decoration.mark ranges, and dispatch them via a
// StateEffect; the StateField provides them as decorations.

const setErrorsEffect = StateEffect.define();

const errorsField = StateField.define({
  create: () => Decoration.none,
  update: (decos, tr) => {
    for (const e of tr.effects) {
      if (e.is(setErrorsEffect)) return e.value;
    }
    return decos.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});

function buildErrorDecos(view, errors) {
  const doc = view.state.doc;
  const marks = [];
  for (const err of errors) {
    try {
      const sLine = doc.line(Math.max(1, Math.min(err.startLine, doc.lines)));
      const eLine = doc.line(Math.max(1, Math.min(err.endLine, doc.lines)));
      // Clamp columns to line length to guard against stale positions
      // (e.g. user edited between compile and decoration dispatch).
      const from = sLine.from + Math.max(0, Math.min(err.startColumn - 1, sLine.length));
      const to = Math.max(from + 1, eLine.from + Math.max(0, Math.min(err.endColumn - 1, eLine.length)));
      marks.push(
        Decoration.mark({
          class: 'cm-playground-error',
          attributes: { title: String(err.message || '') },
        }).range(from, to)
      );
    } catch (_) { /* skip malformed entry */ }
  }
  return Decoration.set(marks, true);
}

export const _setErrors = (view) => (errors) => () => {
  view.dispatch({ effects: setErrorsEffect.of(buildErrorDecos(view, errors)) });
};

// CM6 hover-tooltip extension. Extracts the word at the hover point,
// POSTs to /ide/type, hands the type string to the renderer (which
// returns Sigil HTML when parseable, plain `<code>` otherwise).
// Prefers a Main or Playground.User origin so local bindings win over
// library shadowing.
function makeTypeHover(renderType) {
  return hoverTooltip(async (view, pos, side) => {
    const line = view.state.doc.lineAt(pos);
    const text = line.text;
    let start = pos;
    let end = pos;
    while (start > line.from && isWordChar(text[start - line.from - 1])) start--;
    while (end < line.to && isWordChar(text[end - line.from])) end++;
    if (start === end && side < 0) return null;
    const word = text.slice(start - line.from, end - line.from);
    if (!word || !isWordChar(word[0])) return null;

    let hits = [];
    try {
      const resp = await fetch(IDE_TYPE_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: word }),
      });
      const json = await resp.json();
      hits = json.hits || [];
    } catch (_) {
      return null;
    }
    if (hits.length === 0) return null;

    const hit =
      hits.find((h) => h.moduleName === 'Main' || h.moduleName === 'Playground.User') ||
      hits[0];

    return {
      pos: start,
      end,
      above: true,
      create() {
        const dom = document.createElement('div');
        dom.className = 'cm-tooltip-type';
        const typeHtml = renderType(hit.typeSignature);
        dom.innerHTML =
          '<div class="cm-tooltip-sig">' +
            '<span class="cm-tooltip-name">' + escapeHtml(hit.identifier) + '</span>' +
            ' <span class="cm-tooltip-dcolon">::</span> ' +
            '<span class="cm-tooltip-ty">' + typeHtml + '</span>' +
          '</div>' +
          (hit.moduleName
            ? '<div class="cm-tooltip-module">' + escapeHtml(hit.moduleName) + '</div>'
            : '');
        return { dom };
      },
    };
  });
}

// Creates a CodeMirror 6 view mounted into `parent`. `onChange` fires
// every time the document is edited, with the full new document content.
// Returns the EditorView so callers can query/destroy it later.
export const _createEditor = (parent) => (initialDoc) => (onChange) => (renderType) => () => {
  const typeHover = makeTypeHover(renderType);
  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc: initialDoc,
      extensions: [
        lineNumbers(),
        drawSelection(),
        history(),
        bracketMatching(),
        indentOnInput(),
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        // Haskell's lexer is close enough for PureScript for now; a
        // dedicated PureScript grammar lands as a later upgrade.
        StreamLanguage.define(haskell),
        syntaxHighlighting(playgroundHighlightStyle),
        errorsField,
        editableCompartment.of(EditorView.editable.of(true)),
        typeHover,
        EditorView.updateListener.of((update) => {
          // onChange is an EffectFn1 — call once, no trailing thunk.
          // Skip transactions we initiated ourselves (setContent);
          // only user edits should propagate back up to Halogen.
          if (update.docChanged) {
            const programmatic = update.transactions.some(
              (tr) => tr.annotation(programmaticAnnotation) === true,
            );
            if (!programmatic) {
              onChange(update.state.doc.toString());
            }
          }
        }),
        EditorView.theme({
          '&': { height: '100%' },
          '.cm-scroller': { fontFamily: 'var(--mono)', fontSize: '13px', lineHeight: '1.5' },
          '.cm-content': { padding: '6px 0' },
        }),
      ],
    }),
  });
  return view;
};

export const _getContent = (view) => () => view.state.doc.toString();

export const _setContent = (view) => (content) => () => {
  // Clear error decorations in the SAME transaction as the content
  // replacement — otherwise any surviving decoration at a position
  // beyond the new doc's length blows up errorsField.update's
  // `decos.map(tr.changes)` call with a RangeError. Any currently-
  // valid errors will be re-pushed by the caller's decorateErrors
  // pass immediately afterwards.
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: content },
    effects: [ setErrorsEffect.of(Decoration.none) ],
    annotations: [programmaticAnnotation.of(true)],
  });
};

export const _destroy = (view) => () => view.destroy();

export const _setEditable = (view) => (editable) => () => {
  view.dispatch({
    effects: editableCompartment.reconfigure(EditorView.editable.of(editable)),
  });
};
