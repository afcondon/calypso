module Playground.Server.Synthesize
  ( synthesize
  , Synthesised
  ) where

import Prelude

import Data.Array (filter, findIndex, head, length, mapMaybe, null, snoc, uncons) as Array
import Data.Array (mapMaybe)
import Data.Foldable (foldMap)
import Data.Maybe (Maybe(..), isJust)
import Data.String (length) as Str
import Data.String as Str
import Data.String.Pattern (Pattern(..))

import Playground.Session
  ( Cell(..)
  , CellRange(..)
  , CompileRequest(..)
  , UserModule(..)
  )

-- | The two source files produced on each compile, plus the per-cell
-- | line ranges in `Main.purs`. The frontend uses the line ranges to
-- | attribute compile errors back to the originating cell.
type Synthesised =
  { userSource :: String
  , mainSource :: String
  , cellLines :: Array CellRange
  }

-- | Purerl has no Aff in its package set, so its synthesised main must
-- | be pure Effect (no runAff_/liftEffect/launchAff_). This flag tells
-- | the synthesiser which shape to emit.
type Options = { purerl :: Boolean }

synthesize :: Options -> CompileRequest -> Synthesised
synthesize opts (CompileRequest { "module": UserModule { source }, cells }) =
  let
    userImports = extractImports source
    mainSource = buildMain opts userImports cells
    cellLines = computeCellLines mainSource cells
  in
    { userSource: rewriteModuleHeader source
    , mainSource
    , cellLines
    }

-- | Pull the user module's import lines out of their source so the
-- | synthesised Main can re-include them. Without this, cells only see
-- | what `Playground.User` re-exports (which is only its *declarations*,
-- | not the things it *imports*).
-- |
-- | A pragmatic heuristic: every line that begins with `import ` (after
-- | trimming) is treated as an import. Multi-line import lists with
-- | hanging indent are captured because each continuation line starts
-- | with whitespace (not `import ` at column 1), but purs is whitespace
-- | sensitive only inside the list — the whole block belongs to the
-- | preceding import. We capture contiguous runs starting at an
-- | `import` line until we hit a non-indented, non-blank, non-import
-- | line.
extractImports :: String -> String
extractImports src =
  let
    lines = Str.split (Pattern "\n") src
    collected = Array.filter notDuplicatePrelude (go false [] lines)
  in
    Str.joinWith "\n" collected
  where
  -- The synthesised Main already imports Prelude; skip the user's
  -- version if they had an identical bare `import Prelude` line.
  notDuplicatePrelude line = Str.trim line /= "import Prelude"
  go :: Boolean -> Array String -> Array String -> Array String
  go seenImport acc rest = case Array.uncons rest of
    Nothing -> acc
    Just { head: line, tail } ->
      let trimmed = Str.trim line
      in
        if isImport trimmed then
          go true (Array.snoc acc line) tail
        else if seenImport && (trimmed == "" || startsIndented line) then
          go true (Array.snoc acc line) tail
        else if seenImport then
          acc
        else
          go seenImport acc tail

  isImport s = isJust (Str.stripPrefix (Pattern "import ") s)

  startsIndented line =
    case Str.indexOf (Pattern " ") line, Str.indexOf (Pattern "\t") line of
      Just 0, _ -> true
      _, Just 0 -> true
      _, _ -> false

-- | Replace the user's `module Foo where` (possibly with multi-line export
-- | list) with `module Playground.User where`. If no module header is
-- | found, prepend one. Good enough for MVP — doesn't try to parse inside
-- | strings or comments that happen to contain the literal "module" or
-- | "where".
rewriteModuleHeader :: String -> String
rewriteModuleHeader src =
  case Str.indexOf (Pattern "module") src of
    Nothing -> "module Playground.User where\n" <> src
    Just moduleIdx ->
      let afterModule = Str.drop moduleIdx src
      in case Str.indexOf (Pattern "where") afterModule of
        Nothing -> "module Playground.User where\n" <> src
        Just relWhereIdx ->
          let
            before = Str.take moduleIdx src
            endOfWhere = moduleIdx + relWhereIdx + Str.length "where"
            after = Str.drop endOfWhere src
          in before <> "module Playground.User where" <> after

-- | Build the synthesised Main.purs. Each `expr` cell becomes a top-level
-- | binding `cell_<id>` and contributes a line to `main`; each `let` cell
-- | is spliced in verbatim as a top-level binding (it must be of the form
-- | `name = expr`). `userImports` is the verbatim import block from the
-- | user's module — we include it here so cells see the same scope the
-- | module does.
buildMain :: Options -> String -> Array Cell -> String
buildMain opts userImports cells =
  let
    exprCells = Array.filter isExpr cells
    letSources = mapMaybe letSource cells
    cellBinding (Cell c) = "cell_" <> c.id <> " = " <> c.source <> "\n"
    -- Aff variant: `v <- toPV cell ; liftEffect (emit id v)`.
    -- Effect variant: `v <- toPV cell ; emit id v`.
    -- Purerl's ToPlaygroundValue returns `Effect` directly (no Aff
    -- in the Purerl set), so both sides sit in Effect naturally.
    emitLine (Cell c) =
      if opts.purerl
        then
          "  v_" <> c.id <> " <- toPlaygroundValue cell_" <> c.id
            <> "\n  emit \"" <> c.id <> "\" v_" <> c.id <> "\n"
        else
          "  v_" <> c.id <> " <- toPlaygroundValue cell_" <> c.id
            <> "\n  liftEffect (emit \"" <> c.id <> "\" v_" <> c.id <> ")\n"
    header =
      if opts.purerl
        then
          "module Main where\n\n"
            <> "import Prelude\n"
            <> "import Data.Array as Array\n"
            <> "import Data.Either (Either(..))\n"
            <> "import Data.Maybe (Maybe(..))\n"
            <> "import Data.Tuple (Tuple(..))\n"
            <> "import Effect (Effect)\n"
            -- Open import so cells always see ForceRender / AtelierForceSpec /
            -- etc. without requiring the user module to import them itself
            -- (friction #10 — that re-import was being flagged as redundant
            -- from the user module's POV because only cells referenced it).
            <> "import Playground.Runtime\n"
            <> "import Playground.User\n"
        else
          "module Main where\n\n"
            <> "import Prelude\n"
            <> "import Data.Array as Array\n"
            <> "import Data.Either (Either(..))\n"
            <> "import Data.Maybe (Maybe(..))\n"
            <> "import Data.Tuple (Tuple(..))\n"
            <> "import Effect (Effect)\n"
            <> "import Effect.Aff (runAff_)\n"
            <> "import Effect.Class (liftEffect)\n"
            -- See note in the purerl branch above: open import lets cells
            -- use the runtime's full vocabulary without the user module
            -- needing to re-import it.
            <> "import Playground.Runtime\n"
            <> "import Playground.User\n"
    body =
      if opts.purerl
        then
          "\nmain :: Effect Unit\n"
            <> "main = do\n"
            <> ( if Array.null exprCells
                   then "  pure unit\n  done\n"
                   else foldMap emitLine exprCells <> "  done\n"
               )
        else
          "\nmain :: Effect Unit\n"
            <> "main = runAff_ (\\_ -> done) do\n"
            <> ( if Array.null exprCells
                   then "  pure unit\n"
                   else foldMap emitLine exprCells
               )
  in
    header
      <> (if Str.trim userImports == "" then "" else userImports <> "\n")
      <> "\n"
      <> "-- let-cells (spliced verbatim)\n"
      <> foldMap (\s -> s <> "\n") letSources
      <> "\n-- expr-cells (top-level bindings)\n"
      <> foldMap cellBinding exprCells
      <> body
  where
  isExpr (Cell c) = c.kind == "expr"
  letSource (Cell c) =
    if c.kind == "let" then Just (normaliseLetSource c) else Nothing
  -- A let-cell's source may already be of form `name = expr` (the
  -- user typed a binding), or just `expr` (they toggled [expr] →
  -- [let] without editing). Normalise: if there's no top-level `=`
  -- wrap the source as `<cell_id> = <source>` so the cell id doubles
  -- as the binding name.
  normaliseLetSource c =
    if hasTopLevelEq c.source
      then c.source
      else c.id <> " = " <> c.source

-- | Rough check: does this source look like a top-level binding (has
-- | an `=` outside an initial expression)? The check is intentionally
-- | shallow — an `=` anywhere in the first line counts. Good enough
-- | for the common cases: `x = 5`, `f x = x + 1`, `double 21` (no =).
-- | Mis-classifies things like `[x == y]` but that's fine for MVP
-- | since such sources are unusual let-cell content.
hasTopLevelEq :: String -> Boolean
hasTopLevelEq src =
  case Str.split (Pattern "\n") src of
    [] -> false
    arr -> case Array.head arr of
      Just firstLine -> isJust (Str.indexOf (Pattern "=") firstLine)
      Nothing -> false

-- | For each expr cell, find the inclusive line range its
-- | `cell_<id> = …` binding occupies in the synthesised Main.purs.
-- | Robust against multi-line cell sources: we count newlines in the
-- | cell's source to determine endLine.
computeCellLines :: String -> Array Cell -> Array CellRange
computeCellLines source cells =
  let lines = Str.split (Pattern "\n") source
  in mapMaybe (findRange lines) cells
  where
  findRange lines (Cell c)
    | c.kind /= "expr" = Nothing
    | otherwise =
        let prefix = "cell_" <> c.id <> " = "
        in case Array.findIndex (lineStartsWith prefix) lines of
          Nothing -> Nothing
          Just idx ->
            let
              startLine = idx + 1
              -- A cell binding occupies (1 + newline-count-in-source) lines
              extraLines = newlineCount c.source
              endLine = startLine + extraLines
            in Just (CellRange { id: c.id, startLine, endLine })

  lineStartsWith p line = isJust (Str.stripPrefix (Pattern p) line)

  -- Number of newlines in a string: split-on-\n minus 1, clamped to 0.
  newlineCount s = max 0 (Array.length (Str.split (Pattern "\n") s) - 1)
