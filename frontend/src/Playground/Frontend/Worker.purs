module Playground.Frontend.Worker
  ( Worker
  , WorkerMessage(..)
  , spawnWorker
  , postJs
  , terminate
  ) where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn1, mkEffectFn1)
import Foreign (Foreign, readString)
import Foreign.Index as Index

foreign import data Worker :: Type

-- | Messages the worker posts back to us.
data WorkerMessage
  = Emit String String     -- cellId, renderedValue
  | Done
  | WorkerError String
  | Unknown String

foreign import _spawnWorker :: EffectFn1 Foreign Unit -> Effect Worker
foreign import _postJs :: Worker -> String -> Effect Unit
foreign import _terminate :: Worker -> Effect Unit

spawnWorker :: (WorkerMessage -> Effect Unit) -> Effect Worker
spawnWorker onMessage =
  _spawnWorker (mkEffectFn1 (onMessage <<< decode))

postJs :: Worker -> String -> Effect Unit
postJs = _postJs

terminate :: Worker -> Effect Unit
terminate = _terminate

decode :: Foreign -> WorkerMessage
decode root = case readField "type" of
  Nothing -> Unknown "missing type field"
  Just tag -> case tag of
    "emit" -> case readField "id", readField "value" of
      Just id, Just value -> Emit id value
      _, _ -> Unknown "emit missing id or value"
    "done" -> Done
    "error" -> case readField "message" of
      Just msg -> WorkerError msg
      Nothing -> WorkerError "(no message)"
    other -> Unknown other
  where
  readField :: String -> Maybe String
  readField key =
    case runExcept (Index.readProp key root >>= readString) of
      Right s -> Just s
      Left _ -> Nothing
