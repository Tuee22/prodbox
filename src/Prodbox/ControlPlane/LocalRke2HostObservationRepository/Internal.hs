{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Package-private Lifecycle-Authority repository for the host-observed
-- local RKE2 Healthy claim.  Writes return only a disposition; the opaque
-- committed value is created exclusively by an independent exact read-back.
module Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal
  ( LocalRke2HostObservationRepositoryClient
  , LocalRke2HostObservationCommitResult (..)
  , LocalRke2HostObservationRepositoryError (..)
  , CommittedLocalRke2HostObservation
  , committedLocalRke2HostObservationIdentity
  , committedLocalRke2HostObservationRunId
  , committedLocalRke2HostObservationDescriptorDigest
  , committedLocalRke2HostObservationGraphDigest
  , committedLocalRke2HostObservationScope
  , committedLocalRke2HostObservationFoundation
  , committedLocalRke2HostObservationEstablishOperationId
  , committedLocalRke2HostObservationEstablishAttemptId
  , committedLocalRke2HostObservationIdentityDigest
  , modelBLocalRke2HostObservationRepositoryInternal
  , localRke2HostObservationModelBCodecInternal
  , localRke2HostObservationLogicalNameInternal
  , observeLocalRke2HealthyAfterEstablishBeginInternal
  , commitLocalRke2HostObservationAttemptInternal
  , commitEncodedLocalRke2HostObservationAttemptInternal
  , independentlyReadBackLocalRke2HostObservationAfterEstablishBeginInternal
  , independentlyReadBackLocalRke2HostObservationForRecoveryReadBackInternal
  , independentlyReadBackLocalRke2HostObservationForRecoveryObservationInternal
  , LocalRke2HostObservationRepositoryRegression
  , fixedLocalRke2HostObservationRepositoryRegression
  , localRke2HostObservationRegressionCanonicalBounded
  , localRke2HostObservationRegressionResponseLossRecovered
  , localRke2HostObservationRegressionExactReplayPreserved
  , localRke2HostObservationRegressionConflictPreserved
  , localRke2HostObservationRegressionTamperingRefused
  , localRke2HostObservationRegressionUnknownRefused
  , localRke2HostObservationRegressionAttemptKeySeparated
  , localRke2HostObservationRegressionDelayedAttemptRefused
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryStateError
  , observeLocalRke2RecoveryState
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  )
import Prodbox.ControlPlane.RecoveryPlaneRepository
  ( RecoveryPlaneRepositoryError
  )
import Prodbox.ControlPlane.RecoveryPlaneRepository.Internal
  ( RecoveryPlaneObservationBinding
  , withDescriptorBoundRecoveryPlaneEstablishBindingInternal
  , withDescriptorBoundRecoveryPlaneInitialContextInternal
  , withRecoveryPlaneObservationEstablishBindingInternal
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownExecutionContext
  )
import Prodbox.Lifecycle.Teardown.LocalRke2HostObservation
  ( LocalRke2HostObservationError
  , LocalRke2HostObservationIdentity
  , localRke2HostObservationDescriptorDigest
  , localRke2HostObservationEstablishAttemptId
  , localRke2HostObservationEstablishOperationId
  , localRke2HostObservationFoundation
  , localRke2HostObservationGraphDigest
  , localRke2HostObservationIdentityDigest
  , localRke2HostObservationRunId
  , localRke2HostObservationScope
  , maximumLocalRke2HostObservationBytes
  )
import Prodbox.Lifecycle.Teardown.LocalRke2HostObservation.Internal
  ( LocalRke2HostObservationCandidate
  , admitObservedLocalRke2HealthyInternal
  , encodeLocalRke2HostObservationCandidateInternal
  , encodeLocalRke2HostObservationIdentityInternal
  , fixedLocalRke2HostObservationCandidateInternal
  , fixedStaleLocalRke2HostObservationCandidateInternal
  , localRke2HostObservationCandidateIdentityInternal
  , localRke2HostObservationIdentityFromBindingInternal
  , validateCanonicalLocalRke2HostObservationBytesInternal
  , validateLocalRke2HostObservationCandidateBytesInternal
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface
  , LinuxRke2FoundationId
  , ObservationEvidenceScope
  , ObservationFailure (..)
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RecoverySurfaceWitness
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneIdentity
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( RecoveryPlaneAttemptBinding
  )

data LocalRke2HostObservationRepositoryClient m
  = LocalRke2HostObservationRepositoryClient
      !LongLivedCheckpointAuthority
      !(ModelBCasAdapter 'ClusterRetained m ByteString)

data LocalRke2HostObservationCommitResult
  = LocalRke2HostObservationCommitCreated
  | LocalRke2HostObservationCommitExactReplay
  | LocalRke2HostObservationCommitConflict
  | LocalRke2HostObservationCommitResponseLost !ObservationFailure
  | LocalRke2HostObservationCommitUnavailable !ObservationFailure
  deriving (Eq, Show)

data LocalRke2HostObservationRepositoryError
  = LocalRke2HostObservationRepositoryCoordinateInvalid !Text
  | LocalRke2HostObservationRepositoryEstablishBindingInvalid
      !RecoveryPlaneRepositoryError
  | LocalRke2HostObservationRepositoryStateUnobservable
      !LocalRke2RecoveryStateError
  | LocalRke2HostObservationRepositoryAdmissionInvalid
      !LocalRke2HostObservationError
  | LocalRke2HostObservationRepositoryMissing
  | LocalRke2HostObservationRepositoryCorrupt !Text
  | LocalRke2HostObservationRepositoryUnobservable !ObservationFailure
  | LocalRke2HostObservationRepositoryEncodedInvalid
      !LocalRke2HostObservationError
  deriving (Eq, Show)

newtype CommittedLocalRke2HostObservation (surface :: CleanupSurface)
  = CommittedLocalRke2HostObservationInternal
      (LocalRke2HostObservationIdentity surface)

committedLocalRke2HostObservationIdentity
  :: CommittedLocalRke2HostObservation surface
  -> LocalRke2HostObservationIdentity surface
committedLocalRke2HostObservationIdentity
  (CommittedLocalRke2HostObservationInternal identity) = identity

committedLocalRke2HostObservationRunId
  :: CommittedLocalRke2HostObservation surface -> CleanupRunId
committedLocalRke2HostObservationRunId =
  localRke2HostObservationRunId . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationDescriptorDigest
  :: CommittedLocalRke2HostObservation surface -> CleanupDigest
committedLocalRke2HostObservationDescriptorDigest =
  localRke2HostObservationDescriptorDigest
    . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationGraphDigest
  :: CommittedLocalRke2HostObservation surface -> CleanupDigest
committedLocalRke2HostObservationGraphDigest =
  localRke2HostObservationGraphDigest
    . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationScope
  :: CommittedLocalRke2HostObservation surface -> ObservationEvidenceScope
committedLocalRke2HostObservationScope =
  localRke2HostObservationScope . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationFoundation
  :: CommittedLocalRke2HostObservation surface -> LinuxRke2FoundationId
committedLocalRke2HostObservationFoundation =
  localRke2HostObservationFoundation
    . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationEstablishOperationId
  :: CommittedLocalRke2HostObservation surface -> CleanupOperationId
committedLocalRke2HostObservationEstablishOperationId =
  localRke2HostObservationEstablishOperationId
    . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationEstablishAttemptId
  :: CommittedLocalRke2HostObservation surface -> CleanupAttemptId
committedLocalRke2HostObservationEstablishAttemptId =
  localRke2HostObservationEstablishAttemptId
    . committedLocalRke2HostObservationIdentity

committedLocalRke2HostObservationIdentityDigest
  :: CommittedLocalRke2HostObservation surface -> Text
committedLocalRke2HostObservationIdentityDigest =
  localRke2HostObservationIdentityDigest
    . committedLocalRke2HostObservationIdentity

modelBLocalRke2HostObservationRepositoryInternal
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> LocalRke2HostObservationRepositoryClient m
modelBLocalRke2HostObservationRepositoryInternal =
  LocalRke2HostObservationRepositoryClient

-- | Retained-Authority storage codec.  Generic storage admission validates
-- bounds and canonical structure but cannot mint a committed receipt; exact
-- identity remains mandatory at commit and independent read-back.
localRke2HostObservationModelBCodecInternal :: ModelBCodec ByteString
localRke2HostObservationModelBCodecInternal =
  ModelBCodec
    { encodeModelBValue =
        first show . validateCanonicalLocalRke2HostObservationBytesInternal
    , decodeModelBValue =
        first show . validateCanonicalLocalRke2HostObservationBytesInternal
    }

localRke2HostObservationLogicalNameInternal
  :: LocalRke2HostObservationIdentity surface -> Text
localRke2HostObservationLogicalNameInternal identity =
  "authority/local-rke2-host-observation/"
    <> TextEncoding.decodeUtf8
      ( hexSha256
          ( lengthFrameBytes
              [ "local-rke2-host-observation-coordinate/v1"
              , encodeLocalRke2HostObservationIdentityInternal identity
              ]
          )
      )

-- | The sequencing boundary is intentional: establish admission is checked
-- before the host process/filesystem/API observer runs, so a caller cannot
-- submit a cached state captured before the fenced attempt began.
observeLocalRke2HealthyAfterEstablishBeginInternal
  :: DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> IO
       ( Either
           LocalRke2HostObservationRepositoryError
           (LocalRke2HostObservationCandidate surface)
       )
observeLocalRke2HealthyAfterEstablishBeginInternal bound witness context =
  case withDescriptorBoundRecoveryPlaneEstablishBindingInternal
    bound
    witness
    context
    (,) of
    Left err ->
      pure
        ( Left
            (LocalRke2HostObservationRepositoryEstablishBindingInvalid err)
        )
    Right (identity, binding) -> do
      observed <- observeLocalRke2RecoveryState
      pure $ case observed of
        Left err ->
          Left (LocalRke2HostObservationRepositoryStateUnobservable err)
        Right state ->
          first
            LocalRke2HostObservationRepositoryAdmissionInvalid
            (admitObservedLocalRke2HealthyInternal identity binding state)

commitLocalRke2HostObservationAttemptInternal
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> LocalRke2HostObservationCandidate surface
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           LocalRke2HostObservationCommitResult
       )
commitLocalRke2HostObservationAttemptInternal
  client
  candidate =
    commitEncodedLocalRke2HostObservationAttemptInternal
      client
      identity
      bytes
   where
    identity = localRke2HostObservationCandidateIdentityInternal candidate
    bytes = encodeLocalRke2HostObservationCandidateInternal candidate

-- | Host-transport commit boundary.  Supplied bytes must be canonical and
-- exactly match the opaque Authority-derived identity before the CAS is
-- attempted.  A commit disposition carries no positive read-back proof.
commitEncodedLocalRke2HostObservationAttemptInternal
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> LocalRke2HostObservationIdentity surface
  -> ByteString
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           LocalRke2HostObservationCommitResult
       )
commitEncodedLocalRke2HostObservationAttemptInternal
  client@(LocalRke2HostObservationRepositoryClient _ adapter)
  identity
  bytes =
    case first
      LocalRke2HostObservationRepositoryEncodedInvalid
      (validateLocalRke2HostObservationCandidateBytesInternal identity bytes) of
      Left err -> pure (Left err)
      Right () -> commitValidatedBytes client adapter identity bytes

commitValidatedBytes
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> LocalRke2HostObservationIdentity surface
  -> ByteString
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           LocalRke2HostObservationCommitResult
       )
commitValidatedBytes client adapter identity bytes =
  case observationCoordinate client identity of
    Left err -> pure (Left err)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      case observed of
        ModelBMissing -> initialize adapter coordinate bytes
        ModelBObserved _ existing
          | existing == bytes ->
              pure (Right LocalRke2HostObservationCommitExactReplay)
          | otherwise ->
              pure (Right LocalRke2HostObservationCommitConflict)
        ModelBCorrupt detail ->
          pure
            (Left (LocalRke2HostObservationRepositoryCorrupt detail))
        ModelBEndpointUnready detail ->
          pure (Right (commitUnavailable "observe-endpoint-unready" detail))
        ModelBUnobservable detail ->
          pure (Right (commitUnavailable "observe-unobservable" detail))
 where
  initialize casAdapter coordinate candidateBytes = do
    attempted <-
      modelBCompareAndSwap casAdapter (ModelBInitialize coordinate candidateBytes)
    pure $ case attempted of
      ModelBCasApplied _ applied
        | applied == candidateBytes ->
            Right LocalRke2HostObservationCommitCreated
        | otherwise -> Right LocalRke2HostObservationCommitConflict
      ModelBCasConflict conflict -> Right (classifyConflict candidateBytes conflict)
      ModelBCasRefusedCorrupt detail ->
        Left (LocalRke2HostObservationRepositoryCorrupt detail)
      ModelBCasEndpointUnready detail ->
        Right (commitResponseLost "cas-endpoint-unready" detail)
      ModelBCasUnobservable detail ->
        Right (commitResponseLost "cas-unobservable" detail)

independentlyReadBackLocalRke2HostObservationAfterEstablishBeginInternal
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           (CommittedLocalRke2HostObservation surface)
       )
independentlyReadBackLocalRke2HostObservationAfterEstablishBeginInternal
  client
  bound
  witness
  context =
    case withDescriptorBoundRecoveryPlaneEstablishBindingInternal
      bound
      witness
      context
      (,) of
      Left err ->
        pure
          ( Left
              (LocalRke2HostObservationRepositoryEstablishBindingInvalid err)
          )
      Right (identity, binding) ->
        readBackFromBinding client identity binding

-- | Recovery read-back independently reloads the exact Establish predecessor
-- from the descriptor-bound run.  A delayed receipt for an older attempt has
-- a different logical key and cannot satisfy this lookup.
independentlyReadBackLocalRke2HostObservationForRecoveryReadBackInternal
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           (CommittedLocalRke2HostObservation surface)
       )
independentlyReadBackLocalRke2HostObservationForRecoveryReadBackInternal
  client
  bound
  witness
  context =
    case withDescriptorBoundRecoveryPlaneInitialContextInternal
      bound
      witness
      context
      (\identity establishBinding _ _ -> (identity, establishBinding)) of
      Left err ->
        pure
          ( Left
              (LocalRke2HostObservationRepositoryEstablishBindingInvalid err)
          )
      Right (identity, establishBinding) ->
        readBackFromBinding client identity establishBinding

-- | Component-observer read-back.  The opaque binding is minted only by the
-- descriptor-bound initial/final context validators and carries both the
-- current phase and the authoritative Establish predecessor.  This helper
-- validates the exact identity and phase before deriving the retained key.
independentlyReadBackLocalRke2HostObservationForRecoveryObservationInternal
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> RecoveryPlaneIdentity surface
  -> RecoveryPlaneObservationBinding surface
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           (CommittedLocalRke2HostObservation surface)
       )
independentlyReadBackLocalRke2HostObservationForRecoveryObservationInternal
  client
  identity
  observationBinding =
    case withRecoveryPlaneObservationEstablishBindingInternal
      identity
      observationBinding
      (readBackFromBinding client identity) of
      Left err ->
        pure
          ( Left
              (LocalRke2HostObservationRepositoryEstablishBindingInvalid err)
          )
      Right readBack -> readBack

readBackFromBinding
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> RecoveryPlaneIdentity surface
  -> RecoveryPlaneAttemptBinding surface
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           (CommittedLocalRke2HostObservation surface)
       )
readBackFromBinding client identity binding =
  case first
    LocalRke2HostObservationRepositoryAdmissionInvalid
    (localRke2HostObservationIdentityFromBindingInternal identity binding) of
    Left err -> pure (Left err)
    Right expected -> readBackExpected client expected

readBackExpected
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> LocalRke2HostObservationIdentity surface
  -> m
       ( Either
           LocalRke2HostObservationRepositoryError
           (CommittedLocalRke2HostObservation surface)
       )
readBackExpected
  client@(LocalRke2HostObservationRepositoryClient _ adapter)
  expected =
    case observationCoordinate client expected of
      Left err -> pure (Left err)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Left LocalRke2HostObservationRepositoryMissing
          ModelBObserved _ bytes -> do
            first
              LocalRke2HostObservationRepositoryEncodedInvalid
              ( validateLocalRke2HostObservationCandidateBytesInternal
                  expected
                  bytes
              )
            Right (CommittedLocalRke2HostObservationInternal expected)
          ModelBCorrupt detail ->
            Left (LocalRke2HostObservationRepositoryCorrupt detail)
          ModelBEndpointUnready detail ->
            Left
              ( LocalRke2HostObservationRepositoryUnobservable
                  (repositoryFailure "read-back-endpoint-unready" detail)
              )
          ModelBUnobservable detail ->
            Left
              ( LocalRke2HostObservationRepositoryUnobservable
                  (repositoryFailure "read-back-unobservable" detail)
              )

observationCoordinate
  :: LocalRke2HostObservationRepositoryClient m
  -> LocalRke2HostObservationIdentity surface
  -> Either
       LocalRke2HostObservationRepositoryError
       (ModelBObjectCoordinate 'ClusterRetained)
observationCoordinate
  (LocalRke2HostObservationRepositoryClient authority _)
  identity =
    first
      (LocalRke2HostObservationRepositoryCoordinateInvalid . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (localRke2HostObservationLogicalNameInternal identity)
      )

classifyConflict
  :: ByteString
  -> ModelBObservation ByteString
  -> LocalRke2HostObservationCommitResult
classifyConflict expected observed = case observed of
  ModelBObserved _ existing
    | existing == expected -> LocalRke2HostObservationCommitExactReplay
  _ -> LocalRke2HostObservationCommitConflict

commitUnavailable :: Text -> Text -> LocalRke2HostObservationCommitResult
commitUnavailable category detail =
  LocalRke2HostObservationCommitUnavailable
    (repositoryFailure category detail)

commitResponseLost :: Text -> Text -> LocalRke2HostObservationCommitResult
commitResponseLost category detail =
  LocalRke2HostObservationCommitResponseLost
    (repositoryFailure category detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    ("local-rke2-host-observation/" <> category <> ":" <> detail)

lengthFrameBytes :: [ByteString] -> ByteString
lengthFrameBytes = ByteString.concat . map frame
 where
  frame bytes =
    TextEncoding.encodeUtf8 (Text.pack (show (ByteString.length bytes)) <> ":")
      <> bytes

-- | Fixed non-authorizing regression diagnostics.  No client, adapter,
-- canonical bytes, candidate, or committed value crosses the public facade.
data LocalRke2HostObservationRepositoryRegression
  = LocalRke2HostObservationRepositoryRegression
  { localRke2HostObservationRegressionCanonicalBounded :: !Bool
  , localRke2HostObservationRegressionResponseLossRecovered :: !Bool
  , localRke2HostObservationRegressionExactReplayPreserved :: !Bool
  , localRke2HostObservationRegressionConflictPreserved :: !Bool
  , localRke2HostObservationRegressionTamperingRefused :: !Bool
  , localRke2HostObservationRegressionUnknownRefused :: !Bool
  , localRke2HostObservationRegressionAttemptKeySeparated :: !Bool
  , localRke2HostObservationRegressionDelayedAttemptRefused :: !Bool
  }
  deriving (Eq, Show)

fixedLocalRke2HostObservationRepositoryRegression
  :: IO (Either Text LocalRke2HostObservationRepositoryRegression)
fixedLocalRke2HostObservationRepositoryRegression =
  case (fixedAuthority, mkModelBObjectVersion "host-observation-v1") of
    (Left detail, _) -> pure (Left detail)
    (_, Left err) -> pure (Left (Text.pack (show err)))
    (Right authority, Right version) -> runRegression authority version

runRegression
  :: LongLivedCheckpointAuthority
  -> ModelBObjectVersion
  -> IO (Either Text LocalRke2HostObservationRepositoryRegression)
runRegression authority version = do
  responseLossHarness <- newRegressionHarness version True
  let current = fixedLocalRke2HostObservationCandidateInternal
      stale = fixedStaleLocalRke2HostObservationCandidateInternal
      currentIdentity = localRke2HostObservationCandidateIdentityInternal current
      staleIdentity = localRke2HostObservationCandidateIdentityInternal stale
      currentBytes = encodeLocalRke2HostObservationCandidateInternal current
      staleBytes = encodeLocalRke2HostObservationCandidateInternal stale
      responseLossClient = regressionClient authority responseLossHarness
  responseLost <- commitLocalRke2HostObservationAttemptInternal responseLossClient current
  recovered <- readBackExpected responseLossClient currentIdentity
  replayed <- commitLocalRke2HostObservationAttemptInternal responseLossClient current

  delayedHarness <- newRegressionHarness version False
  let delayedClient = regressionClient authority delayedHarness
  _ <- commitLocalRke2HostObservationAttemptInternal delayedClient stale
  staleCannotAuthorizeCurrent <-
    isMissing <$> readBackExpected delayedClient currentIdentity
  _ <- commitLocalRke2HostObservationAttemptInternal delayedClient current
  currentRecovered <- isRight <$> readBackExpected delayedClient currentIdentity

  conflict <-
    commitLocalRke2HostObservationAttemptInternal
      (constantRegressionClient authority (ModelBObserved version staleBytes))
      current
  tampered <-
    readBackExpected
      ( constantRegressionClient
          authority
          (ModelBObserved version (currentBytes <> "trailing"))
      )
      currentIdentity
  oversized <-
    readBackExpected
      ( constantRegressionClient
          authority
          ( ModelBObserved
              version
              (ByteString.replicate (maximumLocalRke2HostObservationBytes + 1) 0)
          )
      )
      currentIdentity
  missing <-
    readBackExpected
      (constantRegressionClient authority ModelBMissing)
      currentIdentity
  unknown <-
    readBackExpected
      ( constantRegressionClient
          authority
          (ModelBUnobservable "fixed transport ambiguity")
      )
      currentIdentity

  pure
    ( Right
        LocalRke2HostObservationRepositoryRegression
          { localRke2HostObservationRegressionCanonicalBounded =
              ByteString.length currentBytes
                <= maximumLocalRke2HostObservationBytes
                && validateLocalRke2HostObservationCandidateBytesInternal
                  currentIdentity
                  currentBytes
                  == Right ()
          , localRke2HostObservationRegressionResponseLossRecovered =
              isResponseLost responseLost && isRight recovered
          , localRke2HostObservationRegressionExactReplayPreserved =
              replayed
                == Right LocalRke2HostObservationCommitExactReplay
          , localRke2HostObservationRegressionConflictPreserved =
              conflict == Right LocalRke2HostObservationCommitConflict
          , localRke2HostObservationRegressionTamperingRefused =
              isEncodedInvalid tampered && isEncodedInvalid oversized
          , localRke2HostObservationRegressionUnknownRefused =
              isMissing missing && isUnobservable unknown
          , localRke2HostObservationRegressionAttemptKeySeparated =
              localRke2HostObservationLogicalNameInternal staleIdentity
                /= localRke2HostObservationLogicalNameInternal currentIdentity
          , localRke2HostObservationRegressionDelayedAttemptRefused =
              staleCannotAuthorizeCurrent && currentRecovered
          }
    )

data RegressionHarness = RegressionHarness
  { regressionStore
      :: !(IORef (Map.Map Text (ModelBObjectVersion, ByteString)))
  , regressionVersion :: !ModelBObjectVersion
  , regressionLoseNextWrite :: !(IORef Bool)
  }

newRegressionHarness
  :: ModelBObjectVersion -> Bool -> IO RegressionHarness
newRegressionHarness version loseFirstResponse =
  RegressionHarness
    <$> newIORef Map.empty
    <*> pure version
    <*> newIORef loseFirstResponse

regressionClient
  :: LongLivedCheckpointAuthority
  -> RegressionHarness
  -> LocalRke2HostObservationRepositoryClient IO
regressionClient authority harness =
  modelBLocalRke2HostObservationRepositoryInternal
    authority
    ModelBCasAdapter
      { modelBObserve = observeRegression harness
      , modelBCompareAndSwap = compareAndSwapRegression harness
      }

constantRegressionClient
  :: LongLivedCheckpointAuthority
  -> ModelBObservation ByteString
  -> LocalRke2HostObservationRepositoryClient IO
constantRegressionClient authority observation =
  modelBLocalRke2HostObservationRepositoryInternal
    authority
    ModelBCasAdapter
      { modelBObserve = const (pure observation)
      , modelBCompareAndSwap =
          const (pure (ModelBCasUnobservable "unexpected fixed write"))
      }

observeRegression
  :: RegressionHarness
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (ModelBObservation ByteString)
observeRegression harness coordinate = do
  stored <- readIORef (regressionStore harness)
  pure $ case Map.lookup (modelBObjectLogicalName coordinate) stored of
    Nothing -> ModelBMissing
    Just (version, bytes) -> ModelBObserved version bytes

compareAndSwapRegression
  :: RegressionHarness
  -> ModelBCasRequest 'ClusterRetained ByteString
  -> IO (ModelBCasResult ByteString)
compareAndSwapRegression harness request = case request of
  ModelBInitialize coordinate bytes -> do
    let key = modelBObjectLogicalName coordinate
    stored <- readIORef (regressionStore harness)
    case Map.lookup key stored of
      Just (version, existing) ->
        pure (ModelBCasConflict (ModelBObserved version existing))
      Nothing -> do
        modifyIORef'
          (regressionStore harness)
          (Map.insert key (regressionVersion harness, bytes))
        lose <- atomicModifyIORef' (regressionLoseNextWrite harness) (False,)
        pure
          ( if lose
              then ModelBCasUnobservable "fixed response loss after apply"
              else ModelBCasApplied (regressionVersion harness) bytes
          )
  ModelBReplace {} -> unexpectedRegressionRequest
  ModelBInitializeGuarded {} -> unexpectedRegressionRequest
  ModelBReplaceGuarded {} -> unexpectedRegressionRequest

unexpectedRegressionRequest :: IO (ModelBCasResult ByteString)
unexpectedRegressionRequest =
  pure (ModelBCasUnobservable "unexpected fixed regression request")

fixedAuthority :: Either Text LongLivedCheckpointAuthority
fixedAuthority =
  first
    (Text.pack . show)
    ( mkLongLivedCheckpointAuthority
        "home-linux-rke2"
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

isResponseLost
  :: Either
       LocalRke2HostObservationRepositoryError
       LocalRke2HostObservationCommitResult
  -> Bool
isResponseLost result = case result of
  Right LocalRke2HostObservationCommitResponseLost {} -> True
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

isMissing
  :: Either LocalRke2HostObservationRepositoryError value -> Bool
isMissing result = case result of
  Left LocalRke2HostObservationRepositoryMissing -> True
  _ -> False

isUnobservable
  :: Either LocalRke2HostObservationRepositoryError value -> Bool
isUnobservable result = case result of
  Left LocalRke2HostObservationRepositoryUnobservable {} -> True
  _ -> False

isEncodedInvalid
  :: Either LocalRke2HostObservationRepositoryError value -> Bool
isEncodedInvalid result = case result of
  Left LocalRke2HostObservationRepositoryEncodedInvalid {} -> True
  _ -> False
