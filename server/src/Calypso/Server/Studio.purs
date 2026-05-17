-- | Studio — snapshot of the purerl-tidal Studio module (devices,
-- | instruments, drum kits, and any claim conflicts detected by the
-- | reservations validator).
-- |
-- | Calypso frontend consumes this to render the **Studio pane** —
-- | the Audio/MIDI Setup analogue of the composition pane.  The
-- | source of truth lives in `Studio.purs` on the purerl-tidal side;
-- | this adapter calls the `get-studio` WS verb and parses the
-- | tab-delimited multi-line reply (see `tidal_session_walker:
-- | studio_lines/0` in purerl-tidal for the wire format).
-- |
-- | Phase 1b of the frontend reservations work (2026-05-17).
module Calypso.Server.Studio
  ( StudioDevice
  , StudioInstrument
  , StudioHit
  , StudioDrumKit
  , StudioOwner
  , StudioConflict
  , StudioSnapshot
  , getStudio
  , parseStudioReply
  , studioSnapshotCodec
  , emptyStudioSnapshot
  ) where

import Prelude

import Calypso.Server.Adapter.PurerlTidalWS (sendCell)
import Data.Array as Array
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..))
import Data.String as Str
import Effect.Aff (Aff)

type StudioDevice =
  { alias :: String
  , name :: String
  , latencyMs :: Int
  }

type StudioInstrument =
  { alias :: String
  , deviceAlias :: String
  , channel :: Int
  , defNote :: Int
  , defVel :: Int
  , defDurMs :: Int
  }

type StudioHit =
  { name :: String
  , note :: Int
  , vel :: Int
  , durMs :: Int
  }

type StudioDrumKit =
  { alias :: String
  , deviceAlias :: String
  , channel :: Int
  , hits :: Array StudioHit
  }

type StudioOwner =
  { kind :: String
  , name :: String
  }

type StudioConflict =
  { deviceAlias :: String
  , channel :: Int
  , owners :: Array StudioOwner
  , message :: String
  }

type StudioSnapshot =
  { devices :: Array StudioDevice
  , instruments :: Array StudioInstrument
  , drumKits :: Array StudioDrumKit
  , conflicts :: Array StudioConflict
  }

emptyStudioSnapshot :: StudioSnapshot
emptyStudioSnapshot =
  { devices: [], instruments: [], drumKits: [], conflicts: [] }

-- | One round-trip: ship `get-studio` over the purerl-tidal WS, parse
-- | the multi-line reply.  Left on transport failure or malformed
-- | reply; Right on a successful parse (the snapshot may be empty if
-- | `walk_baseline` hasn't run yet).
getStudio :: Aff (Either String StudioSnapshot)
getStudio = do
  reply <- sendCell "get-studio"
  pure $ if reply.ok
    then Right (parseStudioReply reply.reply)
    else Left reply.reply

-- | Parse the multi-line tab-delimited reply from `get-studio` into a
-- | structured snapshot.  Lines that don't match a known shape are
-- | silently skipped; this keeps the parser forward-compatible with
-- | future record kinds (polysignals, ES-9 banks, etc.).
parseStudioReply :: String -> StudioSnapshot
parseStudioReply raw =
  let lines = Str.split (Pattern "\n") raw
      -- Drop the leading "OK: get-studio" envelope; everything below
      -- is a record line.  An "ERR ..." reply would have been caught
      -- by the .ok check upstream.
      bodyLines = Array.drop 1 lines
  in Array.foldl ingest emptyStudioSnapshot bodyLines
  where
  ingest acc line =
    case Str.split (Pattern "\t") line of
      ["device", alias, name, latStr] ->
        acc { devices = Array.snoc acc.devices
              { alias, name, latencyMs: parseIntOr 0 latStr } }
      ["instrument", alias, dev, chStr, noteStr, velStr, durStr] ->
        acc { instruments = Array.snoc acc.instruments
              { alias
              , deviceAlias: dev
              , channel: parseIntOr 0 chStr
              , defNote: parseIntOr 0 noteStr
              , defVel: parseIntOr 0 velStr
              , defDurMs: parseIntOr 0 durStr
              } }
      ["drumkit", alias, dev, chStr, hitsStr] ->
        acc { drumKits = Array.snoc acc.drumKits
              { alias
              , deviceAlias: dev
              , channel: parseIntOr 0 chStr
              , hits: parseHits hitsStr
              } }
      ["conflict", dev, chStr, ownersStr, msg] ->
        acc { conflicts = Array.snoc acc.conflicts
              { deviceAlias: dev
              , channel: parseIntOr 0 chStr
              , owners: parseOwners ownersStr
              , message: msg
              } }
      _ -> acc

  parseIntOr fallback s = fromMaybe fallback (Int.fromString s)

  parseHits "" = []
  parseHits s =
    Array.mapMaybe parseHit (Str.split (Pattern ",") s)

  parseHit hitStr =
    case Str.split (Pattern ":") hitStr of
      [name, noteStr, velStr, durStr] -> Just
        { name
        , note: parseIntOr 0 noteStr
        , vel: parseIntOr 0 velStr
        , durMs: parseIntOr 0 durStr
        }
      _ -> Nothing

  parseOwners "" = []
  parseOwners s =
    Array.mapMaybe parseOwner (Str.split (Pattern ",") s)

  parseOwner ownerStr =
    case Str.split (Pattern ":") ownerStr of
      [kind, name] -> Just { kind, name }
      _ -> Nothing

studioDeviceCodec :: JsonCodec StudioDevice
studioDeviceCodec = CAR.object "StudioDevice"
  { alias: CA.string
  , name: CA.string
  , latencyMs: CA.int
  }

studioInstrumentCodec :: JsonCodec StudioInstrument
studioInstrumentCodec = CAR.object "StudioInstrument"
  { alias: CA.string
  , deviceAlias: CA.string
  , channel: CA.int
  , defNote: CA.int
  , defVel: CA.int
  , defDurMs: CA.int
  }

studioHitCodec :: JsonCodec StudioHit
studioHitCodec = CAR.object "StudioHit"
  { name: CA.string
  , note: CA.int
  , vel: CA.int
  , durMs: CA.int
  }

studioDrumKitCodec :: JsonCodec StudioDrumKit
studioDrumKitCodec = CAR.object "StudioDrumKit"
  { alias: CA.string
  , deviceAlias: CA.string
  , channel: CA.int
  , hits: CA.array studioHitCodec
  }

studioOwnerCodec :: JsonCodec StudioOwner
studioOwnerCodec = CAR.object "StudioOwner"
  { kind: CA.string
  , name: CA.string
  }

studioConflictCodec :: JsonCodec StudioConflict
studioConflictCodec = CAR.object "StudioConflict"
  { deviceAlias: CA.string
  , channel: CA.int
  , owners: CA.array studioOwnerCodec
  , message: CA.string
  }

studioSnapshotCodec :: JsonCodec StudioSnapshot
studioSnapshotCodec = CAR.object "StudioSnapshot"
  { devices: CA.array studioDeviceCodec
  , instruments: CA.array studioInstrumentCodec
  , drumKits: CA.array studioDrumKitCodec
  , conflicts: CA.array studioConflictCodec
  }
