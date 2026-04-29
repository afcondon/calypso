-- | Minimal stub for the workspace ID + path helpers `Main.purs`
-- | imports. Atelier had real workspace materialisation (template
-- | copy, per-workspace spago packages, multi-workspace listing on
-- | disk); Calypso doesn't need any of that — there's a single
-- | session, persisted as `atelier-session.json` under a fixed
-- | directory. The functions here keep the Main.purs surface stable
-- | while doing nothing on disk.
-- |
-- | A future cleanup pass collapses Main.purs to the single-session
-- | shape and deletes this stub entirely.
module Calypso.Server.WorkspaceMgr
  ( WorkspaceId(..)
  , createWorkspace
  , createWorkspaceSync
  , deleteWorkspace
  , listWorkspacesSync
  , requestWorkspaceId
  , validateWorkspaceId
  , workspaceIdString
  , workspacePath
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Effect (Effect)
import Effect.Aff (Aff)
import HTTPurple.Query (Query)
import HTTPurple.Lookup ((!!))

newtype WorkspaceId = WorkspaceId String

derive instance Newtype WorkspaceId _
derive newtype instance Eq WorkspaceId
derive newtype instance Ord WorkspaceId

workspaceIdString :: WorkspaceId -> String
workspaceIdString (WorkspaceId s) = s

-- | Permissive: any non-empty string is a valid workspace id. Real
-- | validation lived alongside template-copy in Atelier; not needed
-- | for a single-session app.
validateWorkspaceId :: String -> Either String WorkspaceId
validateWorkspaceId s
  | s == "" = Left "workspace id cannot be empty"
  | otherwise = Right (WorkspaceId s)

-- | `workspace=...` query param → WorkspaceId, defaulting to "main"
-- | when the query is absent. Backwards-compatible with Atelier-shaped
-- | callers that pass `?workspace=foo`.
requestWorkspaceId :: Query -> Either String WorkspaceId
requestWorkspaceId q = case q !! "workspace" of
  Nothing -> Right (WorkspaceId "main")
  Just s -> validateWorkspaceId s

workspacePath :: String -> WorkspaceId -> String
workspacePath rootDir wid = rootDir <> "/" <> workspaceIdString wid

-- | Atelier listed workspace dirs from `runtime-workspace/workspaces/`.
-- | Calypso has no template-driven workspaces; just return empty.
listWorkspacesSync :: String -> Effect (Array WorkspaceId)
listWorkspacesSync _ = pure []

-- | No-op stubs — Calypso doesn't materialise workspaces from a
-- | template. Kept on the import surface so Main.purs's existing
-- | route handlers don't have to be rewritten in this commit.
createWorkspace
  :: { rootDir :: String, templateDir :: String, packageName :: String }
  -> WorkspaceId
  -> Aff Unit
createWorkspace _ _ = pure unit

createWorkspaceSync
  :: { rootDir :: String, templateDir :: String, packageName :: String }
  -> WorkspaceId
  -> Effect Unit
createWorkspaceSync _ _ = pure unit

deleteWorkspace :: String -> WorkspaceId -> Aff Unit
deleteWorkspace _ _ = pure unit
