{-# LANGUAGE ImportQualifiedPost #-}

module Prodbox.Config.ClosedDhallUnion (closedUnionDecoder, sameClosedType) where

import Data.Foldable qualified as Foldable
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Void (Void)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Map qualified as DMap

-- Exact closed structural agreement is sufficient for judgmental equality.
-- All other forms keep the existing SDK decoder. Traverse the trusted map;
-- matching never follows deeper structure than its expected closed type.
sameClosedType :: Core.Expr s Void -> Core.Expr t Void -> Bool
sameClosedType supplied expected = case (supplied, expected) of
  (Core.Bool, Core.Bool) -> True
  (Core.Natural, Core.Natural) -> True
  (Core.Integer, Core.Integer) -> True
  (Core.Double, Core.Double) -> True
  (Core.Text, Core.Text) -> True
  (Core.App Core.List a, Core.App Core.List b) -> sameClosedType a b
  (Core.App Core.Optional a, Core.App Core.Optional b) -> sameClosedType a b
  (Core.Record a, Core.Record b) -> sameFields (\x y -> sameClosedType (Core.recordFieldValue x) (Core.recordFieldValue y)) a b
  (Core.Union a, Core.Union b) -> sameFields sameOptionalType a b
  _ -> False

sameOptionalType :: Maybe (Core.Expr s Void) -> Maybe (Core.Expr t Void) -> Bool
sameOptionalType Nothing Nothing = True
sameOptionalType (Just a) (Just b) = sameClosedType a b
sameOptionalType _ _ = False

sameFields :: (a -> b -> Bool) -> DMap.Map Text a -> DMap.Map Text b -> Bool
sameFields check supplied expected =
  Map.size left == Map.size right && Map.foldlWithKey' step True right
 where
  left = DMap.toMap supplied
  right = DMap.toMap expected
  step prior key wanted = prior && maybe False (`check` wanted) (Map.lookup key left)

-- The SDK compares the unselected alternatives. Do not evaluate the selected
-- annotation: the SDK deletes it before judgmental equality.
sameClosedUnionRest
  :: Text -> DMap.Map Text (Maybe (Core.Expr s Void)) -> DMap.Map Text (Maybe (Core.Expr t Void)) -> Bool
sameClosedUnionRest selected supplied expected =
  Map.member selected right
    && Map.size left - selectedCount == Map.size right - 1
    && Map.foldlWithKey' step True right
 where
  left = DMap.toMap supplied
  right = DMap.toMap expected
  selectedCount = fromEnum (Map.member selected left)
  step prior key wanted = prior && (key == selected || maybe False (`sameOptionalType` wanted) (Map.lookup key left))

closedUnionDecoder :: [(Text, Dhall.Decoder value)] -> Dhall.Decoder value
closedUnionDecoder branches = Dhall.Decoder {Dhall.expected = Dhall.expected fallback, Dhall.extract = extract}
 where
  fallback = Dhall.union (foldMap (uncurry Dhall.constructor) branches)
  trusted = case Foldable.toList (Dhall.expected fallback) of
    [schema] -> Just schema
    _ -> Nothing
  extract expression = case trusted of
    Nothing -> Dhall.extract fallback expression
    Just schema -> case unionValue expression of
      Just (name, payload, supplied)
        | Just decoder <- lookup name branches
        , Core.Union expected <- schema
        , sameClosedUnionRest name supplied expected ->
            Dhall.extract decoder payload
      _ -> Dhall.extract fallback expression
  unionValue expression = case expression of
    Core.App (Core.Field (Core.Union types) selection) payload -> Just (Core.fieldSelectionLabel selection, payload, types)
    Core.Field (Core.Union types) selection -> Just (Core.fieldSelectionLabel selection, Core.RecordLit mempty, types)
    _ -> Nothing
