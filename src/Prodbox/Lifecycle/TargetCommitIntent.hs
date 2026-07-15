{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded cross-authority target-secret commit planning.
--
-- The retained Model-B authority owns the global intent projection.  A target
-- Vault is a separate authority with its own CAS version; no value in this
-- module claims that either CAS atomically fences the other.  The protocol is
-- therefore prepare, revalidate, at-most-one sink CAS, authoritative readback,
-- and global completion.
module Prodbox.Lifecycle.TargetCommitIntent
  ( CommittedTargetValue
  , CredentialGeneration
  , PreparedTargetWritePermit
  , RegisteredTargetSet
  , StableTargetReadback
  , TargetCommitCompleteDecision (..)
  , TargetCommitDisposition (..)
  , TargetCommitIntent
  , TargetCommitPrepareDecision (..)
  , TargetIntentProjectionCodecError (..)
  , TargetCommitRefusal (..)
  , TargetCommitValueError (..)
  , TargetIntentCompactDecision (..)
  , TargetIntentCoordinate
  , TargetIntentProjection
  , TargetProjectionEntry
  , TargetRecoveryDecision (..)
  , TargetRecoveryOutcome (..)
  , TargetRegistrationError (..)
  , TargetSinkCasRequest (..)
  , TargetSinkCasResult (..)
  , TargetSinkCasAdapter (..)
  , TargetSinkObservation (..)
  , TargetSinkReadbackRefusal (..)
  , TargetSinkRecord (..)
  , TargetSinkVersion
  , TargetSinkWriteDecision (..)
  , TargetValueDigest
  , TimedTargetSinkObservation (..)
  , committedTargetDigest
  , committedTargetGeneration
  , compactTargetIntent
  , confirmTargetSinkReadback
  , credentialGenerationValue
  , decodeTargetIntentProjection
  , decideCompleteTargetCommit
  , decidePrepareTargetCommit
  , decideResolveOutstandingTargets
  , decideTargetSinkWrite
  , emptyTargetIntentProjection
  , encodeTargetIntentProjection
  , mkCredentialGeneration
  , mkRegisteredTargetSet
  , mkTargetIntentCoordinate
  , mkTargetSinkVersion
  , mkTargetValueDigest
  , prepareTargetWrite
  , proveStableTargetReadback
  , proveStableTargetReadbackAfter
  , registeredTargetCapacity
  , registeredTargetByIdentity
  , registeredTargetIdentities
  , sha256TargetValueDigest
  , stableTargetReadbackIntent
  , stableTargetReadbackOutcome
  , targetCommitDeadline
  , targetCommitDigest
  , targetCommitDisposition
  , targetCommitFencingToken
  , targetCommitGeneration
  , targetCommitOwnerNonce
  , targetCommitTargetIdentity
  , targetIntentCoordinateObject
  , targetIntentCoordinateLeaseObject
  , targetIntentProjectionMaximumEncodedBytes
  , targetProjectionEntries
  , targetProjectionEntryCommitted
  , targetProjectionEntryIntent
  , targetProjectionEntryTargetIdentity
  , targetSinkVersionText
  , targetValueDigestText
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasRequest (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , TargetClusterSecretSink
  , mkClusterRetainedCoordinate
  , targetSecretSinkGatewayEndpoint
  , targetSecretSinkIdentity
  , targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , FencedCommitPermit
  , FencingToken
  , LeaseGrant
  , LeaseIdentityError
  , LeaseKey
  , LeasePolicy
  , LeaseValueError
  , OwnerNonce
  , addAuthorityDuration
  , authorityTimeFromMicros
  , authorityTimeMicros
  , fencedCommitFencingToken
  , fencedCommitOwnerNonce
  , fencingTokenValue
  , leaseKeyAccount
  , leaseKeyRegion
  , leaseKeyResource
  , leaseObjectCoordinate
  , leasePolicyProviderVisibilityGrace
  , leasePolicyStableObservationCount
  , mkFencingToken
  , mkOwnerNonce
  , modelBLeaseGuardFromPermit
  , ownerNonceText
  , successorNotBefore
  )

newtype CredentialGeneration = CredentialGeneration
  { internalCredentialGenerationValue :: Natural
  }
  deriving (Eq, Ord, Show)

newtype TargetValueDigest = TargetValueDigest
  { internalTargetValueDigestText :: Text
  }
  deriving (Eq, Ord, Show)

newtype TargetSinkVersion = TargetSinkVersion
  { internalTargetSinkVersionText :: Text
  }
  deriving (Eq, Ord, Show)

data TargetCommitValueError
  = CredentialGenerationMustBePositive
  | TargetValueDigestMustBeLowerHexSha256 !Text
  | TargetSinkVersionEmpty
  | TargetSinkVersionTooLong !Int !Int
  deriving (Eq, Show)

mkCredentialGeneration
  :: Natural -> Either TargetCommitValueError CredentialGeneration
mkCredentialGeneration value
  | value == 0 = Left CredentialGenerationMustBePositive
  | otherwise = Right (CredentialGeneration value)

credentialGenerationValue :: CredentialGeneration -> Natural
credentialGenerationValue = internalCredentialGenerationValue

-- | The digest is deliberately fixed to a canonical SHA-256 rendering.  A
-- changing spelling cannot create a second logical value for one generation.
mkTargetValueDigest :: Text -> Either TargetCommitValueError TargetValueDigest
mkTargetValueDigest value
  | Text.length value /= 64 = Left (TargetValueDigestMustBeLowerHexSha256 value)
  | Text.all isLowerHex value = Right (TargetValueDigest value)
  | otherwise = Left (TargetValueDigestMustBeLowerHexSha256 value)
 where
  isLowerHex character = isDigit character || character `elem` ['a' .. 'f']

targetValueDigestText :: TargetValueDigest -> Text
targetValueDigestText = internalTargetValueDigestText

-- | Total canonical digest construction for in-process payloads.  The
-- SHA-256 result is always exactly 32 bytes and this renderer emits exactly
-- two lowercase hexadecimal characters per byte, so no validation failure or
-- partial constructor is needed.
sha256TargetValueDigest :: ByteString -> TargetValueDigest
sha256TargetValueDigest =
  TargetValueDigest
    . Text.pack
    . concatMap renderHexByte
    . BS.unpack
    . SHA256.hash
 where
  renderHexByte byte
    | byte < 16 = '0' : showHex byte ""
    | otherwise = showHex byte ""

mkTargetSinkVersion :: Text -> Either TargetCommitValueError TargetSinkVersion
mkTargetSinkVersion raw
  | Text.null value = Left TargetSinkVersionEmpty
  | Text.length value > maximumLength =
      Left (TargetSinkVersionTooLong (Text.length value) maximumLength)
  | otherwise = Right (TargetSinkVersion value)
 where
  value = Text.strip raw
  maximumLength = 512

targetSinkVersionText :: TargetSinkVersion -> Text
targetSinkVersionText = internalTargetSinkVersionText

data TargetRegistrationError
  = TargetRegistrationCapacityMustBePositive
  | TargetRegistrationCapacityExceedsHardMaximum !Natural !Natural
  | TargetRegistrationOverBound !Natural !Natural
  | TargetRegistrationDuplicateIdentity !Text
  | TargetRegistrationDuplicateSinkCoordinate !Text !Text
  deriving (Eq, Show)

data RegisteredTargetSet = RegisteredTargetSet
  { internalRegisteredTargetCapacity :: !Int
  , internalRegisteredTargets :: !(Map Text TargetClusterSecretSink)
  }
  deriving (Eq, Show)

-- | A decoded registration is finite twice over: it has a declared capacity
-- and that capacity itself is capped.  This keeps a configuration mistake
-- from turning recovery into an unbounded scan.
mkRegisteredTargetSet
  :: Natural
  -> [TargetClusterSecretSink]
  -> Either TargetRegistrationError RegisteredTargetSet
mkRegisteredTargetSet capacity sinks = do
  when (capacity == 0) (Left TargetRegistrationCapacityMustBePositive)
  when
    (capacity > hardMaximumRegisteredTargets)
    (Left (TargetRegistrationCapacityExceedsHardMaximum capacity hardMaximumRegisteredTargets))
  let actual = fromIntegral (length sinks)
  when (actual > capacity) (Left (TargetRegistrationOverBound actual capacity))
  targets <- foldl' insertUnique (Right Map.empty) sinks
  _ <- foldl' insertUniqueCoordinate (Right Map.empty) sinks
  pure
    RegisteredTargetSet
      { internalRegisteredTargetCapacity = fromIntegral capacity
      , internalRegisteredTargets = targets
      }
 where
  insertUnique result sink = do
    targets <- result
    let identity = targetSecretSinkIdentity sink
    if Map.member identity targets
      then Left (TargetRegistrationDuplicateIdentity identity)
      else Right (Map.insert identity sink targets)

  insertUniqueCoordinate result sink = do
    coordinates <- result
    let coordinate =
          ( targetSecretSinkGatewayEndpoint sink
          , targetSecretSinkVaultMount sink
          , targetSecretSinkKvPath sink
          )
        identity = targetSecretSinkIdentity sink
    case Map.lookup coordinate coordinates of
      Just existing ->
        Left (TargetRegistrationDuplicateSinkCoordinate existing identity)
      Nothing -> Right (Map.insert coordinate identity coordinates)

hardMaximumRegisteredTargets :: Natural
hardMaximumRegisteredTargets = 64

registeredTargetCapacity :: RegisteredTargetSet -> Int
registeredTargetCapacity = internalRegisteredTargetCapacity

registeredTargetIdentities :: RegisteredTargetSet -> [Text]
registeredTargetIdentities = Map.keys . internalRegisteredTargets

registeredTargetByIdentity
  :: RegisteredTargetSet -> Text -> Maybe TargetClusterSecretSink
registeredTargetByIdentity registered identity =
  Map.lookup identity (internalRegisteredTargets registered)

data TargetIntentCoordinate = TargetIntentCoordinate
  { internalTargetIntentCoordinateObject :: !(ModelBObjectCoordinate 'ClusterRetained)
  , internalTargetIntentCoordinateLeaseObject :: !(ModelBObjectCoordinate 'ClusterRetained)
  }
  deriving (Eq, Show)

mkTargetIntentCoordinate
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either AuthorityCoordinateError TargetIntentCoordinate
mkTargetIntentCoordinate authority leaseKey =
  TargetIntentCoordinate
    <$> mkClusterRetainedCoordinate
      authority
      ( Text.intercalate
          "/"
          [ "target-commit-intents"
          , leaseKeyAccount leaseKey
          , leaseKeyRegion leaseKey
          , leaseKeyResource leaseKey
          ]
      )
    <*> leaseObjectCoordinate authority leaseKey

targetIntentCoordinateObject :: TargetIntentCoordinate -> ModelBObjectCoordinate 'ClusterRetained
targetIntentCoordinateObject = internalTargetIntentCoordinateObject

targetIntentCoordinateLeaseObject
  :: TargetIntentCoordinate -> ModelBObjectCoordinate 'ClusterRetained
targetIntentCoordinateLeaseObject = internalTargetIntentCoordinateLeaseObject

data TargetCommitDisposition
  = TargetCommitPrepared
  | TargetCommitCommitted
  | TargetCommitAborted
  deriving (Eq, Show)

data TargetCommitIntent = TargetCommitIntent
  { internalTargetCommitOwnerNonce :: !OwnerNonce
  , internalTargetCommitFencingToken :: !FencingToken
  , internalTargetCommitTargetIdentity :: !Text
  , internalTargetCommitGeneration :: !CredentialGeneration
  , internalTargetCommitDigest :: !TargetValueDigest
  , internalTargetCommitDeadline :: !AuthorityTime
  , internalTargetCommitDisposition :: !TargetCommitDisposition
  }
  deriving (Eq, Show)

targetCommitOwnerNonce :: TargetCommitIntent -> OwnerNonce
targetCommitOwnerNonce = internalTargetCommitOwnerNonce

targetCommitFencingToken :: TargetCommitIntent -> FencingToken
targetCommitFencingToken = internalTargetCommitFencingToken

targetCommitTargetIdentity :: TargetCommitIntent -> Text
targetCommitTargetIdentity = internalTargetCommitTargetIdentity

targetCommitGeneration :: TargetCommitIntent -> CredentialGeneration
targetCommitGeneration = internalTargetCommitGeneration

targetCommitDigest :: TargetCommitIntent -> TargetValueDigest
targetCommitDigest = internalTargetCommitDigest

targetCommitDeadline :: TargetCommitIntent -> AuthorityTime
targetCommitDeadline = internalTargetCommitDeadline

targetCommitDisposition :: TargetCommitIntent -> TargetCommitDisposition
targetCommitDisposition = internalTargetCommitDisposition

data CommittedTargetValue = CommittedTargetValue
  { internalCommittedTargetGeneration :: !CredentialGeneration
  , internalCommittedTargetDigest :: !TargetValueDigest
  }
  deriving (Eq, Show)

committedTargetGeneration :: CommittedTargetValue -> CredentialGeneration
committedTargetGeneration = internalCommittedTargetGeneration

committedTargetDigest :: CommittedTargetValue -> TargetValueDigest
committedTargetDigest = internalCommittedTargetDigest

data TargetProjectionEntry = TargetProjectionEntry
  { internalTargetProjectionEntryTargetIdentity :: !Text
  , internalTargetProjectionEntryCommitted :: !(Maybe CommittedTargetValue)
  , internalTargetProjectionEntryIntent :: !(Maybe TargetCommitIntent)
  }
  deriving (Eq, Show)

targetProjectionEntryTargetIdentity :: TargetProjectionEntry -> Text
targetProjectionEntryTargetIdentity = internalTargetProjectionEntryTargetIdentity

targetProjectionEntryCommitted :: TargetProjectionEntry -> Maybe CommittedTargetValue
targetProjectionEntryCommitted = internalTargetProjectionEntryCommitted

targetProjectionEntryIntent :: TargetProjectionEntry -> Maybe TargetCommitIntent
targetProjectionEntryIntent = internalTargetProjectionEntryIntent

data TargetIntentProjection = TargetIntentProjection
  { internalTargetProjectionRegisteredIdentities :: !(Set Text)
  , internalTargetProjectionEntries :: !(Map Text TargetProjectionEntry)
  }
  deriving (Eq, Show)

emptyTargetIntentProjection :: RegisteredTargetSet -> TargetIntentProjection
emptyTargetIntentProjection registered =
  TargetIntentProjection
    { internalTargetProjectionRegisteredIdentities =
        Map.keysSet (internalRegisteredTargets registered)
    , internalTargetProjectionEntries = Map.empty
    }

targetProjectionEntries :: TargetIntentProjection -> [TargetProjectionEntry]
targetProjectionEntries = Map.elems . internalTargetProjectionEntries

data WireTargetIntentProjection = WireTargetIntentProjection
  { wireTargetProjectionVersion :: !Word16
  , wireTargetProjectionRegisteredIdentities :: ![Text]
  , wireTargetProjectionEntries :: ![WireTargetProjectionEntry]
  }
  deriving (Eq, Generic, Show)

instance Serialise WireTargetIntentProjection

data WireTargetProjectionEntry = WireTargetProjectionEntry
  { wireTargetEntryIdentity :: !Text
  , wireTargetEntryCommitted :: !(Maybe WireCommittedTargetValue)
  , wireTargetEntryIntent :: !(Maybe WireTargetCommitIntent)
  }
  deriving (Eq, Generic, Show)

instance Serialise WireTargetProjectionEntry

data WireCommittedTargetValue = WireCommittedTargetValue
  { wireCommittedTargetGeneration :: !Natural
  , wireCommittedTargetDigest :: !Text
  }
  deriving (Eq, Generic, Show)

instance Serialise WireCommittedTargetValue

data WireTargetCommitIntent = WireTargetCommitIntent
  { wireTargetIntentOwnerNonce :: !Text
  , wireTargetIntentFencingToken :: !Natural
  , wireTargetIntentIdentity :: !Text
  , wireTargetIntentGeneration :: !Natural
  , wireTargetIntentDigest :: !Text
  , wireTargetIntentDeadlineMicros :: !Natural
  , wireTargetIntentDisposition :: !Word8
  }
  deriving (Eq, Generic, Show)

instance Serialise WireTargetCommitIntent

data TargetIntentProjectionCodecError
  = TargetIntentProjectionCodecTooLarge !Int !Int
  | TargetIntentProjectionCodecDecodeFailed !Text
  | TargetIntentProjectionCodecUnsupportedVersion !Word16
  | TargetIntentProjectionCodecRegistrationMismatch ![Text] ![Text]
  | TargetIntentProjectionCodecDuplicateEntry !Text
  | TargetIntentProjectionCodecInvalidDisposition !Word8
  | TargetIntentProjectionCodecIdentityInvalid !LeaseIdentityError
  | TargetIntentProjectionCodecFenceInvalid !LeaseValueError
  | TargetIntentProjectionCodecValueInvalid !TargetCommitValueError
  | TargetIntentProjectionCodecProjectionInvalid !TargetCommitRefusal
  | TargetIntentProjectionCodecNonCanonical
  deriving (Eq, Show)

targetIntentProjectionMaximumEncodedBytes :: Int
targetIntentProjectionMaximumEncodedBytes = 128 * 1024

targetIntentProjectionCodecVersion :: Word16
targetIntentProjectionCodecVersion = 1

encodeTargetIntentProjection :: TargetIntentProjection -> ByteString
encodeTargetIntentProjection =
  BL.toStrict . serialise . wireTargetIntentProjection

decodeTargetIntentProjection
  :: RegisteredTargetSet
  -> ByteString
  -> Either TargetIntentProjectionCodecError TargetIntentProjection
decodeTargetIntentProjection registered bytes
  | BS.length bytes > targetIntentProjectionMaximumEncodedBytes =
      Left
        ( TargetIntentProjectionCodecTooLarge
            (BS.length bytes)
            targetIntentProjectionMaximumEncodedBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (BL.fromStrict bytes) of
        Left err ->
          Left (TargetIntentProjectionCodecDecodeFailed (Text.pack (show err)))
        Right value -> Right value
      unless
        (wireTargetProjectionVersion wire == targetIntentProjectionCodecVersion)
        ( Left
            ( TargetIntentProjectionCodecUnsupportedVersion
                (wireTargetProjectionVersion wire)
            )
        )
      let expectedIdentities = registeredTargetIdentities registered
          encodedIdentities = wireTargetProjectionRegisteredIdentities wire
      unless
        (encodedIdentities == expectedIdentities)
        ( Left
            ( TargetIntentProjectionCodecRegistrationMismatch
                expectedIdentities
                encodedIdentities
            )
        )
      entries <- foldl' decodeAndInsertEntry (Right Map.empty) (wireTargetProjectionEntries wire)
      let projection =
            TargetIntentProjection
              { internalTargetProjectionRegisteredIdentities = Set.fromList encodedIdentities
              , internalTargetProjectionEntries = entries
              }
      mapCodecProjection (validateProjection registered projection)
      unless
        (encodeTargetIntentProjection projection == bytes)
        (Left TargetIntentProjectionCodecNonCanonical)
      pure projection

wireTargetIntentProjection
  :: TargetIntentProjection -> WireTargetIntentProjection
wireTargetIntentProjection projection =
  WireTargetIntentProjection
    { wireTargetProjectionVersion = targetIntentProjectionCodecVersion
    , wireTargetProjectionRegisteredIdentities =
        Set.toAscList (internalTargetProjectionRegisteredIdentities projection)
    , wireTargetProjectionEntries =
        map wireTargetProjectionEntry (targetProjectionEntries projection)
    }

wireTargetProjectionEntry
  :: TargetProjectionEntry -> WireTargetProjectionEntry
wireTargetProjectionEntry entry =
  WireTargetProjectionEntry
    { wireTargetEntryIdentity = targetProjectionEntryTargetIdentity entry
    , wireTargetEntryCommitted = wireCommittedTargetValue <$> targetProjectionEntryCommitted entry
    , wireTargetEntryIntent = wireTargetCommitIntent <$> targetProjectionEntryIntent entry
    }

wireCommittedTargetValue
  :: CommittedTargetValue -> WireCommittedTargetValue
wireCommittedTargetValue committed =
  WireCommittedTargetValue
    { wireCommittedTargetGeneration =
        credentialGenerationValue (committedTargetGeneration committed)
    , wireCommittedTargetDigest = targetValueDigestText (committedTargetDigest committed)
    }

wireTargetCommitIntent :: TargetCommitIntent -> WireTargetCommitIntent
wireTargetCommitIntent intent =
  WireTargetCommitIntent
    { wireTargetIntentOwnerNonce = ownerNonceText (targetCommitOwnerNonce intent)
    , wireTargetIntentFencingToken = fencingTokenValue (targetCommitFencingToken intent)
    , wireTargetIntentIdentity = targetCommitTargetIdentity intent
    , wireTargetIntentGeneration = credentialGenerationValue (targetCommitGeneration intent)
    , wireTargetIntentDigest = targetValueDigestText (targetCommitDigest intent)
    , wireTargetIntentDeadlineMicros = authorityTimeMicros (targetCommitDeadline intent)
    , wireTargetIntentDisposition = encodeTargetDisposition (targetCommitDisposition intent)
    }

decodeAndInsertEntry
  :: Either TargetIntentProjectionCodecError (Map Text TargetProjectionEntry)
  -> WireTargetProjectionEntry
  -> Either TargetIntentProjectionCodecError (Map Text TargetProjectionEntry)
decodeAndInsertEntry accumulated wire = do
  entries <- accumulated
  let identity = wireTargetEntryIdentity wire
  when
    (Map.member identity entries)
    (Left (TargetIntentProjectionCodecDuplicateEntry identity))
  committed <- traverse decodeWireCommittedTargetValue (wireTargetEntryCommitted wire)
  intent <- traverse (decodeWireTargetCommitIntent identity) (wireTargetEntryIntent wire)
  pure
    ( Map.insert
        identity
        TargetProjectionEntry
          { internalTargetProjectionEntryTargetIdentity = identity
          , internalTargetProjectionEntryCommitted = committed
          , internalTargetProjectionEntryIntent = intent
          }
        entries
    )

decodeWireCommittedTargetValue
  :: WireCommittedTargetValue
  -> Either TargetIntentProjectionCodecError CommittedTargetValue
decodeWireCommittedTargetValue wire = do
  generation <- mapCodecValue (mkCredentialGeneration (wireCommittedTargetGeneration wire))
  digest <- mapCodecValue (mkTargetValueDigest (wireCommittedTargetDigest wire))
  pure
    CommittedTargetValue
      { internalCommittedTargetGeneration = generation
      , internalCommittedTargetDigest = digest
      }

decodeWireTargetCommitIntent
  :: Text
  -> WireTargetCommitIntent
  -> Either TargetIntentProjectionCodecError TargetCommitIntent
decodeWireTargetCommitIntent entryIdentity wire = do
  owner <- mapCodecIdentity (mkOwnerNonce (wireTargetIntentOwnerNonce wire))
  fence <- mapCodecFence (mkFencingToken (wireTargetIntentFencingToken wire))
  generation <- mapCodecValue (mkCredentialGeneration (wireTargetIntentGeneration wire))
  digest <- mapCodecValue (mkTargetValueDigest (wireTargetIntentDigest wire))
  disposition <- decodeTargetDisposition (wireTargetIntentDisposition wire)
  let identity = wireTargetIntentIdentity wire
  unless
    (identity == entryIdentity)
    ( Left
        ( TargetIntentProjectionCodecProjectionInvalid
            (TargetCommitIntentTargetMismatch entryIdentity identity)
        )
    )
  pure
    TargetCommitIntent
      { internalTargetCommitOwnerNonce = owner
      , internalTargetCommitFencingToken = fence
      , internalTargetCommitTargetIdentity = identity
      , internalTargetCommitGeneration = generation
      , internalTargetCommitDigest = digest
      , internalTargetCommitDeadline =
          authorityTimeFromMicros (wireTargetIntentDeadlineMicros wire)
      , internalTargetCommitDisposition = disposition
      }

encodeTargetDisposition :: TargetCommitDisposition -> Word8
encodeTargetDisposition disposition = case disposition of
  TargetCommitPrepared -> 0
  TargetCommitCommitted -> 1
  TargetCommitAborted -> 2

decodeTargetDisposition
  :: Word8 -> Either TargetIntentProjectionCodecError TargetCommitDisposition
decodeTargetDisposition encoded = case encoded of
  0 -> Right TargetCommitPrepared
  1 -> Right TargetCommitCommitted
  2 -> Right TargetCommitAborted
  _ -> Left (TargetIntentProjectionCodecInvalidDisposition encoded)

mapCodecIdentity
  :: Either LeaseIdentityError value
  -> Either TargetIntentProjectionCodecError value
mapCodecIdentity =
  either (Left . TargetIntentProjectionCodecIdentityInvalid) Right

mapCodecFence
  :: Either LeaseValueError value
  -> Either TargetIntentProjectionCodecError value
mapCodecFence =
  either (Left . TargetIntentProjectionCodecFenceInvalid) Right

mapCodecValue
  :: Either TargetCommitValueError value
  -> Either TargetIntentProjectionCodecError value
mapCodecValue =
  either (Left . TargetIntentProjectionCodecValueInvalid) Right

mapCodecProjection
  :: Either TargetCommitRefusal value
  -> Either TargetIntentProjectionCodecError value
mapCodecProjection =
  either (Left . TargetIntentProjectionCodecProjectionInvalid) Right

data TargetCommitPrepareDecision
  = TargetCommitPrepareCompareAndSwap
      !(ModelBCasRequest 'ClusterRetained TargetIntentProjection)
      !TargetCommitIntent
  | TargetCommitPrepareAlreadyCommitted !CommittedTargetValue
  | TargetCommitPrepareRefused !TargetCommitRefusal
  deriving (Eq, Show)

data TargetCommitRefusal
  = TargetCommitGlobalMissingAfterPrepare
  | TargetCommitGlobalCorrupt !Text
  | TargetCommitGlobalUnobservable !Text
  | TargetCommitProjectionRegistrationMismatch ![Text] ![Text]
  | TargetCommitProjectionOverBound !Int !Int
  | TargetCommitProjectionKeyMismatch !Text !Text
  | TargetCommitIntentTargetMismatch !Text !Text
  | TargetCommitUnregisteredTarget !Text
  | TargetCommitDeadlineReached !AuthorityTime !AuthorityTime
  | TargetCommitGenerationStale !CredentialGeneration !CredentialGeneration
  | TargetCommitGenerationDigestConflict !CredentialGeneration
  | TargetCommitOutstandingIntent !Text !FencingToken
  | TargetCommitTerminalIntentNeedsCompaction !Text !TargetCommitDisposition
  | TargetCommitExpectedIntentMissing !Text
  | TargetCommitExpectedIntentChanged !TargetCommitIntent !(Maybe TargetCommitIntent)
  | TargetCommitPermitOwnerMismatch !OwnerNonce !OwnerNonce
  | TargetCommitPermitFenceMismatch !FencingToken !FencingToken
  | TargetCommitRecoveryFenceNotNewer !FencingToken !FencingToken
  | TargetCommitRecoveryWitnessMissing !Text
  | TargetCommitRecoveryWitnessUnexpected !Text
  | TargetCommitRecoveryWitnessIntentMismatch !Text
  deriving (Eq, Show)

decidePrepareTargetCommit
  :: RegisteredTargetSet
  -> TargetIntentCoordinate
  -> AuthorityTime
  -> AuthorityTime
  -> FencedCommitPermit
  -> TargetClusterSecretSink
  -> CredentialGeneration
  -> TargetValueDigest
  -> ModelBObservation TargetIntentProjection
  -> TargetCommitPrepareDecision
decidePrepareTargetCommit registered coordinate now deadline permit sink generation digest observation
  | not (Map.member identity (internalRegisteredTargets registered)) =
      TargetCommitPrepareRefused (TargetCommitUnregisteredTarget identity)
  | deadline <= now =
      TargetCommitPrepareRefused (TargetCommitDeadlineReached now deadline)
  | otherwise =
      case observation of
        ModelBCorrupt detail ->
          TargetCommitPrepareRefused (TargetCommitGlobalCorrupt detail)
        ModelBUnobservable detail ->
          TargetCommitPrepareRefused (TargetCommitGlobalUnobservable detail)
        ModelBMissing -> planAgainst Nothing (emptyTargetIntentProjection registered)
        ModelBObserved version projection -> planAgainst (Just version) projection
 where
  identity = targetSecretSinkIdentity sink

  planAgainst maybeVersion projection =
    case validateProjection registered projection of
      Left refusal -> TargetCommitPrepareRefused refusal
      Right () ->
        case firstBlockingIntent permit generation digest projection of
          Just refusal -> TargetCommitPrepareRefused refusal
          Nothing ->
            case Map.lookup identity (internalTargetProjectionEntries projection) of
              Just entry -> case internalTargetProjectionEntryCommitted entry of
                Just committed
                  | committedTargetGeneration committed > generation ->
                      TargetCommitPrepareRefused
                        (TargetCommitGenerationStale generation (committedTargetGeneration committed))
                  | committedTargetGeneration committed == generation
                      && committedTargetDigest committed == digest ->
                      TargetCommitPrepareAlreadyCommitted committed
                  | committedTargetGeneration committed == generation ->
                      TargetCommitPrepareRefused
                        (TargetCommitGenerationDigestConflict generation)
                _ -> prepareCas maybeVersion projection
              Nothing -> prepareCas maybeVersion projection

  prepareCas maybeVersion projection =
    let intent =
          TargetCommitIntent
            { internalTargetCommitOwnerNonce = fencedCommitOwnerNonce permit
            , internalTargetCommitFencingToken = fencedCommitFencingToken permit
            , internalTargetCommitTargetIdentity = identity
            , internalTargetCommitGeneration = generation
            , internalTargetCommitDigest = digest
            , internalTargetCommitDeadline = deadline
            , internalTargetCommitDisposition = TargetCommitPrepared
            }
        previous = Map.lookup identity (internalTargetProjectionEntries projection)
        entry =
          TargetProjectionEntry
            { internalTargetProjectionEntryTargetIdentity = identity
            , internalTargetProjectionEntryCommitted =
                previous >>= internalTargetProjectionEntryCommitted
            , internalTargetProjectionEntryIntent = Just intent
            }
        nextProjection =
          projection
            { internalTargetProjectionEntries =
                Map.insert identity entry (internalTargetProjectionEntries projection)
            }
        request = case maybeVersion of
          Nothing ->
            ModelBInitializeGuarded
              (targetIntentCoordinateObject coordinate)
              leaseGuard
              nextProjection
          Just version ->
            ModelBReplaceGuarded
              (targetIntentCoordinateObject coordinate)
              version
              leaseGuard
              nextProjection
        leaseGuard =
          modelBLeaseGuardFromPermit
            (targetIntentCoordinateLeaseObject coordinate)
            permit
     in TargetCommitPrepareCompareAndSwap request intent

firstBlockingIntent
  :: FencedCommitPermit
  -> CredentialGeneration
  -> TargetValueDigest
  -> TargetIntentProjection
  -> Maybe TargetCommitRefusal
firstBlockingIntent permit generation digest projection =
  foldl' choose Nothing (targetProjectionEntries projection)
 where
  choose refusal _ | Just _ <- refusal = refusal
  choose Nothing entry = case targetProjectionEntryIntent entry of
    Nothing -> Nothing
    Just intent -> case targetCommitDisposition intent of
      TargetCommitPrepared
        | targetCommitOwnerNonce intent == fencedCommitOwnerNonce permit
            && targetCommitFencingToken intent == fencedCommitFencingToken permit
            && targetCommitGeneration intent == generation
            && targetCommitDigest intent == digest ->
            Nothing
        | otherwise ->
            Just
              ( TargetCommitOutstandingIntent
                  (targetCommitTargetIdentity intent)
                  (targetCommitFencingToken intent)
              )
      terminal ->
        Just
          ( TargetCommitTerminalIntentNeedsCompaction
              (targetCommitTargetIdentity intent)
              terminal
          )

data PreparedTargetWritePermit = PreparedTargetWritePermit
  { internalPreparedTargetWriteIntent :: !TargetCommitIntent
  , internalPreparedTargetWriteSink :: !TargetClusterSecretSink
  }
  deriving (Eq, Show)

prepareTargetWrite
  :: RegisteredTargetSet
  -> AuthorityTime
  -> FencedCommitPermit
  -> TargetClusterSecretSink
  -> TargetCommitIntent
  -> ModelBObservation TargetIntentProjection
  -> Either TargetCommitRefusal PreparedTargetWritePermit
prepareTargetWrite registered now permit sink expected observation = do
  projection <- observedProjection observation
  validateProjection registered projection
  validateRegisteredSink registered sink
  validateCurrentPrepared now permit expected projection
  unless
    (targetSecretSinkIdentity sink == targetCommitTargetIdentity expected)
    ( Left
        ( TargetCommitIntentTargetMismatch
            (targetCommitTargetIdentity expected)
            (targetSecretSinkIdentity sink)
        )
    )
  pure
    PreparedTargetWritePermit
      { internalPreparedTargetWriteIntent = expected
      , internalPreparedTargetWriteSink = sink
      }

data TargetSinkRecord payload = TargetSinkRecord
  { targetSinkRecordOwnerNonce :: !OwnerNonce
  , targetSinkRecordFencingToken :: !FencingToken
  , targetSinkRecordGeneration :: !CredentialGeneration
  , targetSinkRecordDigest :: !TargetValueDigest
  , targetSinkRecordPayload :: !payload
  }
  deriving (Eq, Show)

data TargetSinkObservation payload
  = TargetSinkMissing
  | TargetSinkObserved !TargetSinkVersion !(TargetSinkRecord payload)
  | TargetSinkRetired
  | TargetSinkUnobservable !Text
  | TargetSinkUnbounded !Natural !Natural
  | TargetSinkChanging !Text
  deriving (Eq, Show)

data TargetSinkCasRequest payload
  = TargetSinkInitialize
      !TargetClusterSecretSink
      !(TargetSinkRecord payload)
  | TargetSinkReplace
      !TargetClusterSecretSink
      !TargetSinkVersion
      !(TargetSinkRecord payload)
  deriving (Eq, Show)

data TargetSinkCasResult payload
  = TargetSinkCasApplied !TargetSinkVersion !(TargetSinkRecord payload)
  | TargetSinkCasConflict !(TargetSinkObservation payload)
  | TargetSinkCasRefused !Text
  | TargetSinkCasUnobservable !Text
  deriving (Eq, Show)

-- | Injected bounded target authority. The adapter performs one CAS per
-- request and never converts a transport/auth/decode failure to absence.
data TargetSinkCasAdapter m payload = TargetSinkCasAdapter
  { targetSinkObserve
      :: TargetClusterSecretSink
      -> m (TargetSinkObservation payload)
  , targetSinkCompareAndSwap
      :: TargetSinkCasRequest payload
      -> m (TargetSinkCasResult payload)
  }

data TargetSinkWriteDecision payload
  = TargetSinkWriteCompareAndSwap !(TargetSinkCasRequest payload)
  | TargetSinkWriteAlreadyApplied
  | TargetSinkWriteRefused !TargetSinkReadbackRefusal
  deriving (Eq, Show)

data TargetSinkReadbackRefusal
  = TargetSinkPayloadDigestMismatch !TargetValueDigest !TargetValueDigest
  | TargetSinkReadbackMissing
  | TargetSinkReadbackRetired
  | TargetSinkReadbackUnobservable !Text
  | TargetSinkReadbackUnbounded !Natural !Natural
  | TargetSinkReadbackChanging !Text
  | TargetSinkReadbackValueMismatch
  | TargetSinkGenerationNewer !CredentialGeneration !CredentialGeneration
  | TargetSinkGenerationCollision !CredentialGeneration
  | TargetSinkStableSampleCountMismatch !Int !Int
  | TargetSinkObservationBeforeGrace !AuthorityTime !AuthorityTime
  | TargetSinkObservationsTooClose !AuthorityTime !AuthorityTime !AuthorityDuration
  | TargetSinkStableStateChanged
  | TargetSinkRecoveryIntentNotPrepared !TargetCommitDisposition
  | TargetSinkRecoveryTargetUnregistered !Text
  deriving (Eq, Show)

decideTargetSinkWrite
  :: (payload -> TargetValueDigest)
  -> PreparedTargetWritePermit
  -> payload
  -> TargetSinkObservation payload
  -> TargetSinkWriteDecision payload
decideTargetSinkWrite digestPayload permit payload observation
  | actualDigest /= expectedDigest =
      TargetSinkWriteRefused
        (TargetSinkPayloadDigestMismatch expectedDigest actualDigest)
  | otherwise = case observation of
      TargetSinkMissing ->
        TargetSinkWriteCompareAndSwap
          (TargetSinkInitialize sink expectedRecord)
      TargetSinkObserved version current
        | recordMatchesIntent digestPayload intent current -> TargetSinkWriteAlreadyApplied
        | targetSinkRecordGeneration current > targetCommitGeneration intent ->
            TargetSinkWriteRefused
              ( TargetSinkGenerationNewer
                  (targetSinkRecordGeneration current)
                  (targetCommitGeneration intent)
              )
        | targetSinkRecordGeneration current == targetCommitGeneration intent ->
            TargetSinkWriteRefused
              (TargetSinkGenerationCollision (targetCommitGeneration intent))
        | otherwise ->
            TargetSinkWriteCompareAndSwap
              (TargetSinkReplace sink version expectedRecord)
      TargetSinkRetired -> TargetSinkWriteRefused TargetSinkReadbackRetired
      TargetSinkUnobservable detail ->
        TargetSinkWriteRefused (TargetSinkReadbackUnobservable detail)
      TargetSinkUnbounded actual maximumCardinality ->
        TargetSinkWriteRefused
          (TargetSinkReadbackUnbounded actual maximumCardinality)
      TargetSinkChanging detail ->
        TargetSinkWriteRefused (TargetSinkReadbackChanging detail)
 where
  intent = internalPreparedTargetWriteIntent permit
  sink = internalPreparedTargetWriteSink permit
  expectedDigest = targetCommitDigest intent
  actualDigest = digestPayload payload
  expectedRecord = recordForIntent intent payload

data TargetSinkReadback payload = TargetSinkReadback
  { internalTargetSinkReadbackIntent :: !TargetCommitIntent
  , internalTargetSinkReadbackRecord :: !(TargetSinkRecord payload)
  }
  deriving (Eq, Show)

confirmTargetSinkReadback
  :: (payload -> TargetValueDigest)
  -> PreparedTargetWritePermit
  -> TargetSinkObservation payload
  -> Either TargetSinkReadbackRefusal (TargetSinkReadback payload)
confirmTargetSinkReadback digestPayload permit observation =
  case observation of
    TargetSinkMissing -> Left TargetSinkReadbackMissing
    TargetSinkRetired -> Left TargetSinkReadbackRetired
    TargetSinkUnobservable detail -> Left (TargetSinkReadbackUnobservable detail)
    TargetSinkUnbounded actual maximumCardinality ->
      Left (TargetSinkReadbackUnbounded actual maximumCardinality)
    TargetSinkChanging detail -> Left (TargetSinkReadbackChanging detail)
    TargetSinkObserved _ record
      | recordMatchesIntent digestPayload intent record ->
          Right
            TargetSinkReadback
              { internalTargetSinkReadbackIntent = intent
              , internalTargetSinkReadbackRecord = record
              }
      | otherwise -> Left TargetSinkReadbackValueMismatch
 where
  intent = internalPreparedTargetWriteIntent permit

data TargetCommitCompleteDecision
  = TargetCommitCompleteCompareAndSwap !(ModelBCasRequest 'ClusterRetained TargetIntentProjection)
  | TargetCommitCompleteAlreadyApplied
  | TargetCommitCompleteRefused !TargetCommitRefusal
  deriving (Eq, Show)

decideCompleteTargetCommit
  :: RegisteredTargetSet
  -> TargetIntentCoordinate
  -> AuthorityTime
  -> FencedCommitPermit
  -> TargetSinkReadback payload
  -> ModelBObservation TargetIntentProjection
  -> TargetCommitCompleteDecision
decideCompleteTargetCommit registered coordinate now permit readback observation =
  case observedProjection observation of
    Left refusal -> TargetCommitCompleteRefused refusal
    Right projection ->
      case validateProjection registered projection of
        Left refusal -> TargetCommitCompleteRefused refusal
        Right () ->
          let expected = internalTargetSinkReadbackIntent readback
              identity = targetCommitTargetIdentity expected
           in case Map.lookup identity (internalTargetProjectionEntries projection) of
                Just entry -> case targetProjectionEntryIntent entry of
                  Just current
                    | current == expected ->
                        case validateCurrentPrepared now permit expected projection of
                          Left refusal -> TargetCommitCompleteRefused refusal
                          Right () ->
                            let committedIntent =
                                  current
                                    { internalTargetCommitDisposition = TargetCommitCommitted
                                    }
                                nextEntry =
                                  entry
                                    { internalTargetProjectionEntryIntent = Just committedIntent
                                    }
                                nextProjection =
                                  projection
                                    { internalTargetProjectionEntries =
                                        Map.insert
                                          identity
                                          nextEntry
                                          (internalTargetProjectionEntries projection)
                                    }
                             in case observation of
                                  ModelBObserved version _ ->
                                    TargetCommitCompleteCompareAndSwap
                                      ( ModelBReplaceGuarded
                                          (targetIntentCoordinateObject coordinate)
                                          version
                                          ( modelBLeaseGuardFromPermit
                                              (targetIntentCoordinateLeaseObject coordinate)
                                              permit
                                          )
                                          nextProjection
                                      )
                                  _ -> TargetCommitCompleteRefused TargetCommitGlobalMissingAfterPrepare
                  Just current
                    | targetCommitDisposition current == TargetCommitCommitted
                        && sameIntentCoordinates expected current ->
                        TargetCommitCompleteAlreadyApplied
                  current ->
                    TargetCommitCompleteRefused
                      (TargetCommitExpectedIntentChanged expected current)
                Nothing ->
                  TargetCommitCompleteRefused (TargetCommitExpectedIntentMissing identity)

data TimedTargetSinkObservation payload = TimedTargetSinkObservation
  { timedTargetSinkObservedAt :: !AuthorityTime
  , timedTargetSinkObservation :: !(TargetSinkObservation payload)
  }
  deriving (Eq, Show)

data TargetRecoveryOutcome
  = TargetRecoveryObservedExact
  | TargetRecoveryObservedAbsent
  | TargetRecoveryObservedDifferent
  | TargetRecoveryAuthoritativelyRetired
  deriving (Eq, Show)

data StableTargetReadback = StableTargetReadback
  { internalStableTargetReadbackIntent :: !TargetCommitIntent
  , internalStableTargetReadbackOutcome :: !TargetRecoveryOutcome
  , internalStableTargetReadbackObservedThrough :: !AuthorityTime
  }
  deriving (Eq, Show)

stableTargetReadbackIntent :: StableTargetReadback -> TargetCommitIntent
stableTargetReadbackIntent = internalStableTargetReadbackIntent

stableTargetReadbackOutcome :: StableTargetReadback -> TargetRecoveryOutcome
stableTargetReadbackOutcome = internalStableTargetReadbackOutcome

proveStableTargetReadback
  :: (Eq payload)
  => (payload -> TargetValueDigest)
  -> RegisteredTargetSet
  -> LeasePolicy
  -> LeaseGrant
  -> TargetCommitIntent
  -> [TimedTargetSinkObservation payload]
  -> Either TargetSinkReadbackRefusal StableTargetReadback
proveStableTargetReadback digestPayload registered policy predecessor intent samples = do
  proveStableTargetReadbackAfter
    (successorNotBefore policy predecessor)
    digestPayload
    registered
    policy
    intent
    samples

-- | Recovery proof at an already validated lease recovery boundary.  A
-- voluntary-release tombstone anchors this boundary at release time rather
-- than at the original grant expiry; expired active grants use the latter.
proveStableTargetReadbackAfter
  :: (Eq payload)
  => AuthorityTime
  -> (payload -> TargetValueDigest)
  -> RegisteredTargetSet
  -> LeasePolicy
  -> TargetCommitIntent
  -> [TimedTargetSinkObservation payload]
  -> Either TargetSinkReadbackRefusal StableTargetReadback
proveStableTargetReadbackAfter notBefore digestPayload registered policy intent samples = do
  unless
    (targetCommitDisposition intent == TargetCommitPrepared)
    (Left (TargetSinkRecoveryIntentNotPrepared (targetCommitDisposition intent)))
  unless
    (Map.member (targetCommitTargetIdentity intent) (internalRegisteredTargets registered))
    (Left (TargetSinkRecoveryTargetUnregistered (targetCommitTargetIdentity intent)))
  let required = leasePolicyStableObservationCount policy
      actual = length samples
  unless
    (actual == required)
    (Left (TargetSinkStableSampleCountMismatch required actual))
  mapM_ (validateSampleTime notBefore) samples
  validateTargetIntervals
    (leasePolicyProviderVisibilityGrace policy)
    (map timedTargetSinkObservedAt samples)
  case samples of
    [] -> Left (TargetSinkStableSampleCountMismatch required actual)
    firstSample : remaining -> do
      unless
        (all ((== timedTargetSinkObservation firstSample) . timedTargetSinkObservation) remaining)
        (Left TargetSinkStableStateChanged)
      outcome <- classifyRecoveryObservation digestPayload intent (timedTargetSinkObservation firstSample)
      pure
        StableTargetReadback
          { internalStableTargetReadbackIntent = intent
          , internalStableTargetReadbackOutcome = outcome
          , internalStableTargetReadbackObservedThrough = timedTargetSinkObservedAt (last samples)
          }

data TargetRecoveryDecision
  = TargetRecoveryCompareAndSwap !(ModelBCasRequest 'ClusterRetained TargetIntentProjection)
  | TargetRecoveryAlreadyResolved
  | TargetRecoveryRefused !TargetCommitRefusal
  deriving (Eq, Show)

decideResolveOutstandingTargets
  :: RegisteredTargetSet
  -> TargetIntentCoordinate
  -> FencedCommitPermit
  -> [StableTargetReadback]
  -> ModelBObservation TargetIntentProjection
  -> TargetRecoveryDecision
decideResolveOutstandingTargets registered coordinate successorPermit witnesses observation =
  case observation of
    ModelBMissing -> TargetRecoveryRefused TargetCommitGlobalMissingAfterPrepare
    ModelBCorrupt detail -> TargetRecoveryRefused (TargetCommitGlobalCorrupt detail)
    ModelBUnobservable detail -> TargetRecoveryRefused (TargetCommitGlobalUnobservable detail)
    ModelBObserved version projection ->
      case validateProjection registered projection of
        Left refusal -> TargetRecoveryRefused refusal
        Right () ->
          let prepared = preparedIntents projection
           in if null prepared
                then case witnesses of
                  [] -> TargetRecoveryAlreadyResolved
                  witness : _ ->
                    TargetRecoveryRefused
                      ( TargetCommitRecoveryWitnessUnexpected
                          (targetCommitTargetIdentity (stableTargetReadbackIntent witness))
                      )
                else case matchRecoveryWitnesses prepared witnesses of
                  Left refusal -> TargetRecoveryRefused refusal
                  Right matched ->
                    case validateSuccessorFence successorPermit prepared of
                      Left refusal -> TargetRecoveryRefused refusal
                      Right () ->
                        let nextProjection = foldl' applyRecovery projection matched
                         in TargetRecoveryCompareAndSwap
                              ( ModelBReplaceGuarded
                                  (targetIntentCoordinateObject coordinate)
                                  version
                                  ( modelBLeaseGuardFromPermit
                                      (targetIntentCoordinateLeaseObject coordinate)
                                      successorPermit
                                  )
                                  nextProjection
                              )

data TargetIntentCompactDecision
  = TargetIntentCompactCompareAndSwap !(ModelBCasRequest 'ClusterRetained TargetIntentProjection)
  | TargetIntentCompactAlreadyApplied
  | TargetIntentCompactRefused !TargetCommitRefusal
  deriving (Eq, Show)

compactTargetIntent
  :: RegisteredTargetSet
  -> TargetIntentCoordinate
  -> FencedCommitPermit
  -> Text
  -> ModelBObservation TargetIntentProjection
  -> TargetIntentCompactDecision
compactTargetIntent registered coordinate permit identity observation
  | not (Map.member identity (internalRegisteredTargets registered)) =
      TargetIntentCompactRefused (TargetCommitUnregisteredTarget identity)
  | otherwise = case observation of
      ModelBMissing -> TargetIntentCompactAlreadyApplied
      ModelBCorrupt detail -> TargetIntentCompactRefused (TargetCommitGlobalCorrupt detail)
      ModelBUnobservable detail ->
        TargetIntentCompactRefused (TargetCommitGlobalUnobservable detail)
      ModelBObserved version projection ->
        case validateProjection registered projection of
          Left refusal -> TargetIntentCompactRefused refusal
          Right () -> case Map.lookup identity (internalTargetProjectionEntries projection) of
            Nothing -> TargetIntentCompactAlreadyApplied
            Just entry -> case targetProjectionEntryIntent entry of
              Nothing -> TargetIntentCompactAlreadyApplied
              Just intent -> case targetCommitDisposition intent of
                TargetCommitPrepared ->
                  TargetIntentCompactRefused
                    (TargetCommitOutstandingIntent identity (targetCommitFencingToken intent))
                TargetCommitCommitted ->
                  let compacted =
                        entry
                          { internalTargetProjectionEntryCommitted =
                              Just
                                CommittedTargetValue
                                  { internalCommittedTargetGeneration = targetCommitGeneration intent
                                  , internalCommittedTargetDigest = targetCommitDigest intent
                                  }
                          , internalTargetProjectionEntryIntent = Nothing
                          }
                   in TargetIntentCompactCompareAndSwap
                        ( ModelBReplaceGuarded
                            (targetIntentCoordinateObject coordinate)
                            version
                            ( modelBLeaseGuardFromPermit
                                (targetIntentCoordinateLeaseObject coordinate)
                                permit
                            )
                            projection
                              { internalTargetProjectionEntries =
                                  Map.insert identity compacted (internalTargetProjectionEntries projection)
                              }
                        )
                TargetCommitAborted ->
                  let entries =
                        case targetProjectionEntryCommitted entry of
                          Nothing -> Map.delete identity (internalTargetProjectionEntries projection)
                          Just _ ->
                            Map.insert
                              identity
                              entry {internalTargetProjectionEntryIntent = Nothing}
                              (internalTargetProjectionEntries projection)
                   in TargetIntentCompactCompareAndSwap
                        ( ModelBReplaceGuarded
                            (targetIntentCoordinateObject coordinate)
                            version
                            ( modelBLeaseGuardFromPermit
                                (targetIntentCoordinateLeaseObject coordinate)
                                permit
                            )
                            projection {internalTargetProjectionEntries = entries}
                        )

validateProjection
  :: RegisteredTargetSet
  -> TargetIntentProjection
  -> Either TargetCommitRefusal ()
validateProjection registered projection = do
  let expected = Map.keysSet (internalRegisteredTargets registered)
      actual = internalTargetProjectionRegisteredIdentities projection
  unless
    (actual == expected)
    ( Left
        ( TargetCommitProjectionRegistrationMismatch
            (sort (Set.toList expected))
            (sort (Set.toList actual))
        )
    )
  let entries = internalTargetProjectionEntries projection
  when
    (Map.size entries > registeredTargetCapacity registered)
    ( Left
        ( TargetCommitProjectionOverBound
            (Map.size entries)
            (registeredTargetCapacity registered)
        )
    )
  mapM_ validateEntry (Map.toList entries)
 where
  validateEntry (key, entry) = do
    unless
      (key == targetProjectionEntryTargetIdentity entry)
      (Left (TargetCommitProjectionKeyMismatch key (targetProjectionEntryTargetIdentity entry)))
    unless
      (Map.member key (internalRegisteredTargets registered))
      (Left (TargetCommitUnregisteredTarget key))
    case targetProjectionEntryIntent entry of
      Nothing -> Right ()
      Just intent ->
        unless
          (targetCommitTargetIdentity intent == key)
          ( Left
              ( TargetCommitIntentTargetMismatch
                  key
                  (targetCommitTargetIdentity intent)
              )
          )

validateRegisteredSink
  :: RegisteredTargetSet
  -> TargetClusterSecretSink
  -> Either TargetCommitRefusal ()
validateRegisteredSink registered sink =
  unless
    (Map.lookup identity (internalRegisteredTargets registered) == Just sink)
    (Left (TargetCommitUnregisteredTarget identity))
 where
  identity = targetSecretSinkIdentity sink

validateCurrentPrepared
  :: AuthorityTime
  -> FencedCommitPermit
  -> TargetCommitIntent
  -> TargetIntentProjection
  -> Either TargetCommitRefusal ()
validateCurrentPrepared now permit expected projection = do
  when
    (now >= targetCommitDeadline expected)
    (Left (TargetCommitDeadlineReached now (targetCommitDeadline expected)))
  unless
    (fencedCommitOwnerNonce permit == targetCommitOwnerNonce expected)
    ( Left
        ( TargetCommitPermitOwnerMismatch
            (targetCommitOwnerNonce expected)
            (fencedCommitOwnerNonce permit)
        )
    )
  unless
    (fencedCommitFencingToken permit == targetCommitFencingToken expected)
    ( Left
        ( TargetCommitPermitFenceMismatch
            (targetCommitFencingToken expected)
            (fencedCommitFencingToken permit)
        )
    )
  let current =
        Map.lookup
          (targetCommitTargetIdentity expected)
          (internalTargetProjectionEntries projection)
          >>= targetProjectionEntryIntent
  unless
    (current == Just expected && targetCommitDisposition expected == TargetCommitPrepared)
    ( Left
        ( TargetCommitExpectedIntentChanged
            expected
            current
        )
    )

observedProjection
  :: ModelBObservation TargetIntentProjection
  -> Either TargetCommitRefusal TargetIntentProjection
observedProjection observation = case observation of
  ModelBMissing -> Left TargetCommitGlobalMissingAfterPrepare
  ModelBCorrupt detail -> Left (TargetCommitGlobalCorrupt detail)
  ModelBUnobservable detail -> Left (TargetCommitGlobalUnobservable detail)
  ModelBObserved _ projection -> Right projection

recordForIntent :: TargetCommitIntent -> payload -> TargetSinkRecord payload
recordForIntent intent payload =
  TargetSinkRecord
    { targetSinkRecordOwnerNonce = targetCommitOwnerNonce intent
    , targetSinkRecordFencingToken = targetCommitFencingToken intent
    , targetSinkRecordGeneration = targetCommitGeneration intent
    , targetSinkRecordDigest = targetCommitDigest intent
    , targetSinkRecordPayload = payload
    }

recordMatchesIntent
  :: (payload -> TargetValueDigest)
  -> TargetCommitIntent
  -> TargetSinkRecord payload
  -> Bool
recordMatchesIntent digestPayload intent record =
  targetSinkRecordOwnerNonce record == targetCommitOwnerNonce intent
    && targetSinkRecordFencingToken record == targetCommitFencingToken intent
    && targetSinkRecordGeneration record == targetCommitGeneration intent
    && targetSinkRecordDigest record == targetCommitDigest intent
    && digestPayload (targetSinkRecordPayload record) == targetCommitDigest intent

sameIntentCoordinates :: TargetCommitIntent -> TargetCommitIntent -> Bool
sameIntentCoordinates left right =
  targetCommitOwnerNonce left == targetCommitOwnerNonce right
    && targetCommitFencingToken left == targetCommitFencingToken right
    && targetCommitTargetIdentity left == targetCommitTargetIdentity right
    && targetCommitGeneration left == targetCommitGeneration right
    && targetCommitDigest left == targetCommitDigest right
    && targetCommitDeadline left == targetCommitDeadline right

validateSampleTime
  :: AuthorityTime
  -> TimedTargetSinkObservation payload
  -> Either TargetSinkReadbackRefusal ()
validateSampleTime notBefore sample =
  when
    (timedTargetSinkObservedAt sample < notBefore)
    ( Left
        ( TargetSinkObservationBeforeGrace
            (timedTargetSinkObservedAt sample)
            notBefore
        )
    )

validateTargetIntervals
  :: AuthorityDuration
  -> [AuthorityTime]
  -> Either TargetSinkReadbackRefusal ()
validateTargetIntervals visibility times = case times of
  earlier : later : rest
    | later < addAuthorityDuration earlier visibility ->
        Left (TargetSinkObservationsTooClose earlier later visibility)
    | otherwise -> validateTargetIntervals visibility (later : rest)
  _ -> Right ()

classifyRecoveryObservation
  :: (payload -> TargetValueDigest)
  -> TargetCommitIntent
  -> TargetSinkObservation payload
  -> Either TargetSinkReadbackRefusal TargetRecoveryOutcome
classifyRecoveryObservation digestPayload intent observation = case observation of
  TargetSinkMissing -> Right TargetRecoveryObservedAbsent
  TargetSinkRetired -> Right TargetRecoveryAuthoritativelyRetired
  TargetSinkUnobservable detail -> Left (TargetSinkReadbackUnobservable detail)
  TargetSinkUnbounded actual maximumCardinality ->
    Left (TargetSinkReadbackUnbounded actual maximumCardinality)
  TargetSinkChanging detail -> Left (TargetSinkReadbackChanging detail)
  TargetSinkObserved _ record
    | recordMatchesIntent digestPayload intent record -> Right TargetRecoveryObservedExact
    | otherwise -> Right TargetRecoveryObservedDifferent

preparedIntents :: TargetIntentProjection -> [TargetCommitIntent]
preparedIntents projection =
  [ intent
  | entry <- targetProjectionEntries projection
  , Just intent <- [targetProjectionEntryIntent entry]
  , targetCommitDisposition intent == TargetCommitPrepared
  ]

matchRecoveryWitnesses
  :: [TargetCommitIntent]
  -> [StableTargetReadback]
  -> Either TargetCommitRefusal [(TargetCommitIntent, StableTargetReadback)]
matchRecoveryWitnesses intents witnesses = do
  witnessMap <- foldl' insertWitness (Right Map.empty) witnesses
  mapM_ ensureExpected (Map.keys witnessMap)
  mapM (matchOne witnessMap) intents
 where
  intended = Set.fromList (map targetCommitTargetIdentity intents)

  insertWitness result witness = do
    indexed <- result
    let identity = targetCommitTargetIdentity (stableTargetReadbackIntent witness)
    if Map.member identity indexed
      then Left (TargetCommitRecoveryWitnessUnexpected identity)
      else Right (Map.insert identity witness indexed)

  ensureExpected identity =
    unless
      (Set.member identity intended)
      (Left (TargetCommitRecoveryWitnessUnexpected identity))

  matchOne indexed intent =
    case Map.lookup (targetCommitTargetIdentity intent) indexed of
      Nothing -> Left (TargetCommitRecoveryWitnessMissing (targetCommitTargetIdentity intent))
      Just witness
        | stableTargetReadbackIntent witness /= intent ->
            Left (TargetCommitRecoveryWitnessIntentMismatch (targetCommitTargetIdentity intent))
        | otherwise -> Right (intent, witness)

validateSuccessorFence
  :: FencedCommitPermit
  -> [TargetCommitIntent]
  -> Either TargetCommitRefusal ()
validateSuccessorFence successorPermit =
  mapM_ $ \intent ->
    unless
      ( fencingTokenValue (fencedCommitFencingToken successorPermit)
          > fencingTokenValue (targetCommitFencingToken intent)
      )
      ( Left
          ( TargetCommitRecoveryFenceNotNewer
              (targetCommitFencingToken intent)
              (fencedCommitFencingToken successorPermit)
          )
      )

applyRecovery
  :: TargetIntentProjection
  -> (TargetCommitIntent, StableTargetReadback)
  -> TargetIntentProjection
applyRecovery projection (intent, witness) =
  projection {internalTargetProjectionEntries = nextEntries}
 where
  identity = targetCommitTargetIdentity intent
  entries = internalTargetProjectionEntries projection
  nextEntries = case stableTargetReadbackOutcome witness of
    TargetRecoveryAuthoritativelyRetired -> Map.delete identity entries
    outcome ->
      Map.adjust
        ( \entry ->
            entry
              { internalTargetProjectionEntryIntent =
                  Just
                    intent
                      { internalTargetCommitDisposition = case outcome of
                          TargetRecoveryObservedExact -> TargetCommitCommitted
                          TargetRecoveryObservedAbsent -> TargetCommitAborted
                          TargetRecoveryObservedDifferent -> TargetCommitAborted
                      }
              }
        )
        identity
        entries
