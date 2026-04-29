module Playground.Server.WorkspaceMgr
  ( WorkspaceId(..)
  , workspaceIdString
  , validateWorkspaceId
  , requestWorkspaceId
  , workspacePath
  , listWorkspaces
  , listWorkspacesSync
  , createWorkspace
  , createWorkspaceSync
  , deleteWorkspace
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Data.Array (all)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (null) as String
import Data.String.CodeUnits (toCharArray)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign.Object as Object
import HTTPurple.Query (Query)

-- | Opaque workspace identifier. Equality + ordering so it can key a
-- | Map; Show only for diagnostics (not the wire form — the wire form
-- | is plain JSON strings, assembled inline at the route boundaries).
newtype WorkspaceId = WorkspaceId String

derive newtype instance Eq WorkspaceId
derive newtype instance Ord WorkspaceId

instance Show WorkspaceId where
  show (WorkspaceId s) = "WorkspaceId " <> show s

workspaceIdString :: WorkspaceId -> String
workspaceIdString (WorkspaceId s) = s

-- | A workspace id must be non-empty and drawn from [A-Za-z0-9_-].
-- | These constraints keep it safe to use as a directory name and
-- | URL segment without escaping.
validateWorkspaceId :: String -> Either String WorkspaceId
validateWorkspaceId s
  | String.null s = Left "workspace id cannot be empty"
  | all isValidWorkspaceIdChar (toCharArray s) = Right (WorkspaceId s)
  | otherwise = Left "workspace id must match [A-Za-z0-9_-]+"

isValidWorkspaceIdChar :: Char -> Boolean
isValidWorkspaceIdChar c =
  (c >= '0' && c <= '9')
    || (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || c == '_'
    || c == '-'

-- | Resolve the workspace id for an incoming request. Missing or
-- | empty `workspace` query param → "main"; otherwise validate.
-- | Returns Left with a message on invalid ids so handlers can 400.
requestWorkspaceId :: Query -> Either String WorkspaceId
requestWorkspaceId q = case Object.lookup "workspace" q of
  Nothing -> Right (WorkspaceId "main")
  Just "" -> Right (WorkspaceId "main")
  Just s -> validateWorkspaceId s

-- | On-disk path for a workspace under the given root.
workspacePath :: String -> WorkspaceId -> String
workspacePath rootDir (WorkspaceId id) = rootDir <> "/" <> id

-- ============================================================
-- Filesystem operations (JS FFI)
-- ============================================================

foreign import _listWorkspaceDirs :: String -> Effect (Promise (Array String))
foreign import _listWorkspaceDirsSync :: String -> Effect (Array String)
foreign import _createWorkspaceDir
  :: String -> String -> String -> String -> Effect (Promise Unit)
foreign import _createWorkspaceDirSync
  :: String -> String -> String -> String -> Effect Unit
foreign import _deleteWorkspaceDir
  :: String -> String -> Effect (Promise Unit)

-- | Enumerate existing workspace subdirectories under `rootDir`. Any
-- | directory name is treated as a valid id at this layer; invalid
-- | ones would have been rejected at creation time.
listWorkspaces :: String -> Aff (Array WorkspaceId)
listWorkspaces rootDir = map WorkspaceId <$> toAffE (_listWorkspaceDirs rootDir)

-- | Synchronous variant used during boot, where we need the workspace
-- | map populated before the HTTP listener starts accepting requests.
listWorkspacesSync :: String -> Effect (Array WorkspaceId)
listWorkspacesSync rootDir = map WorkspaceId <$> _listWorkspaceDirsSync rootDir

-- | Materialise a new workspace on disk: create the directory, copy
-- | the runtime-library files from `templateDir`, rewrite
-- | `spago.yaml` + `package.json` so the package is uniquely named
-- | (the outer workspace sees every workspace's package at once, so
-- | `spago build -p <name>` needs distinct names to pick the right
-- | one), and seed `src/Main.purs` + `src/Playground/User.purs`.
createWorkspace
  :: { rootDir :: String, templateDir :: String, packageName :: String }
  -> WorkspaceId
  -> Aff Unit
createWorkspace { rootDir, templateDir, packageName } (WorkspaceId id) =
  toAffE (_createWorkspaceDir rootDir templateDir packageName id)

-- | Synchronous variant of `createWorkspace` used at boot to materialise
-- | the `eval-scratch` workspace before the HTTP listener starts.
createWorkspaceSync
  :: { rootDir :: String, templateDir :: String, packageName :: String }
  -> WorkspaceId
  -> Effect Unit
createWorkspaceSync { rootDir, templateDir, packageName } (WorkspaceId id) =
  _createWorkspaceDirSync rootDir templateDir packageName id

-- | Recursively remove a workspace from disk.
deleteWorkspace :: String -> WorkspaceId -> Aff Unit
deleteWorkspace rootDir (WorkspaceId id) =
  toAffE (_deleteWorkspaceDir rootDir id)
