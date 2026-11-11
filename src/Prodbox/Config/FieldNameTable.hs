{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE TemplateHaskell #-}

module Prodbox.Config.FieldNameTable
  ( FieldNameTableRole (..)
  , SFieldNameTableRole (..)
  , FieldNameTable
  , FieldNameTableDefinition
  , FieldNameTableError (..)
  , prepareFieldNameTableDefinition
  , liftFieldNameTableDefinition
  , fieldNameTableDataBytes
  , fieldNameTableDefinitionDataBytes
  , fieldNameTableEntries
  , modifyFieldName
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString qualified as Bytes
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Language.Haskell.TH.Syntax (Code, Lift (liftTyped), Quote)
import Numeric.Natural (Natural)

data FieldNameTableRole
  = AwsProfileFields
  | ScalingSubstrateFields
  | RetainedDeclarationFields
  | RetainedSectionFields
  deriving (Bounded, Enum)

data SFieldNameTableRole (tableRole :: FieldNameTableRole) where
  SAwsProfileFields :: SFieldNameTableRole 'AwsProfileFields
  SScalingSubstrateFields :: SFieldNameTableRole 'ScalingSubstrateFields
  SRetainedDeclarationFields :: SFieldNameTableRole 'RetainedDeclarationFields
  SRetainedSectionFields :: SFieldNameTableRole 'RetainedSectionFields

type role FieldNameTable nominal
data FieldNameTable (tableRole :: FieldNameTableRole) = FieldNameTable !Natural [(Text, Text)]
type role FieldNameTableDefinition nominal
data FieldNameTableDefinition (tableRole :: FieldNameTableRole)
  = FieldNameTableDefinition !Natural [(Text, Text)]

data FieldNameTableError = FieldNameTableDuplicateSource !Text | FieldNameTableDataExceedsAddressSpace
  deriving (Eq, Show)

instance NFData (FieldNameTable tableRole) where
  rnf (FieldNameTable bytes entries) = rnf bytes `seq` rnf entries

fieldNameTableDataBytes :: FieldNameTable tableRole -> Natural
fieldNameTableDataBytes (FieldNameTable bytes _) = bytes
fieldNameTableDefinitionDataBytes :: FieldNameTableDefinition tableRole -> Natural
fieldNameTableDefinitionDataBytes (FieldNameTableDefinition bytes _) = bytes

fieldNameTableEntries :: FieldNameTable tableRole -> [(Text, Text)]
fieldNameTableEntries (FieldNameTable _ entries) = entries

modifyFieldName :: FieldNameTable tableRole -> Text -> Text
modifyFieldName (FieldNameTable _ entries) original = go entries
 where
  go [] = original
  go ((source, target) : rest)
    | source == original = target
    | otherwise = go rest

prepareFieldNameTableDefinition
  :: SFieldNameTableRole tableRole
  -> [(Text, Text)]
  -> Either FieldNameTableError (FieldNameTableDefinition tableRole)
prepareFieldNameTableDefinition _ entries = do
  validateSources Set.empty entries
  let required = 72 + sum [48 + literalTextData source + literalTextData target | (source, target) <- entries]
  if required <= fromIntegral (maxBound :: Int)
    then Right (FieldNameTableDefinition required entries)
    else Left FieldNameTableDataExceedsAddressSpace
 where
  validateSources _ [] = Right ()
  validateSources seen ((source, _) : rest)
    | Set.member source seen = Left (FieldNameTableDuplicateSource source)
    | otherwise = validateSources (Set.insert source seen) rest

-- Table24 + Natural16 + prospective literal Integer16 + Nil16. Each entry
-- adds cons24/pair24. text2.0.2 Lift uses unpackCStringLen#: one exact byte
-- array/header16, MArray16, Array16, Text32, prospective Int/Integer32, Ptr16, two offset Int16s, and copy-result Unit16.
-- Source bytes in native read-only storage, compiler/control/update/GC/native
-- costs and actual SDK invocation accounting remain independent.
literalTextData :: Text -> Natural
literalTextData value = 176 + alignBytes (fromIntegral (Bytes.length (Text.encodeUtf8 value)))
 where
  alignBytes bytes = 8 * ((bytes + 7) `div` 8)

liftFieldNameTableDefinition
  :: (Quote m) => FieldNameTableDefinition tableRole -> Code m (FieldNameTable tableRole)
liftFieldNameTableDefinition (FieldNameTableDefinition bytes entries) =
  [||FieldNameTable (fromInteger $$(liftTyped (toInteger bytes))) $$(liftEntries entries)||]
 where
  liftEntries [] = [||[]||]
  liftEntries ((source, target) : rest) = [||($$(liftTyped source), $$(liftTyped target)) : $$(liftEntries rest)||]
