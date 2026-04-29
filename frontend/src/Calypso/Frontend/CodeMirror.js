import { EditorView, keymap, lineNumbers, drawSelection, Decoration, WidgetType } from '@codemirror/view';
import { EditorState, StateField, StateEffect, Annotation, Compartment } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import {
  bracketMatching, indentOnInput, StreamLanguage,
  syntaxHighlighting, HighlightStyle,
} from '@codemirror/language';
import { haskell } from '@codemirror/legacy-modes/mode/haskell';
import { tags as t } from '@lezer/highlight';
import { autocompletion } from '@codemirror/autocomplete';

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

// Matrix CRT highlight theme — phosphor green primary, brighter
// green for keywords, cyan for types/strings, amber for numbers,
// dim green for chrome (comments, punctuation).  Foreground hues
// match the body palette in style.css.
const playgroundHighlightStyle = HighlightStyle.define([
  { tag: t.comment,            color: '#1f6e3a', fontStyle: 'italic' },
  { tag: t.lineComment,        color: '#1f6e3a', fontStyle: 'italic' },
  { tag: t.blockComment,       color: '#1f6e3a', fontStyle: 'italic' },
  { tag: t.keyword,            color: '#9bffb6', fontWeight: '600' },
  { tag: t.controlKeyword,     color: '#9bffb6', fontWeight: '600' },
  { tag: t.definitionKeyword,  color: '#9bffb6', fontWeight: '600' },
  { tag: t.operatorKeyword,    color: '#9bffb6' },
  { tag: t.operator,           color: '#9bffb6' },
  { tag: t.string,             color: '#4afff0' },
  { tag: t.number,             color: '#ffb84a' },
  { tag: t.bool,               color: '#ffb84a', fontWeight: '600' },
  { tag: t.null,               color: '#ffb84a', fontStyle: 'italic' },
  { tag: t.className,          color: '#4afff0', fontWeight: '600' },
  { tag: t.typeName,           color: '#4afff0', fontWeight: '600' },
  { tag: t.variableName,       color: '#41ff7c' },
  { tag: t.function(t.variableName), color: '#41ff7c' },
  { tag: t.propertyName,       color: '#41ff7c' },
  { tag: t.labelName,          color: '#ffb84a' },
  { tag: t.meta,               color: '#1f6e3a' },
  { tag: t.punctuation,        color: '#1f6e3a' },
  { tag: t.bracket,            color: '#1f6e3a' },
  { tag: t.namespace,          color: '#4afff0' },
]);

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
          class: 'cm-calypso-error',
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

// --- Pending proposals: ghost-line block widgets -----------------
// One block widget per hunk, rendered above the line where the hunk
// would land.  The widget shows author/prompt header, struck-through
// `-` lines for what would be removed, bright `+` lines for what
// would be added, and ✓/✗ buttons.  Buttons fire the host-supplied
// onAccept/onReject callbacks with (proposalId, hunkIdx).
//
// Buttons live inside the widget DOM, so we have to thread the
// host callbacks all the way through to the widget constructor.
// The createEditor closure captures them and reuses them on every
// _setProposals call via a small mutable host record.

class HunkWidget extends WidgetType {
  constructor(hv, host) {
    super();
    this.hv = hv;       // HunkView from PS
    this.host = host;   // { onAccept, onReject }
  }

  // Equality keyed on the proposal+hunk identity and the rendered
  // content — CM uses this to avoid rebuilding DOM unnecessarily.
  eq(other) {
    if (!(other instanceof HunkWidget)) return false;
    const a = this.hv;
    const b = other.hv;
    if (a.proposalId !== b.proposalId) return false;
    if (a.hunkIdx !== b.hunkIdx) return false;
    if (a.startLine !== b.startLine) return false;
    if (a.author !== b.author) return false;
    if (a.prompt !== b.prompt) return false;
    if (!sameStrings(a.removed, b.removed)) return false;
    if (!sameStrings(a.added, b.added)) return false;
    return true;
  }

  toDOM() {
    const root = document.createElement('div');
    root.className = 'cm-ghost-hunk';

    // Left sidebar: ✓ / ✗ buttons.  Always visible regardless of
    // body width — the body is the part that scrolls horizontally
    // when content is wider than the column.
    const buttons = document.createElement('div');
    buttons.className = 'cm-ghost-buttons';
    const accept = document.createElement('button');
    accept.className = 'cm-ghost-btn cm-ghost-btn-accept';
    accept.textContent = '✓';
    accept.title = 'Accept this hunk';
    accept.onclick = (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      this.host.onAccept(this.hv.proposalId, this.hv.hunkIdx);
    };
    const reject = document.createElement('button');
    reject.className = 'cm-ghost-btn cm-ghost-btn-reject';
    reject.textContent = '✗';
    reject.title = 'Reject this hunk';
    reject.onclick = (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      this.host.onReject(this.hv.proposalId, this.hv.hunkIdx);
    };
    buttons.appendChild(accept);
    buttons.appendChild(reject);
    root.appendChild(buttons);

    const body = document.createElement('div');
    body.className = 'cm-ghost-body';

    const header = document.createElement('div');
    header.className = 'cm-ghost-header';

    const author = document.createElement('span');
    author.className = 'cm-ghost-author';
    author.textContent = '[' + this.hv.author + ']';
    header.appendChild(author);

    if (this.hv.prompt && this.hv.prompt.length > 0) {
      const prompt = document.createElement('span');
      prompt.className = 'cm-ghost-prompt';
      prompt.textContent = ' ' + this.hv.prompt;
      header.appendChild(prompt);
    }

    const at = document.createElement('span');
    at.className = 'cm-ghost-at';
    at.textContent = '@line ' + this.hv.startLine;
    header.appendChild(at);

    body.appendChild(header);

    for (const line of this.hv.removed) {
      const row = document.createElement('div');
      row.className = 'cm-ghost-row cm-ghost-row-remove';
      const sigil = document.createElement('span');
      sigil.className = 'cm-ghost-sigil';
      sigil.textContent = '- ';
      const txt = document.createElement('span');
      txt.className = 'cm-ghost-text';
      txt.textContent = line;
      row.appendChild(sigil);
      row.appendChild(txt);
      body.appendChild(row);
    }

    for (const line of this.hv.added) {
      const row = document.createElement('div');
      row.className = 'cm-ghost-row cm-ghost-row-add';
      const sigil = document.createElement('span');
      sigil.className = 'cm-ghost-sigil';
      sigil.textContent = '+ ';
      const txt = document.createElement('span');
      txt.className = 'cm-ghost-text';
      txt.textContent = line;
      row.appendChild(sigil);
      row.appendChild(txt);
      body.appendChild(row);
    }

    root.appendChild(body);

    return root;
  }

  // Block widgets are non-atomic by default; the host doc isn't
  // affected by clicks/edits inside them.
  ignoreEvent() { return false; }
}

function sameStrings(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

const setProposalsEffect = StateEffect.define();

const proposalsField = StateField.define({
  create: () => Decoration.none,
  update: (decos, tr) => {
    for (const e of tr.effects) {
      if (e.is(setProposalsEffect)) return e.value;
    }
    return decos.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});

function buildProposalDecos(view, hunkViews, host) {
  const doc = view.state.doc;
  const decos = [];
  for (const hv of hunkViews) {
    try {
      // Clamp startLine into the doc's range so a stale hunk against
      // a freshly-shrunk doc doesn't blow up doc.line().
      const ln = Math.max(1, Math.min(hv.startLine, doc.lines));
      const line = doc.line(ln);
      decos.push(
        Decoration.widget({
          widget: new HunkWidget(hv, host),
          block: true,
          side: -1,
        }).range(line.from)
      );
    } catch (_) { /* skip malformed entry */ }
  }
  // Decoration.set requires sorted-by-from; ranges() does that for us.
  return Decoration.set(decos, true);
}

// _setProposals reuses the host callbacks captured at createEditor
// time.  We stash them in a per-view WeakMap keyed by the EditorView
// so this FFI surface stays signature-stable.
const proposalHosts = new WeakMap();

export const _setProposals = (view) => (hunkViews) => () => {
  const host = proposalHosts.get(view) || { onAccept: () => {}, onReject: () => {} };
  view.dispatch({
    effects: setProposalsEffect.of(buildProposalDecos(view, hunkViews, host)),
  });
};

// --- Autocomplete vocabulary -----------------------------------
// PureScript hands us a flat Array of completions (see
// Calypso.Frontend.Completion) — already shaped for CodeMirror's
// Completion type ({ label, type, detail, info }).  We hold them in
// a StateField so they live alongside the editor state and the
// completion source can read them on every keystroke.

const setVocabularyEffect = StateEffect.define();

const vocabularyField = StateField.define({
  create: () => [],
  update: (current, tr) => {
    for (const e of tr.effects) {
      if (e.is(setVocabularyEffect)) return e.value;
    }
    return current;
  },
});

// Completion source: matches identifiers consisting of word chars
// and dashes (so `laplace-resonator-decay` is one token).  Returns
// the field's options unfiltered — CodeMirror's autocomplete engine
// scores and filters by the typed prefix automatically.
function vocabularyCompletionSource(context) {
  const word = context.matchBefore(/[\w-]+/);
  if (!word || (word.from === word.to && !context.explicit)) return null;
  const options = context.state.field(vocabularyField, false) || [];
  if (options.length === 0) return null;
  return {
    from: word.from,
    options: options.map((c) => ({
      label: c.label,
      type: c.kind,
      detail: c.detail,
      info: c.info && c.info.length > 0 ? c.info : undefined,
    })),
  };
}

export const _setVocabulary = (view) => (completions) => () => {
  view.dispatch({
    effects: setVocabularyEffect.of(completions),
  });
};

// Creates a CodeMirror 6 view mounted into `parent`.
//   onChange   fires on every edit with the full doc content
//   onSubmit   fires on Mod-Enter with the full doc content
//   onAccept   fires on a ghost-hunk accept click with (id, idx)
//   onReject   fires on a ghost-hunk reject click with (id, idx)
//
// `_renderType` is unused — Calypso has no types to render in hover
// tooltips.  Kept on the FFI surface so the PureScript signature
// stays stable while we settle on what tooltip content (if any) the
// composition pane wants.
export const _createEditor =
  (parent) => (initialDoc) => (onChange) => (onSubmit) =>
  (onAccept) => (onReject) => (_renderType) => () => {
  // Tidal-style fire gesture: Cmd-Enter (Mac) / Ctrl-Enter (others)
  // sends the current document up to the parent component, which
  // POSTs to /eval.  Returns true so CM swallows the keystroke
  // (no newline insertion).
  const submitKeymap = keymap.of([
    {
      key: 'Mod-Enter',
      run: (v) => {
        onSubmit(v.state.doc.toString());
        return true;
      },
    },
  ]);
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
        submitKeymap,
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        // Haskell's lexer is close enough for Tidal mini-notation
        // surface syntax; a Tidal-aware grammar lands as a later
        // upgrade once the mini-notation parser exists on the
        // PureScript side.
        StreamLanguage.define(haskell),
        syntaxHighlighting(playgroundHighlightStyle),
        errorsField,
        proposalsField,
        vocabularyField,
        autocompletion({
          override: [vocabularyCompletionSource],
          activateOnTyping: true,
        }),
        editableCompartment.of(EditorView.editable.of(true)),
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
          '.cm-scroller': { fontFamily: 'var(--mono-code)', fontSize: '16px', lineHeight: '1.4' },
          '.cm-content': { padding: '6px 0' },
        }),
      ],
    }),
  });
  // Stash the accept/reject callbacks so _setProposals (called later
  // with no callbacks of its own) can wire ghost-hunk buttons through
  // to them.  EffectFn2's JS shape is (a, b) -> undefined; calling
  // it triggers the effect immediately, no trailing thunk.
  proposalHosts.set(view, {
    onAccept: (proposalId, hunkIdx) => onAccept(proposalId, hunkIdx),
    onReject: (proposalId, hunkIdx) => onReject(proposalId, hunkIdx),
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
