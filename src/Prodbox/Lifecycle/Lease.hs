{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure bounded lease, fencing, and provider-quiescence policy for
-- account-scoped desired-present reconciliation.
--
-- Authority time is supplied by the retained Model-B authority.  No function
-- in this module reads a process clock, renews a grant, or treats an
-- in-process CAS plan as an externally established fact.
module Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , AwsSessionDeadline
  , FencedCommitPermit
  , FencingToken
  , LeaseAcquireDecision (..)
  , LeaseAcquireRequest
  , LeaseCommitDecision (..)
  , LeaseGrant
  , LeaseIdentityError (..)
  , LeaseKey
  , LeaseOwnershipStatus (..)
  , LeasePolicy
  , LeasePolicyError (..)
  , LeasePolicyField (..)
  , LeaseProjection
  , LeaseProjectionCodecError (..)
  , LeaseProjectionError (..)
  , LeaseRefusal (..)
  , LeaseReleaseDecision (..)
  , LeaseRecoveryPredecessor
  , LeaseUseDecision (..)
  , LeaseUsePermit
  , LeaseValueError (..)
  , LeaseWork (..)
  , OwnerNonce
  , ProviderObservation (..)
  , QuiescenceRefusal (..)
  , RawLeasePolicy (..)
  , StableQuiescenceWitness
  , TimedProviderObservation (..)
  , authorityDurationFromMicros
  , authorityDurationMicros
  , addAuthorityDuration
  , authorityTimeFromMicros
  , authorityTimeMicros
  , authorizeLeaseWork
  , awsSessionExpiresAt
  , beginLeaseAcquire
  , confirmLeaseAcquired
  , decideFencedCommit
  , decideLeaseAcquire
  , decideLeaseRelease
  , decodeLeaseProjection
  , defaultSesLeasePolicy
  , deriveAwsSessionDeadline
  , encodeLeaseProjection
  , fencedCommitExpectedLeaseVersion
  , fencedCommitFencingToken
  , fencedCommitOwnerNonce
  , fencingTokenValue
  , leaseAcquireDeadline
  , leaseAcquireCoordinate
  , leaseAcquireOwnerNonce
  , leaseGrantExpiresAt
  , leaseGrantFencingToken
  , leaseGrantIssuedAt
  , leaseGrantKey
  , leaseGrantOwnerNonce
  , leaseGrantSafeUseDeadline
  , leaseKeyAccount
  , leaseKeyRegion
  , leaseKeyResource
  , leaseLogicalName
  , leaseObjectCoordinate
  , leaseOwnershipStatus
  , leasePolicyAcquireTimeout
  , leasePolicyCancellationGrace
  , leasePolicyClockSkew
  , leasePolicyGrantTtl
  , leasePolicyProviderInFlightGrace
  , leasePolicyProviderVisibilityGrace
  , leasePolicyReadinessBudget
  , leasePolicyReconcileBudget
  , leasePolicySafetyMargin
  , leasePolicySmtpCommitBudget
  , leasePolicyStableObservationCount
  , leasePolicyTargetWriteGrace
  , leaseProjectionActiveGrant
  , leaseProjectionLastFencingToken
  , leaseProjectionReleasedPredecessor
  , leaseProjectionReleasedAt
  , leaseProjectionRecoveryPredecessor
  , leaseRecoveryGrant
  , leaseRecoveryNotBefore
  , leaseProjectionMaximumEncodedBytes
  , leaseUseDeadline
  , leaseUseFencingToken
  , leaseUseOwnerNonce
  , mkFencingToken
  , mkLeaseGrant
  , mkLeaseKey
  , mkLeasePolicy
  , mkLeaseProjection
  , modelBLeaseGuardFromPermit
  , mkOwnerNonce
  , ownerNonceText
  , proveStableProviderQuiescence
  , proveStableProviderQuiescenceFor
  , stableQuiescenceInventory
  , stableQuiescenceObservedThrough
  , successorNotBefore
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasRequest (..)
  , ModelBLeaseGuard (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , modelBObjectLogicalName
  )

newtype AuthorityTime = AuthorityTime
  { internalAuthorityTimeMicros :: Natural
  }
  deriving (Eq, Ord, Show)

-- | A strictly positive authority-clock duration.
newtype AuthorityDuration = AuthorityDuration
  { internalAuthorityDurationMicros :: Natural
  }
  deriving (Eq, Ord, Show)

data LeaseValueError
  = AuthorityDurationMustBePositive
  | FencingTokenMustBePositive
  deriving (Eq, Show)

authorityTimeFromMicros :: Natural -> AuthorityTime
authorityTimeFromMicros = AuthorityTime

authorityTimeMicros :: AuthorityTime -> Natural
authorityTimeMicros = internalAuthorityTimeMicros

authorityDurationFromMicros
  :: Natural -> Either LeaseValueError AuthorityDuration
authorityDurationFromMicros value
  | value == 0 = Left AuthorityDurationMustBePositive
  | otherwise = Right (AuthorityDuration value)

authorityDurationMicros :: AuthorityDuration -> Natural
authorityDurationMicros = internalAuthorityDurationMicros

-- | Advance an authority-clock timestamp without converting through a process
-- wall clock. 'Natural' arithmetic makes the operation non-wrapping.
addAuthorityDuration :: AuthorityTime -> AuthorityDuration -> AuthorityTime
addAuthorityDuration = addDuration

newtype OwnerNonce = OwnerNonce
  { internalOwnerNonceText :: Text
  }
  deriving (Eq, Ord, Show)

newtype FencingToken = FencingToken
  { internalFencingTokenValue :: Natural
  }
  deriving (Eq, Ord, Show)

data LeaseIdentityError
  = LeaseIdentityEmpty !Text
  | LeaseIdentityTooLong !Text !Int !Int
  | LeaseIdentityContainsUnsafeCharacter !Text !Char
  deriving (Eq, Show)

mkOwnerNonce :: Text -> Either LeaseIdentityError OwnerNonce
mkOwnerNonce raw =
  OwnerNonce <$> validateIdentity "owner_nonce" 128 raw

ownerNonceText :: OwnerNonce -> Text
ownerNonceText = internalOwnerNonceText

mkFencingToken :: Natural -> Either LeaseValueError FencingToken
mkFencingToken value
  | value == 0 = Left FencingTokenMustBePositive
  | otherwise = Right (FencingToken value)

fencingTokenValue :: FencingToken -> Natural
fencingTokenValue = internalFencingTokenValue

data LeaseKey = LeaseKey
  { internalLeaseKeyAccount :: !Text
  , internalLeaseKeyRegion :: !Text
  , internalLeaseKeyResource :: !Text
  }
  deriving (Eq, Ord, Show)

mkLeaseKey
  :: Text -> Text -> Text -> Either LeaseIdentityError LeaseKey
mkLeaseKey account region resource =
  LeaseKey
    <$> validateIdentity "account" 128 account
    <*> validateIdentity "region" 64 region
    <*> validateIdentity "resource" 128 resource

leaseKeyAccount :: LeaseKey -> Text
leaseKeyAccount = internalLeaseKeyAccount

leaseKeyRegion :: LeaseKey -> Text
leaseKeyRegion = internalLeaseKeyRegion

leaseKeyResource :: LeaseKey -> Text
leaseKeyResource = internalLeaseKeyResource

leaseObjectCoordinate
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'ClusterRetained)
leaseObjectCoordinate authority key =
  mkClusterRetainedCoordinate authority (leaseLogicalName key)

leaseLogicalName :: LeaseKey -> Text
leaseLogicalName key =
  Text.intercalate
    "/"
    [ "leases"
    , leaseKeyAccount key
    , leaseKeyRegion key
    , leaseKeyResource key
    ]

data LeasePolicyField
  = LeaseAcquireTimeoutField
  | LeaseGrantTtlField
  | LeaseReconcileBudgetField
  | LeaseReadinessBudgetField
  | LeaseSmtpCommitBudgetField
  | LeaseCancellationGraceField
  | LeaseClockSkewField
  | LeaseSafetyMarginField
  | LeaseProviderInFlightGraceField
  | LeaseProviderVisibilityGraceField
  | LeaseTargetWriteGraceField
  deriving (Bounded, Enum, Eq, Show)

data RawLeasePolicy = RawLeasePolicy
  { rawLeaseAcquireTimeoutMicros :: !Natural
  , rawLeaseGrantTtlMicros :: !Natural
  , rawLeaseReconcileBudgetMicros :: !Natural
  , rawLeaseReadinessBudgetMicros :: !Natural
  , rawLeaseSmtpCommitBudgetMicros :: !Natural
  , rawLeaseCancellationGraceMicros :: !Natural
  , rawLeaseClockSkewMicros :: !Natural
  , rawLeaseSafetyMarginMicros :: !Natural
  , rawLeaseProviderInFlightGraceMicros :: !Natural
  , rawLeaseProviderVisibilityGraceMicros :: !Natural
  , rawLeaseTargetWriteGraceMicros :: !Natural
  , rawLeaseStableObservationCount :: !Natural
  }
  deriving (Eq, Show)

data LeasePolicyError
  = LeasePolicyFieldMustBePositive !LeasePolicyField
  | LeasePolicyGrantDoesNotOutliveTransaction
      { leasePolicyRequiredTransactionMicros :: !Natural
      , leasePolicyConfiguredGrantMicros :: !Natural
      }
  | LeasePolicyStableObservationCountTooSmall !Natural
  | LeasePolicyStableObservationCountExceedsInt !Natural
  deriving (Eq, Show)

data LeasePolicy = LeasePolicy
  { internalLeasePolicyAcquireTimeout :: !AuthorityDuration
  , internalLeasePolicyGrantTtl :: !AuthorityDuration
  , internalLeasePolicyReconcileBudget :: !AuthorityDuration
  , internalLeasePolicyReadinessBudget :: !AuthorityDuration
  , internalLeasePolicySmtpCommitBudget :: !AuthorityDuration
  , internalLeasePolicyCancellationGrace :: !AuthorityDuration
  , internalLeasePolicyClockSkew :: !AuthorityDuration
  , internalLeasePolicySafetyMargin :: !AuthorityDuration
  , internalLeasePolicyProviderInFlightGrace :: !AuthorityDuration
  , internalLeasePolicyProviderVisibilityGrace :: !AuthorityDuration
  , internalLeasePolicyTargetWriteGrace :: !AuthorityDuration
  , internalLeasePolicyStableObservationCount :: !Int
  }
  deriving (Eq, Show)

mkLeasePolicy :: RawLeasePolicy -> Either LeasePolicyError LeasePolicy
mkLeasePolicy raw = do
  mapM_ validatePositive (rawPolicyFields raw)
  when
    (rawLeaseStableObservationCount raw < 2)
    (Left (LeasePolicyStableObservationCountTooSmall (rawLeaseStableObservationCount raw)))
  when
    (rawLeaseStableObservationCount raw > fromIntegral (maxBound :: Int))
    (Left (LeasePolicyStableObservationCountExceedsInt (rawLeaseStableObservationCount raw)))
  let required = rawTransactionBudget raw
      configured = rawLeaseGrantTtlMicros raw
  unless
    (configured > required)
    ( Left
        LeasePolicyGrantDoesNotOutliveTransaction
          { leasePolicyRequiredTransactionMicros = required
          , leasePolicyConfiguredGrantMicros = configured
          }
    )
  pure
    LeasePolicy
      { internalLeasePolicyAcquireTimeout = durationUnsafe (rawLeaseAcquireTimeoutMicros raw)
      , internalLeasePolicyGrantTtl = durationUnsafe (rawLeaseGrantTtlMicros raw)
      , internalLeasePolicyReconcileBudget = durationUnsafe (rawLeaseReconcileBudgetMicros raw)
      , internalLeasePolicyReadinessBudget = durationUnsafe (rawLeaseReadinessBudgetMicros raw)
      , internalLeasePolicySmtpCommitBudget = durationUnsafe (rawLeaseSmtpCommitBudgetMicros raw)
      , internalLeasePolicyCancellationGrace = durationUnsafe (rawLeaseCancellationGraceMicros raw)
      , internalLeasePolicyClockSkew = durationUnsafe (rawLeaseClockSkewMicros raw)
      , internalLeasePolicySafetyMargin = durationUnsafe (rawLeaseSafetyMarginMicros raw)
      , internalLeasePolicyProviderInFlightGrace = durationUnsafe (rawLeaseProviderInFlightGraceMicros raw)
      , internalLeasePolicyProviderVisibilityGrace =
          durationUnsafe (rawLeaseProviderVisibilityGraceMicros raw)
      , internalLeasePolicyTargetWriteGrace = durationUnsafe (rawLeaseTargetWriteGraceMicros raw)
      , internalLeasePolicyStableObservationCount = fromIntegral (rawLeaseStableObservationCount raw)
      }
 where
  validatePositive (field, value)
    | value == 0 = Left (LeasePolicyFieldMustBePositive field)
    | otherwise = Right ()

-- | Seventy-minute canonical SES transaction.  The 65-minute transaction
-- proof is 15m reconcile + 30m semantic readiness + 12m SMTP repair/commit +
-- 2m cancellation + 1m skew + 5m safety, leaving a strict 5-minute surplus.
-- The 35-minute acquisition bound also exceeds the full 28-minute successor
-- grace (skew + cancellation + provider in-flight/visibility + target write),
-- leaving time for the second stable provider sample.
defaultSesLeasePolicy :: LeasePolicy
defaultSesLeasePolicy =
  LeasePolicy
    { internalLeasePolicyAcquireTimeout = seconds 2100
    , internalLeasePolicyGrantTtl = seconds 4200
    , internalLeasePolicyReconcileBudget = seconds 900
    , internalLeasePolicyReadinessBudget = seconds 1800
    , internalLeasePolicySmtpCommitBudget = seconds 720
    , internalLeasePolicyCancellationGrace = seconds 120
    , internalLeasePolicyClockSkew = seconds 60
    , internalLeasePolicySafetyMargin = seconds 300
    , internalLeasePolicyProviderInFlightGrace = seconds 900
    , internalLeasePolicyProviderVisibilityGrace = seconds 300
    , internalLeasePolicyTargetWriteGrace = seconds 300
    , internalLeasePolicyStableObservationCount = 2
    }

leasePolicyAcquireTimeout :: LeasePolicy -> AuthorityDuration
leasePolicyAcquireTimeout = internalLeasePolicyAcquireTimeout

leasePolicyGrantTtl :: LeasePolicy -> AuthorityDuration
leasePolicyGrantTtl = internalLeasePolicyGrantTtl

leasePolicyReconcileBudget :: LeasePolicy -> AuthorityDuration
leasePolicyReconcileBudget = internalLeasePolicyReconcileBudget

leasePolicyReadinessBudget :: LeasePolicy -> AuthorityDuration
leasePolicyReadinessBudget = internalLeasePolicyReadinessBudget

leasePolicySmtpCommitBudget :: LeasePolicy -> AuthorityDuration
leasePolicySmtpCommitBudget = internalLeasePolicySmtpCommitBudget

leasePolicyCancellationGrace :: LeasePolicy -> AuthorityDuration
leasePolicyCancellationGrace = internalLeasePolicyCancellationGrace

leasePolicyClockSkew :: LeasePolicy -> AuthorityDuration
leasePolicyClockSkew = internalLeasePolicyClockSkew

leasePolicySafetyMargin :: LeasePolicy -> AuthorityDuration
leasePolicySafetyMargin = internalLeasePolicySafetyMargin

leasePolicyProviderInFlightGrace :: LeasePolicy -> AuthorityDuration
leasePolicyProviderInFlightGrace = internalLeasePolicyProviderInFlightGrace

leasePolicyProviderVisibilityGrace :: LeasePolicy -> AuthorityDuration
leasePolicyProviderVisibilityGrace = internalLeasePolicyProviderVisibilityGrace

leasePolicyTargetWriteGrace :: LeasePolicy -> AuthorityDuration
leasePolicyTargetWriteGrace = internalLeasePolicyTargetWriteGrace

leasePolicyStableObservationCount :: LeasePolicy -> Int
leasePolicyStableObservationCount = internalLeasePolicyStableObservationCount

data LeaseGrant = LeaseGrant
  { internalLeaseGrantKey :: !LeaseKey
  , internalLeaseGrantOwnerNonce :: !OwnerNonce
  , internalLeaseGrantFencingToken :: !FencingToken
  , internalLeaseGrantIssuedAt :: !AuthorityTime
  , internalLeaseGrantExpiresAt :: !AuthorityTime
  , internalLeaseGrantSafeUseDeadline :: !AuthorityTime
  }
  deriving (Eq, Show)

data ReleasedLeasePredecessor = ReleasedLeasePredecessor
  { internalReleasedLeaseGrant :: !LeaseGrant
  , internalReleasedLeaseAt :: !AuthorityTime
  }
  deriving (Eq, Show)

-- | Recovery context derived from the currently observed predecessor state.
-- Expired active grants anchor recovery at grant expiry; voluntary releases
-- anchor it at the authority-observed release time.
data LeaseRecoveryPredecessor = LeaseRecoveryPredecessor
  { internalLeaseRecoveryGrant :: !LeaseGrant
  , internalLeaseRecoveryNotBefore :: !AuthorityTime
  }
  deriving (Eq, Show)

data LeaseProjection = LeaseProjection
  { internalLeaseProjectionLastFencingToken :: !FencingToken
  , internalLeaseProjectionActiveGrant :: !(Maybe LeaseGrant)
  , internalLeaseProjectionReleasedPredecessor :: !(Maybe ReleasedLeasePredecessor)
  }
  deriving (Eq, Show)

-- | Version 1 is retained only as an explicit read migration.  An active v1
-- grant is losslessly promoted to v2.  A v1 projection with no active grant
-- cannot be promoted safely because the old release operation discarded the
-- predecessor needed for late-effect recovery; decoding therefore refuses it
-- instead of silently allowing an unfenced successor.
data WireLeaseProjectionV1 = WireLeaseProjectionV1
  { wireLeaseProjectionVersion :: !Word16
  , wireLeaseProjectionLastFence :: !Natural
  , wireLeaseProjectionActiveGrant :: !(Maybe WireLeaseGrant)
  }
  deriving (Eq, Generic, Show)

instance Serialise WireLeaseProjectionV1

-- | Version 2 retains exactly one current state: an active owner or the
-- voluntarily released predecessor whose bounded late effects a successor
-- must drain before replacing it.
data WireLeaseProjectionV2 = WireLeaseProjectionV2
  { wireLeaseProjectionV2Version :: !Word16
  , wireLeaseProjectionV2LastFence :: !Natural
  , wireLeaseProjectionV2ActiveGrant :: !(Maybe WireLeaseGrant)
  , wireLeaseProjectionV2ReleasedPredecessor :: !(Maybe WireReleasedLeasePredecessor)
  }
  deriving (Eq, Generic, Show)

instance Serialise WireLeaseProjectionV2

data WireReleasedLeasePredecessor = WireReleasedLeasePredecessor
  { wireReleasedLeaseGrant :: !WireLeaseGrant
  , wireReleasedLeaseAt :: !Natural
  }
  deriving (Eq, Generic, Show)

instance Serialise WireReleasedLeasePredecessor

data WireLeaseGrant = WireLeaseGrant
  { wireLeaseGrantAccount :: !Text
  , wireLeaseGrantRegion :: !Text
  , wireLeaseGrantResource :: !Text
  , wireLeaseGrantOwnerNonce :: !Text
  , wireLeaseGrantFence :: !Natural
  , wireLeaseGrantIssuedAt :: !Natural
  , wireLeaseGrantExpiresAt :: !Natural
  , wireLeaseGrantSafeUseDeadline :: !Natural
  }
  deriving (Eq, Generic, Show)

instance Serialise WireLeaseGrant

data LeaseProjectionCodecError
  = LeaseProjectionCodecTooLarge !Int !Int
  | LeaseProjectionCodecDecodeFailed !Text
  | LeaseProjectionCodecUnsupportedVersion !Word16
  | LeaseProjectionCodecLegacyReleasedPredecessorMissing !Natural
  | LeaseProjectionCodecIdentityInvalid !LeaseIdentityError
  | LeaseProjectionCodecValueInvalid !LeaseValueError
  | LeaseProjectionCodecProjectionInvalid !LeaseProjectionError
  deriving (Eq, Show)

-- | The logical projection has fixed cardinality and bounded identity fields;
-- reject an oversized body before asking the CBOR decoder to allocate.
leaseProjectionMaximumEncodedBytes :: Int
leaseProjectionMaximumEncodedBytes = 16 * 1024

leaseProjectionCodecVersion :: Word16
leaseProjectionCodecVersion = 2

encodeLeaseProjection :: LeaseProjection -> ByteString
encodeLeaseProjection =
  BL.toStrict . serialise . wireLeaseProjectionV2

decodeLeaseProjection
  :: LeasePolicy
  -> ByteString
  -> Either LeaseProjectionCodecError LeaseProjection
decodeLeaseProjection policy bytes
  | BS.length bytes > leaseProjectionMaximumEncodedBytes =
      Left
        ( LeaseProjectionCodecTooLarge
            (BS.length bytes)
            leaseProjectionMaximumEncodedBytes
        )
  | otherwise = do
      case deserialiseOrFail (BL.fromStrict bytes) of
        Right wireV2 -> decodeWireLeaseProjectionV2 policy wireV2
        Left v2Error ->
          case deserialiseOrFail (BL.fromStrict bytes) of
            Right wireV1 -> decodeWireLeaseProjectionV1 policy wireV1
            Left _ ->
              Left (LeaseProjectionCodecDecodeFailed (Text.pack (show v2Error)))

wireLeaseProjectionV2 :: LeaseProjection -> WireLeaseProjectionV2
wireLeaseProjectionV2 projection =
  WireLeaseProjectionV2
    { wireLeaseProjectionV2Version = leaseProjectionCodecVersion
    , wireLeaseProjectionV2LastFence =
        fencingTokenValue (leaseProjectionLastFencingToken projection)
    , wireLeaseProjectionV2ActiveGrant =
        wireLeaseGrant <$> leaseProjectionActiveGrant projection
    , wireLeaseProjectionV2ReleasedPredecessor =
        wireReleasedLeasePredecessor
          <$> internalLeaseProjectionReleasedPredecessor projection
    }

decodeWireLeaseProjectionV2
  :: LeasePolicy
  -> WireLeaseProjectionV2
  -> Either LeaseProjectionCodecError LeaseProjection
decodeWireLeaseProjectionV2 policy wire = do
  unless
    (wireLeaseProjectionV2Version wire == leaseProjectionCodecVersion)
    (Left (LeaseProjectionCodecUnsupportedVersion (wireLeaseProjectionV2Version wire)))
  lastFence <- mapCodecValue (mkFencingToken (wireLeaseProjectionV2LastFence wire))
  active <- traverse (decodeWireLeaseGrant policy) (wireLeaseProjectionV2ActiveGrant wire)
  released <-
    traverse
      (decodeWireReleasedLeasePredecessor policy)
      (wireLeaseProjectionV2ReleasedPredecessor wire)
  mapCodecProjection (mkLeaseProjectionState lastFence active released)

decodeWireLeaseProjectionV1
  :: LeasePolicy
  -> WireLeaseProjectionV1
  -> Either LeaseProjectionCodecError LeaseProjection
decodeWireLeaseProjectionV1 policy wire = do
  unless
    (wireLeaseProjectionVersion wire == 1)
    (Left (LeaseProjectionCodecUnsupportedVersion (wireLeaseProjectionVersion wire)))
  lastFence <- mapCodecValue (mkFencingToken (wireLeaseProjectionLastFence wire))
  case wireLeaseProjectionActiveGrant wire of
    Nothing ->
      Left
        ( LeaseProjectionCodecLegacyReleasedPredecessorMissing
            (wireLeaseProjectionLastFence wire)
        )
    Just wireGrant -> do
      active <- decodeWireLeaseGrant policy wireGrant
      mapCodecProjection (mkLeaseProjectionState lastFence (Just active) Nothing)

wireReleasedLeasePredecessor
  :: ReleasedLeasePredecessor -> WireReleasedLeasePredecessor
wireReleasedLeasePredecessor predecessor =
  WireReleasedLeasePredecessor
    { wireReleasedLeaseGrant =
        wireLeaseGrant (internalReleasedLeaseGrant predecessor)
    , wireReleasedLeaseAt =
        authorityTimeMicros (internalReleasedLeaseAt predecessor)
    }

decodeWireReleasedLeasePredecessor
  :: LeasePolicy
  -> WireReleasedLeasePredecessor
  -> Either LeaseProjectionCodecError ReleasedLeasePredecessor
decodeWireReleasedLeasePredecessor policy wire = do
  grant <- decodeWireLeaseGrant policy (wireReleasedLeaseGrant wire)
  mapCodecProjection
    ( mkReleasedLeasePredecessor
        grant
        (authorityTimeFromMicros (wireReleasedLeaseAt wire))
    )

wireLeaseGrant :: LeaseGrant -> WireLeaseGrant
wireLeaseGrant grant =
  WireLeaseGrant
    { wireLeaseGrantAccount = leaseKeyAccount (leaseGrantKey grant)
    , wireLeaseGrantRegion = leaseKeyRegion (leaseGrantKey grant)
    , wireLeaseGrantResource = leaseKeyResource (leaseGrantKey grant)
    , wireLeaseGrantOwnerNonce = ownerNonceText (leaseGrantOwnerNonce grant)
    , wireLeaseGrantFence = fencingTokenValue (leaseGrantFencingToken grant)
    , wireLeaseGrantIssuedAt = authorityTimeMicros (leaseGrantIssuedAt grant)
    , wireLeaseGrantExpiresAt = authorityTimeMicros (leaseGrantExpiresAt grant)
    , wireLeaseGrantSafeUseDeadline =
        authorityTimeMicros (leaseGrantSafeUseDeadline grant)
    }

decodeWireLeaseGrant
  :: LeasePolicy
  -> WireLeaseGrant
  -> Either LeaseProjectionCodecError LeaseGrant
decodeWireLeaseGrant policy wire = do
  key <-
    mapCodecIdentity
      ( mkLeaseKey
          (wireLeaseGrantAccount wire)
          (wireLeaseGrantRegion wire)
          (wireLeaseGrantResource wire)
      )
  owner <- mapCodecIdentity (mkOwnerNonce (wireLeaseGrantOwnerNonce wire))
  fence <- mapCodecValue (mkFencingToken (wireLeaseGrantFence wire))
  mapCodecProjection
    ( mkLeaseGrant
        policy
        key
        owner
        fence
        (authorityTimeFromMicros (wireLeaseGrantIssuedAt wire))
        (authorityTimeFromMicros (wireLeaseGrantExpiresAt wire))
        (authorityTimeFromMicros (wireLeaseGrantSafeUseDeadline wire))
    )

mapCodecIdentity
  :: Either LeaseIdentityError value
  -> Either LeaseProjectionCodecError value
mapCodecIdentity =
  either (Left . LeaseProjectionCodecIdentityInvalid) Right

mapCodecValue
  :: Either LeaseValueError value
  -> Either LeaseProjectionCodecError value
mapCodecValue =
  either (Left . LeaseProjectionCodecValueInvalid) Right

mapCodecProjection
  :: Either LeaseProjectionError value
  -> Either LeaseProjectionCodecError value
mapCodecProjection =
  either (Left . LeaseProjectionCodecProjectionInvalid) Right

data LeaseProjectionError
  = LeaseGrantExpiryDoesNotMatchPolicy !AuthorityTime !AuthorityTime
  | LeaseGrantSafeUseDeadlineDoesNotMatchPolicy !AuthorityTime !AuthorityTime
  | LeaseGrantSafeUseDeadlineNotBeforeExpiry !AuthorityTime !AuthorityTime
  | LeaseProjectionActiveFenceDoesNotMatchLast !FencingToken !FencingToken
  | LeaseProjectionReleasedFenceDoesNotMatchLast !FencingToken !FencingToken
  | LeaseProjectionMustHaveExactlyOneGrant
  | LeaseReleasedPredecessorBeforeGrant !AuthorityTime !AuthorityTime
  | LeaseReleasedPredecessorNotBeforeExpiry !AuthorityTime !AuthorityTime
  deriving (Eq, Show)

mkLeaseGrant
  :: LeasePolicy
  -> LeaseKey
  -> OwnerNonce
  -> FencingToken
  -> AuthorityTime
  -> AuthorityTime
  -> AuthorityTime
  -> Either LeaseProjectionError LeaseGrant
mkLeaseGrant policy key owner fence issuedAt expiresAt safeUseDeadline = do
  let expectedExpiry = addDuration issuedAt (leasePolicyGrantTtl policy)
      expectedSafe = subtractDuration expectedExpiry (leaseSafeReserve policy)
  unless
    (expiresAt == expectedExpiry)
    (Left (LeaseGrantExpiryDoesNotMatchPolicy expiresAt expectedExpiry))
  unless
    (safeUseDeadline == expectedSafe)
    (Left (LeaseGrantSafeUseDeadlineDoesNotMatchPolicy safeUseDeadline expectedSafe))
  unless
    (safeUseDeadline < expiresAt)
    (Left (LeaseGrantSafeUseDeadlineNotBeforeExpiry safeUseDeadline expiresAt))
  pure
    LeaseGrant
      { internalLeaseGrantKey = key
      , internalLeaseGrantOwnerNonce = owner
      , internalLeaseGrantFencingToken = fence
      , internalLeaseGrantIssuedAt = issuedAt
      , internalLeaseGrantExpiresAt = expiresAt
      , internalLeaseGrantSafeUseDeadline = safeUseDeadline
      }

mkLeaseProjection
  :: FencingToken
  -> Maybe LeaseGrant
  -> Either LeaseProjectionError LeaseProjection
mkLeaseProjection lastFence active =
  mkLeaseProjectionState lastFence active Nothing

mkLeaseProjectionState
  :: FencingToken
  -> Maybe LeaseGrant
  -> Maybe ReleasedLeasePredecessor
  -> Either LeaseProjectionError LeaseProjection
mkLeaseProjectionState lastFence active released = do
  case (active, released) of
    (Just grant, Nothing) ->
      validateProjectionFence
        LeaseProjectionActiveFenceDoesNotMatchLast
        lastFence
        grant
    (Nothing, Just predecessor) ->
      validateProjectionFence
        LeaseProjectionReleasedFenceDoesNotMatchLast
        lastFence
        (internalReleasedLeaseGrant predecessor)
    _ -> Left LeaseProjectionMustHaveExactlyOneGrant
  pure
    LeaseProjection
      { internalLeaseProjectionLastFencingToken = lastFence
      , internalLeaseProjectionActiveGrant = active
      , internalLeaseProjectionReleasedPredecessor = released
      }

validateProjectionFence
  :: (FencingToken -> FencingToken -> LeaseProjectionError)
  -> FencingToken
  -> LeaseGrant
  -> Either LeaseProjectionError ()
validateProjectionFence mismatch lastFence grant =
  unless
    (leaseGrantFencingToken grant == lastFence)
    (Left (mismatch (leaseGrantFencingToken grant) lastFence))

mkReleasedLeasePredecessor
  :: LeaseGrant
  -> AuthorityTime
  -> Either LeaseProjectionError ReleasedLeasePredecessor
mkReleasedLeasePredecessor grant releasedAt = do
  when
    (releasedAt < leaseGrantIssuedAt grant)
    ( Left
        ( LeaseReleasedPredecessorBeforeGrant
            releasedAt
            (leaseGrantIssuedAt grant)
        )
    )
  when
    (releasedAt >= leaseGrantExpiresAt grant)
    ( Left
        ( LeaseReleasedPredecessorNotBeforeExpiry
            releasedAt
            (leaseGrantExpiresAt grant)
        )
    )
  pure
    ReleasedLeasePredecessor
      { internalReleasedLeaseGrant = grant
      , internalReleasedLeaseAt = releasedAt
      }

leaseGrantKey :: LeaseGrant -> LeaseKey
leaseGrantKey = internalLeaseGrantKey

leaseGrantOwnerNonce :: LeaseGrant -> OwnerNonce
leaseGrantOwnerNonce = internalLeaseGrantOwnerNonce

leaseGrantFencingToken :: LeaseGrant -> FencingToken
leaseGrantFencingToken = internalLeaseGrantFencingToken

leaseGrantIssuedAt :: LeaseGrant -> AuthorityTime
leaseGrantIssuedAt = internalLeaseGrantIssuedAt

leaseGrantExpiresAt :: LeaseGrant -> AuthorityTime
leaseGrantExpiresAt = internalLeaseGrantExpiresAt

leaseGrantSafeUseDeadline :: LeaseGrant -> AuthorityTime
leaseGrantSafeUseDeadline = internalLeaseGrantSafeUseDeadline

leaseProjectionLastFencingToken :: LeaseProjection -> FencingToken
leaseProjectionLastFencingToken = internalLeaseProjectionLastFencingToken

leaseProjectionActiveGrant :: LeaseProjection -> Maybe LeaseGrant
leaseProjectionActiveGrant = internalLeaseProjectionActiveGrant

leaseProjectionReleasedPredecessor :: LeaseProjection -> Maybe LeaseGrant
leaseProjectionReleasedPredecessor =
  fmap internalReleasedLeaseGrant . internalLeaseProjectionReleasedPredecessor

leaseProjectionReleasedAt :: LeaseProjection -> Maybe AuthorityTime
leaseProjectionReleasedAt =
  fmap internalReleasedLeaseAt . internalLeaseProjectionReleasedPredecessor

leaseProjectionRecoveryPredecessor
  :: LeasePolicy -> LeaseProjection -> Maybe LeaseRecoveryPredecessor
leaseProjectionRecoveryPredecessor policy projection =
  case leaseProjectionActiveGrant projection of
    Just grant ->
      Just
        LeaseRecoveryPredecessor
          { internalLeaseRecoveryGrant = grant
          , internalLeaseRecoveryNotBefore = successorNotBefore policy grant
          }
    Nothing -> do
      released <- internalLeaseProjectionReleasedPredecessor projection
      pure
        LeaseRecoveryPredecessor
          { internalLeaseRecoveryGrant = internalReleasedLeaseGrant released
          , internalLeaseRecoveryNotBefore =
              releasedSuccessorNotBefore policy released
          }

leaseRecoveryGrant :: LeaseRecoveryPredecessor -> LeaseGrant
leaseRecoveryGrant = internalLeaseRecoveryGrant

leaseRecoveryNotBefore :: LeaseRecoveryPredecessor -> AuthorityTime
leaseRecoveryNotBefore = internalLeaseRecoveryNotBefore

data LeaseAcquireRequest = LeaseAcquireRequest
  { internalLeaseAcquireCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , internalLeaseAcquireKey :: !LeaseKey
  , internalLeaseAcquireOwnerNonce :: !OwnerNonce
  , internalLeaseAcquireStartedAt :: !AuthorityTime
  , internalLeaseAcquireDeadline :: !AuthorityTime
  }
  deriving (Eq, Show)

beginLeaseAcquire
  :: LeasePolicy
  -> LongLivedCheckpointAuthority
  -> LeaseKey
  -> OwnerNonce
  -> AuthorityTime
  -> Either AuthorityCoordinateError LeaseAcquireRequest
beginLeaseAcquire policy authority key owner startedAt = do
  coordinate <- leaseObjectCoordinate authority key
  pure
    LeaseAcquireRequest
      { internalLeaseAcquireCoordinate = coordinate
      , internalLeaseAcquireKey = key
      , internalLeaseAcquireOwnerNonce = owner
      , internalLeaseAcquireStartedAt = startedAt
      , internalLeaseAcquireDeadline =
          addDuration startedAt (leasePolicyAcquireTimeout policy)
      }

leaseAcquireOwnerNonce :: LeaseAcquireRequest -> OwnerNonce
leaseAcquireOwnerNonce = internalLeaseAcquireOwnerNonce

leaseAcquireCoordinate :: LeaseAcquireRequest -> ModelBObjectCoordinate 'ClusterRetained
leaseAcquireCoordinate = internalLeaseAcquireCoordinate

leaseAcquireDeadline :: LeaseAcquireRequest -> AuthorityTime
leaseAcquireDeadline = internalLeaseAcquireDeadline

data LeaseRefusal
  = LeaseAuthorityMissing
  | LeaseAuthorityCorrupt !Text
  | LeaseAuthorityUnobservable !Text
  | LeaseCoordinateMismatch !Text !Text
  | LeaseKeyMismatch !LeaseKey !LeaseKey
  | LeaseOwnerMismatch !OwnerNonce !OwnerNonce
  | LeaseFenceMismatch !FencingToken !FencingToken
  | LeaseGrantExpired !AuthorityTime !AuthorityTime
  | LeaseSafeUseDeadlineReached !AuthorityTime !AuthorityTime
  | LeaseWorkWouldOutliveSafeUse !LeaseWork !AuthorityTime !AuthorityTime
  | LeaseAwsSessionTooShort !AuthorityTime !AuthorityTime
  | LeaseProjectionHasNoActiveGrant !FencingToken
  | LeaseStaleRelease !FencingToken !FencingToken
  | LeaseRecoveryWitnessMismatch !FencingToken !FencingToken
  | LeaseRecoveryWitnessContextMismatch !AuthorityTime !AuthorityTime
  | LeaseRecoveryWitnessFromFuture !AuthorityTime !AuthorityTime
  | LeaseRecoveryWitnessStale !AuthorityTime !AuthorityTime
  deriving (Eq, Show)

data LeaseAcquireDecision
  = LeaseAcquireCompareAndSwap !(ModelBCasRequest 'ClusterRetained LeaseProjection)
  | LeaseAcquireAlreadyOwned !LeaseGrant
  | LeaseAcquireContended !LeaseGrant
  | LeaseAcquireRecoveryRequired !AuthorityTime
  | LeaseAcquireTimedOut !AuthorityTime
  | LeaseAcquireRefused !LeaseRefusal
  deriving (Eq, Show)

decideLeaseAcquire
  :: LeasePolicy
  -> AuthorityTime
  -> LeaseAcquireRequest
  -> Maybe (StableQuiescenceWitness inventory)
  -> ModelBObservation LeaseProjection
  -> LeaseAcquireDecision
decideLeaseAcquire policy now request maybeWitness observation
  | now >= leaseAcquireDeadline request =
      LeaseAcquireTimedOut (leaseAcquireDeadline request)
  | otherwise =
      case observation of
        ModelBMissing ->
          LeaseAcquireCompareAndSwap
            ( ModelBInitialize
                (internalLeaseAcquireCoordinate request)
                (projectionWithGrant (firstGrant policy now request))
            )
        ModelBCorrupt detail -> LeaseAcquireRefused (LeaseAuthorityCorrupt detail)
        ModelBUnobservable detail ->
          LeaseAcquireRefused (LeaseAuthorityUnobservable detail)
        ModelBObserved version projection ->
          case leaseProjectionActiveGrant projection of
            Nothing ->
              case internalLeaseProjectionReleasedPredecessor projection of
                Nothing ->
                  LeaseAcquireRefused
                    ( LeaseAuthorityCorrupt
                        "lease projection has neither an active grant nor a released predecessor"
                    )
                Just released ->
                  let predecessor = internalReleasedLeaseGrant released
                   in if leaseGrantKey predecessor /= internalLeaseAcquireKey request
                        then
                          LeaseAcquireRefused
                            ( LeaseKeyMismatch
                                (internalLeaseAcquireKey request)
                                (leaseGrantKey predecessor)
                            )
                        else
                          decideExpiredReplacement
                            policy
                            now
                            request
                            version
                            projection
                            predecessor
                            (releasedSuccessorNotBefore policy released)
                            maybeWitness
            Just current
              | leaseGrantKey current /= internalLeaseAcquireKey request ->
                  LeaseAcquireRefused
                    ( LeaseKeyMismatch
                        (internalLeaseAcquireKey request)
                        (leaseGrantKey current)
                    )
              | now < leaseGrantExpiresAt current
                  && leaseGrantOwnerNonce current == leaseAcquireOwnerNonce request ->
                  LeaseAcquireAlreadyOwned current
              | now < leaseGrantExpiresAt current -> LeaseAcquireContended current
              | otherwise ->
                  decideExpiredReplacement
                    policy
                    now
                    request
                    version
                    projection
                    current
                    (successorNotBefore policy current)
                    maybeWitness

confirmLeaseAcquired
  :: LeasePolicy
  -> AuthorityTime
  -> LeaseAcquireRequest
  -> ModelBObservation LeaseProjection
  -> Either LeaseRefusal LeaseGrant
confirmLeaseAcquired policy now request observation = do
  (version, projection, grant) <- activeLeaseObservation observation
  let _expectedVersion = version
  validateCoordinateForKey (internalLeaseAcquireCoordinate request) (internalLeaseAcquireKey request)
  unless
    (leaseGrantKey grant == internalLeaseAcquireKey request)
    (Left (LeaseKeyMismatch (internalLeaseAcquireKey request) (leaseGrantKey grant)))
  unless
    (leaseGrantOwnerNonce grant == leaseAcquireOwnerNonce request)
    (Left (LeaseOwnerMismatch (leaseAcquireOwnerNonce request) (leaseGrantOwnerNonce grant)))
  validateGrantAgainstPolicy policy grant
  unless
    (leaseProjectionLastFencingToken projection == leaseGrantFencingToken grant)
    ( Left
        ( LeaseFenceMismatch
            (leaseGrantFencingToken grant)
            (leaseProjectionLastFencingToken projection)
        )
    )
  when
    (now >= leaseGrantExpiresAt grant)
    (Left (LeaseGrantExpired now (leaseGrantExpiresAt grant)))
  pure grant

data LeaseReleaseDecision
  = LeaseReleaseCompareAndSwap !(ModelBCasRequest 'ClusterRetained LeaseProjection)
  | LeaseReleaseAlreadyApplied
  | LeaseReleaseRefused !LeaseRefusal
  deriving (Eq, Show)

decideLeaseRelease
  :: AuthorityTime
  -> ModelBObjectCoordinate 'ClusterRetained
  -> LeaseGrant
  -> ModelBObservation LeaseProjection
  -> LeaseReleaseDecision
decideLeaseRelease now coordinate grant observation =
  case validateCoordinateForKey coordinate (leaseGrantKey grant) of
    Left refusal -> LeaseReleaseRefused refusal
    Right () ->
      case observation of
        ModelBMissing -> LeaseReleaseRefused LeaseAuthorityMissing
        ModelBCorrupt detail -> LeaseReleaseRefused (LeaseAuthorityCorrupt detail)
        ModelBUnobservable detail ->
          LeaseReleaseRefused (LeaseAuthorityUnobservable detail)
        ModelBObserved version projection ->
          case leaseProjectionActiveGrant projection of
            Nothing ->
              case leaseProjectionReleasedPredecessor projection of
                Just released ->
                  case exactGrantOwnership grant released of
                    Right () -> LeaseReleaseAlreadyApplied
                    Left refusal -> LeaseReleaseRefused refusal
                Nothing ->
                  LeaseReleaseRefused
                    ( LeaseAuthorityCorrupt
                        "released lease projection is missing its predecessor tombstone"
                    )
            Just current ->
              case exactGrantOwnership grant current of
                Left refusal -> LeaseReleaseRefused refusal
                Right ()
                  | now >= leaseGrantExpiresAt grant ->
                      LeaseReleaseRefused
                        (LeaseGrantExpired now (leaseGrantExpiresAt grant))
                  | otherwise ->
                      LeaseReleaseCompareAndSwap
                        ( ModelBReplace
                            coordinate
                            version
                            (releasedProjection now grant)
                        )

data LeaseOwnershipStatus
  = LeaseStillOwned
  | LeaseLost !LeaseRefusal
  deriving (Eq, Show)

leaseOwnershipStatus
  :: AuthorityTime
  -> LeaseGrant
  -> ModelBObservation LeaseProjection
  -> LeaseOwnershipStatus
leaseOwnershipStatus now expected observation =
  case currentOwnedGrant now expected observation of
    Left refusal -> LeaseLost refusal
    Right _ -> LeaseStillOwned

data LeaseWork
  = LeaseReconcileWork
  | LeaseReadinessWork
  | LeaseSmtpCommitWork
  deriving (Bounded, Enum, Eq, Show)

data LeaseUsePermit = LeaseUsePermit
  { internalLeaseUseOwnerNonce :: !OwnerNonce
  , internalLeaseUseFencingToken :: !FencingToken
  , internalLeaseUseStartedAt :: !AuthorityTime
  , internalLeaseUseDeadline :: !AuthorityTime
  , internalLeaseUseGrantExpiry :: !AuthorityTime
  }
  deriving (Eq, Show)

data LeaseUseDecision
  = LeaseUseAuthorized !LeaseUsePermit
  | LeaseUseRefused !LeaseRefusal
  deriving (Eq, Show)

authorizeLeaseWork
  :: LeasePolicy
  -> AuthorityTime
  -> LeaseWork
  -> LeaseGrant
  -> ModelBObservation LeaseProjection
  -> LeaseUseDecision
authorizeLeaseWork policy now work expected observation =
  case currentOwnedGrant now expected observation of
    Left refusal -> LeaseUseRefused refusal
    Right current
      | now >= leaseGrantSafeUseDeadline current ->
          LeaseUseRefused
            (LeaseSafeUseDeadlineReached now (leaseGrantSafeUseDeadline current))
      | workDeadline > leaseGrantSafeUseDeadline current ->
          LeaseUseRefused
            ( LeaseWorkWouldOutliveSafeUse
                work
                workDeadline
                (leaseGrantSafeUseDeadline current)
            )
      | otherwise ->
          LeaseUseAuthorized
            LeaseUsePermit
              { internalLeaseUseOwnerNonce = leaseGrantOwnerNonce current
              , internalLeaseUseFencingToken = leaseGrantFencingToken current
              , internalLeaseUseStartedAt = now
              , internalLeaseUseDeadline = workDeadline
              , internalLeaseUseGrantExpiry = leaseGrantExpiresAt current
              }
 where
  workDeadline = addDuration now (leaseWorkBudget policy work)

leaseUseOwnerNonce :: LeaseUsePermit -> OwnerNonce
leaseUseOwnerNonce = internalLeaseUseOwnerNonce

leaseUseFencingToken :: LeaseUsePermit -> FencingToken
leaseUseFencingToken = internalLeaseUseFencingToken

leaseUseDeadline :: LeaseUsePermit -> AuthorityTime
leaseUseDeadline = internalLeaseUseDeadline

newtype AwsSessionDeadline = AwsSessionDeadline
  { internalAwsSessionExpiresAt :: AuthorityTime
  }
  deriving (Eq, Show)

deriveAwsSessionDeadline
  :: AuthorityDuration
  -> LeaseUsePermit
  -> Either LeaseRefusal AwsSessionDeadline
deriveAwsSessionDeadline requestedDuration permit = do
  let requestedDeadline =
        addDuration
          (internalLeaseUseStartedAt permit)
          requestedDuration
      expiresAt = min requestedDeadline (internalLeaseUseGrantExpiry permit)
  when
    (expiresAt < leaseUseDeadline permit)
    (Left (LeaseAwsSessionTooShort expiresAt (leaseUseDeadline permit)))
  pure (AwsSessionDeadline expiresAt)

awsSessionExpiresAt :: AwsSessionDeadline -> AuthorityTime
awsSessionExpiresAt = internalAwsSessionExpiresAt

data FencedCommitPermit = FencedCommitPermit
  { internalFencedCommitOwnerNonce :: !OwnerNonce
  , internalFencedCommitFencingToken :: !FencingToken
  , internalFencedCommitExpectedLeaseVersion :: !ModelBObjectVersion
  }
  deriving (Eq, Show)

data LeaseCommitDecision
  = LeaseCommitAuthorized !FencedCommitPermit
  | LeaseCommitRefused !LeaseRefusal
  deriving (Eq, Show)

decideFencedCommit
  :: AuthorityTime
  -> LeaseGrant
  -> ModelBObservation LeaseProjection
  -> LeaseCommitDecision
decideFencedCommit now expected observation =
  case currentOwnedGrantWithVersion now expected observation of
    Left refusal -> LeaseCommitRefused refusal
    Right (version, current)
      | now >= leaseGrantSafeUseDeadline current ->
          LeaseCommitRefused
            (LeaseSafeUseDeadlineReached now (leaseGrantSafeUseDeadline current))
      | otherwise ->
          LeaseCommitAuthorized
            FencedCommitPermit
              { internalFencedCommitOwnerNonce = leaseGrantOwnerNonce current
              , internalFencedCommitFencingToken = leaseGrantFencingToken current
              , internalFencedCommitExpectedLeaseVersion = version
              }

fencedCommitOwnerNonce :: FencedCommitPermit -> OwnerNonce
fencedCommitOwnerNonce = internalFencedCommitOwnerNonce

fencedCommitFencingToken :: FencedCommitPermit -> FencingToken
fencedCommitFencingToken = internalFencedCommitFencingToken

fencedCommitExpectedLeaseVersion :: FencedCommitPermit -> ModelBObjectVersion
fencedCommitExpectedLeaseVersion = internalFencedCommitExpectedLeaseVersion

modelBLeaseGuardFromPermit
  :: ModelBObjectCoordinate 'ClusterRetained -> FencedCommitPermit -> ModelBLeaseGuard
modelBLeaseGuardFromPermit coordinate permit =
  ModelBLeaseGuard
    { modelBLeaseGuardCoordinate = coordinate
    , modelBLeaseGuardExpectedVersion =
        fencedCommitExpectedLeaseVersion permit
    , modelBLeaseGuardOwnerNonceText =
        ownerNonceText (fencedCommitOwnerNonce permit)
    , modelBLeaseGuardFencingTokenValue =
        fencingTokenValue (fencedCommitFencingToken permit)
    }

data ProviderObservation inventory
  = ProviderQuiescent !inventory
  | ProviderPending !Text
  | ProviderUnbounded
      { providerObservedCardinality :: !Natural
      , providerMaximumCardinality :: !Natural
      }
  | ProviderUnobservable !Text
  deriving (Eq, Show)

data TimedProviderObservation inventory = TimedProviderObservation
  { timedProviderObservedAt :: !AuthorityTime
  , timedProviderObservation :: !(ProviderObservation inventory)
  }
  deriving (Eq, Show)

data QuiescenceRefusal
  = QuiescenceInsufficientSamples !Int !Int
  | QuiescenceBeforeSuccessorGrace !AuthorityTime !AuthorityTime
  | QuiescenceSamplesTooClose !AuthorityTime !AuthorityTime !AuthorityDuration
  | QuiescenceInventoryChanged
  | QuiescenceProviderPending !Text
  | QuiescenceProviderUnbounded !Natural !Natural
  | QuiescenceProviderUnobservable !Text
  deriving (Eq, Show)

data StableQuiescenceWitness inventory = StableQuiescenceWitness
  { internalStableQuiescencePredecessorKey :: !LeaseKey
  , internalStableQuiescencePredecessorFence :: !FencingToken
  , internalStableQuiescenceRecoveryNotBefore :: !AuthorityTime
  , internalStableQuiescenceInventory :: !inventory
  , internalStableQuiescenceObservedThrough :: !AuthorityTime
  }
  deriving (Eq, Show)

successorNotBefore :: LeasePolicy -> LeaseGrant -> AuthorityTime
successorNotBefore policy grant =
  successorNotBeforeFrom policy (leaseGrantExpiresAt grant)

releasedSuccessorNotBefore
  :: LeasePolicy -> ReleasedLeasePredecessor -> AuthorityTime
releasedSuccessorNotBefore policy predecessor =
  successorNotBeforeFrom policy (internalReleasedLeaseAt predecessor)

successorNotBeforeFrom :: LeasePolicy -> AuthorityTime -> AuthorityTime
successorNotBeforeFrom policy anchor =
  foldl'
    addDuration
    anchor
    [ leasePolicyClockSkew policy
    , leasePolicyCancellationGrace policy
    , leasePolicyProviderInFlightGrace policy
    , leasePolicyProviderVisibilityGrace policy
    , leasePolicyTargetWriteGrace policy
    ]

proveStableProviderQuiescence
  :: (Eq inventory)
  => LeasePolicy
  -> LeaseGrant
  -> [TimedProviderObservation inventory]
  -> Either QuiescenceRefusal (StableQuiescenceWitness inventory)
proveStableProviderQuiescence policy predecessor samples = do
  proveStableProviderQuiescenceFor
    policy
    LeaseRecoveryPredecessor
      { internalLeaseRecoveryGrant = predecessor
      , internalLeaseRecoveryNotBefore = successorNotBefore policy predecessor
      }
    samples

proveStableProviderQuiescenceFor
  :: (Eq inventory)
  => LeasePolicy
  -> LeaseRecoveryPredecessor
  -> [TimedProviderObservation inventory]
  -> Either QuiescenceRefusal (StableQuiescenceWitness inventory)
proveStableProviderQuiescenceFor policy recovery samples = do
  let required = leasePolicyStableObservationCount policy
      actual = length samples
      predecessor = leaseRecoveryGrant recovery
      notBefore = leaseRecoveryNotBefore recovery
  when
    (actual < required)
    (Left (QuiescenceInsufficientSamples required actual))
  inventories <- mapM (settledInventory notBefore) samples
  validateIntervals
    (leasePolicyProviderVisibilityGrace policy)
    (map timedProviderObservedAt samples)
  case inventories of
    [] -> Left (QuiescenceInsufficientSamples required actual)
    firstInventory : remaining -> do
      unless
        (all (== firstInventory) remaining)
        (Left QuiescenceInventoryChanged)
      let observedThrough = timedProviderObservedAt (last samples)
      pure
        StableQuiescenceWitness
          { internalStableQuiescencePredecessorKey = leaseGrantKey predecessor
          , internalStableQuiescencePredecessorFence = leaseGrantFencingToken predecessor
          , internalStableQuiescenceRecoveryNotBefore = notBefore
          , internalStableQuiescenceInventory = firstInventory
          , internalStableQuiescenceObservedThrough = observedThrough
          }

stableQuiescenceInventory :: StableQuiescenceWitness inventory -> inventory
stableQuiescenceInventory = internalStableQuiescenceInventory

stableQuiescenceObservedThrough
  :: StableQuiescenceWitness inventory -> AuthorityTime
stableQuiescenceObservedThrough = internalStableQuiescenceObservedThrough

decideExpiredReplacement
  :: LeasePolicy
  -> AuthorityTime
  -> LeaseAcquireRequest
  -> ModelBObjectVersion
  -> LeaseProjection
  -> LeaseGrant
  -> AuthorityTime
  -> Maybe (StableQuiescenceWitness inventory)
  -> LeaseAcquireDecision
decideExpiredReplacement policy now request version projection predecessor notBefore maybeWitness
  | now < notBefore = LeaseAcquireRecoveryRequired notBefore
  | otherwise =
      case maybeWitness of
        Nothing -> LeaseAcquireRecoveryRequired notBefore
        Just witness
          | internalStableQuiescencePredecessorFence witness
              /= leaseGrantFencingToken predecessor ->
              LeaseAcquireRefused
                ( LeaseRecoveryWitnessMismatch
                    (leaseGrantFencingToken predecessor)
                    (internalStableQuiescencePredecessorFence witness)
                )
          | internalStableQuiescencePredecessorKey witness /= leaseGrantKey predecessor ->
              LeaseAcquireRefused
                ( LeaseKeyMismatch
                    (leaseGrantKey predecessor)
                    (internalStableQuiescencePredecessorKey witness)
                )
          | internalStableQuiescenceRecoveryNotBefore witness /= notBefore ->
              LeaseAcquireRefused
                ( LeaseRecoveryWitnessContextMismatch
                    notBefore
                    (internalStableQuiescenceRecoveryNotBefore witness)
                )
          | stableQuiescenceObservedThrough witness > now ->
              LeaseAcquireRefused
                ( LeaseRecoveryWitnessFromFuture
                    (stableQuiescenceObservedThrough witness)
                    now
                )
          | now > witnessValidUntil ->
              LeaseAcquireRefused
                ( LeaseRecoveryWitnessStale
                    (stableQuiescenceObservedThrough witness)
                    witnessValidUntil
                )
          | otherwise ->
              LeaseAcquireCompareAndSwap
                ( ModelBReplace
                    (internalLeaseAcquireCoordinate request)
                    version
                    ( projectionWithGrant
                        ( nextGrant
                            policy
                            now
                            request
                            (leaseProjectionLastFencingToken projection)
                        )
                    )
                )
 where
  witnessValidUntil =
    case maybeWitness of
      Nothing -> notBefore
      Just witness ->
        addDuration
          (stableQuiescenceObservedThrough witness)
          (leasePolicyProviderVisibilityGrace policy)

firstGrant :: LeasePolicy -> AuthorityTime -> LeaseAcquireRequest -> LeaseGrant
firstGrant policy issuedAt request =
  newGrant policy issuedAt request (FencingToken 1)

nextGrant
  :: LeasePolicy
  -> AuthorityTime
  -> LeaseAcquireRequest
  -> FencingToken
  -> LeaseGrant
nextGrant policy issuedAt request previous =
  newGrant
    policy
    issuedAt
    request
    (FencingToken (fencingTokenValue previous + 1))

newGrant
  :: LeasePolicy
  -> AuthorityTime
  -> LeaseAcquireRequest
  -> FencingToken
  -> LeaseGrant
newGrant policy issuedAt request fence =
  LeaseGrant
    { internalLeaseGrantKey = internalLeaseAcquireKey request
    , internalLeaseGrantOwnerNonce = leaseAcquireOwnerNonce request
    , internalLeaseGrantFencingToken = fence
    , internalLeaseGrantIssuedAt = issuedAt
    , internalLeaseGrantExpiresAt = expiresAt
    , internalLeaseGrantSafeUseDeadline =
        subtractDuration expiresAt (leaseSafeReserve policy)
    }
 where
  expiresAt = addDuration issuedAt (leasePolicyGrantTtl policy)

projectionWithGrant :: LeaseGrant -> LeaseProjection
projectionWithGrant grant =
  LeaseProjection
    { internalLeaseProjectionLastFencingToken = leaseGrantFencingToken grant
    , internalLeaseProjectionActiveGrant = Just grant
    , internalLeaseProjectionReleasedPredecessor = Nothing
    }

releasedProjection :: AuthorityTime -> LeaseGrant -> LeaseProjection
releasedProjection releasedAt predecessor =
  LeaseProjection
    { internalLeaseProjectionLastFencingToken =
        leaseGrantFencingToken predecessor
    , internalLeaseProjectionActiveGrant = Nothing
    , internalLeaseProjectionReleasedPredecessor =
        Just
          ReleasedLeasePredecessor
            { internalReleasedLeaseGrant = predecessor
            , internalReleasedLeaseAt = releasedAt
            }
    }

activeLeaseObservation
  :: ModelBObservation LeaseProjection
  -> Either LeaseRefusal (ModelBObjectVersion, LeaseProjection, LeaseGrant)
activeLeaseObservation observation =
  case observation of
    ModelBMissing -> Left LeaseAuthorityMissing
    ModelBCorrupt detail -> Left (LeaseAuthorityCorrupt detail)
    ModelBUnobservable detail -> Left (LeaseAuthorityUnobservable detail)
    ModelBObserved version projection ->
      case leaseProjectionActiveGrant projection of
        Nothing ->
          Left
            (LeaseProjectionHasNoActiveGrant (leaseProjectionLastFencingToken projection))
        Just grant -> Right (version, projection, grant)

currentOwnedGrant
  :: AuthorityTime
  -> LeaseGrant
  -> ModelBObservation LeaseProjection
  -> Either LeaseRefusal LeaseGrant
currentOwnedGrant now expected observation =
  snd <$> currentOwnedGrantWithVersion now expected observation

currentOwnedGrantWithVersion
  :: AuthorityTime
  -> LeaseGrant
  -> ModelBObservation LeaseProjection
  -> Either LeaseRefusal (ModelBObjectVersion, LeaseGrant)
currentOwnedGrantWithVersion now expected observation = do
  (version, projection, current) <- activeLeaseObservation observation
  exactGrantOwnership expected current
  unless
    (leaseProjectionLastFencingToken projection == leaseGrantFencingToken current)
    ( Left
        ( LeaseFenceMismatch
            (leaseGrantFencingToken current)
            (leaseProjectionLastFencingToken projection)
        )
    )
  when
    (now >= leaseGrantExpiresAt current)
    (Left (LeaseGrantExpired now (leaseGrantExpiresAt current)))
  pure (version, current)

exactGrantOwnership :: LeaseGrant -> LeaseGrant -> Either LeaseRefusal ()
exactGrantOwnership expected current = do
  unless
    (leaseGrantKey expected == leaseGrantKey current)
    (Left (LeaseKeyMismatch (leaseGrantKey expected) (leaseGrantKey current)))
  unless
    (leaseGrantOwnerNonce expected == leaseGrantOwnerNonce current)
    ( Left
        ( LeaseOwnerMismatch
            (leaseGrantOwnerNonce expected)
            (leaseGrantOwnerNonce current)
        )
    )
  unless
    (leaseGrantFencingToken expected == leaseGrantFencingToken current)
    ( Left
        ( LeaseFenceMismatch
            (leaseGrantFencingToken expected)
            (leaseGrantFencingToken current)
        )
    )

validateGrantAgainstPolicy :: LeasePolicy -> LeaseGrant -> Either LeaseRefusal ()
validateGrantAgainstPolicy policy grant = do
  let expectedExpiry = addDuration (leaseGrantIssuedAt grant) (leasePolicyGrantTtl policy)
      expectedSafe = subtractDuration expectedExpiry (leaseSafeReserve policy)
  unless
    (leaseGrantExpiresAt grant == expectedExpiry)
    (Left (LeaseGrantExpired (leaseGrantExpiresAt grant) expectedExpiry))
  unless
    (leaseGrantSafeUseDeadline grant == expectedSafe)
    ( Left
        ( LeaseSafeUseDeadlineReached
            (leaseGrantSafeUseDeadline grant)
            expectedSafe
        )
    )

validateCoordinateForKey
  :: ModelBObjectCoordinate l -> LeaseKey -> Either LeaseRefusal ()
validateCoordinateForKey coordinate key =
  unless
    (modelBObjectLogicalName coordinate == expected)
    (Left (LeaseCoordinateMismatch expected (modelBObjectLogicalName coordinate)))
 where
  expected =
    leaseLogicalName key

settledInventory
  :: AuthorityTime
  -> TimedProviderObservation inventory
  -> Either QuiescenceRefusal inventory
settledInventory notBefore sample
  | timedProviderObservedAt sample < notBefore =
      Left
        ( QuiescenceBeforeSuccessorGrace
            (timedProviderObservedAt sample)
            notBefore
        )
  | otherwise =
      case timedProviderObservation sample of
        ProviderQuiescent inventory -> Right inventory
        ProviderPending detail -> Left (QuiescenceProviderPending detail)
        ProviderUnbounded observed maximumCardinality ->
          Left (QuiescenceProviderUnbounded observed maximumCardinality)
        ProviderUnobservable detail ->
          Left (QuiescenceProviderUnobservable detail)

validateIntervals
  :: AuthorityDuration
  -> [AuthorityTime]
  -> Either QuiescenceRefusal ()
validateIntervals visibility times =
  case times of
    earlier : later : rest
      | later < addDuration earlier visibility ->
          Left (QuiescenceSamplesTooClose earlier later visibility)
      | otherwise -> validateIntervals visibility (later : rest)
    _ -> Right ()

leaseWorkBudget :: LeasePolicy -> LeaseWork -> AuthorityDuration
leaseWorkBudget policy work =
  case work of
    LeaseReconcileWork -> leasePolicyReconcileBudget policy
    LeaseReadinessWork -> leasePolicyReadinessBudget policy
    LeaseSmtpCommitWork -> leasePolicySmtpCommitBudget policy

leaseSafeReserve :: LeasePolicy -> AuthorityDuration
leaseSafeReserve policy =
  AuthorityDuration
    ( sum
        [ authorityDurationMicros (leasePolicyCancellationGrace policy)
        , authorityDurationMicros (leasePolicyClockSkew policy)
        , authorityDurationMicros (leasePolicySafetyMargin policy)
        ]
    )

rawTransactionBudget :: RawLeasePolicy -> Natural
rawTransactionBudget raw =
  sum
    [ rawLeaseReconcileBudgetMicros raw
    , rawLeaseReadinessBudgetMicros raw
    , rawLeaseSmtpCommitBudgetMicros raw
    , rawLeaseCancellationGraceMicros raw
    , rawLeaseClockSkewMicros raw
    , rawLeaseSafetyMarginMicros raw
    ]

rawPolicyFields :: RawLeasePolicy -> [(LeasePolicyField, Natural)]
rawPolicyFields raw =
  [ (LeaseAcquireTimeoutField, rawLeaseAcquireTimeoutMicros raw)
  , (LeaseGrantTtlField, rawLeaseGrantTtlMicros raw)
  , (LeaseReconcileBudgetField, rawLeaseReconcileBudgetMicros raw)
  , (LeaseReadinessBudgetField, rawLeaseReadinessBudgetMicros raw)
  , (LeaseSmtpCommitBudgetField, rawLeaseSmtpCommitBudgetMicros raw)
  , (LeaseCancellationGraceField, rawLeaseCancellationGraceMicros raw)
  , (LeaseClockSkewField, rawLeaseClockSkewMicros raw)
  , (LeaseSafetyMarginField, rawLeaseSafetyMarginMicros raw)
  , (LeaseProviderInFlightGraceField, rawLeaseProviderInFlightGraceMicros raw)
  , (LeaseProviderVisibilityGraceField, rawLeaseProviderVisibilityGraceMicros raw)
  , (LeaseTargetWriteGraceField, rawLeaseTargetWriteGraceMicros raw)
  ]

durationUnsafe :: Natural -> AuthorityDuration
durationUnsafe = AuthorityDuration

seconds :: Natural -> AuthorityDuration
seconds value = AuthorityDuration (value * 1000000)

addDuration :: AuthorityTime -> AuthorityDuration -> AuthorityTime
addDuration time duration =
  AuthorityTime (authorityTimeMicros time + authorityDurationMicros duration)

subtractDuration :: AuthorityTime -> AuthorityDuration -> AuthorityTime
subtractDuration time duration =
  AuthorityTime (authorityTimeMicros time - authorityDurationMicros duration)

validateIdentity
  :: Text -> Int -> Text -> Either LeaseIdentityError Text
validateIdentity label maximumLength raw
  | Text.null value = Left (LeaseIdentityEmpty label)
  | byteLength > maximumLength = Left (LeaseIdentityTooLong label byteLength maximumLength)
  | otherwise =
      case Text.find (not . identityCharacter) value of
        Just invalid -> Left (LeaseIdentityContainsUnsafeCharacter label invalid)
        Nothing -> Right value
 where
  value = Text.strip raw
  byteLength = Text.length (TextEncoding.decodeLatin1 (TextEncoding.encodeUtf8 value))
  identityCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-._:@" :: String)
