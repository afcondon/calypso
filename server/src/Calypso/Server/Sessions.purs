-- | Server-side helpers for the session library — the `src/Sessions/`
-- | directory of `purerl-tidal/` holding starter session templates
-- | (Fugue, Grids, Rene, ZR, Polysignals, Full).
-- |
-- | Exposed via two routes:
-- |
-- |   GET /sessions             → { names: [String] }
-- |   GET /sessions/<name>      → { source: String }
-- |
-- | The frontend's gear menu calls these to populate a session picker
-- | and to fetch the chosen session's content, which is then routed
-- | through the existing fire-typeful path (PATCH /session/module +
-- | POST /session-source) — same machinery as the composition pane's
-- | Run button.
-- |
-- | Module rewrite: the on-disk template uses `module Sessions.<Name>`,
-- | but the BEAM-walked module is `Calypso.Generated.Session`.  We
-- | rewrite at fetch time so the frontend doesn't need to know.
module Calypso.Server.Sessions
  ( sessionsDir
  , listSessions
  , readSession
  , sessionsListCodec
  , sessionContentCodec
  ) where

import Prelude

import Data.Array as Array
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..))
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff as Aff
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.Path as Path
import Node.Process as Process

-- | Locate `purerl-tidal/src/Sessions/`.  Honours `PURERL_TIDAL_ROOT`
-- | env (same convention as `SessionSource.js`); otherwise resolves
-- | `../purerl-tidal/src/Sessions/` relative to the server's cwd.
sessionsDir :: Effect String
sessionsDir = do
  mRoot <- Process.lookupEnv "PURERL_TIDAL_ROOT"
  cwd   <- Process.cwd
  let root = case mRoot of
        Just r  -> r
        Nothing -> Path.concat [cwd, "..", "purerl-tidal"]
  pure (Path.concat [root, "src", "Sessions"])

-- | List `*.purs` filenames in the sessions directory, without the
-- | `.purs` suffix.  Errors (missing dir, perms) collapse to `[]` so
-- | callers can render "no sessions available" rather than failing.
listSessions :: String -> Aff (Array String)
listSessions dir = do
  result <- Aff.attempt (FSA.readdir dir)
  let names = case result of
        Left _   -> []
        Right ns -> ns
  pure
    (Array.sort
      (Array.mapMaybe (String.stripSuffix (Pattern ".purs")) names))

-- | Read `<dir>/<name>.purs` and rewrite the module declaration from
-- | `module Sessions.<Name>` to `module Calypso.Generated.Session`.
-- | Returns the rewritten text or an error string suitable for a 4xx.
-- |
-- | Path-traversal guard: only accepts non-empty, non-dotted names
-- | with no slashes or backslashes.  Length capped at 32 characters
-- | (sessions are PascalCase short words).
readSession :: String -> String -> Aff (Either String String)
readSession dir name =
  if not safe then
    pure (Left ("invalid session name: " <> show name))
  else do
    let path = Path.concat [dir, name <> ".purs"]
    result <- Aff.attempt (FSA.readTextFile UTF8 path)
    case result of
      Left e    -> pure (Left ("read " <> path <> ": " <> Aff.message e))
      Right raw -> pure (Right (stripComments (rewriteModuleDecl name raw)))
  where
    safe =
      String.length name > 0
        && String.length name <= 32
        && String.indexOf (Pattern "/")  name == Nothing
        && String.indexOf (Pattern "\\") name == Nothing
        && String.indexOf (Pattern ".")  name == Nothing

-- | Rewrite the first `module Sessions.<Name>` line.  String-level
-- | substitution; if the file's module decl uses a different shape,
-- | we leave it alone and let `purs compile` reject it downstream.
rewriteModuleDecl :: String -> String -> String
rewriteModuleDecl name raw =
  String.replace
    (Pattern     ("module Sessions." <> name))
    (Replacement  "module Calypso.Generated.Session")
    raw

-- | Strip whole-line comments + collapse the runs of blank lines that
-- | result.  Composition-pane readers don't want the on-disk
-- | docstrings cluttering the editor; the .purs file keeps its
-- | documentation, the editor gets clean code.  Anti-pattern in normal
-- | code review but right for "the user is going to *play* this".
stripComments :: String -> String
stripComments raw =
  let
    lines      = String.split (Pattern "\n") raw
    -- A "comment line" is one whose first non-whitespace characters
    -- are `--`.  Keep code lines + inline-comments-following-code (the
    -- comment lives on the same line as code; rare in our templates).
    isComment  = \s -> String.take 2 (String.trim s) == "--"
    keptLines  = Array.filter (not <<< isComment) lines
    -- Collapse runs of >=2 consecutive blank lines down to one.
    collapsed  = foldlBlankRuns keptLines
  in String.joinWith "\n" collapsed

foldlBlankRuns :: Array String -> Array String
foldlBlankRuns =
  let
    step acc line =
      let blank = String.trim line == ""
          prevBlank = case Array.last acc of
            Just s -> String.trim s == ""
            Nothing -> false
      in if blank && prevBlank
           then acc
           else Array.snoc acc line
  in Array.foldl step []

-- ---------------------------------------------------------------------------
-- JSON codecs
-- ---------------------------------------------------------------------------

sessionsListCodec :: JsonCodec { names :: Array String }
sessionsListCodec = CAR.object "SessionsList"
  { names: CA.array CA.string }

sessionContentCodec :: JsonCodec { source :: String }
sessionContentCodec = CAR.object "SessionContent"
  { source: CA.string }
