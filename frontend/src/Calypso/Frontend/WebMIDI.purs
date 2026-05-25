-- | Web MIDI access for Calypso's controller layer.
-- |
-- | Ported from `producing-with-your-feet/src/Foreign/WebMIDI.purs`.  The
-- | controller pump reads from a hardware surface (Midifighter Twister and
-- | friends) and writes the resulting named scalars to the live-control
-- | bus over the existing WS connection.  Output ports give LED feedback
-- | (ring fill, indicator hue) by sending CC frames back to the device —
-- | wired by Slab 6.5b / the bank-switch repaint pass in `Controller.purs`.
module Calypso.Frontend.WebMIDI
  ( MIDIAccess
  , MIDIInput
  , MIDIOutput
  , MidiPort
  , requestMIDIAccess
  , getInputs
  , getOutputs
  , openInput
  , openInputByName
  , openOutput
  , openOutputByName
  , onMessage
  , sendMessage
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
foreign import data MIDIOutput :: Type

-- | A descriptor for one MIDI port the browser sees.
type MidiPort = { id :: String, name :: String }

foreign import requestMIDIAccessImpl
  :: (MIDIAccess -> Effect Unit)
  -> (Error -> Effect Unit)
  -> Effect Unit

foreign import getInputsImpl :: MIDIAccess -> Effect (Array MidiPort)
foreign import getOutputsImpl :: MIDIAccess -> Effect (Array MidiPort)

foreign import openInputImpl
  :: (MIDIInput -> Maybe MIDIInput)
  -> Maybe MIDIInput
  -> MIDIAccess
  -> String
  -> Effect (Maybe MIDIInput)

foreign import openOutputImpl
  :: (MIDIOutput -> Maybe MIDIOutput)
  -> Maybe MIDIOutput
  -> MIDIAccess
  -> String
  -> Effect (Maybe MIDIOutput)

foreign import onMessageImpl
  :: MIDIInput
  -> (Array Int -> Effect Unit)
  -> Effect (Effect Unit)

foreign import sendMessageImpl
  :: MIDIOutput
  -> Array Int
  -> Effect Unit

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

-- | Enumerate all currently-visible MIDI output ports.
getOutputs :: MIDIAccess -> Effect (Array MidiPort)
getOutputs = getOutputsImpl

-- | Open an input by its WebMIDI `id`.
openInput :: MIDIAccess -> String -> Effect (Maybe MIDIInput)
openInput = openInputImpl Just Nothing

-- | Open an output by its WebMIDI `id`.
openOutput :: MIDIAccess -> String -> Effect (Maybe MIDIOutput)
openOutput = openOutputImpl Just Nothing

-- | Open the first input whose `name` matches exactly.  Convenience for
-- | the common case where the user knows the hardware by name (e.g.
-- | `"Midi Fighter Twister"`) but not its WebMIDI-assigned id.
openInputByName :: MIDIAccess -> String -> Effect (Maybe MIDIInput)
openInputByName access name = do
  ports <- getInputs access
  case Array.find (\p -> p.name == name) ports of
    Nothing -> pure Nothing
    Just p -> openInput access p.id

-- | Output-side twin of `openInputByName`.  Same hardware, same name —
-- | most MIDI devices expose both an input and an output under the
-- | identical port name.
openOutputByName :: MIDIAccess -> String -> Effect (Maybe MIDIOutput)
openOutputByName access name = do
  ports <- getOutputs access
  case Array.find (\p -> p.name == name) ports of
    Nothing -> pure Nothing
    Just p -> openOutput access p.id

-- | Register a handler for incoming MIDI messages on this input.  Returns
-- | an unsubscribe effect — call it to detach the handler.  The bytes
-- | array is the raw MIDI frame (status, data1, data2, …).
onMessage :: MIDIInput -> (Array Int -> Effect Unit) -> Effect (Effect Unit)
onMessage = onMessageImpl

-- | Send a raw MIDI frame to an output port.  The bytes are passed
-- | straight to `MIDIOutput.send` — caller is responsible for valid
-- | MIDI byte sequences (status + data).  For Twister ring-fill paint:
-- |
-- |     sendMessage twisterOut [0xB0, knobIdx, fillByte]   -- ring fill
-- |     sendMessage twisterOut [0xB1, knobIdx, hueByte]    -- indicator hue
sendMessage :: MIDIOutput -> Array Int -> Effect Unit
sendMessage = sendMessageImpl
