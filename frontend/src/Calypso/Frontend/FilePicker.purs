-- | Browser file picker for loading a calypso-session.json from
-- | disk into the running app. Pairs with the toolbar's "Load…"
-- | button.
module Calypso.Frontend.FilePicker
  ( pickJsonFile
  ) where

import Prelude

import Data.Either (Either(..))
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Uncurried (EffectFn2, EffectFn1, mkEffectFn1, runEffectFn2)

-- | Effectful FFI primitive. Calls onSuccess(text) once on a
-- | successful read, or onError(message) on cancel / read failure.
-- | Exactly one of the two callbacks fires.
foreign import pickJsonFileImpl
  :: EffectFn2 (EffectFn1 String Unit) (EffectFn1 String Unit) Unit

-- | Open a browser file picker for a JSON file. The Aff resolves
-- | with the file's text on success, or `Left <message>` if the user
-- | cancels or the read fails. Never rejects — errors flow through
-- | the Either, matching how callers already handle transport errors.
pickJsonFile :: Aff (Either String String)
pickJsonFile = makeAff \resolve -> do
  runEffectFn2 pickJsonFileImpl
    (mkEffectFn1 \text -> resolve (Right (Right text)))
    (mkEffectFn1 \err -> resolve (Right (Left err)))
  pure nonCanceler
