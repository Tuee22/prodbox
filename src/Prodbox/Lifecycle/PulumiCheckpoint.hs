{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed Pulumi-checkpoint identities and canonical checkpoint bytes.
--
-- The registered identity is derived from 'StackDescriptor'; callers cannot
-- manufacture a project/stack pair.  Checkpoint JSON is bounded, versioned,
-- shape-checked, canonicalised, and content-addressed before it can cross the
-- Lifecycle Authority repository boundary.
module Prodbox.Lifecycle.PulumiCheckpoint
  ( RegisteredPulumiCheckpoint
  , RegisteredPulumiCheckpointError (..)
  , registeredPulumiCheckpoints
  , registeredPulumiCheckpointByName
  , registeredPulumiCheckpointFor
  , registeredPulumiCheckpointName
  , registeredPulumiCheckpointProject
  , registeredPulumiCheckpointStack
  , PulumiCheckpointPayloadKind (..)
  , PulumiCheckpointCodecError (..)
  , CanonicalPulumiCheckpoint
  , canonicalPulumiCheckpointBytes
  , canonicalPulumiCheckpointDigest
  , canonicalPulumiCheckpointKind
  , PulumiCheckpointDigest
  , pulumiCheckpointDigestText
  , PulumiCheckpointOperationRef
  , PulumiCheckpointOperationRefError (..)
  , mkPulumiCheckpointOperationRef
  , pulumiCheckpointOperationRefText
  , pulumiCheckpointMaximumBytes
  , decodeCanonicalPulumiCheckpoint
  )
where

import Codec.Serialise (Serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.List (find)
import Data.Scientific (toBoundedInteger)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
import Prodbox.Infra.StackDescriptor
  ( StackDescriptor (..)
  , stackDescriptors
  )

data RegisteredPulumiCheckpoint = RegisteredPulumiCheckpoint
  { internalCheckpointName :: !Text
  , internalCheckpointProject :: !Text
  , internalCheckpointStack :: !Text
  }
  deriving stock (Eq, Ord, Show)

data RegisteredPulumiCheckpointError
  = PulumiCheckpointNameUnregistered !Text
  | PulumiCheckpointCoordinatesUnregistered !Text !Text
  deriving stock (Eq, Show)

registeredPulumiCheckpoints :: [RegisteredPulumiCheckpoint]
registeredPulumiCheckpoints = map checkpointFromDescriptor stackDescriptors

registeredPulumiCheckpointByName
  :: Text
  -> Either RegisteredPulumiCheckpointError RegisteredPulumiCheckpoint
registeredPulumiCheckpointByName raw =
  maybe
    (Left (PulumiCheckpointNameUnregistered raw))
    Right
    (find ((== raw) . registeredPulumiCheckpointName) registeredPulumiCheckpoints)

registeredPulumiCheckpointFor
  :: Text
  -> Text
  -> Either RegisteredPulumiCheckpointError RegisteredPulumiCheckpoint
registeredPulumiCheckpointFor project stack =
  maybe
    (Left (PulumiCheckpointCoordinatesUnregistered project stack))
    Right
    ( find
        ( \checkpoint ->
            registeredPulumiCheckpointProject checkpoint == project
              && registeredPulumiCheckpointStack checkpoint == stack
        )
        registeredPulumiCheckpoints
    )

registeredPulumiCheckpointName :: RegisteredPulumiCheckpoint -> Text
registeredPulumiCheckpointName = internalCheckpointName

registeredPulumiCheckpointProject :: RegisteredPulumiCheckpoint -> Text
registeredPulumiCheckpointProject = internalCheckpointProject

registeredPulumiCheckpointStack :: RegisteredPulumiCheckpoint -> Text
registeredPulumiCheckpointStack = internalCheckpointStack

checkpointFromDescriptor :: StackDescriptor -> RegisteredPulumiCheckpoint
checkpointFromDescriptor descriptor =
  RegisteredPulumiCheckpoint
    { internalCheckpointName = Text.pack (stackRegistryName descriptor)
    , internalCheckpointProject = Text.pack (stackPulumiProjectName descriptor)
    , internalCheckpointStack = Text.pack (stackPulumiStackId descriptor)
    }

data PulumiCheckpointPayloadKind
  = PulumiFileBackendCheckpoint
  | PulumiLegacyExportCheckpoint
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointCodecError
  = PulumiCheckpointTooLarge !Int !Int
  | PulumiCheckpointInvalid !Text
  | PulumiCheckpointUnsupportedVersion !Word
  | PulumiCheckpointPayloadKindRefused !PulumiCheckpointPayloadKind
  deriving stock (Eq, Show)

newtype PulumiCheckpointDigest = PulumiCheckpointDigest Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data CanonicalPulumiCheckpoint = CanonicalPulumiCheckpoint
  { internalCanonicalCheckpointBytes :: !ByteString
  , internalCanonicalCheckpointDigest :: !PulumiCheckpointDigest
  , internalCanonicalCheckpointKind :: !PulumiCheckpointPayloadKind
  }
  deriving stock (Eq, Show)

canonicalPulumiCheckpointBytes :: CanonicalPulumiCheckpoint -> ByteString
canonicalPulumiCheckpointBytes = internalCanonicalCheckpointBytes

canonicalPulumiCheckpointDigest :: CanonicalPulumiCheckpoint -> PulumiCheckpointDigest
canonicalPulumiCheckpointDigest = internalCanonicalCheckpointDigest

canonicalPulumiCheckpointKind :: CanonicalPulumiCheckpoint -> PulumiCheckpointPayloadKind
canonicalPulumiCheckpointKind = internalCanonicalCheckpointKind

pulumiCheckpointDigestText :: PulumiCheckpointDigest -> Text
pulumiCheckpointDigestText (PulumiCheckpointDigest digest) = digest

-- | Opaque reference to an already admitted Lifecycle Authority operation.
-- The checkpoint route may transport it, but only the injected Authority
-- repository can prove that the referenced operation authorises the exact
-- registered stack and mutation.  A caller therefore cannot turn this token
-- into a generic object-store capability.
newtype PulumiCheckpointOperationRef = PulumiCheckpointOperationRef Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointOperationRefError
  = PulumiCheckpointOperationRefInvalid !Text
  deriving stock (Eq, Show)

mkPulumiCheckpointOperationRef
  :: Text
  -> Either PulumiCheckpointOperationRefError PulumiCheckpointOperationRef
mkPulumiCheckpointOperationRef raw
  | Text.null raw
      || Text.length raw > 512
      || Text.any (\character -> isControl character || isSpace character) raw =
      Left (PulumiCheckpointOperationRefInvalid raw)
  | otherwise = Right (PulumiCheckpointOperationRef raw)

pulumiCheckpointOperationRefText :: PulumiCheckpointOperationRef -> Text
pulumiCheckpointOperationRefText (PulumiCheckpointOperationRef value) = value

pulumiCheckpointMaximumBytes :: Int
pulumiCheckpointMaximumBytes = 64 * 1024 * 1024

decodeCanonicalPulumiCheckpoint
  :: Set PulumiCheckpointPayloadKind
  -> Int
  -> ByteString
  -> Either PulumiCheckpointCodecError CanonicalPulumiCheckpoint
decodeCanonicalPulumiCheckpoint acceptedKinds maximumBytes bytes
  | maximumBytes <= 0 || actual > maximumBytes =
      Left (PulumiCheckpointTooLarge actual maximumBytes)
  | otherwise = do
      value <-
        mapLeft
          (PulumiCheckpointInvalid . Text.pack)
          (eitherDecodeStrict' bytes)
      object <- case value of
        Object fields -> Right fields
        _ -> Left (PulumiCheckpointInvalid "top-level checkpoint is not an object")
      version <- case KeyMap.lookup "version" object of
        Just (Number scientific) ->
          maybe
            (Left (PulumiCheckpointInvalid "checkpoint version is not an unsigned integer"))
            Right
            (toBoundedInteger scientific :: Maybe Word)
        _ -> Left (PulumiCheckpointInvalid "checkpoint has no numeric version")
      if version `elem` supportedCheckpointVersions
        then Right ()
        else Left (PulumiCheckpointUnsupportedVersion version)
      kind <- checkpointPayloadKind object
      if Set.member kind acceptedKinds
        then Right ()
        else Left (PulumiCheckpointPayloadKindRefused kind)
      let canonical = LazyByteString.toStrict (encode value)
      pure
        CanonicalPulumiCheckpoint
          { internalCanonicalCheckpointBytes = canonical
          , internalCanonicalCheckpointDigest = digestCheckpoint canonical
          , internalCanonicalCheckpointKind = kind
          }
 where
  actual = ByteString.length bytes

supportedCheckpointVersions :: [Word]
supportedCheckpointVersions = [1, 2, 3]

checkpointPayloadKind
  :: KeyMap.KeyMap Value
  -> Either PulumiCheckpointCodecError PulumiCheckpointPayloadKind
checkpointPayloadKind object =
  case (KeyMap.member "checkpoint" object, KeyMap.member "deployment" object) of
    (True, False) -> Right PulumiFileBackendCheckpoint
    (False, True) -> Right PulumiLegacyExportCheckpoint
    _ ->
      Left
        ( PulumiCheckpointInvalid
            "checkpoint must contain exactly one of checkpoint or deployment"
        )

digestCheckpoint :: ByteString -> PulumiCheckpointDigest
digestCheckpoint = PulumiCheckpointDigest . lowerHex . SHA256.hash

lowerHex :: ByteString -> Text
lowerHex = Text.pack . concatMap byteHex . ByteString.unpack
 where
  byteHex byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered

mapLeft :: (left -> mapped) -> Either left value -> Either mapped value
mapLeft f = either (Left . f) Right
