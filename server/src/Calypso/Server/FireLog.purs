-- | Append-only log of every cell fire.
-- |
-- | Persists to `~/.calypso/fire-log.jsonl` — JSON-lines format, one
-- | entry per line.  Append-only across sessions; the file just grows
-- | (cap by date if we ever care; for now the working assumption is
-- | that performance sessions produce on the order of hundreds of
-- | fires so disk growth is trivial).
-- |
-- | The log makes the cells-pane "wipe & restore" gesture safe: any
-- | clever pattern you played with but forgot to push back to the code
-- | pane is recoverable from the log.  The `GET /log` endpoint returns
-- | recent entries the frontend can render and re-instantiate as cells.
module Calypso.Server.FireLog
  ( Entry
  , entryCodec
  , appendFire
  , readRecent
  , logFilePath
  ) where

import Prelude

import Data.Array as Array
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as Str
import Data.String.Pattern (Pattern(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff as Aff
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Exception (try)
import Calypso.Server.Proposals (currentTimeMs)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.FS.Perms as Perms
import Node.FS.Sync as FSS
import Node.Path as Path
import Node.Process as Process
import Data.Argonaut.Core (stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Codec.Argonaut as CAJ

-- | A single fire-log entry.
-- |
-- |   * `timestamp`  — Unix epoch milliseconds.
-- |   * `source`     — the raw cell text fired (post-comment-strip,
-- |                    pre-daemon).  This is what gets restored.
-- |   * `ok`         — did the daemon reply OK?  (`false` = errored.)
-- |   * `reply`      — the daemon's reply line, useful for context.
type Entry =
  { timestamp :: Number
  , source :: String
  , ok :: Boolean
  , reply :: String
  }

entryCodec :: JsonCodec Entry
entryCodec = CAR.object "FireLogEntry"
  { timestamp: CA.number
  , source: CA.string
  , ok: CA.boolean
  , reply: CA.string
  }

-- | `~/.calypso/fire-log.jsonl`.  Resolved at call time off `$HOME`
-- | so the path follows the human's account; falls back to `.calypso`
-- | in cwd if `$HOME` is unset (very unusual).
logFilePath :: Effect String
logFilePath = do
  home <- Process.lookupEnv "HOME"
  let base = case home of
        Just h | not (Str.null h) -> h
        _ -> "."
  pure (Path.concat [ base, ".calypso", "fire-log.jsonl" ])

-- | mkdir -p the parent dir and append one line.  Errors logged to
-- | stderr but not propagated — a fire-log write failure should never
-- | break the user's actual fire dispatch.
appendFire :: { source :: String, ok :: Boolean, reply :: String } -> Aff Unit
appendFire { source, ok, reply } = do
  ts <- liftEffect currentTimeMs
  let entry = { timestamp: ts, source, ok, reply }
  path <- liftEffect logFilePath
  liftEffect (ensureParentDir path)
  let line = stringify (CAJ.encode entryCodec entry) <> "\n"
  result <- Aff.attempt (FSA.appendTextFile UTF8 path line)
  case result of
    Left e -> liftEffect $ Console.warn $
      "fire-log: append failed at " <> path <> ": " <> show e
    Right _ -> pure unit

-- | Read the last N entries (or all if N is large enough).  Tolerant
-- | of malformed lines (mid-write tears, hand-edits) — those are
-- | dropped; the rest comes through.
readRecent :: Int -> Aff (Array Entry)
readRecent n = do
  path <- liftEffect logFilePath
  result <- Aff.attempt (FSA.readTextFile UTF8 path)
  let entries = case result of
        Left _ -> []
        Right body ->
          let lines = Str.split (Pattern "\n") body
              nonEmpty = Array.filter (\l -> not (Str.null (Str.trim l))) lines
          in Array.mapMaybe parseLine nonEmpty
  pure (Array.takeEnd n entries)
  where
    parseLine line = case jsonParser line of
      Left _ -> Nothing
      Right json -> case CAJ.decode entryCodec json of
        Left _ -> Nothing
        Right e -> Just e

-- | mkdir -p the parent directory of `path`.  Quiet on success;
-- | warns on failure.
ensureParentDir :: String -> Effect Unit
ensureParentDir path = do
  let dir = Path.dirname path
  let dirMode = Perms.mkPerms Perms.all (Perms.read + Perms.execute) (Perms.read + Perms.execute)
  result <- try (FSS.mkdir' dir { recursive: true, mode: dirMode })
  case result of
    Left e -> Console.warn $
      "fire-log: mkdir failed at " <> dir <> ": " <> show e
    Right _ -> pure unit
