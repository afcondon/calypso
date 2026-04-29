-- | Favorites discovery: the user keeps a folder of `.tidal` files at
-- | `~/.calypso/favorites/` (cross-machine personal — survives clone
-- | churn).  Each file in that folder is a composition-pane template;
-- | the server lists them at `GET /favorites` so the frontend dropdown
-- | can render any file the user has dropped in.
-- |
-- | On first run the folder is created and seeded with `default.tidal`
-- | so the dropdown is non-empty out of the box.  Subsequent runs
-- | leave existing files alone.
module Calypso.Server.Favorites
  ( favoritesDir
  , ensureFavoritesDir
  , listFavorites
  , loadDefaultBody
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as Str
import Data.String.Pattern (Pattern(..))
import Data.Traversable (for)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff as Aff
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Effect.Exception (try)
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FSA
import Node.FS.Perms as Perms
import Node.FS.Sync as FSS
import Node.Path as Path
import Node.Process as Process

import Calypso.Favorite (Favorite(..))

-- | Default body seeded into `default.tidal` on first run.  The
-- | wording mirrors `Session.tidalStarterModule` so the cross-machine
-- | shape stays consistent — the server's pristine session and the
-- | dropdown's default favorite render the same starter content.
defaultFavoriteBody :: String
defaultFavoriteBody = """-- Calypso composition. Edit freely; cells fire against a running
-- purerl-tidal at ws://localhost:3012/ws.
--
-- @scale       c-minor-pentatonic [c d# f g a#]
-- @progression vamp [Dm7 G7 Cmaj7]
--
-- Load device vocabularies from the purerl-tidal setup directory
-- before firing patterns:
--
--   load rample
--   load qd
--   load laplace
--   load turnado
"""

-- | `~/.calypso/favorites`.  Resolved at call time off `$HOME` so the
-- | path follows the human's account when running over SSH or as a
-- | LaunchAgent under a different user.  Falls back to `.calypso` in
-- | the cwd if `$HOME` is unset (very unusual; keeps the function
-- | total).
favoritesDir :: Effect String
favoritesDir = do
  home <- Process.lookupEnv "HOME"
  let base = case home of
        Just h | not (Str.null h) -> h
        _ -> "."
  pure (Path.concat [ base, ".calypso", "favorites" ])

-- | mkdir -p the favorites dir on boot, and seed `default.tidal` with
-- | the starter body if the directory ends up empty.  Idempotent.
-- | Synchronous because the server's boot path runs in `Effect`; we
-- | want the directory in place before the first request arrives.
ensureFavoritesDir :: String -> Effect Unit
ensureFavoritesDir dir = do
  -- rwx for owner, r-x for group + others (0o755 — standard for dirs).
  let dirMode = Perms.mkPerms Perms.all (Perms.read + Perms.execute) (Perms.read + Perms.execute)
  mkResult <- try (FSS.mkdir' dir { recursive: true, mode: dirMode })
  case mkResult of
    Left e -> Console.warn $ "favorites: mkdir failed at " <> dir <> ": " <> show e
    Right _ -> pure unit
  entries <- listTidalFilesSync dir
  when (Array.null entries) do
    let seedPath = Path.concat [ dir, "default.tidal" ]
    seedResult <- try (FSS.writeTextFile UTF8 seedPath defaultFavoriteBody)
    case seedResult of
      Left e -> Console.warn $ "favorites: seeding default.tidal at " <> seedPath <> " failed: " <> show e
      Right _ -> Console.log $ "favorites: seeded " <> seedPath

-- | List the favorites visible to the dropdown.  Sorted alphabetically
-- | by filename so the order is stable across reloads.  Returns `[]`
-- | (not an error) if the directory is unreadable so the frontend
-- | falls back to "no favorites yet" rather than a transport error.
listFavorites :: String -> Aff (Array Favorite)
listFavorites dir = do
  files <- listTidalFiles dir
  for files \fname -> do
    let path = Path.concat [ dir, fname ]
        key = stripDotTidal fname
    body <- readTextOrEmpty path
    pure (Favorite { key, label: key, body })

-- | Read `default.tidal` if present; used by the server's initial-state
-- | seed so a fresh session arrives with whatever the user's chosen
-- | default is, rather than the hardcoded fallback.  Synchronous —
-- | called from the boot path before the first `Session.newStore`.
loadDefaultBody :: String -> Effect (Maybe String)
loadDefaultBody dir = do
  let path = Path.concat [ dir, "default.tidal" ]
  result <- try (FSS.readTextFile UTF8 path)
  pure (case result of
    Left _ -> Nothing
    Right body -> Just body)

-- | Internal: list `*.tidal` filenames in a directory, sorted.  Errors
-- | (missing dir, perms) collapse to `[]` so listing is total.
listTidalFiles :: String -> Aff (Array String)
listTidalFiles dir = do
  result <- Aff.attempt (FSA.readdir dir)
  let names = case result of
        Left _ -> []
        Right ns -> ns
  pure (Array.sort (Array.filter isTidalName names))

-- | Synchronous variant; only used at boot to decide whether the
-- | directory needs seeding.
listTidalFilesSync :: String -> Effect (Array String)
listTidalFilesSync dir = do
  result <- try (FSS.readdir dir)
  let names = case result of
        Left _ -> []
        Right ns -> ns
  pure (Array.sort (Array.filter isTidalName names))

isTidalName :: String -> Boolean
isTidalName n = case Str.stripSuffix (Pattern ".tidal") n of
  Just _ -> true
  Nothing -> false

-- | Read a file as UTF-8; on any error return empty string so a
-- | broken favorite shows up in the dropdown but loads nothing rather
-- | than crashing the listing.  Logs on failure so the human can see
-- | which file's the problem.
readTextOrEmpty :: String -> Aff String
readTextOrEmpty path = do
  result <- Aff.attempt (FSA.readTextFile UTF8 path)
  case result of
    Left e -> do
      liftEffect $ Console.warn $ "favorites: reading " <> path <> " failed: " <> Aff.message e
      pure ""
    Right body -> pure body

stripDotTidal :: String -> String
stripDotTidal s = case Str.stripSuffix (Pattern ".tidal") s of
  Just rest -> rest
  Nothing -> s
