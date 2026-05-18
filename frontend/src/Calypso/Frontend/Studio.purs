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
  , StudioSourceFetch
  , StudioSourceResult
  , StudioSourceTimings
  , studioSnapshotCodec
  , fetchStudioSnapshot
  , fetchStudioSource
  , postStudioSource
  ) where

import Prelude

import Affjax.RequestBody (string) as RB
import Affjax.RequestHeader (RequestHeader) as AX
import Affjax.ResponseFormat as RF
import Affjax.StatusCode (StatusCode(..)) as AX
import Affjax.Web (defaultRequest, printError, request) as AX
import Data.Argonaut.Core as AJ
import Data.Argonaut.Core (stringify)
import Data.Codec.Argonaut (JsonCodec)
import Data.Codec.Argonaut as CA
import Data.Codec.Argonaut.Record as CAR
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Effect.Aff (Aff)
import Foreign.Object as Object

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

-- | Studio.purs source on disk — GET /studio-source.
type StudioSourceFetch =
  { ok :: Boolean
  , source :: String
  , error :: String
  }

type StudioSourceTimings =
  { write :: Int
  , purs :: Int
  , be :: Int
  , erlc :: Int
  , ws :: Int
  , total :: Int
  }

type StudioSourceResult =
  { ok :: Boolean
  , reply :: String
  , error :: String
  , pursErrorsJson :: String
  , timings :: StudioSourceTimings
  }

studioSourceFetchCodec :: JsonCodec StudioSourceFetch
studioSourceFetchCodec = CAR.object "StudioSourceFetch"
  { ok: CA.boolean
  , source: CA.string
  , error: CA.string
  }

-- | GET /studio-source.  Auth-free; returns the current Studio.purs
-- | source so the frontend pane can populate its edit buffer.
fetchStudioSource :: Aff (Either String String)
fetchStudioSource = do
  result <- AX.request $ AX.defaultRequest
    { method = Left GET
    , url = backendUrl <> "/studio-source"
    , responseFormat = RF.json
    }
  pure case result of
    Left err -> Left ("studio-source fetch: " <> AX.printError err)
    Right { body } -> case CA.decode studioSourceFetchCodec body of
      Left decodeErr ->
        Left ("studio-source decode: " <> CA.printJsonDecodeError decodeErr)
      Right r ->
        if r.ok then Right r.source else Left r.error

-- | POST /studio-source `{source}`.  Caller supplies the auth header
-- | array (pen).  Returns the timings + reply on success or an error
-- | string on failure.  Mirrors `buildSessionRequest` in Shell.purs.
postStudioSource
  :: Array AX.RequestHeader
  -> String
  -> Aff (Either String { reply :: String, totalMs :: Int })
postStudioSource authHeaders src = do
  let body = stringify
        ( AJ.fromObject (Object.singleton "source" (AJ.fromString src)) )
  result <- AX.request $ AX.defaultRequest
    { method = Left POST
    , url = backendUrl <> "/studio-source"
    , responseFormat = RF.json
    , content = Just (RB.string body)
    , headers = authHeaders
    }
  pure case result of
    Left err -> Left (AX.printError err)
    Right r
      | r.status == AX.StatusCode 200 -> decodeStudioPostBody r.body
      | r.status == AX.StatusCode 409 ->
          Left "studio-source: pen-held — take the pen first"
      | otherwise -> Left ("studio-source: HTTP " <> show r.status)

decodeStudioPostBody
  :: AJ.Json
  -> Either String { reply :: String, totalMs :: Int }
decodeStudioPostBody body = case AJ.toObject body of
  Nothing -> Left "studio-source: response not an object"
  Just o ->
    let ok = fromMaybe false (Object.lookup "ok" o >>= AJ.toBoolean)
        reply = fromMaybe "" (Object.lookup "reply" o >>= AJ.toString)
        err = fromMaybe "" (Object.lookup "error" o >>= AJ.toString)
        total = fromMaybe 0 do
          t <- Object.lookup "timings" o
          tObj <- AJ.toObject t
          n <- Object.lookup "total" tObj >>= AJ.toNumber
          Int.fromNumber n
    in if ok
       then Right { reply, totalMs: total }
       else Left (if String.null err then reply else err)
