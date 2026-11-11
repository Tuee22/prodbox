{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- Validate the producer's closed data shape before allocating a general Dhall
-- expression. Recursion follows the trusted schema, not untrusted expression
-- nesting. Canonical re-encoding and semantic validation remain independent.
module Prodbox.Config.CanonicalDhallValueShape
  ( CanonicalDhallValueShape
  , CanonicalDhallValueShapeError (..)
  , CanonicalDhallValueUsage
  , CanonicalDhallValueBound
  , boundCanonicalDhallValueShape
  , canonicalDhallBoundValueVisits
  , canonicalDhallBoundTypeVisits
  , canonicalDhallBoundListElements
  , canonicalDhallBoundRecordFields
  , canonicalDhallBoundUnionAlternatives
  , canonicalDhallBoundTextTokens
  , canonicalDhallBoundIntegerTokens
  , CanonicalDhallValueRequirement (..)
  , requireCanonicalDhallValue
  , canonicalDhallInputBytes
  , canonicalDhallValueVisits
  , canonicalDhallBooleanValues
  , canonicalDhallListValues
  , canonicalDhallOptionalValues
  , canonicalDhallRecordValues
  , canonicalDhallAwsProfileValues
  , canonicalDhallUnionValues
  , canonicalDhallSelectedUnionEntries
  , canonicalDhallSelectedUnionHeightSum
  , canonicalDhallTextValues
  , canonicalDhallTypeVisits
  , canonicalDhallTypeRecordFields
  , canonicalDhallTypeUnionAlternatives
  , canonicalDhallTypeTextTokens
  , canonicalDhallTypeTextTokenBytes
  , canonicalDhallListElements
  , canonicalDhallRecordFields
  , canonicalDhallUnionAlternatives
  , canonicalDhallMapEntryHeightSum
  , canonicalDhallCheckedContainers
  , canonicalDhallTextTokens
  , canonicalDhallIntegerTokens
  , canonicalDhallTextTokenBytes
  , canonicalDhallIntegerTokenBytes
  , canonicalDhallMaximumCheckDepth
  , canonicalDhallUsageNormalFormBytes
  , StaticShapeTemplate
  , staticShapeTemplateDataBytes
  , materializeStaticShapeTemplate
  , StaticShapeTemplateError (..)
  , StaticShapeTransform (..)
  , StaticShapeDefinition
  , staticShapeDefinitionShape
  , prepareStaticShapeDefinition
  , liftStaticShapeDefinition
  , materializeStaticShapeTemplateWithin
  , compileCanonicalDhallValueShape
  , compileClosedDhallValueShape
  , canonicalDhallValueShapeDataBytes
  , canonicalDhallValueShapeCompilationDataBytes
  , markCanonicalDhallPathText
  , markCanonicalDhallAwsProfile
  , canonicalDhallPathComponentCharacters
  , canonicalDhallPathTextCharacters
  , canonicalDhallPathTextValues
  , checkCanonicalDhallValueShape
  , measureCanonicalDhallValueShape
  ) where

import Prodbox.Capacity.BoxedNormalForm

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Read qualified as Cbor
import Control.Monad (replicateM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans.State.Strict (StateT, modify', runStateT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Internal qualified as MapInternal
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap
import Language.Haskell.TH.Syntax (Code, Lift (liftTyped), Quote)
import Numeric.Natural (Natural)

data CanonicalDhallValueShape
  = BooleanValue
  | NaturalValue
  | ExactNaturalValue !Natural
  | IntegerValue
  | DoubleValue
  | TextValue
  | ExactTextValue !Text
  | PathTextValue
  | ListValue !CanonicalDhallValueShape
  | CountedListValue !Natural !CanonicalDhallValueShape
  | OptionalValue !CanonicalDhallValueShape
  | PresentOptionalValue !CanonicalDhallValueShape
  | RecordValue !(Map Text CanonicalDhallValueShape)
  | AwsProfileRecordValue !(Map Text CanonicalDhallValueShape)
  | UnionValue !(Map Text (Maybe CanonicalDhallValueShape))
  deriving (Eq)

data CanonicalDhallValueShapeError
  = CanonicalDhallValueSchemaUnsupported
  | CanonicalDhallValueShapeMismatch
  | CanonicalDhallValueEncodingInvalid
  | CanonicalDhallValueRequirementMismatch
  deriving (Eq, Show)

compileCanonicalDhallValueShape
  :: Core.Expr source Void -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
compileCanonicalDhallValueShape = compileClosedDhallValueShape . Core.normalize

-- The pinned typed producers used by the controller declare only primitive,
-- record, list, optional and union types. This structural entrypoint does not
-- evaluate general type expressions; the normalizing entrypoint keeps that
-- broader contract for other callers.
compileClosedDhallValueShape
  :: Core.Expr source Void -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
compileClosedDhallValueShape = compile
 where
  compile expression = case expression of
    Core.Bool -> Right BooleanValue
    Core.Natural -> Right NaturalValue
    Core.Integer -> Right IntegerValue
    Core.Double -> Right DoubleValue
    Core.Text -> Right TextValue
    Core.App Core.List element -> do
      child <- compile element
      pure $! ListValue child
    Core.App Core.Optional element -> do
      child <- compile element
      pure $! OptionalValue child
    Core.Record fields -> do
      compiled <- Map.traverseWithKey (const (compile . Core.recordFieldValue)) (DhallMap.toMap fields)
      pure $! RecordValue compiled
    Core.Union fields -> do
      compiled <- Map.traverseWithKey (const compileAlternative) (DhallMap.toMap fields)
      pure $! UnionValue compiled
    _ -> Left CanonicalDhallValueSchemaUnsupported
  compileAlternative alternative = case alternative of
    Nothing -> Right Nothing
    Just expression -> do
      !child <- compile expression
      pure (Just child)

-- Mark one trusted record coordinate without changing its accepted grammar.
-- The resulting usage retains only a component length, never the path value.
markCanonicalDhallPathText
  :: [Text] -> CanonicalDhallValueShape -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
markCanonicalDhallPathText path shape = case (path, shape) of
  ([], TextValue) -> Right PathTextValue
  (name : rest, RecordValue fields) -> do
    nested <- maybe (Left CanonicalDhallValueSchemaUnsupported) Right (Map.lookup name fields)
    marked <- markCanonicalDhallPathText rest nested
    pure (RecordValue (Map.insert name marked fields))
  _ -> Left CanonicalDhallValueSchemaUnsupported

-- A trusted caller marks its actual narrowing record. Optional absence and
-- type-only declarations do not execute that narrowing; count only values.
-- The marker changes no accepted grammar and grants no admission witness.
markCanonicalDhallAwsProfile
  :: [Text] -> CanonicalDhallValueShape -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
markCanonicalDhallAwsProfile path shape = case (path, shape) of
  ([], RecordValue fields) -> Right (AwsProfileRecordValue fields)
  ([], AwsProfileRecordValue _) -> Right shape
  (_, OptionalValue child) -> OptionalValue <$> markCanonicalDhallAwsProfile path child
  (name : rest, RecordValue fields) -> do
    child <- maybe (Left CanonicalDhallValueSchemaUnsupported) Right (Map.lookup name fields)
    marked <- markCanonicalDhallAwsProfile rest child
    pure (RecordValue (Map.insert name marked fields))
  _ -> Left CanonicalDhallValueSchemaUnsupported

-- These are authored semantic requirements on an already closed record shape.
-- They supply no new canonicality, decoded-state budget or admission witness.
-- A caller must establish that its ordinary typed validator already requires
-- the same values; the general shape compiler has no such restrictions.
data CanonicalDhallValueRequirement
  = RequireText !Text
  | RequirePresentNatural !Natural
  | RequireListElements !Natural
  deriving (Eq, Show)

requireCanonicalDhallValue
  :: [Text]
  -> CanonicalDhallValueRequirement
  -> CanonicalDhallValueShape
  -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
requireCanonicalDhallValue path requirement shape = case (path, shape) of
  ([], TextValue) -> case requirement of
    RequireText value -> Right (ExactTextValue value)
    _ -> unsupported
  ([], OptionalValue NaturalValue) -> case requirement of
    RequirePresentNatural value -> Right (PresentOptionalValue (ExactNaturalValue value))
    _ -> unsupported
  ([], ListValue element) -> case requirement of
    RequireListElements count -> Right (CountedListValue count element)
    _ -> unsupported
  (name : rest, RecordValue fields) -> do
    nested <- maybe unsupported Right (Map.lookup name fields)
    required <- requireCanonicalDhallValue rest requirement nested
    pure (RecordValue (Map.insert name required fields))
  _ -> unsupported
 where
  unsupported = Left CanonicalDhallValueSchemaUnsupported

-- Maxima over all values admitted by this trusted shape. These count only
-- decoded normal-form structure; token payload storage needs its own encoded
-- byte ceiling. The result contains no shape, value or observation receipt.
data CanonicalDhallValueBound = Bound !Natural !Natural !Natural !Natural !Natural !Natural !Natural
  deriving (Eq, Show)

canonicalDhallBoundValueVisits
  , canonicalDhallBoundTypeVisits
  , canonicalDhallBoundListElements
  , canonicalDhallBoundRecordFields
  , canonicalDhallBoundUnionAlternatives
  , canonicalDhallBoundTextTokens
  , canonicalDhallBoundIntegerTokens
    :: CanonicalDhallValueBound -> Natural
canonicalDhallBoundValueVisits (Bound value _ _ _ _ _ _) = value
canonicalDhallBoundTypeVisits (Bound _ value _ _ _ _ _) = value
canonicalDhallBoundListElements (Bound _ _ value _ _ _ _) = value
canonicalDhallBoundRecordFields (Bound _ _ _ value _ _ _) = value
canonicalDhallBoundUnionAlternatives (Bound _ _ _ _ value _ _) = value
canonicalDhallBoundTextTokens (Bound _ _ _ _ _ value _) = value
canonicalDhallBoundIntegerTokens (Bound _ _ _ _ _ _ value) = value

-- An unconstrained value list, including one under an optional/union, has no
-- static element bound. Counted empty lists carry only the element's finite
-- type, so even an unbounded element value shape is safe in that special case.
-- Optional/union alternatives join componentwise; impossible combinations may
-- overcount but never discount one branch. No Int-sized arithmetic is used.
boundCanonicalDhallValueShape :: CanonicalDhallValueShape -> Maybe CanonicalDhallValueBound
boundCanonicalDhallValueShape shape = addBound valueVisit <$> children
 where
  children = case shape of
    BooleanValue -> pure emptyBound
    NaturalValue -> pure integerToken
    ExactNaturalValue _ -> pure integerToken
    IntegerValue -> pure integerToken
    DoubleValue -> pure emptyBound
    TextValue -> pure textToken
    ExactTextValue _ -> pure textToken
    PathTextValue -> pure textToken
    ListValue _ -> Nothing
    CountedListValue count element
      | count == 0 -> pure (boundType element)
      | otherwise -> do
          child <- boundCanonicalDhallValueShape element
          pure (addBound (Bound 0 0 count 0 0 0 0) (scaleBound count child))
    OptionalValue element -> do
      child <- boundCanonicalDhallValueShape element
      pure (joinBound child (addBound textToken (boundType element)))
    PresentOptionalValue element -> boundCanonicalDhallValueShape element
    RecordValue fields -> do
      childrenBound <- traverse boundCanonicalDhallValueShape fields
      let count = fromIntegral (Map.size fields)
      pure (addBound (Bound 0 0 0 count 0 count 0) (sumBounds childrenBound))
    AwsProfileRecordValue fields -> do
      childrenBound <- traverse boundCanonicalDhallValueShape fields
      let count = fromIntegral (Map.size fields)
      pure (addBound (Bound 0 0 0 count 0 count 0) (sumBounds childrenBound))
    UnionValue alternatives -> do
      payloads <- traverse (traverse boundCanonicalDhallValueShape) alternatives
      let payload = foldr joinBound emptyBound [value | Just value <- Map.elems payloads]
      pure (sumBounds [boundType shape, textToken, payload])

-- Types have finite structure even when their values contain arbitrary lists.
-- Keep the token/field accounting identical to checkType below.
boundType :: CanonicalDhallValueShape -> CanonicalDhallValueBound
boundType shape = addBound typeVisit $ case shape of
  BooleanValue -> textToken
  NaturalValue -> textToken
  ExactNaturalValue _ -> textToken
  IntegerValue -> textToken
  DoubleValue -> textToken
  TextValue -> textToken
  ExactTextValue _ -> textToken
  PathTextValue -> textToken
  ListValue element -> addBound textToken (boundType element)
  CountedListValue _ element -> addBound textToken (boundType element)
  OptionalValue element -> addBound textToken (boundType element)
  PresentOptionalValue element -> addBound textToken (boundType element)
  RecordValue fields ->
    let count = fromIntegral (Map.size fields)
     in addBound (Bound 0 0 0 count 0 count 0) (sumBounds (fmap boundType fields))
  AwsProfileRecordValue fields ->
    let count = fromIntegral (Map.size fields)
     in addBound (Bound 0 0 0 count 0 count 0) (sumBounds (fmap boundType fields))
  UnionValue alternatives ->
    let count = fromIntegral (Map.size alternatives)
     in addBound
          (Bound 0 0 0 0 count count 0)
          (sumBounds [boundType value | Just value <- Map.elems alternatives])

emptyBound, valueVisit, typeVisit, textToken, integerToken :: CanonicalDhallValueBound
emptyBound = Bound 0 0 0 0 0 0 0
valueVisit = Bound 1 0 0 0 0 0 0
typeVisit = Bound 0 1 0 0 0 0 0
textToken = Bound 0 0 0 0 0 1 0
integerToken = Bound 0 0 0 0 0 0 1

addBound
  , joinBound
    :: CanonicalDhallValueBound -> CanonicalDhallValueBound -> CanonicalDhallValueBound
addBound (Bound a b c d e f g) (Bound h i j k l m n) = Bound (a + h) (b + i) (c + j) (d + k) (e + l) (f + m) (g + n)
joinBound (Bound a b c d e f g) (Bound h i j k l m n) = Bound (max a h) (max b i) (max c j) (max d k) (max e l) (max f m) (max g n)

scaleBound :: Natural -> CanonicalDhallValueBound -> CanonicalDhallValueBound
scaleBound count (Bound a b c d e f g) = Bound (count * a) (count * b) (count * c) (count * d) (count * e) (count * f) (count * g)

sumBounds :: (Foldable container) => container CanonicalDhallValueBound -> CanonicalDhallValueBound
sumBounds = foldr addBound emptyBound

-- Counts describe the checked encoded structure, not a heap-size proof or an
-- admission capability. Token spans include CBOR headers. No input values,
-- field names or arbitrary expression tree are retained in this result.
data CanonicalDhallValueUsage = Usage
  { storedInputBytes :: !Natural
  , storedValueVisits :: !Natural
  , storedTypeVisits :: !Natural
  , storedListElements :: !Natural
  , storedRecordFields :: !Natural
  , storedUnionAlternatives :: !Natural
  , storedCheckedContainers :: !Natural
  , storedTextTokenBytes :: !Natural
  , storedIntegerTokenBytes :: !Natural
  , storedMaximumCheckDepth :: !Natural
  , storedTextTokens :: !Natural
  , storedIntegerTokens :: !Natural
  , storedPathComponentCharacters :: !Natural
  , storedPathTextCharacters :: !Natural
  , storedPathTextValues :: !Natural
  , storedBooleanValues :: !Natural
  , storedListValues :: !Natural
  , storedOptionalValues :: !Natural
  , storedRecordValues :: !Natural
  , storedUnionValues :: !Natural
  , storedTextValues :: !Natural
  , storedMapEntryHeightSum :: !Natural
  , storedAwsProfileValues :: !Natural
  , storedTypeRecordFields :: !Natural
  , storedTypeUnionAlternatives :: !Natural
  , storedTypeTextTokens :: !Natural
  , storedTypeTextTokenBytes :: !Natural
  , storedSelectedUnionEntries :: !Natural
  , storedSelectedUnionHeightSum :: !Natural
  }
  deriving (Eq, Show)

canonicalDhallInputBytes :: CanonicalDhallValueUsage -> Natural
canonicalDhallInputBytes = storedInputBytes

canonicalDhallValueVisits :: CanonicalDhallValueUsage -> Natural
canonicalDhallValueVisits = storedValueVisits

canonicalDhallBooleanValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallBooleanValues = storedBooleanValues

canonicalDhallListValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallListValues = storedListValues

canonicalDhallOptionalValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallOptionalValues = storedOptionalValues

canonicalDhallRecordValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallRecordValues = storedRecordValues

canonicalDhallAwsProfileValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallAwsProfileValues = storedAwsProfileValues

canonicalDhallUnionValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallUnionValues = storedUnionValues

-- Each selected value union deletes its constructor from both the supplied
-- and expected maps. Type-only unions do not execute these deletions.
canonicalDhallSelectedUnionEntries
  , canonicalDhallSelectedUnionHeightSum
    :: CanonicalDhallValueUsage -> Natural
canonicalDhallSelectedUnionEntries = storedSelectedUnionEntries
canonicalDhallSelectedUnionHeightSum = storedSelectedUnionHeightSum

canonicalDhallTextValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallTextValues = storedTextValues

canonicalDhallTypeVisits :: CanonicalDhallValueUsage -> Natural
canonicalDhallTypeVisits = storedTypeVisits

canonicalDhallTypeRecordFields
  , canonicalDhallTypeUnionAlternatives
  , canonicalDhallTypeTextTokens
  , canonicalDhallTypeTextTokenBytes
    :: CanonicalDhallValueUsage -> Natural
canonicalDhallTypeRecordFields = storedTypeRecordFields
canonicalDhallTypeUnionAlternatives = storedTypeUnionAlternatives
canonicalDhallTypeTextTokens = storedTypeTextTokens
canonicalDhallTypeTextTokenBytes = storedTypeTextTokenBytes

canonicalDhallListElements :: CanonicalDhallValueUsage -> Natural
canonicalDhallListElements = storedListElements

canonicalDhallRecordFields :: CanonicalDhallValueUsage -> Natural
canonicalDhallRecordFields = storedRecordFields

canonicalDhallUnionAlternatives :: CanonicalDhallValueUsage -> Natural
canonicalDhallUnionAlternatives = storedUnionAlternatives

-- Sum n*h(n) for each checked record/union map. For the reviewed delta=3
-- invariant, h(n)=n for n<=2 and h(n)=1+h(floor(3*(n-1)/4)) otherwise.
-- This count retains no key/value and grants no memory/admission certificate.
canonicalDhallMapEntryHeightSum :: CanonicalDhallValueUsage -> Natural
canonicalDhallMapEntryHeightSum = storedMapEntryHeightSum

canonicalDhallCheckedContainers :: CanonicalDhallValueUsage -> Natural
canonicalDhallCheckedContainers = storedCheckedContainers

canonicalDhallTextTokens :: CanonicalDhallValueUsage -> Natural
canonicalDhallTextTokens = storedTextTokens

canonicalDhallIntegerTokens :: CanonicalDhallValueUsage -> Natural
canonicalDhallIntegerTokens = storedIntegerTokens

canonicalDhallTextTokenBytes :: CanonicalDhallValueUsage -> Natural
canonicalDhallTextTokenBytes = storedTextTokenBytes

canonicalDhallIntegerTokenBytes :: CanonicalDhallValueUsage -> Natural
canonicalDhallIntegerTokenBytes = storedIntegerTokenBytes

canonicalDhallMaximumCheckDepth :: CanonicalDhallValueUsage -> Natural
canonicalDhallMaximumCheckDepth = storedMaximumCheckDepth

canonicalDhallPathComponentCharacters :: CanonicalDhallValueUsage -> Natural
canonicalDhallPathComponentCharacters = storedPathComponentCharacters

-- Separate conversion demand: all characters, including separators and dot
-- components, can enter a raw FilePath String before path normalization.
-- Count marked values without retaining their text or changing their grammar.
canonicalDhallPathTextCharacters :: CanonicalDhallValueUsage -> Natural
canonicalDhallPathTextCharacters = storedPathTextCharacters

canonicalDhallPathTextValues :: CanonicalDhallValueUsage -> Natural
canonicalDhallPathTextValues = storedPathTextValues

type Check state =
  ExceptT CanonicalDhallValueShapeError (StateT CanonicalDhallValueUsage (Cbor.Decoder state))

checkCanonicalDhallValueShape
  :: CanonicalDhallValueShape -> ByteString -> Either CanonicalDhallValueShapeError ()
checkCanonicalDhallValueShape shape bytes = void (measureCanonicalDhallValueShape shape bytes)

measureCanonicalDhallValueShape
  :: CanonicalDhallValueShape
  -> ByteString
  -> Either CanonicalDhallValueShapeError CanonicalDhallValueUsage
measureCanonicalDhallValueShape shape bytes = do
  (remaining, (result, usage)) <-
    first (const CanonicalDhallValueEncodingInvalid) $
      Cbor.deserialiseFromBytes
        ( runStateT
            (runExceptT (checkValue 1 shape))
            (Usage (fromIntegral (Bytes.length bytes)) 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
        )
        (Lazy.fromStrict bytes)
  result
  unless (Lazy.null remaining) (Left CanonicalDhallValueEncodingInvalid)
  pure usage

-- Raw-data constructor categories count only values. Type declarations under
-- None/empty lists/unions do not become returned Haskell values.
countDecodedValue
  :: CanonicalDhallValueShape -> CanonicalDhallValueUsage -> CanonicalDhallValueUsage
countDecodedValue shape usage = case shape of
  BooleanValue -> usage {storedBooleanValues = storedBooleanValues usage + 1}
  NaturalValue -> usage
  ExactNaturalValue _ -> usage
  IntegerValue -> usage
  DoubleValue -> usage
  TextValue -> textValue
  ExactTextValue _ -> textValue
  PathTextValue -> textValue
  ListValue _ -> listValue
  CountedListValue _ _ -> listValue
  OptionalValue _ -> optionalValue
  PresentOptionalValue _ -> optionalValue
  RecordValue _ -> usage {storedRecordValues = storedRecordValues usage + 1}
  AwsProfileRecordValue _ ->
    usage
      { storedRecordValues = storedRecordValues usage + 1
      , storedAwsProfileValues = storedAwsProfileValues usage + 1
      }
  UnionValue alternatives ->
    let entries = fromIntegral (Map.size alternatives)
     in usage
          { storedUnionValues = storedUnionValues usage + 1
          , storedSelectedUnionEntries = storedSelectedUnionEntries usage + entries
          , storedSelectedUnionHeightSum = storedSelectedUnionHeightSum usage + mapHeightBound entries
          }
 where
  textValue = usage {storedTextValues = storedTextValues usage + 1}
  listValue = usage {storedListValues = storedListValues usage + 1}
  optionalValue = usage {storedOptionalValues = storedOptionalValues usage + 1}

checkValue :: Natural -> CanonicalDhallValueShape -> Check state ()
checkValue depth shape = do
  change (countDecodedValue shape)
  change
    ( \usage ->
        usage
          { storedValueVisits = storedValueVisits usage + 1
          , storedMaximumCheckDepth = max depth (storedMaximumCheckDepth usage)
          }
    )
  case shape of
    BooleanValue -> void (decode Cbor.decodeBool)
    NaturalValue -> tagged 2 15 >> integer >>= require . (>= 0)
    ExactNaturalValue expected -> do
      tagged 2 15
      actual <- integer
      require (actual >= 0)
      requireValue (actual == toInteger expected)
    IntegerValue -> tagged 2 16 >> void integer
    DoubleValue -> void (decode Cbor.decodeDouble)
    TextValue -> tagged 2 18 >> void text
    ExactTextValue expected -> tagged 2 18 >> text >>= requireValue . (== expected)
    PathTextValue -> do
      tagged 2 18
      value <- text
      let characters = longestOrdinaryPathComponent value
      change
        ( \usage ->
            usage
              { storedPathComponentCharacters = max characters (storedPathComponentCharacters usage)
              , storedPathTextCharacters = storedPathTextCharacters usage + fromIntegral (Text.length value)
              , storedPathTextValues = storedPathTextValues usage + 1
              }
        )
    ListValue element -> checkListValue depth Nothing element
    CountedListValue count element -> checkListValue depth (Just count) element
    OptionalValue element -> checkOptionalValue depth False element
    PresentOptionalValue element -> checkOptionalValue depth True element
    RecordValue fields -> tagged 2 8 >> checkFields ValueFieldScope RecordFields (checkValue (depth + 1)) fields
    AwsProfileRecordValue fields -> tagged 2 8 >> checkFields ValueFieldScope RecordFields (checkValue (depth + 1)) fields
    UnionValue alternatives -> do
      count <- container Cbor.decodeListLen
      label <- decode Cbor.decodeWord
      require (count == 3)
      case label of
        9 -> do
          checkType (depth + 1) shape
          name <- text
          case Map.lookup name alternatives of
            Just Nothing -> pure ()
            _ -> throwE CanonicalDhallValueShapeMismatch
        0 -> do
          tagged 3 9
          checkType (depth + 1) shape
          name <- text
          case Map.lookup name alternatives of
            Just (Just payload) -> checkValue (depth + 1) payload
            _ -> throwE CanonicalDhallValueShapeMismatch
        _ -> throwE CanonicalDhallValueShapeMismatch

checkListValue :: Natural -> Maybe Natural -> CanonicalDhallValueShape -> Check state ()
checkListValue depth expected element = do
  count <- container Cbor.decodeListLen
  label <- decode Cbor.decodeWord
  require (label == 4 && count >= 2)
  case expected of
    Nothing -> pure ()
    Just wanted -> requireValue (fromIntegral (count - 2) == wanted)
  if count == 2
    then checkType (depth + 1) element
    else do
      decode Cbor.decodeNull
      change (\usage -> usage {storedListElements = storedListElements usage + fromIntegral (count - 2)})
      replicateM_ (count - 2) (checkValue (depth + 1) element)

checkOptionalValue :: Natural -> Bool -> CanonicalDhallValueShape -> Check state ()
checkOptionalValue depth present element = do
  count <- container Cbor.decodeListLen
  label <- decode Cbor.decodeWord
  require (count == 3)
  case label of
    5 -> decode Cbor.decodeNull >> checkValue (depth + 1) element
    0 -> requireValue (not present) >> literal "None" >> checkType (depth + 1) element
    _ -> throwE CanonicalDhallValueShapeMismatch

-- Empty lists, None and union selectors carry their exact closed type. The
-- checker never delegates an untrusted type expression to the general parser.
checkType :: Natural -> CanonicalDhallValueShape -> Check state ()
checkType depth shape = do
  change
    ( \usage ->
        usage
          { storedTypeVisits = storedTypeVisits usage + 1
          , storedMaximumCheckDepth = max depth (storedMaximumCheckDepth usage)
          }
    )
  case shape of
    BooleanValue -> typeLiteral "Bool"
    NaturalValue -> typeLiteral "Natural"
    ExactNaturalValue _ -> typeLiteral "Natural"
    IntegerValue -> typeLiteral "Integer"
    DoubleValue -> typeLiteral "Double"
    TextValue -> typeLiteral "Text"
    ExactTextValue _ -> typeLiteral "Text"
    PathTextValue -> typeLiteral "Text"
    ListValue element -> tagged 3 0 >> typeLiteral "List" >> checkType (depth + 1) element
    CountedListValue _ element -> tagged 3 0 >> typeLiteral "List" >> checkType (depth + 1) element
    OptionalValue element -> tagged 3 0 >> typeLiteral "Optional" >> checkType (depth + 1) element
    PresentOptionalValue element -> tagged 3 0 >> typeLiteral "Optional" >> checkType (depth + 1) element
    RecordValue fields -> tagged 2 7 >> checkFields TypeFieldScope RecordFields (checkType (depth + 1)) fields
    AwsProfileRecordValue fields -> tagged 2 7 >> checkFields TypeFieldScope RecordFields (checkType (depth + 1)) fields
    UnionValue alternatives -> tagged 2 11 >> checkFields TypeFieldScope UnionAlternatives checkAlternative alternatives
 where
  checkAlternative Nothing = decode Cbor.decodeNull
  checkAlternative (Just payload) = checkType (depth + 1) payload

data FieldKind = RecordFields | UnionAlternatives

data FieldScope = ValueFieldScope | TypeFieldScope

-- Field count, membership and uniqueness are bounded by the trusted schema.
-- Field ordering is left to the existing canonical-value equality check.
checkFields
  :: FieldScope -> FieldKind -> (value -> Check state ()) -> Map Text value -> Check state ()
checkFields scope kind check fields = do
  count <- container Cbor.decodeMapLen
  require (count == Map.size fields)
  change (countFields scope kind count)
  loop count Set.empty
 where
  loop 0 _ = pure ()
  loop count seen = do
    name <- textIn scope
    require (Set.notMember name seen)
    case Map.lookup name fields of
      Nothing -> throwE CanonicalDhallValueShapeMismatch
      Just value -> check value >> loop (count - 1) (Set.insert name seen)

tagged :: Int -> Word -> Check state ()
tagged count label = do
  actualCount <- container Cbor.decodeListLen
  require (actualCount == count)
  actualLabel <- decode Cbor.decodeWord
  require (actualLabel == label)

countFields
  :: FieldScope -> FieldKind -> Int -> CanonicalDhallValueUsage -> CanonicalDhallValueUsage
countFields scope kind count usage = case scope of
  ValueFieldScope -> global
  TypeFieldScope -> case kind of
    RecordFields -> global {storedTypeRecordFields = storedTypeRecordFields usage + entries}
    UnionAlternatives -> global {storedTypeUnionAlternatives = storedTypeUnionAlternatives usage + entries}
 where
  entries = fromIntegral count
  global = case kind of
    RecordFields -> counted {storedRecordFields = storedRecordFields usage + entries}
    UnionAlternatives -> counted {storedUnionAlternatives = storedUnionAlternatives usage + entries}
  counted =
    usage {storedMapEntryHeightSum = storedMapEntryHeightSum usage + entries * mapHeightBound entries}

mapHeightBound :: Natural -> Natural
mapHeightBound = go 0
 where
  go !width !remaining
    | remaining <= 2 = width + remaining
    | otherwise = go (width + 1) (3 * (remaining - 1) `div` 4)

literal :: Text -> Check state ()
literal expected = text >>= require . (== expected)

typeLiteral :: Text -> Check state ()
typeLiteral expected = textIn TypeFieldScope >>= require . (== expected)

decode :: Cbor.Decoder state value -> Check state value
decode = lift . lift

change :: (CanonicalDhallValueUsage -> CanonicalDhallValueUsage) -> Check state ()
change = lift . modify'

container :: Cbor.Decoder state value -> Check state value
container action = do
  change (\usage -> usage {storedCheckedContainers = storedCheckedContainers usage + 1})
  decode action

spanned :: Cbor.Decoder state value -> Check state (value, Natural)
spanned action = do
  before <- decode Cbor.peekByteOffset
  value <- decode action
  after <- decode Cbor.peekByteOffset
  require (after >= before)
  pure (value, fromIntegral (after - before))

text :: Check state Text
text = textIn ValueFieldScope

textIn :: FieldScope -> Check state Text
textIn scope = do
  (value, bytes) <- spanned Cbor.decodeString
  change
    ( \usage ->
        let global =
              usage
                { storedTextTokenBytes = storedTextTokenBytes usage + bytes
                , storedTextTokens = storedTextTokens usage + 1
                }
         in case scope of
              ValueFieldScope -> global
              TypeFieldScope ->
                global
                  { storedTypeTextTokenBytes = storedTypeTextTokenBytes usage + bytes
                  , storedTypeTextTokens = storedTypeTextTokens usage + 1
                  }
    )
  pure value

integer :: Check state Integer
integer = do
  (value, bytes) <- spanned Cbor.decodeInteger
  change
    ( \usage ->
        usage
          { storedIntegerTokenBytes = storedIntegerTokenBytes usage + bytes
          , storedIntegerTokens = storedIntegerTokens usage + 1
          }
    )
  pure value

require :: Bool -> Check state ()
require condition = unless condition (throwE CanonicalDhallValueShapeMismatch)

requireValue :: Bool -> Check state ()
requireValue condition = unless condition (throwE CanonicalDhallValueRequirementMismatch)

-- POSIX simplification preserves ordinary components of a valid safe relative
-- path. Dot-only components of length one or two are not such components.
-- The strict scan has constant live state even for many empty components.
data PathComponentScan = PathComponentScan !Natural !Bool !Natural

longestOrdinaryPathComponent :: Text -> Natural
longestOrdinaryPathComponent = finish . Text.foldl' step (PathComponentScan 0 True 0)
 where
  step previous@(PathComponentScan size dots longest) character
    | character == '/' = PathComponentScan 0 True (finish previous)
    | otherwise = PathComponentScan (size + 1) (dots && character == '.') longest
  finish (PathComponentScan size dots longest)
    | dots && size <= 2 = longest
    | otherwise = max size longest

canonicalDhallUsageNormalFormBytes :: CanonicalDhallValueUsage -> Natural
canonicalDhallUsageNormalFormBytes
  ( Usage
      input
      values
      types
      elements
      records
      unions
      containers
      textBytes
      integerBytes
      depth
      texts
      integers
      pathCharacters
      pathTextCharacters
      pathTextValues
      booleanValues
      listValues
      optionalValues
      recordValues
      unionValues
      textValues
      mapEntryHeightSum
      awsProfileValues
      typeRecords
      typeUnions
      typeTexts
      typeTextBytes
      selectedUnionEntries
      selectedUnionHeightSum
    ) =
    boxedRecordBytes
      ( map
          boxedNaturalBytes
          [ input
          , values
          , types
          , elements
          , records
          , unions
          , containers
          , textBytes
          , integerBytes
          , depth
          , texts
          , integers
          , pathCharacters
          , pathTextCharacters
          , pathTextValues
          , booleanValues
          , listValues
          , optionalValues
          , recordValues
          , unionValues
          , textValues
          , mapEntryHeightSum
          , awsProfileValues
          , typeRecords
          , typeUnions
          , typeTexts
          , typeTextBytes
          , selectedUnionEntries
          , selectedUnionHeightSum
          ]
      )

-- Fully evaluated structural data for this closed trusted shape, including
-- complete Text backing arrays and exact requirement scalars. This observation
-- does not pre-fund construction, compiler/control/GC/native work or admission.
canonicalDhallValueShapeDataBytes :: CanonicalDhallValueShape -> Natural
canonicalDhallValueShapeDataBytes shape = case shape of
  BooleanValue -> boxedRecordBytes []
  NaturalValue -> boxedRecordBytes []
  ExactNaturalValue n -> boxedRecordBytes [boxedNaturalBytes n]
  IntegerValue -> boxedRecordBytes []
  DoubleValue -> boxedRecordBytes []
  TextValue -> boxedRecordBytes []
  ExactTextValue t -> boxedRecordBytes [boxedTextBytes t]
  PathTextValue -> boxedRecordBytes []
  ListValue child -> boxedRecordBytes [canonicalDhallValueShapeDataBytes child]
  CountedListValue n child -> boxedRecordBytes [boxedNaturalBytes n, canonicalDhallValueShapeDataBytes child]
  OptionalValue child -> boxedRecordBytes [canonicalDhallValueShapeDataBytes child]
  PresentOptionalValue child -> boxedRecordBytes [canonicalDhallValueShapeDataBytes child]
  RecordValue fields -> record fields
  AwsProfileRecordValue fields -> record fields
  UnionValue alternatives ->
    boxedRecordBytes
      [boxedMapBytes boxedTextBytes (boxedMaybeBytes canonicalDhallValueShapeDataBytes) alternatives]
 where
  record fields = boxedRecordBytes [boxedMapBytes boxedTextBytes canonicalDhallValueShapeDataBytes fields]

-- Constructor data allocated by the closed shape compiler, without relying on
-- collection between subtrees. The returned graph includes full shared key
-- backings conservatively. Each compile step allocates at most one Right;
-- containers-0.6.8 traversal uses at most four Rights per entry plus four per
-- map root, including Tip results and intermediate applicative results.
-- Union alternatives add one Right each; their Maybe data is in the graph.
-- This is not SDK declaration/key construction, compiler closures, control,
-- stack, GC, native memory, bound calculation or a complete preparation/admission bound.
canonicalDhallValueShapeCompilationDataBytes :: CanonicalDhallValueShape -> Natural
canonicalDhallValueShapeCompilationDataBytes shape =
  canonicalDhallValueShapeDataBytes shape + resultData shape
 where
  resultData current =
    16 + case current of
      BooleanValue -> 0
      NaturalValue -> 0
      ExactNaturalValue _ -> 0
      IntegerValue -> 0
      DoubleValue -> 0
      TextValue -> 0
      ExactTextValue _ -> 0
      PathTextValue -> 0
      ListValue child -> resultData child
      CountedListValue _ child -> resultData child
      OptionalValue child -> resultData child
      PresentOptionalValue child -> resultData child
      RecordValue fields -> mapResults resultData fields
      AwsProfileRecordValue fields -> mapResults resultData fields
      UnionValue alternatives -> mapResults (maybe 16 ((16 +) . resultData)) alternatives
  mapResults children fields =
    64 * (1 + fromIntegral (Map.size fields))
      + Map.foldl' (\total child -> total + children child) 0 fields

-- Fixed metadata, derived from the actual typed producer at build time.
-- Reading the numeric constructor-data floor does not demand the shape field.
type role StaticShapeTemplate nominal
data StaticShapeTemplate value = StaticShapeTemplate !Natural CanonicalDhallValueShape

data StaticShapeTemplateError
  = StaticShapeSchemaRefused CanonicalDhallValueShapeError
  | StaticShapeDataExceedsAddressSpace
  | StaticShapeDataUnderfunded !Natural !Natural
  deriving (Eq, Show)

data StaticShapeTransform
  = StaticPathText [Text]
  | StaticAwsProfile [Text]
  | StaticRequirement [Text] CanonicalDhallValueRequirement

staticShapeTemplateDataBytes :: StaticShapeTemplate value -> Natural
staticShapeTemplateDataBytes (StaticShapeTemplate bytes _) = bytes

materializeStaticShapeTemplate :: StaticShapeTemplate value -> CanonicalDhallValueShape
materializeStaticShapeTemplate (StaticShapeTemplate _ shape) = shape

type role StaticShapeDefinition nominal
data StaticShapeDefinition value = StaticShapeDefinition !Natural !CanonicalDhallValueShape

staticShapeDefinitionShape :: StaticShapeDefinition value -> CanonicalDhallValueShape
staticShapeDefinitionShape (StaticShapeDefinition _ shape) = shape

prepareStaticShapeDefinition
  :: forall value
   . (Dhall.ToDhall value)
  => Proxy value
  -> [StaticShapeTransform]
  -> Either StaticShapeTemplateError (StaticShapeDefinition value)
prepareStaticShapeDefinition _ transforms = do
  compiled <-
    first
      StaticShapeSchemaRefused
      (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @value)))
  shape <- first StaticShapeSchemaRefused (applyTransforms transforms compiled)
  -- Template (24), its Natural (16), a prospective literal Integer (16),
  -- and the successful materialization Right (16). Control/GC/native costs
  -- retain separate obligations.
  let required = canonicalDhallValueShapeDataBytes shape + literalTemporaries shape + 72
  if required <= fromIntegral (maxBound :: Int)
    then pure $! StaticShapeDefinition required shape
    else Left StaticShapeDataExceedsAddressSpace

liftStaticShapeDefinition
  :: (Quote m) => StaticShapeDefinition value -> Code m (StaticShapeTemplate value)
liftStaticShapeDefinition (StaticShapeDefinition required shape) =
  [||StaticShapeTemplate (fromInteger $$(liftTyped (toInteger required))) $$(liftShape shape)||]

materializeStaticShapeTemplateWithin
  :: Natural
  -> StaticShapeTemplate value
  -> Either StaticShapeTemplateError CanonicalDhallValueShape
materializeStaticShapeTemplateWithin available template
  | available < required = Left (StaticShapeDataUnderfunded required available)
  | otherwise = Right $! materializeStaticShapeTemplate template
 where
  required = staticShapeTemplateDataBytes template

applyTransforms
  :: [StaticShapeTransform]
  -> CanonicalDhallValueShape
  -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
applyTransforms transforms shape = case transforms of
  [] -> Right shape
  transform : rest -> do
    updated <- case transform of
      StaticPathText path -> markCanonicalDhallPathText path shape
      StaticAwsProfile path -> markCanonicalDhallAwsProfile path shape
      StaticRequirement path requirement -> requireCanonicalDhallValue path requirement shape
    applyTransforms rest updated

liftShape :: (Quote m) => CanonicalDhallValueShape -> Code m CanonicalDhallValueShape
liftShape shape = case shape of
  BooleanValue -> [||BooleanValue||]
  NaturalValue -> [||NaturalValue||]
  ExactNaturalValue n -> [||ExactNaturalValue (fromInteger $$(liftTyped (toInteger n)))||]
  IntegerValue -> [||IntegerValue||]
  DoubleValue -> [||DoubleValue||]
  TextValue -> [||TextValue||]
  ExactTextValue value -> [||ExactTextValue $$(liftTyped value)||]
  PathTextValue -> [||PathTextValue||]
  ListValue child -> [||ListValue $$(liftShape child)||]
  CountedListValue n child -> [||CountedListValue (fromInteger $$(liftTyped (toInteger n))) $$(liftShape child)||]
  OptionalValue child -> [||OptionalValue $$(liftShape child)||]
  PresentOptionalValue child -> [||PresentOptionalValue $$(liftShape child)||]
  RecordValue fields -> [||RecordValue $$(liftMap liftShape fields)||]
  AwsProfileRecordValue fields -> [||AwsProfileRecordValue $$(liftMap liftShape fields)||]
  UnionValue alternatives -> [||UnionValue $$(liftMap liftAlternative alternatives)||]

liftAlternative
  :: (Quote m) => Maybe CanonicalDhallValueShape -> Code m (Maybe CanonicalDhallValueShape)
liftAlternative alternative = case alternative of
  Nothing -> [||Nothing||]
  Just child -> [||let value = $$(liftShape child) in value `seq` Just value||]

liftMap :: (Quote m) => (value -> Code m value) -> Map Text value -> Code m (Map Text value)
liftMap field fields = case fields of
  MapInternal.Tip -> [||MapInternal.Tip||]
  MapInternal.Bin size key value left right ->
    [||
    let result = $$(field value)
     in result `seq`
          MapInternal.Bin
            $$(liftTyped size)
            $$(liftTyped key)
            result
            $$(liftMap field left)
            $$(liftMap field right)
    ||]

literalTemporaries :: CanonicalDhallValueShape -> Natural
literalTemporaries shape = case shape of
  BooleanValue -> 0
  NaturalValue -> 0
  ExactNaturalValue n -> boxedIntegerBytes (toInteger n)
  IntegerValue -> 0
  DoubleValue -> 0
  TextValue -> 0
  ExactTextValue _ -> 48
  PathTextValue -> 0
  ListValue child -> literalTemporaries child
  CountedListValue n child -> boxedIntegerBytes (toInteger n) + literalTemporaries child
  OptionalValue child -> literalTemporaries child
  PresentOptionalValue child -> literalTemporaries child
  RecordValue fields -> fieldsTemporary literalTemporaries fields
  AwsProfileRecordValue fields -> fieldsTemporary literalTemporaries fields
  UnionValue alternatives -> fieldsTemporary (maybe 0 literalTemporaries) alternatives
 where
  -- One Int/map node and one Int/Text length, their prospective Integer
  -- literals and the Ptr wrapper passed to Text's pinned literal copier.
  fieldsTemporary field fields =
    80 * fromIntegral (Map.size fields) + Map.foldl' (\total child -> total + field child) 0 fields
