{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Validate the producer's closed data shape before allocating a general Dhall
-- expression. Recursion follows the trusted schema, not untrusted expression
-- nesting. Canonical re-encoding and semantic validation remain independent.
module Prodbox.Config.CanonicalDhallValueShape
  ( CanonicalDhallValueShape
  , CanonicalDhallValueShapeError (..)
  , compileCanonicalDhallValueShape
  , checkCanonicalDhallValueShape
  ) where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Read qualified as Cbor
import Control.Monad (replicateM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Void (Void)
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap

data CanonicalDhallValueShape
  = BooleanValue
  | NaturalValue
  | IntegerValue
  | DoubleValue
  | TextValue
  | ListValue !CanonicalDhallValueShape
  | OptionalValue !CanonicalDhallValueShape
  | RecordValue !(Map Text CanonicalDhallValueShape)
  | UnionValue !(Map Text (Maybe CanonicalDhallValueShape))

data CanonicalDhallValueShapeError
  = CanonicalDhallValueSchemaUnsupported
  | CanonicalDhallValueShapeMismatch
  | CanonicalDhallValueEncodingInvalid
  deriving (Eq, Show)

compileCanonicalDhallValueShape
  :: Core.Expr source Void -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
compileCanonicalDhallValueShape = compile . Core.normalize . Core.denote
 where
  compile expression = case expression of
    Core.Bool -> Right BooleanValue
    Core.Natural -> Right NaturalValue
    Core.Integer -> Right IntegerValue
    Core.Double -> Right DoubleValue
    Core.Text -> Right TextValue
    Core.App Core.List element -> ListValue <$> compile element
    Core.App Core.Optional element -> OptionalValue <$> compile element
    Core.Record fields ->
      RecordValue <$> traverse (compile . Core.recordFieldValue) (Map.fromList (DhallMap.toList fields))
    Core.Union fields ->
      UnionValue <$> traverse (traverse compile) (Map.fromList (DhallMap.toList fields))
    _ -> Left CanonicalDhallValueSchemaUnsupported

type Check state = ExceptT CanonicalDhallValueShapeError (Cbor.Decoder state)

checkCanonicalDhallValueShape
  :: CanonicalDhallValueShape -> ByteString -> Either CanonicalDhallValueShapeError ()
checkCanonicalDhallValueShape shape bytes = do
  (remaining, result) <-
    first (const CanonicalDhallValueEncodingInvalid) $
      Cbor.deserialiseFromBytes (runExceptT (checkValue shape)) (Lazy.fromStrict bytes)
  result
  unless (Lazy.null remaining) (Left CanonicalDhallValueEncodingInvalid)

checkValue :: CanonicalDhallValueShape -> Check state ()
checkValue BooleanValue = void (lift Cbor.decodeBool)
checkValue NaturalValue = do
  tagged 2 15
  value <- lift Cbor.decodeInteger
  require (value >= 0)
checkValue IntegerValue = tagged 2 16 >> void (lift Cbor.decodeInteger)
checkValue DoubleValue = void (lift Cbor.decodeDouble)
checkValue TextValue = tagged 2 18 >> void (lift Cbor.decodeString)
checkValue (ListValue element) = do
  count <- lift Cbor.decodeListLen
  label <- lift Cbor.decodeWord
  require (label == 4 && count >= 2)
  if count == 2
    then checkType element
    else lift Cbor.decodeNull >> replicateM_ (count - 2) (checkValue element)
checkValue (OptionalValue element) = do
  count <- lift Cbor.decodeListLen
  label <- lift Cbor.decodeWord
  require (count == 3)
  case label of
    5 -> lift Cbor.decodeNull >> checkValue element
    0 -> literal "None" >> checkType element
    _ -> throwE CanonicalDhallValueShapeMismatch
checkValue (RecordValue fields) = tagged 2 8 >> checkFields checkValue fields
checkValue shape@(UnionValue alternatives) = do
  count <- lift Cbor.decodeListLen
  label <- lift Cbor.decodeWord
  require (count == 3)
  case label of
    9 -> do
      checkType shape
      name <- lift Cbor.decodeString
      case Map.lookup name alternatives of
        Just Nothing -> pure ()
        _ -> throwE CanonicalDhallValueShapeMismatch
    0 -> do
      tagged 3 9
      checkType shape
      name <- lift Cbor.decodeString
      case Map.lookup name alternatives of
        Just (Just payload) -> checkValue payload
        _ -> throwE CanonicalDhallValueShapeMismatch
    _ -> throwE CanonicalDhallValueShapeMismatch

-- Empty lists, None and union selectors carry their exact closed type. The
-- checker never delegates an untrusted type expression to the general parser.
checkType :: CanonicalDhallValueShape -> Check state ()
checkType shape = case shape of
  BooleanValue -> literal "Bool"
  NaturalValue -> literal "Natural"
  IntegerValue -> literal "Integer"
  DoubleValue -> literal "Double"
  TextValue -> literal "Text"
  ListValue element -> tagged 3 0 >> literal "List" >> checkType element
  OptionalValue element -> tagged 3 0 >> literal "Optional" >> checkType element
  RecordValue fields -> tagged 2 7 >> checkFields checkType fields
  UnionValue alternatives -> tagged 2 11 >> checkFields checkAlternative alternatives
 where
  checkAlternative Nothing = lift Cbor.decodeNull
  checkAlternative (Just payload) = checkType payload

-- Field count, membership and uniqueness are bounded by the trusted schema.
-- Field ordering is left to the existing canonical-value equality check.
checkFields :: (value -> Check state ()) -> Map Text value -> Check state ()
checkFields check fields = do
  count <- lift Cbor.decodeMapLen
  require (count == Map.size fields)
  loop count Set.empty
 where
  loop 0 _ = pure ()
  loop count seen = do
    name <- lift Cbor.decodeString
    require (Set.notMember name seen)
    case Map.lookup name fields of
      Nothing -> throwE CanonicalDhallValueShapeMismatch
      Just value -> check value >> loop (count - 1) (Set.insert name seen)

tagged :: Int -> Word -> Check state ()
tagged count label = do
  actualCount <- lift Cbor.decodeListLen
  require (actualCount == count)
  actualLabel <- lift Cbor.decodeWord
  require (actualLabel == label)

literal :: Text -> Check state ()
literal expected = lift Cbor.decodeString >>= require . (== expected)

require :: Bool -> Check state ()
require condition = unless condition (throwE CanonicalDhallValueShapeMismatch)
