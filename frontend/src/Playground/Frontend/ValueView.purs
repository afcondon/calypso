module Playground.Frontend.ValueView
  ( render
  ) where

import Prelude

import Data.Array (length)
import Data.Array as Array
import Data.Int (round, toNumber)
import Data.Number.Format as Number
import Data.Tuple (Tuple(..))
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Playground.Frontend.Value (PlaygroundValue(..))

-- | Recursively render a PlaygroundValue as Halogen HTML. The classes
-- | below (`pv-…`) are styled in style.css; constructors get an accent
-- | colour, separators are muted small-caps, arrays and records lay
-- | out on one line if short or break to multi-line when longer.
render :: forall w i. PlaygroundValue -> HH.HTML w i
render = case _ of
  PVNull -> hspan "pv-null" "null"
  PVBool b -> hspan "pv-bool" (if b then "true" else "false")
  PVNumber n -> hspan "pv-number" (formatNumber n)
  PVString s ->
    HH.span [ HP.class_ (HH.ClassName "pv-string") ]
      [ HH.text ("\"" <> s <> "\"") ]
  PVArray xs -> renderArray xs
  PVCtor name args -> renderCtor name args
  PVRecord fields -> renderRecord fields
  PVRaw s ->
    HH.span [ HP.class_ (HH.ClassName "pv-raw") ] [ HH.text s ]

hspan :: forall w i. String -> String -> HH.HTML w i
hspan cls txt =
  HH.span [ HP.class_ (HH.ClassName cls) ] [ HH.text txt ]

-- Ints often arrive as Number via the JSON wire. If the number has no
-- fractional part, print without the trailing ".0".
formatNumber :: Number -> String
formatNumber n =
  let asInt = round n
  in if toNumber asInt == n then show asInt else Number.toString n

renderArray :: forall w i. Array PlaygroundValue -> HH.HTML w i
renderArray xs =
  HH.span [ HP.class_ (HH.ClassName "pv-array") ]
    ( [ punct "[" ] <> interspersed <> [ punct "]" ] )
  where
  interspersed = Array.intersperse (punct ", ") (map render xs)

-- Records render in PureScript surface syntax: `{ field: value, ... }`.
-- Field names get their own class so stylesheet can pick them out from
-- string values etc.
renderRecord :: forall w i. Array (Tuple String PlaygroundValue) -> HH.HTML w i
renderRecord fields =
  HH.span [ HP.class_ (HH.ClassName "pv-record") ]
    ( [ punct "{ " ] <> interspersed <> [ punct " }" ] )
  where
  interspersed = Array.intersperse (punct ", ") (map renderField fields)
  renderField (Tuple k v) =
    HH.span [ HP.class_ (HH.ClassName "pv-field") ]
      [ HH.span [ HP.class_ (HH.ClassName "pv-field-name") ] [ HH.text k ]
      , punct ": "
      , render v
      ]

renderCtor :: forall w i. String -> Array PlaygroundValue -> HH.HTML w i
renderCtor name args =
  case length args of
    0 ->
      HH.span [ HP.class_ (HH.ClassName "pv-ctor pv-ctor-nullary") ]
        [ HH.span [ HP.class_ (HH.ClassName "pv-ctor-name") ] [ HH.text name ] ]
    _ ->
      HH.span [ HP.class_ (HH.ClassName "pv-ctor") ]
        ( [ HH.span [ HP.class_ (HH.ClassName "pv-ctor-name") ] [ HH.text name ] ]
            <> (args >>= \a -> [ punct " ", renderArg a ])
        )

-- A ctor argument that's itself a compound (array / non-nullary ctor)
-- gets parenthesised so the parse is unambiguous on sight.
renderArg :: forall w i. PlaygroundValue -> HH.HTML w i
renderArg v = case v of
  PVCtor _ args | length args > 0 ->
    HH.span [ HP.class_ (HH.ClassName "pv-parens") ]
      [ punct "(", render v, punct ")" ]
  _ -> render v

punct :: forall w i. String -> HH.HTML w i
punct s =
  HH.span [ HP.class_ (HH.ClassName "pv-punct") ] [ HH.text s ]
