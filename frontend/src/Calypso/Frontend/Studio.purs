-- | Frontend mirror of the Studio snapshot types defined server-side
-- | in `Calypso.Server.Studio`. The frontend package depends on
-- | `calypso-shared` but not `calypso-server`, so the types are
-- | duplicated here rather than promoted into shared — the wire
-- | format is the only contract that matters across the seam.
-- |
-- | Phase 1b of the frontend reservations work (2026-05-17): the
-- | Studio pane is an Audio/MIDI-Setup analogue — a read-only view of
-- | the rig's devices, instruments, drum kits, and any duplicate-
-- | claim conflicts the reservations validator reports.
module Calypso.Frontend.Studio
  ( StudioDevice
  , StudioInstrument
  , StudioHit
  , StudioDrumKit
  , StudioOwner
  , StudioConflict
  , StudioSnapshot
  , studioSnapshotCodec
  , fetchStudioSnapshot
  ) where

import Prelude

import Affjax.ResponseFormat as RF
import Affjax.Web (defaultRequest, printError, request) as AX
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Effect.Aff (Aff)

import Calypso.Frontend.Config (backendUrl)

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

-- | GET /studio.  Left on transport failure, decode failure, or a
-- | non-2xx response; Right on a successful decoded snapshot.
fetchStudioSnapshot :: Aff (Either String StudioSnapshot)
fetchStudioSnapshot = do
  result <- AX.request $ AX.defaultRequest
    { method = Left GET
    , url = backendUrl <> "/studio"
    , responseFormat = RF.json
    }
  pure case result of
    Left err -> Left ("studio fetch: " <> AX.printError err)
    Right { body } -> case CA.decode studioSnapshotCodec body of
      Left decodeErr -> Left ("studio decode: " <> CA.printJsonDecodeError decodeErr)
      Right snap -> Right snap
