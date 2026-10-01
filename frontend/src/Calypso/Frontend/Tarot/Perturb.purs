-- | Staff-card perturbation operators — the Botanica spread's "staff" column.
-- |
-- | The cross (significator + minors + oracle) sets the combinatoric centre via
-- | `sampleGenre genre seed`. The **staff** cards then perturb ONE axis each of
-- | that sampled `JamManifest`, post-hoc, holding the rest fixed:
-- |
-- |   * `ScaleAxis`  — swap the late-bound mode (`key.scale`); degrees re-map at
-- |     lowering, no re-sample. Cheap.
-- |   * `FeelAxis`   — set the shared groove (`tempo.swing`/`swingN`) and opt the
-- |     voices into it. Cheap.
-- |   * `MotionAxis` — append a Tidal transform to the melodic voices
-- |     (`voice.transforms`) to break repetition. Cheap.
-- |
-- | A card carries a drawn `value` (the selector into its axis pool) and a
-- | `reversed` flag (tarot-style polarity flip → the *reversed* pool).
-- |
-- | EXPERIMENTATION SURFACE: `defaultPerturbConfig` is the single place to
-- | retune ranges, choices, and reversed polarities by ear. Edit it and rebuild;
-- | the seamless re-deal means a flipped card is heard immediately in context.
-- | Bass-refresh (re-roll one voice) is the next axis — it needs a small
-- | `sampleGenre` refactor, so it's deferred. See voice-identity work too.
module Calypso.Frontend.Tarot.Perturb
  ( StaffAxis(..)
  , StaffCard
  , staffAxes
  , axisLabel
  , axisGlyph
  , AxisPool
  , PerturbConfig
  , defaultPerturbConfig
  , applyStaff
  , applyStaffPipeline
  , describeStaff
  ) where

import Prelude

import Data.Array (foldl, length, (!!))
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.JamManifest (JamManifest, Target(..), Voice)

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------

-- | The axis a staff slot controls. Slot order in the spread = `staffAxes`.
data StaffAxis = ScaleAxis | FeelAxis | MotionAxis

derive instance eqStaffAxis :: Eq StaffAxis

-- | One staff card. `axis` is fixed by its slot; `value` is the drawn selector
-- | into the axis pool (0..N, taken mod pool length); `reversed` flips polarity.
type StaffCard =
  { axis :: StaffAxis
  , value :: Int
  , reversed :: Boolean
  }

-- | The staff slots, in spread order (top → bottom of the staff column).
staffAxes :: Array StaffAxis
staffAxes = [ ScaleAxis, FeelAxis, MotionAxis ]

axisLabel :: StaffAxis -> String
axisLabel = case _ of
  ScaleAxis -> "scale"
  FeelAxis -> "feel"
  MotionAxis -> "motion"

axisGlyph :: StaffAxis -> String
axisGlyph = case _ of
  ScaleAxis -> "𝄞"
  FeelAxis -> "♺"
  MotionAxis -> "↯"

-- ---------------------------------------------------------------------------
-- Tunable config — THE EXPERIMENTATION SURFACE. Edit + rebuild to retune.
-- ---------------------------------------------------------------------------

-- | A per-axis pair of pools: the upright draw picks from `forward`, the
-- | reversed card picks from `reversed`. Keeping both as explicit data (rather
-- | than computing an inverse) means the reversed semantics are themselves a
-- | tuning knob.
type AxisPool a = { forward :: Array a, reversed :: Array a }

type PerturbConfig =
  { scale :: AxisPool String      -- engine scale-registry names (Lower.scaleIdent)
  , feelSwing :: AxisPool Number   -- swing depth 0..1
  , feelSwingN :: Int              -- swing subdivision (4 = 8ths, 8 = 16ths)
  , motion :: AxisPool String      -- Tidal transforms, applied outward as `t (body)`
  }

-- | Starting palette. Deliberately a first guess — the whole point is to flip
-- | cards, listen, and retune these arrays. Reversed pools lean toward the
-- | darker / gentler / inverse reading of each axis.
defaultPerturbConfig :: PerturbConfig
defaultPerturbConfig =
  { scale:
      -- forward: brighter / more open modes; reversed: darker / tenser
      { forward: [ "dorian", "mixolydian", "lydian", "major", "aeolian" ]
      , reversed: [ "phrygian", "locrian", "harmonic-minor", "phrygian-dominant", "aeolian" ]
      }
  , feelSwing:
      -- forward: livelier swing; reversed: straighten toward the grid
      { forward: [ 0.33, 0.5, 0.6, 0.75 ]
      , reversed: [ 0.0, 0.1, 0.15, 0.2 ]
      }
  , feelSwingN: 4
  , motion:
      -- Only combinators re-exported by the engine's Calypso.Prelude (= all of
      -- Tidal.Pattern.Core, plus `r` = fromInt). NB: `fast`/`slow` take a
      -- Rational, hence `r N`; `jux` is NOT exported (it lives in Pattern.Branched).
      { forward: [ "rev", "every 3 rev", "chunk 4 rev", "iter 4", "fast (r 2)" ]
      , reversed: [ "slow (r 2)", "every 4 rev", "iter 2", "rev" ]
      }
  }

-- ---------------------------------------------------------------------------
-- Operators — each a pure JamManifest -> JamManifest edit
-- ---------------------------------------------------------------------------

-- | Apply one staff card's perturbation to a manifest.
applyStaff :: PerturbConfig -> StaffCard -> JamManifest -> JamManifest
applyStaff cfg card m = case card.axis of
  ScaleAxis ->
    case pick card.value (poolOf card.reversed cfg.scale) of
      Just sc -> m { key = m.key { scale = sc } }
      Nothing -> m
  FeelAxis ->
    case pick card.value (poolOf card.reversed cfg.feelSwing) of
      Just sw ->
        m
          { tempo = m.tempo { swing = sw, swingN = cfg.feelSwingN }
          -- A feel card only bites if the voices opt into the shared swing.
          -- Upright (sw > 0) swings everything; a reversed/straight pick leaves
          -- each voice's genre default untouched.
          , voices = map (\v -> v { swung = sw > 0.0 || v.swung }) m.voices
          }
      Nothing -> m
  MotionAxis ->
    case pick card.value (poolOf card.reversed cfg.motion) of
      Just t -> m { voices = map (addMotion t) m.voices }
      Nothing -> m

-- | Fold a whole staff over a sampled manifest, in slot order.
applyStaffPipeline :: PerturbConfig -> Array StaffCard -> JamManifest -> JamManifest
applyStaffPipeline cfg staff m = foldl (\acc c -> applyStaff cfg c acc) m staff

-- | A human-readable summary of what a card resolves to, for the card face.
describeStaff :: PerturbConfig -> StaffCard -> String
describeStaff cfg card =
  axisLabel card.axis <> " → " <> resolved <> (if card.reversed then "  ⟲" else "")
  where
  resolved = case card.axis of
    ScaleAxis -> showStr (poolOf card.reversed cfg.scale)
    FeelAxis -> maybe "—" (\n -> "swing " <> show n) (pick card.value (poolOf card.reversed cfg.feelSwing))
    MotionAxis -> showStr (poolOf card.reversed cfg.motion)
  showStr pool = fromMaybe "—" (pick card.value pool)

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

poolOf :: forall a. Boolean -> AxisPool a -> Array a
poolOf reversed p = if reversed then p.reversed else p.forward

pick :: forall a. Int -> Array a -> Maybe a
pick v pool = pool !! (v `mod` max 1 (length pool))

-- | Motion targets melodic voices only — drums hold the grid steady while the
-- | pitched parts get the "longer, less repetitive" treatment.
addMotion :: String -> Voice -> Voice
addMotion t v = if isDrumTarget v.target then v else v { transforms = v.transforms <> [ t ] }

isDrumTarget :: Target -> Boolean
isDrumTarget = case _ of
  Dirt _ -> true
  _ -> false
