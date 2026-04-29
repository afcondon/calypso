-- | In-memory store for pending edit proposals.  Proposals are
-- | ephemeral by design — a server restart wipes the queue.  If
-- | persistent proposals turn out to matter, the store grows a
-- | calypso-proposals.json sibling to the session snapshot; for now
-- | the simpler shape is good enough.
module Calypso.Server.Proposals
  ( ProposalStore
  , newStore
  , freshProposalId
  , addProposal
  , listProposals
  , withdraw
  , takeHunk
  , currentTimeMs
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Ref (Ref)
import Effect.Ref as Ref

import Calypso.Proposal (Hunk, Proposal(..), ProposalId(..))

newtype ProposalStore = ProposalStore (Ref (Map ProposalId Proposal))

newStore :: Effect ProposalStore
newStore = ProposalStore <$> Ref.new Map.empty

-- | Mint a fresh ProposalId (UUID-shaped).  Same FFI pattern as
-- | Subscribers — guessability is fine for local dev.
freshProposalId :: Effect ProposalId
freshProposalId = ProposalId <$> _freshProposalIdRaw

-- | Insert a proposal into the store.  Caller is expected to have
-- | minted the id via `freshProposalId`.
addProposal :: ProposalStore -> Proposal -> Effect Unit
addProposal (ProposalStore ref) p@(Proposal r) =
  Ref.modify_ (Map.insert r.id p) ref

-- | Snapshot of all current proposals, ordered by createdAt
-- | (oldest first) so the queue is stable across reads.
listProposals :: ProposalStore -> Effect (Array Proposal)
listProposals (ProposalStore ref) = do
  m <- Ref.read ref
  let entries = Array.fromFoldable (Map.values m)
      sorted = Array.sortBy
        (\(Proposal a) (Proposal b) -> compare a.createdAt b.createdAt)
        entries
  pure sorted

-- | Remove a proposal entirely.  Returns the removed proposal so
-- | the caller can broadcast the appropriate retired-id frame.
withdraw :: ProposalStore -> ProposalId -> Effect (Maybe Proposal)
withdraw (ProposalStore ref) pid = do
  m <- Ref.read ref
  case Map.lookup pid m of
    Nothing -> pure Nothing
    Just p -> do
      Ref.write (Map.delete pid m) ref
      pure (Just p)

-- | Pluck a hunk out of a proposal by stable index.
-- |
-- | Returns the hunk that was taken plus a `Maybe Proposal`:
-- |   - `Just p`  the proposal still has hunks; broadcast as Updated
-- |   - `Nothing` the proposal had no other hunks; broadcast as Retired
-- |
-- | The whole-proposal returned to the caller carries the *plucked*
-- | hunk gone from its hunks array — accept and reject share this
-- | path; what differs is whether the caller applies the hunk to the
-- | source (accept) or just drops it (reject).
-- |
-- | Indices are stable: accepting hunk[1] of [a, b, c] leaves
-- | [a, c] but the remaining hunks keep their original indices
-- | 0 and 2.  This is implemented by storing hunks as an Array
-- | with a sentinel for plucked entries — for v1 we just remove
-- | from the array because the frontend always works with the
-- | server's view, never holds a stale array.
takeHunk
  :: ProposalStore
  -> ProposalId
  -> Int
  -> Effect (Maybe (Tuple Hunk (Maybe Proposal)))
takeHunk (ProposalStore ref) pid idx = do
  m <- Ref.read ref
  case Map.lookup pid m of
    Nothing -> pure Nothing
    Just (Proposal p) -> case Array.index p.hunks idx of
      Nothing -> pure Nothing
      Just h ->
        let remaining = removeAt idx p.hunks
        in if Array.null remaining
             then do
               Ref.write (Map.delete pid m) ref
               pure (Just (Tuple h Nothing))
             else do
               let p' = Proposal (p { hunks = remaining })
               Ref.write (Map.insert pid p' m) ref
               pure (Just (Tuple h (Just p')))
  where
  removeAt i xs = case Array.deleteAt i xs of
    Just ys -> ys
    Nothing -> xs

foreign import _freshProposalIdRaw :: Effect String

foreign import currentTimeMs :: Effect Number
