{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}

-- | Retained, persistence-first continuity for one gateway emitter.
--
-- The authority record is deliberately small: one committed fixed-width
-- anchor and, while an assertion is crossing the publication boundary, one
-- exact signed payload with its next anchor.  A successful compare-and-swap is
-- not itself permission to publish.  Publication becomes representable only
-- after the exact staged record is observed again.
module Prodbox.Gateway.Continuity
  ( -- * Validated scope and bounds
    ContinuityBoundField (..)
  , ContinuityBounds
  , mkContinuityBounds
  , continuityMaxEmitterBytes
  , continuityMaxOrdersAnchorBytes
  , continuityMaxSignedAssertionBytes
  , ContinuityScope
  , mkContinuityScope
  , continuityScopeEmitter
  , continuityScopeOrdersAnchor

    -- * Fixed-width anchors and retained records
  , ContinuityDigest
  , mkContinuityDigest
  , continuityDigestBytes
  , ContinuityAnchor
  , restoreContinuityAnchor
  , continuityAnchorEpoch
  , continuityAnchorSequence
  , continuityAnchorPreviousDigest
  , AuthorityRecord
  , mkInitialAuthorityRecord
  , authorityRecordCommittedAnchor
  , authorityRecordStagedAssertion
  , authorityRecordRetainedBytes
  , authorityRecordMaximumRetainedBytes
  , authorityRecordMaximumEncodedBytes
  , encodeVersionedAuthorityRecord
  , decodeVersionedAuthorityRecord
  , StagedTransition (..)
  , nextAnchorFor
  , StagedAssertion
  , stagedAssertionTransition
  , stagedAssertionSignedBytes
  , stagedAssertionPreviousDigest
  , stagedAssertionNextAnchor

    -- * Opaque signed inputs
  , SignedSemanticAssertion
  , mkSignedSemanticAssertion
  , SignedEpochInvalidation
  , mkSignedEpochInvalidation

    -- * Versioned authority interpreter
  , AuthorityVersion
  , authorityVersionValue
  , VersionedAuthorityRecord
  , versionAuthorityRecord
  , versionedAuthorityVersion
  , versionedAuthorityRecord
  , AuthorityObservation (..)
  , AuthorityCasResult (..)
  , GatewayContinuityAuthority
  , gatewayContinuityAuthority
  , gatewayContinuityAuthorityWithInitialize

    -- * One-time first admission
  , FirstContinuityAdmission
  , mkFirstContinuityAdmission
  , initializeContinuityAtFirstAdmission

    -- * Startup, staging, publication, and commit
  , StartupRecovery (..)
  , CurrentContinuity
  , currentContinuityVersion
  , currentContinuityAnchor
  , recoverContinuityAtStartup
  , DurableStageAcknowledgement
  , durableStageVersion
  , stageSemanticAssertion
  , stageEpochInvalidation
  , PublicationWitness
  , publicationSignedBytes
  , publicationTransition
  , publicationPreviousDigest
  , publicationNextAnchor
  , reobserveDurableStage
  , acknowledgePublication
  , PublishedAssertion
  , commitPublishedAssertion

    -- * Pure in-memory interpreter
  , InMemoryAuthority
  , runInMemoryAuthority
  , FakeAuthorityState
  , fakeAuthorityPresent
  , fakeAuthorityMissing
  , fakeAuthorityCorrupt
  , fakeAuthorityUnobservable
  , fakeAuthorityReplacePresent
  , fakeAuthorityReadCount
  , fakeAuthorityCasCount
  , fakeAuthorityStoredRecord
  , inMemoryGatewayContinuityAuthority

    -- * Structured failures
  , ContinuityError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data ContinuityBoundField
  = MaximumEmitterBytes
  | MaximumOrdersAnchorBytes
  | MaximumSignedAssertionBytes
  deriving (Eq, Ord, Show)

data ContinuityBounds = ContinuityBounds
  { internalMaximumEmitterBytes :: Natural
  , internalMaximumOrdersAnchorBytes :: Natural
  , internalMaximumSignedAssertionBytes :: Natural
  }
  deriving (Eq, Show)

mkContinuityBounds
  :: Natural
  -> Natural
  -> Natural
  -> Either ContinuityError ContinuityBounds
mkContinuityBounds emitterBytes ordersBytes assertionBytes = do
  requirePositiveBound MaximumEmitterBytes emitterBytes
  requirePositiveBound MaximumOrdersAnchorBytes ordersBytes
  requirePositiveBound MaximumSignedAssertionBytes assertionBytes
  Right
    ContinuityBounds
      { internalMaximumEmitterBytes = emitterBytes
      , internalMaximumOrdersAnchorBytes = ordersBytes
      , internalMaximumSignedAssertionBytes = assertionBytes
      }

requirePositiveBound
  :: ContinuityBoundField
  -> Natural
  -> Either ContinuityError ()
requirePositiveBound field value =
  when (value == 0) (Left (ContinuityBoundMustBePositive field))

continuityMaxEmitterBytes :: ContinuityBounds -> Natural
continuityMaxEmitterBytes = internalMaximumEmitterBytes

continuityMaxOrdersAnchorBytes :: ContinuityBounds -> Natural
continuityMaxOrdersAnchorBytes = internalMaximumOrdersAnchorBytes

continuityMaxSignedAssertionBytes :: ContinuityBounds -> Natural
continuityMaxSignedAssertionBytes = internalMaximumSignedAssertionBytes

data ContinuityScope = ContinuityScope
  { internalContinuityBounds :: ContinuityBounds
  , internalContinuityEmitter :: Text
  , internalContinuityOrdersAnchor :: ByteString
  }
  deriving (Eq, Show)

mkContinuityScope
  :: ContinuityBounds
  -> Text
  -> ByteString
  -> Either ContinuityError ContinuityScope
mkContinuityScope bounds emitter ordersAnchor = do
  let emitterBytes = textBytes emitter
      ordersBytes = byteStringBytes ordersAnchor
      normalizedEmitter = Text.strip emitter
  when (Text.null normalizedEmitter) (Left ContinuityEmitterMustNotBeEmpty)
  when
    (emitterBytes > continuityMaxEmitterBytes bounds)
    ( Left
        ( ContinuityEmitterTooLarge
            emitterBytes
            (continuityMaxEmitterBytes bounds)
        )
    )
  when (BS.null ordersAnchor) (Left ContinuityOrdersAnchorMustNotBeEmpty)
  when
    (ordersBytes > continuityMaxOrdersAnchorBytes bounds)
    ( Left
        ( ContinuityOrdersAnchorTooLarge
            ordersBytes
            (continuityMaxOrdersAnchorBytes bounds)
        )
    )
  Right
    ContinuityScope
      { internalContinuityBounds = bounds
      , internalContinuityEmitter = normalizedEmitter
      , internalContinuityOrdersAnchor = ordersAnchor
      }

continuityScopeEmitter :: ContinuityScope -> Text
continuityScopeEmitter = internalContinuityEmitter

continuityScopeOrdersAnchor :: ContinuityScope -> ByteString
continuityScopeOrdersAnchor = internalContinuityOrdersAnchor

newtype ContinuityDigest = ContinuityDigest ByteString
  deriving (Eq, Generic, Ord, Show)

instance Serialise ContinuityDigest

continuityDigestWidth :: Int
continuityDigestWidth = 32

mkContinuityDigest :: ByteString -> Either ContinuityError ContinuityDigest
mkContinuityDigest bytes
  | BS.length bytes == continuityDigestWidth = Right (ContinuityDigest bytes)
  | otherwise =
      Left
        ( ContinuityDigestWidthInvalid
            continuityDigestWidth
            (BS.length bytes)
        )

continuityDigestBytes :: ContinuityDigest -> ByteString
continuityDigestBytes (ContinuityDigest bytes) = bytes

data ContinuityAnchor = ContinuityAnchor
  { internalContinuityEpoch :: Word64
  , internalContinuitySequence :: Word64
  , internalContinuityPreviousDigest :: ContinuityDigest
  }
  deriving (Eq, Generic, Ord, Show)

instance Serialise ContinuityAnchor

-- | Restore an anchor whose fixed-width digest has already passed
-- 'mkContinuityDigest'. Epoch and sequence span their complete 'Word64'
-- domains, so no additional partial validation remains at this boundary.
restoreContinuityAnchor :: Word64 -> Word64 -> ContinuityDigest -> ContinuityAnchor
restoreContinuityAnchor = ContinuityAnchor

continuityAnchorEpoch :: ContinuityAnchor -> Word64
continuityAnchorEpoch = internalContinuityEpoch

continuityAnchorSequence :: ContinuityAnchor -> Word64
continuityAnchorSequence = internalContinuitySequence

continuityAnchorPreviousDigest :: ContinuityAnchor -> ContinuityDigest
continuityAnchorPreviousDigest = internalContinuityPreviousDigest

data StagedTransition
  = SemanticAdvance
  | EpochInvalidation
  | OrdersScopeInvalidation
  deriving (Eq, Generic, Ord, Show)

instance Serialise StagedTransition

data StagedAssertion = StagedAssertion
  { internalStagedTransition :: StagedTransition
  , internalStagedSignedBytes :: ByteString
  , internalStagedPreviousDigest :: ContinuityDigest
  , internalStagedNextAnchor :: ContinuityAnchor
  }
  deriving (Eq, Generic, Show)

instance Serialise StagedAssertion

stagedAssertionTransition :: StagedAssertion -> StagedTransition
stagedAssertionTransition = internalStagedTransition

stagedAssertionSignedBytes :: StagedAssertion -> ByteString
stagedAssertionSignedBytes = internalStagedSignedBytes

stagedAssertionPreviousDigest :: StagedAssertion -> ContinuityDigest
stagedAssertionPreviousDigest = internalStagedPreviousDigest

stagedAssertionNextAnchor :: StagedAssertion -> ContinuityAnchor
stagedAssertionNextAnchor = internalStagedNextAnchor

data AuthorityRecord = AuthorityRecord
  { internalRecordEmitter :: Text
  , internalRecordOrdersAnchor :: ByteString
  , internalRecordCommittedAnchor :: ContinuityAnchor
  , internalRecordStagedAssertion :: Maybe StagedAssertion
  }
  deriving (Eq, Generic, Show)

instance Serialise AuthorityRecord

mkInitialAuthorityRecord
  :: ContinuityScope
  -> Word64
  -> Word64
  -> ContinuityDigest
  -> AuthorityRecord
mkInitialAuthorityRecord scope epoch sequenceNumber previousDigest =
  AuthorityRecord
    { internalRecordEmitter = continuityScopeEmitter scope
    , internalRecordOrdersAnchor = continuityScopeOrdersAnchor scope
    , internalRecordCommittedAnchor =
        ContinuityAnchor
          { internalContinuityEpoch = epoch
          , internalContinuitySequence = sequenceNumber
          , internalContinuityPreviousDigest = previousDigest
          }
    , internalRecordStagedAssertion = Nothing
    }

authorityRecordCommittedAnchor :: AuthorityRecord -> ContinuityAnchor
authorityRecordCommittedAnchor = internalRecordCommittedAnchor

authorityRecordStagedAssertion :: AuthorityRecord -> Maybe StagedAssertion
authorityRecordStagedAssertion = internalRecordStagedAssertion

-- | Concrete retained size of the bounded logical record.  Numeric fields and
-- the transition tag are counted at their fixed binary widths; an object-store
-- codec may add a separately bounded constant envelope.
authorityRecordRetainedBytes :: AuthorityRecord -> Natural
authorityRecordRetainedBytes record =
  textBytes (internalRecordEmitter record)
    + byteStringBytes (internalRecordOrdersAnchor record)
    + anchorBytes
    + maybe 0 stagedBytes (internalRecordStagedAssertion record)
 where
  anchorBytes = 8 + 8 + fromIntegral continuityDigestWidth
  stagedBytes staged =
    1
      + byteStringBytes (stagedAssertionSignedBytes staged)
      + fromIntegral continuityDigestWidth
      + anchorBytes

authorityRecordMaximumRetainedBytes :: ContinuityBounds -> Natural
authorityRecordMaximumRetainedBytes bounds =
  continuityMaxEmitterBytes bounds
    + continuityMaxOrdersAnchorBytes bounds
    + anchorBytes
    + 1
    + continuityMaxSignedAssertionBytes bounds
    + fromIntegral continuityDigestWidth
    + anchorBytes
 where
  anchorBytes = 8 + 8 + fromIntegral continuityDigestWidth

-- | Conservative ceiling for the CBOR record wrapper.  The fixed overhead
-- covers tags and length prefixes; all variable-width values are already
-- accounted for by 'authorityRecordMaximumRetainedBytes'.
authorityRecordMaximumEncodedBytes :: ContinuityBounds -> Natural
authorityRecordMaximumEncodedBytes bounds =
  authorityRecordMaximumRetainedBytes bounds + 256

data SignedSemanticAssertion = SignedSemanticAssertion
  { internalSemanticSignedBytes :: ByteString
  , internalSemanticDigest :: ContinuityDigest
  }
  deriving (Eq, Show)

data SignedEpochInvalidation = SignedEpochInvalidation
  { internalInvalidationSignedBytes :: ByteString
  , internalInvalidationDigest :: ContinuityDigest
  }
  deriving (Eq, Show)

mkSignedSemanticAssertion
  :: ContinuityBounds
  -> ByteString
  -> Either ContinuityError SignedSemanticAssertion
mkSignedSemanticAssertion bounds bytes = do
  validateSignedBytes bounds bytes
  Right
    SignedSemanticAssertion
      { internalSemanticSignedBytes = bytes
      , internalSemanticDigest = digestSignedBytes bytes
      }

mkSignedEpochInvalidation
  :: ContinuityBounds
  -> ByteString
  -> Either ContinuityError SignedEpochInvalidation
mkSignedEpochInvalidation bounds bytes = do
  validateSignedBytes bounds bytes
  Right
    SignedEpochInvalidation
      { internalInvalidationSignedBytes = bytes
      , internalInvalidationDigest = digestSignedBytes bytes
      }

validateSignedBytes
  :: ContinuityBounds
  -> ByteString
  -> Either ContinuityError ()
validateSignedBytes bounds bytes = do
  let actual = byteStringBytes bytes
      allowed = continuityMaxSignedAssertionBytes bounds
  when (BS.null bytes) (Left ContinuitySignedAssertionMustNotBeEmpty)
  when
    (actual > allowed)
    (Left (ContinuitySignedAssertionTooLarge actual allowed))

digestSignedBytes :: ByteString -> ContinuityDigest
digestSignedBytes = ContinuityDigest . SHA256.hash

newtype AuthorityVersion = AuthorityVersion Word64
  deriving (Eq, Generic, Ord, Show)

instance Serialise AuthorityVersion

authorityVersionValue :: AuthorityVersion -> Word64
authorityVersionValue (AuthorityVersion value) = value

data VersionedAuthorityRecord = VersionedAuthorityRecord
  { internalAuthorityVersion :: AuthorityVersion
  , internalVersionedRecord :: AuthorityRecord
  }
  deriving (Eq, Generic, Show)

instance Serialise VersionedAuthorityRecord

versionAuthorityRecord :: Word64 -> AuthorityRecord -> VersionedAuthorityRecord
versionAuthorityRecord version record =
  VersionedAuthorityRecord
    { internalAuthorityVersion = AuthorityVersion version
    , internalVersionedRecord = record
    }

versionedAuthorityVersion :: VersionedAuthorityRecord -> AuthorityVersion
versionedAuthorityVersion = internalAuthorityVersion

versionedAuthorityRecord :: VersionedAuthorityRecord -> AuthorityRecord
versionedAuthorityRecord = internalVersionedRecord

encodeVersionedAuthorityRecord :: VersionedAuthorityRecord -> ByteString
encodeVersionedAuthorityRecord = BL.toStrict . serialise

decodeVersionedAuthorityRecord
  :: ContinuityScope
  -> ByteString
  -> Either ContinuityError VersionedAuthorityRecord
decodeVersionedAuthorityRecord scope bytes = do
  let actualBytes = byteStringBytes bytes
      allowedBytes =
        authorityRecordMaximumEncodedBytes (internalContinuityBounds scope)
  when
    (actualBytes > allowedBytes)
    (Left (ContinuityEncodedRecordTooLarge actualBytes allowedBytes))
  versioned <-
    case deserialiseOrFail (BL.fromStrict bytes) of
      Left err -> Left (ContinuityRecordDecodeFailed (Text.pack (show err)))
      Right value -> Right value
  validateRecord scope (versionedAuthorityRecord versioned)
  Right versioned

data AuthorityObservation
  = AuthorityObserved VersionedAuthorityRecord
  | AuthorityMissing
  | AuthorityCorrupt Text
  | AuthorityUnobservable Text
  deriving (Eq, Show)

data AuthorityCasResult
  = AuthorityCasApplied VersionedAuthorityRecord
  | AuthorityCasConflict (Maybe AuthorityVersion)
  | AuthorityCasMissing
  | AuthorityCasCorrupt Text
  | AuthorityCasUnobservable Text
  deriving (Eq, Show)

data GatewayContinuityAuthority m = GatewayContinuityAuthority
  { internalAuthorityScope :: ContinuityScope
  , internalObserveAuthority :: m AuthorityObservation
  , internalInitializeAuthority :: AuthorityRecord -> m AuthorityCasResult
  , internalCompareAndSwapAuthority
      :: AuthorityVersion
      -> AuthorityRecord
      -> m AuthorityCasResult
  }

gatewayContinuityAuthority
  :: (Applicative m)
  => ContinuityScope
  -> m AuthorityObservation
  -> (AuthorityVersion -> AuthorityRecord -> m AuthorityCasResult)
  -> GatewayContinuityAuthority m
gatewayContinuityAuthority scope observe compareAndSwap =
  GatewayContinuityAuthority
    { internalAuthorityScope = scope
    , internalObserveAuthority = observe
    , internalInitializeAuthority = const (pure AuthorityCasMissing)
    , internalCompareAndSwapAuthority = compareAndSwap
    }

gatewayContinuityAuthorityWithInitialize
  :: ContinuityScope
  -> m AuthorityObservation
  -> (AuthorityRecord -> m AuthorityCasResult)
  -> (AuthorityVersion -> AuthorityRecord -> m AuthorityCasResult)
  -> GatewayContinuityAuthority m
gatewayContinuityAuthorityWithInitialize scope observe initialize compareAndSwap =
  GatewayContinuityAuthority
    { internalAuthorityScope = scope
    , internalObserveAuthority = observe
    , internalInitializeAuthority = initialize
    , internalCompareAndSwapAuthority = compareAndSwap
    }

data FirstContinuityAdmission = FirstContinuityAdmission
  { internalFirstAdmissionScope :: ContinuityScope
  , internalFirstAdmissionGenesisDigest :: ContinuityDigest
  }
  deriving (Eq, Show)

mkFirstContinuityAdmission
  :: ContinuityScope
  -> ContinuityDigest
  -> FirstContinuityAdmission
mkFirstContinuityAdmission scope genesisDigest =
  FirstContinuityAdmission
    { internalFirstAdmissionScope = scope
    , internalFirstAdmissionGenesisDigest = genesisDigest
    }

-- | Seed the retained anchor exactly once.  Only a definitive missing
-- observation reaches the initialize-if-absent callback; corrupt and
-- unobservable storage fail closed.  A concurrent initializer is resolved by
-- re-observing its winning record.
initializeContinuityAtFirstAdmission
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> FirstContinuityAdmission
  -> m (Either ContinuityError StartupRecovery)
initializeContinuityAtFirstAdmission authority admission =
  if internalFirstAdmissionScope admission /= internalAuthorityScope authority
    then pure (Left ContinuityFirstAdmissionScopeMismatch)
    else do
      observation <- internalObserveAuthority authority
      case observation of
        AuthorityObserved versioned -> pure (startupFromObserved authority versioned)
        AuthorityCorrupt reason -> pure (Left (ContinuityAuthorityCorrupt reason))
        AuthorityUnobservable reason ->
          pure (Left (ContinuityAuthorityUnobservable reason))
        AuthorityMissing -> do
          let initialRecord =
                mkInitialAuthorityRecord
                  (internalAuthorityScope authority)
                  1
                  0
                  (internalFirstAdmissionGenesisDigest admission)
              expected = versionAuthorityRecord 0 initialRecord
          result <- internalInitializeAuthority authority initialRecord
          case result of
            AuthorityCasApplied applied
              | applied == expected ->
                  pure (Right (StartupCurrent (CurrentContinuity applied)))
              | otherwise ->
                  pure (Left (ContinuityInitialAcknowledgementMismatch expected applied))
            AuthorityCasConflict _ -> recoverContinuityAtStartup authority
            AuthorityCasMissing -> pure (Left ContinuityAuthorityMissing)
            AuthorityCasCorrupt reason ->
              pure (Left (ContinuityAuthorityCorrupt reason))
            AuthorityCasUnobservable reason ->
              pure (Left (ContinuityAuthorityUnobservable reason))

data CurrentContinuity = CurrentContinuity VersionedAuthorityRecord
  deriving (Eq, Show)

currentContinuityVersion :: CurrentContinuity -> AuthorityVersion
currentContinuityVersion (CurrentContinuity versioned) =
  versionedAuthorityVersion versioned

currentContinuityAnchor :: CurrentContinuity -> ContinuityAnchor
currentContinuityAnchor (CurrentContinuity versioned) =
  authorityRecordCommittedAnchor (versionedAuthorityRecord versioned)

data PublicationWitness = PublicationWitness
  { internalPublicationVersioned :: VersionedAuthorityRecord
  , internalPublicationStaged :: StagedAssertion
  }
  deriving (Eq, Show)

publicationSignedBytes :: PublicationWitness -> ByteString
publicationSignedBytes = stagedAssertionSignedBytes . internalPublicationStaged

publicationTransition :: PublicationWitness -> StagedTransition
publicationTransition = stagedAssertionTransition . internalPublicationStaged

publicationPreviousDigest :: PublicationWitness -> ContinuityDigest
publicationPreviousDigest =
  stagedAssertionPreviousDigest . internalPublicationStaged

publicationNextAnchor :: PublicationWitness -> ContinuityAnchor
publicationNextAnchor = stagedAssertionNextAnchor . internalPublicationStaged

data StartupRecovery
  = StartupCurrent CurrentContinuity
  | StartupRepublish PublicationWitness
  deriving (Eq, Show)

recoverContinuityAtStartup
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> m (Either ContinuityError StartupRecovery)
recoverContinuityAtStartup authority = do
  observed <- observeValidated authority
  pure (observed >>= startupFromValidated)

startupFromObserved
  :: GatewayContinuityAuthority m
  -> VersionedAuthorityRecord
  -> Either ContinuityError StartupRecovery
startupFromObserved authority versioned = do
  validateRecord
    (internalAuthorityScope authority)
    (versionedAuthorityRecord versioned)
  startupFromValidated versioned

startupFromValidated
  :: VersionedAuthorityRecord
  -> Either ContinuityError StartupRecovery
startupFromValidated versioned =
  case authorityRecordStagedAssertion (versionedAuthorityRecord versioned) of
    Nothing -> Right (StartupCurrent (CurrentContinuity versioned))
    Just staged -> Right (StartupRepublish (PublicationWitness versioned staged))

data DurableStageAcknowledgement = DurableStageAcknowledgement VersionedAuthorityRecord
  deriving (Eq, Show)

durableStageVersion :: DurableStageAcknowledgement -> AuthorityVersion
durableStageVersion (DurableStageAcknowledgement versioned) =
  versionedAuthorityVersion versioned

stageSemanticAssertion
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> CurrentContinuity
  -> SignedSemanticAssertion
  -> m (Either ContinuityError DurableStageAcknowledgement)
stageSemanticAssertion authority current signed =
  stagePrepared
    authority
    current
    SemanticAdvance
    (internalSemanticSignedBytes signed)
    (internalSemanticDigest signed)

stageEpochInvalidation
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> CurrentContinuity
  -> SignedEpochInvalidation
  -> m (Either ContinuityError DurableStageAcknowledgement)
stageEpochInvalidation authority current signed =
  stagePrepared
    authority
    current
    EpochInvalidation
    (internalInvalidationSignedBytes signed)
    (internalInvalidationDigest signed)

stagePrepared
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> CurrentContinuity
  -> StagedTransition
  -> ByteString
  -> ContinuityDigest
  -> m (Either ContinuityError DurableStageAcknowledgement)
stagePrepared authority (CurrentContinuity current) transition signedBytes resultDigest =
  case prepareStagedRecord authority current transition signedBytes resultDigest of
    Left err -> pure (Left err)
    Right desired -> do
      let expectedVersion = versionedAuthorityVersion current
      case successorAuthorityVersion expectedVersion of
        Left err -> pure (Left err)
        Right nextVersion -> do
          outcome <-
            internalCompareAndSwapAuthority
              authority
              expectedVersion
              desired
          pure $ do
            applied <- mapCasResult outcome
            let expected =
                  VersionedAuthorityRecord
                    { internalAuthorityVersion = nextVersion
                    , internalVersionedRecord = desired
                    }
            unless
              (applied == expected)
              (Left (ContinuityDurableAcknowledgementMismatch expected applied))
            Right (DurableStageAcknowledgement applied)

prepareStagedRecord
  :: GatewayContinuityAuthority m
  -> VersionedAuthorityRecord
  -> StagedTransition
  -> ByteString
  -> ContinuityDigest
  -> Either ContinuityError AuthorityRecord
prepareStagedRecord authority current transition signedBytes resultDigest = do
  let scope = internalAuthorityScope authority
      record = versionedAuthorityRecord current
      committed = authorityRecordCommittedAnchor record
      bounds = internalContinuityBounds scope
  validateRecord scope record
  validateSignedBytes bounds signedBytes
  case authorityRecordStagedAssertion record of
    Just _ -> Left ContinuityAssertionAlreadyStaged
    Nothing -> do
      nextAnchor <- nextAnchorFor transition committed resultDigest
      let staged =
            StagedAssertion
              { internalStagedTransition = transition
              , internalStagedSignedBytes = signedBytes
              , internalStagedPreviousDigest =
                  continuityAnchorPreviousDigest committed
              , internalStagedNextAnchor = nextAnchor
              }
      Right record {internalRecordStagedAssertion = Just staged}

nextAnchorFor
  :: StagedTransition
  -> ContinuityAnchor
  -> ContinuityDigest
  -> Either ContinuityError ContinuityAnchor
nextAnchorFor transition committed resultDigest =
  let epoch = continuityAnchorEpoch committed
      sequenceNumber = continuityAnchorSequence committed
   in case transition of
        SemanticAdvance -> do
          when
            (sequenceNumber == maxBound)
            (Left (ContinuitySequenceRequiresRotation epoch))
          Right
            ContinuityAnchor
              { internalContinuityEpoch = epoch
              , internalContinuitySequence = sequenceNumber + 1
              , internalContinuityPreviousDigest = resultDigest
              }
        EpochInvalidation -> do
          unless
            (sequenceNumber == maxBound)
            (Left (ContinuityRotationBeforeSequenceExhaustion sequenceNumber))
          when
            (epoch == maxBound)
            (Left (ContinuityCountersExhausted epoch sequenceNumber))
          Right
            ContinuityAnchor
              { internalContinuityEpoch = epoch + 1
              , internalContinuitySequence = 0
              , internalContinuityPreviousDigest = resultDigest
              }
        OrdersScopeInvalidation -> do
          when
            (epoch == maxBound)
            (Left (ContinuityCountersExhausted epoch sequenceNumber))
          Right
            ContinuityAnchor
              { internalContinuityEpoch = epoch + 1
              , internalContinuitySequence = 0
              , internalContinuityPreviousDigest = resultDigest
              }

reobserveDurableStage
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> DurableStageAcknowledgement
  -> m (Either ContinuityError PublicationWitness)
reobserveDurableStage authority (DurableStageAcknowledgement acknowledged) = do
  observed <- observeValidated authority
  pure $ do
    reobserved <- observed
    unless
      (reobserved == acknowledged)
      (Left (ContinuityReobservationMismatch acknowledged reobserved))
    case authorityRecordStagedAssertion (versionedAuthorityRecord reobserved) of
      Nothing -> Left ContinuityReobservedStageWasAbsent
      Just staged -> Right (PublicationWitness reobserved staged)

newtype PublishedAssertion = PublishedAssertion PublicationWitness
  deriving (Eq, Show)

-- | Cross the effect boundary only after the caller has successfully
-- published the exact bytes carried by the witness.  A recovered staged
-- assertion uses this same function after idempotent re-publication.
acknowledgePublication :: PublicationWitness -> PublishedAssertion
acknowledgePublication = PublishedAssertion

commitPublishedAssertion
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> PublishedAssertion
  -> m (Either ContinuityError CurrentContinuity)
commitPublishedAssertion authority (PublishedAssertion witness) =
  let stagedVersioned = internalPublicationVersioned witness
      stagedRecord = versionedAuthorityRecord stagedVersioned
      staged = internalPublicationStaged witness
      committedRecord =
        stagedRecord
          { internalRecordCommittedAnchor = stagedAssertionNextAnchor staged
          , internalRecordStagedAssertion = Nothing
          }
      expectedVersion = versionedAuthorityVersion stagedVersioned
   in case validateRecord (internalAuthorityScope authority) stagedRecord of
        Left err -> pure (Left err)
        Right () ->
          case successorAuthorityVersion expectedVersion of
            Left err -> pure (Left err)
            Right nextVersion -> do
              outcome <-
                internalCompareAndSwapAuthority
                  authority
                  expectedVersion
                  committedRecord
              pure $ do
                applied <- mapCasResult outcome
                let expected =
                      VersionedAuthorityRecord
                        { internalAuthorityVersion = nextVersion
                        , internalVersionedRecord = committedRecord
                        }
                unless
                  (applied == expected)
                  (Left (ContinuityDurableAcknowledgementMismatch expected applied))
                Right (CurrentContinuity applied)

observeValidated
  :: (Monad m)
  => GatewayContinuityAuthority m
  -> m (Either ContinuityError VersionedAuthorityRecord)
observeValidated authority = do
  observation <- internalObserveAuthority authority
  pure $ case observation of
    AuthorityMissing -> Left ContinuityAuthorityMissing
    AuthorityCorrupt reason -> Left (ContinuityAuthorityCorrupt reason)
    AuthorityUnobservable reason ->
      Left (ContinuityAuthorityUnobservable reason)
    AuthorityObserved versioned -> do
      validateRecord
        (internalAuthorityScope authority)
        (versionedAuthorityRecord versioned)
      Right versioned

validateRecord
  :: ContinuityScope
  -> AuthorityRecord
  -> Either ContinuityError ()
validateRecord scope record = do
  unless
    (internalRecordEmitter record == continuityScopeEmitter scope)
    ( Left
        ( ContinuityEmitterMismatch
            (continuityScopeEmitter scope)
            (internalRecordEmitter record)
        )
    )
  unless
    (internalRecordOrdersAnchor record == continuityScopeOrdersAnchor scope)
    (Left ContinuityOrdersAnchorMismatch)
  let actualBytes = authorityRecordRetainedBytes record
      maximumBytes = authorityRecordMaximumRetainedBytes (internalContinuityBounds scope)
  when
    (actualBytes > maximumBytes)
    (Left (ContinuityRecordBoundExceeded actualBytes maximumBytes))
  case authorityRecordStagedAssertion record of
    Nothing -> Right ()
    Just staged -> validateStagedRecord scope record staged

validateStagedRecord
  :: ContinuityScope
  -> AuthorityRecord
  -> StagedAssertion
  -> Either ContinuityError ()
validateStagedRecord scope record staged = do
  validateSignedBytes
    (internalContinuityBounds scope)
    (stagedAssertionSignedBytes staged)
  let committed = authorityRecordCommittedAnchor record
      previous = continuityAnchorPreviousDigest committed
      actualDigest = digestSignedBytes (stagedAssertionSignedBytes staged)
  unless
    (stagedAssertionPreviousDigest staged == previous)
    (Left ContinuityStagedPreviousDigestMismatch)
  unless
    (continuityAnchorPreviousDigest (stagedAssertionNextAnchor staged) == actualDigest)
    (Left ContinuityStagedPayloadDigestMismatch)
  expectedNext <-
    nextAnchorFor
      (stagedAssertionTransition staged)
      committed
      actualDigest
  unless
    (stagedAssertionNextAnchor staged == expectedNext)
    (Left ContinuityStagedAnchorInvalid)

successorAuthorityVersion
  :: AuthorityVersion
  -> Either ContinuityError AuthorityVersion
successorAuthorityVersion version
  | authorityVersionValue version == maxBound =
      Left (ContinuityAuthorityVersionExhausted version)
  | otherwise =
      Right (AuthorityVersion (authorityVersionValue version + 1))

mapCasResult
  :: AuthorityCasResult
  -> Either ContinuityError VersionedAuthorityRecord
mapCasResult outcome =
  case outcome of
    AuthorityCasApplied versioned -> Right versioned
    AuthorityCasConflict version -> Left (ContinuityAuthorityCasConflict version)
    AuthorityCasMissing -> Left ContinuityAuthorityMissing
    AuthorityCasCorrupt reason -> Left (ContinuityAuthorityCorrupt reason)
    AuthorityCasUnobservable reason ->
      Left (ContinuityAuthorityUnobservable reason)

newtype InMemoryAuthority a = InMemoryAuthority
  { runInMemoryAuthority :: FakeAuthorityState -> (a, FakeAuthorityState)
  }

instance Functor InMemoryAuthority where
  fmap transform action =
    InMemoryAuthority $ \initial ->
      let (value, final) = runInMemoryAuthority action initial
       in (transform value, final)

instance Applicative InMemoryAuthority where
  pure value = InMemoryAuthority (value,)
  functionAction <*> valueAction =
    InMemoryAuthority $ \initial ->
      let (function, afterFunction) = runInMemoryAuthority functionAction initial
          (value, final) = runInMemoryAuthority valueAction afterFunction
       in (function value, final)

instance Monad InMemoryAuthority where
  action >>= continue =
    InMemoryAuthority $ \initial ->
      let (value, afterAction) = runInMemoryAuthority action initial
       in runInMemoryAuthority (continue value) afterAction

data FakeAuthorityDisposition
  = FakeAuthorityPresent VersionedAuthorityRecord
  | FakeAuthorityMissing
  | FakeAuthorityCorrupt Text
  | FakeAuthorityUnobservable Text
  deriving (Eq, Show)

data FakeAuthorityState = FakeAuthorityState
  { internalFakeDisposition :: FakeAuthorityDisposition
  , internalFakeReadCount :: Natural
  , internalFakeCasCount :: Natural
  }
  deriving (Eq, Show)

fakeAuthorityPresent :: VersionedAuthorityRecord -> FakeAuthorityState
fakeAuthorityPresent versioned =
  initialFakeAuthority (FakeAuthorityPresent versioned)

fakeAuthorityMissing :: FakeAuthorityState
fakeAuthorityMissing = initialFakeAuthority FakeAuthorityMissing

fakeAuthorityCorrupt :: Text -> FakeAuthorityState
fakeAuthorityCorrupt reason =
  initialFakeAuthority (FakeAuthorityCorrupt reason)

fakeAuthorityUnobservable :: Text -> FakeAuthorityState
fakeAuthorityUnobservable reason =
  initialFakeAuthority (FakeAuthorityUnobservable reason)

initialFakeAuthority :: FakeAuthorityDisposition -> FakeAuthorityState
initialFakeAuthority disposition =
  FakeAuthorityState
    { internalFakeDisposition = disposition
    , internalFakeReadCount = 0
    , internalFakeCasCount = 0
    }

fakeAuthorityReplacePresent
  :: VersionedAuthorityRecord
  -> FakeAuthorityState
  -> FakeAuthorityState
fakeAuthorityReplacePresent versioned state =
  state {internalFakeDisposition = FakeAuthorityPresent versioned}

fakeAuthorityReadCount :: FakeAuthorityState -> Natural
fakeAuthorityReadCount = internalFakeReadCount

fakeAuthorityCasCount :: FakeAuthorityState -> Natural
fakeAuthorityCasCount = internalFakeCasCount

fakeAuthorityStoredRecord
  :: FakeAuthorityState
  -> Maybe VersionedAuthorityRecord
fakeAuthorityStoredRecord state =
  case internalFakeDisposition state of
    FakeAuthorityPresent versioned -> Just versioned
    FakeAuthorityMissing -> Nothing
    FakeAuthorityCorrupt _ -> Nothing
    FakeAuthorityUnobservable _ -> Nothing

inMemoryGatewayContinuityAuthority
  :: ContinuityScope
  -> GatewayContinuityAuthority InMemoryAuthority
inMemoryGatewayContinuityAuthority scope =
  gatewayContinuityAuthorityWithInitialize
    scope
    observeFake
    initializeFake
    compareAndSwapFake

observeFake :: InMemoryAuthority AuthorityObservation
observeFake =
  InMemoryAuthority $ \state ->
    let observation =
          case internalFakeDisposition state of
            FakeAuthorityPresent versioned -> AuthorityObserved versioned
            FakeAuthorityMissing -> AuthorityMissing
            FakeAuthorityCorrupt reason -> AuthorityCorrupt reason
            FakeAuthorityUnobservable reason -> AuthorityUnobservable reason
        nextState =
          state {internalFakeReadCount = internalFakeReadCount state + 1}
     in (observation, nextState)

initializeFake
  :: AuthorityRecord
  -> InMemoryAuthority AuthorityCasResult
initializeFake desired =
  InMemoryAuthority $ \state ->
    let attempted =
          state {internalFakeCasCount = internalFakeCasCount state + 1}
     in case internalFakeDisposition state of
          FakeAuthorityMissing ->
            let initial = versionAuthorityRecord 0 desired
             in ( AuthorityCasApplied initial
                , attempted
                    { internalFakeDisposition = FakeAuthorityPresent initial
                    }
                )
          FakeAuthorityPresent current ->
            ( AuthorityCasConflict (Just (versionedAuthorityVersion current))
            , attempted
            )
          FakeAuthorityCorrupt reason ->
            (AuthorityCasCorrupt reason, attempted)
          FakeAuthorityUnobservable reason ->
            (AuthorityCasUnobservable reason, attempted)

compareAndSwapFake
  :: AuthorityVersion
  -> AuthorityRecord
  -> InMemoryAuthority AuthorityCasResult
compareAndSwapFake expected desired =
  InMemoryAuthority $ \state ->
    let attempted =
          state {internalFakeCasCount = internalFakeCasCount state + 1}
     in case internalFakeDisposition state of
          FakeAuthorityMissing -> (AuthorityCasMissing, attempted)
          FakeAuthorityCorrupt reason ->
            (AuthorityCasCorrupt reason, attempted)
          FakeAuthorityUnobservable reason ->
            (AuthorityCasUnobservable reason, attempted)
          FakeAuthorityPresent current
            | versionedAuthorityVersion current /= expected ->
                ( AuthorityCasConflict
                    (Just (versionedAuthorityVersion current))
                , attempted
                )
            | authorityVersionValue expected == maxBound ->
                (AuthorityCasConflict (Just expected), attempted)
            | otherwise ->
                let next =
                      VersionedAuthorityRecord
                        { internalAuthorityVersion =
                            AuthorityVersion (authorityVersionValue expected + 1)
                        , internalVersionedRecord = desired
                        }
                 in ( AuthorityCasApplied next
                    , attempted
                        { internalFakeDisposition = FakeAuthorityPresent next
                        }
                    )

textBytes :: Text -> Natural
textBytes = byteStringBytes . TextEncoding.encodeUtf8

byteStringBytes :: ByteString -> Natural
byteStringBytes = fromIntegral . BS.length

data ContinuityError
  = ContinuityBoundMustBePositive ContinuityBoundField
  | ContinuityEmitterMustNotBeEmpty
  | ContinuityEmitterTooLarge Natural Natural
  | ContinuityOrdersAnchorMustNotBeEmpty
  | ContinuityOrdersAnchorTooLarge Natural Natural
  | ContinuityDigestWidthInvalid Int Int
  | ContinuitySignedAssertionMustNotBeEmpty
  | ContinuitySignedAssertionTooLarge Natural Natural
  | ContinuityAuthorityMissing
  | ContinuityAuthorityCorrupt Text
  | ContinuityAuthorityUnobservable Text
  | ContinuityEmitterMismatch Text Text
  | ContinuityOrdersAnchorMismatch
  | ContinuityRecordBoundExceeded Natural Natural
  | ContinuityEncodedRecordTooLarge Natural Natural
  | ContinuityRecordDecodeFailed Text
  | ContinuityFirstAdmissionScopeMismatch
  | ContinuityInitialAcknowledgementMismatch
      VersionedAuthorityRecord
      VersionedAuthorityRecord
  | ContinuityAssertionAlreadyStaged
  | ContinuitySequenceRequiresRotation Word64
  | ContinuityRotationBeforeSequenceExhaustion Word64
  | ContinuityCountersExhausted Word64 Word64
  | ContinuityAuthorityVersionExhausted AuthorityVersion
  | ContinuityAuthorityCasConflict (Maybe AuthorityVersion)
  | ContinuityDurableAcknowledgementMismatch
      VersionedAuthorityRecord
      VersionedAuthorityRecord
  | ContinuityReobservationMismatch
      VersionedAuthorityRecord
      VersionedAuthorityRecord
  | ContinuityReobservedStageWasAbsent
  | ContinuityStagedPreviousDigestMismatch
  | ContinuityStagedPayloadDigestMismatch
  | ContinuityStagedAnchorInvalid
  deriving (Eq, Show)
