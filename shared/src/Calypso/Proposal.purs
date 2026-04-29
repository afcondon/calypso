-- | Proposals — the unit of edit suggestion in Calypso's
-- | "anyone proposes, only the Pen holder accepts" collaboration
-- | model.  A proposal targets either the composition module or
-- | a specific cell, carries a content-hash (`basedOn`) of the
-- | source it was made against, and packages one or more `Hunk`s
-- | that can be accepted or rejected independently.
-- |
-- | The author is a free-form string ("claude-code:music-tidal",
-- | "andrew@laptop", etc.).  No verification at the network layer
-- | — trust comes from where the request originates.
-- |
-- | An optional `prompt` records the human-readable intent that
-- | generated the proposal ("add Autechre beats"); useful when the
-- | reviewer comes back to a queue ten minutes later.
module Calypso.Proposal
  ( ProposalId(..)
  , unProposalId
  , proposalIdCodec
  , ProposalTarget(..)
  , proposalTargetCodec
  , Hunk(..)
  , hunkCodec
  , Proposal(..)
  , proposalCodec
  , proposalsCodec
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as AJ
import Data.Codec.Argonaut (JsonCodec, JsonDecodeError(..))
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple)
import Data.Tuple.Nested ((/\))
import Foreign.Object as Object

newtype ProposalId = ProposalId String

derive newtype instance Eq ProposalId
derive newtype instance Ord ProposalId
derive newtype instance Show ProposalId

unProposalId :: ProposalId -> String
unProposalId (ProposalId s) = s

proposalIdCodec :: JsonCodec ProposalId
proposalIdCodec =
  CA.prismaticCodec "ProposalId" (Just <<< ProposalId) unProposalId CA.string

-- | Where a proposal applies.  `TgtModule` is the composition pane;
-- | `TgtCell id` is one specific cell.
data ProposalTarget
  = TgtModule
  | TgtCell String

derive instance Eq ProposalTarget

-- | Wire shape: tagged-object form, like the Broadcast / ClientMsg
-- | sums in Calypso.Pen.
proposalTargetCodec :: JsonCodec ProposalTarget
proposalTargetCodec = CA.codec' decode encode
  where
  decode json = case AJ.toObject json of
    Nothing -> Left (TypeMismatch "ProposalTarget object")
    Just o -> case Object.lookup "type" o >>= AJ.toString of
      Just "module" -> Right TgtModule
      Just "cell" -> case Object.lookup "id" o >>= AJ.toString of
        Just cid -> Right (TgtCell cid)
        Nothing -> Left (AtKey "id" MissingValue)
      Just tag -> Left (UnexpectedValue (AJ.fromString tag))
      Nothing -> Left (AtKey "type" MissingValue)
  encode = case _ of
    TgtModule -> tagged "module" []
    TgtCell cid -> tagged "cell" [ "id" /\ AJ.fromString cid ]

-- | One contiguous diff hunk.  `startLine` is 1-based and references
-- | the `basedOn` source, not the current source.  `removed` is the
-- | lines being replaced (empty for a pure insertion); `added` is
-- | the new lines (empty for a pure deletion).
newtype Hunk = Hunk
  { startLine :: Int
  , removed :: Array String
  , added :: Array String
  }

hunkCodec :: JsonCodec Hunk
hunkCodec = CA.prismaticCodec "Hunk" (Just <<< Hunk) un $
  CAR.object "Hunk"
    { startLine: CA.int
    , removed: CA.array CA.string
    , added: CA.array CA.string
    }
  where un (Hunk r) = r

newtype Proposal = Proposal
  { id :: ProposalId
  , author :: String
  , target :: ProposalTarget
  , basedOn :: String         -- SHA-1 hex of the target source at proposal time
  , hunks :: Array Hunk
  , prompt :: Maybe String    -- human-readable intent that generated the proposal
  , createdAt :: Number       -- ms since epoch
  }

proposalCodec :: JsonCodec Proposal
proposalCodec = CA.prismaticCodec "Proposal" (Just <<< Proposal) un $
  CAR.object "Proposal"
    { id: proposalIdCodec
    , author: CA.string
    , target: proposalTargetCodec
    , basedOn: CA.string
    , hunks: CA.array hunkCodec
    , prompt: nullableStringCodec
    , createdAt: CA.number
    }
  where un (Proposal r) = r

proposalsCodec :: JsonCodec (Array Proposal)
proposalsCodec = CA.array proposalCodec

-- Internal helpers (mirror the ones in Calypso.Pen).
nullableStringCodec :: JsonCodec (Maybe String)
nullableStringCodec = CA.codec' decode encode
  where
  decode json
    | AJ.isNull json = Right Nothing
    | otherwise = case AJ.toString json of
        Just s -> Right (Just s)
        Nothing -> Left (TypeMismatch "string or null")
  encode = case _ of
    Nothing -> AJ.jsonNull
    Just s -> AJ.fromString s

tagged :: String -> Array (Tuple String Json) -> Json
tagged tag fields =
  AJ.fromObject (Object.fromFoldable ([ "type" /\ AJ.fromString tag ] <> fields))
