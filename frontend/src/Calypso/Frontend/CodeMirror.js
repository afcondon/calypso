import { EditorView, keymap, lineNumbers, drawSelection, Decoration } from '@codemirror/view';
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

// Creates a CodeMirror 6 view mounted into `parent`.
//   onChange  fires on every edit with the full doc content
//   onSubmit  fires on the explicit fire gesture (Mod-Enter on Mac;
//             Ctrl-Enter on others) with the full doc content
//
// `_renderType` is unused — Calypso has no types to render in hover
// tooltips.  Kept on the FFI surface so the PureScript signature
// stays stable while we settle on what tooltip content (if any) the
// composition pane wants.
export const _createEditor = (parent) => (initialDoc) => (onChange) => (onSubmit) => (_renderType) => () => {
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
