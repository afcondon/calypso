-- | Web MIDI input access for Calypso's controller layer.
-- |
-- | Ported from `producing-with-your-feet/src/Foreign/WebMIDI.purs`, trimmed
-- | to inputs only — the controller pump reads from a hardware surface
-- | (Midifighter Twister and friends) and writes the resulting named
-- | scalars to the live-control bus over the existing WS connection.
-- | LED feedback (output side) is deferred to a follow-up.
module Calypso.Frontend.WebMIDI
  ( MIDIAccess
  , MIDIInput
  , MidiPort
  , requestMIDIAccess
  , getInputs
  , openInput
  , openInputByName
  , onMessage
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Exception (Error)

foreign import data MIDIAccess :: Type
foreign import data MIDIInput :: Type

-- | A descriptor for one MIDI port the browser sees.
type MidiPort = { id :: String, name :: String }

foreign import requestMIDIAccessImpl
  :: (MIDIAccess -> Effect Unit)
  -> (Error -> Effect Unit)
  -> Effect Unit

foreign import getInputsImpl :: MIDIAccess -> Effect (Array MidiPort)

foreign import openInputImpl
  :: (MIDIInput -> Maybe MIDIInput)
  -> Maybe MIDIInput
  -> MIDIAccess
  -> String
  -> Effect (Maybe MIDIInput)

foreign import onMessageImpl
  :: MIDIInput
  -> (Array Int -> Effect Unit)
  -> Effect (Effect Unit)

-- | Request browser-level MIDI access.  Resolves to a `MIDIAccess` handle
-- | when the user has granted permission; rejects on denial or on
-- | browsers without WebMIDI support.
requestMIDIAccess :: Aff MIDIAccess
requestMIDIAccess = makeAff \cb -> do
  requestMIDIAccessImpl
    (\access -> cb (Right access))
    (\err -> cb (Left err))
  pure nonCanceler

-- | Enumerate all currently-visible MIDI input ports.
getInputs :: MIDIAccess -> Effect (Array MidiPort)
getInputs = getInputsImpl

-- | Open an input by its WebMIDI `id`.
openInput :: MIDIAccess -> String -> Effect (Maybe MIDIInput)
openInput = openInputImpl Just Nothing

-- | Open the first input whose `name` matches exactly.  Convenience for
-- | the common case where the user knows the hardware by name (e.g.
-- | `"Midi Fighter Twister"`) but not its WebMIDI-assigned id.
openInputByName :: MIDIAccess -> String -> Effect (Maybe MIDIInput)
openInputByName access name = do
  ports <- getInputs access
  case Array.find (\p -> p.name == name) ports of
    Nothing -> pure Nothing
    Just p -> openInput access p.id

-- | Register a handler for incoming MIDI messages on this input.  Returns
-- | an unsubscribe effect — call it to detach the handler.  The bytes
-- | array is the raw MIDI frame (status, data1, data2, …).
onMessage :: MIDIInput -> (Array Int -> Effect Unit) -> Effect (Effect Unit)
onMessage = onMessageImpl
