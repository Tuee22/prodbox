{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

-- | Authority-owned create-or-exact-replay storage for a compiled cleanup
-- program descriptor.  A write result is never proof of durability: only the
-- independent read-back path decodes, recompiles, and exact-validates the
-- descriptor before returning the opaque committed value.
module Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
  ( CleanupProgramDescriptorAuthorityClient
  , CleanupProgramDescriptorCommitResult (..)
  , CleanupProgramDescriptorRepositoryError (..)
  , CommittedCleanupProgramDescriptor
  , committedCleanupProgramDescriptorRunId
  , committedCleanupProgramDescriptorSurface
  , committedCleanupProgramDescriptorFoundation
  , committedCleanupProgramDescriptorAwsScope
  , committedCleanupProgramDescriptorAwsDnsZone
  , committedCleanupProgramDescriptorRegistryRevision
  , committedCleanupProgramDescriptorLifecycleOperation
  , committedCleanupProgramDescriptorGraphDigest
  , committedCleanupProgramDescriptorCapabilityCatalogDigest
  , committedCleanupProgramDescriptorDigest
  , committedCleanupProgramDescriptorBytes
  , cleanupProgramDescriptorAuthorityLogicalName
  , modelBCleanupProgramDescriptorRepository
  , cleanupProgramDescriptorModelBCodec
  , commitCleanupProgramDescriptorAttempt
  , independentlyReadBackCommittedCleanupProgramDescriptor
  , confirmCommittedCleanupProgramDescriptorBytes
  , withCommittedCleanupProgramDescriptor
  , CleanupProgramDescriptorRepositoryRegression
  , fixedCleanupProgramDescriptorRepositoryRegression
  , cleanupProgramDescriptorRegressionAllSurfacesCaptured
  , cleanupProgramDescriptorRegressionInitialStateRefused
  , cleanupProgramDescriptorRegressionResponseLossRecovered
  , cleanupProgramDescriptorRegressionExactReplayPreserved
  , cleanupProgramDescriptorRegressionConflictPreserved
  , cleanupProgramDescriptorRegressionTamperingRefused
  , cleanupProgramDescriptorRegressionUnknownStatesRefused
  , cleanupProgramDescriptorRegressionWrongRunRefused
  , cleanupProgramDescriptorRegressionRestartReconstructionValidated
  , cleanupProgramDescriptorRegressionLegacyV1RestartReadable
  )
where

import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft, isRight)
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
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import Prodbox.Aws.SigV4 (hexSha256)
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
  ( CleanupDigest
  , CleanupOwnerId
  , CleanupPrimaryOutcome (CleanupPrimarySucceeded)
  , CleanupRunId
  , cleanupLeaseFence
  , cleanupRunIdText
  , cleanupRunLease
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  , recordPrimaryOutcome
  )
import Prodbox.Lifecycle.CleanupRun qualified as CleanupRun
import Prodbox.Lifecycle.DnsRecord
  ( HostedZoneId
  , hostedZoneIdText
  , mkHostedZoneId
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , CleanupProgramDescriptorError
  , captureCleanupProgramDescriptor
  , cleanupProgramDescriptorAwsDnsZone
  , cleanupProgramDescriptorAwsScope
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorCapabilityCatalogDigest
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorFoundation
  , cleanupProgramDescriptorGraphDigest
  , cleanupProgramDescriptorLifecycleOperation
  , cleanupProgramDescriptorOperationIdentityVersion
  , cleanupProgramDescriptorRegistryRevision
  , cleanupProgramDescriptorRunId
  , cleanupProgramDescriptorSurface
  , maximumCleanupProgramDescriptorBytes
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal
  ( decodeAndValidateCleanupProgramDescriptor
  , legacyV1CleanupProgramDescriptorBytesForRegression
  , withRecompiledCleanupProgramDescriptor
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  )
import Prodbox.Lifecycle.Teardown.Graph qualified as TeardownGraph
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , LifecycleOperation
  , LinuxRke2FoundationId (..)
  , ObservationFailure (..)
  , RegistryRevision
  , cleanupSurfaceFromWitness
  )

data CleanupProgramDescriptorAuthorityClient m
  = CleanupProgramDescriptorAuthorityClient
      !LongLivedCheckpointAuthority
      !(ModelBCasAdapter 'ClusterRetained m ByteString.ByteString)

data CleanupProgramDescriptorCommitResult
  = CleanupProgramDescriptorCommitCreated
  | CleanupProgramDescriptorCommitExactReplay
  | CleanupProgramDescriptorCommitConflict
  | CleanupProgramDescriptorCommitResponseLost !ObservationFailure
  | CleanupProgramDescriptorCommitUnavailable !ObservationFailure
  deriving (Eq, Show)

data CleanupProgramDescriptorRepositoryError
  = CleanupProgramDescriptorRepositoryCoordinateInvalid !Text
  | CleanupProgramDescriptorRepositoryMissing
  | CleanupProgramDescriptorRepositoryCorrupt !Text
  | CleanupProgramDescriptorRepositoryUnobservable !ObservationFailure
  | CleanupProgramDescriptorRepositoryUnbounded !Int !Int
  | CleanupProgramDescriptorRepositoryDescriptorInvalid
      !CleanupProgramDescriptorError
  | CleanupProgramDescriptorRepositoryRunIdMismatch
      !CleanupRunId
      !CleanupRunId
  deriving (Eq, Show)

newtype CommittedCleanupProgramDescriptor
  = CommittedCleanupProgramDescriptor CleanupProgramDescriptor

committedCleanupProgramDescriptorRunId
  :: CommittedCleanupProgramDescriptor -> CleanupRunId
committedCleanupProgramDescriptorRunId
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorRunId descriptor

committedCleanupProgramDescriptorSurface
  :: CommittedCleanupProgramDescriptor -> CleanupSurface
committedCleanupProgramDescriptorSurface
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorSurface descriptor

committedCleanupProgramDescriptorFoundation
  :: CommittedCleanupProgramDescriptor -> LinuxRke2FoundationId
committedCleanupProgramDescriptorFoundation
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorFoundation descriptor

committedCleanupProgramDescriptorAwsScope
  :: CommittedCleanupProgramDescriptor -> Maybe AwsScope
committedCleanupProgramDescriptorAwsScope
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorAwsScope descriptor

committedCleanupProgramDescriptorAwsDnsZone
  :: CommittedCleanupProgramDescriptor -> Maybe HostedZoneId
committedCleanupProgramDescriptorAwsDnsZone
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorAwsDnsZone descriptor

committedCleanupProgramDescriptorRegistryRevision
  :: CommittedCleanupProgramDescriptor -> RegistryRevision
committedCleanupProgramDescriptorRegistryRevision
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorRegistryRevision descriptor

committedCleanupProgramDescriptorLifecycleOperation
  :: CommittedCleanupProgramDescriptor -> LifecycleOperation
committedCleanupProgramDescriptorLifecycleOperation
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorLifecycleOperation descriptor

committedCleanupProgramDescriptorGraphDigest
  :: CommittedCleanupProgramDescriptor -> CleanupDigest
committedCleanupProgramDescriptorGraphDigest
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorGraphDigest descriptor

committedCleanupProgramDescriptorCapabilityCatalogDigest
  :: CommittedCleanupProgramDescriptor -> Text
committedCleanupProgramDescriptorCapabilityCatalogDigest
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorCapabilityCatalogDigest descriptor

committedCleanupProgramDescriptorDigest
  :: CommittedCleanupProgramDescriptor -> CleanupDigest
committedCleanupProgramDescriptorDigest
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorDigest descriptor

committedCleanupProgramDescriptorBytes
  :: CommittedCleanupProgramDescriptor -> ByteString.ByteString
committedCleanupProgramDescriptorBytes
  (CommittedCleanupProgramDescriptor descriptor) =
    cleanupProgramDescriptorBytes descriptor

-- | Package-private Authority restart boundary.  Committed bytes are decoded
-- and the closed surface program plus exact initial run are reconstructed
-- inside a rank-2 continuation, so no existential or raw decoder escapes.
withCommittedCleanupProgramDescriptor
  :: CommittedCleanupProgramDescriptor
  -> ( forall surface
        . CleanupSurfaceWitness surface
       -> TeardownGraph.CompiledDesiredAbsenceProgram surface
       -> CleanupRun.CleanupRun
       -> result
     )
  -> Either CleanupProgramDescriptorRepositoryError result
withCommittedCleanupProgramDescriptor
  (CommittedCleanupProgramDescriptor descriptor)
  consume =
    first
      CleanupProgramDescriptorRepositoryDescriptorInvalid
      (withRecompiledCleanupProgramDescriptor descriptor consume)

cleanupProgramDescriptorAuthorityLogicalName :: CleanupRunId -> Text
cleanupProgramDescriptorAuthorityLogicalName runId =
  "authority/cleanup-program-descriptors/"
    <> TextEncoding.decodeUtf8
      ( hexSha256
          ( TextEncoding.encodeUtf8
              ( Text.concat
                  ( map
                      frame
                      [ "cleanup-program-descriptor-identity/v1"
                      , cleanupRunIdText runId
                      ]
                  )
              )
          )
      )
 where
  -- A CleanupRunId owns exactly one immutable descriptor slot.  The full
  -- canonical bytes are compared on every replay; a different graph, scope,
  -- catalog, or initial run under the same run id is an explicit conflict,
  -- never a second logical key.
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

modelBCleanupProgramDescriptorRepository
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString.ByteString
  -> CleanupProgramDescriptorAuthorityClient m
modelBCleanupProgramDescriptorRepository =
  CleanupProgramDescriptorAuthorityClient

cleanupProgramDescriptorModelBCodec :: ModelBCodec ByteString.ByteString
cleanupProgramDescriptorModelBCodec =
  ModelBCodec
    { encodeModelBValue = validateBytes
    , decodeModelBValue = validateBytes
    }
 where
  validateBytes bytes
    | ByteString.length bytes > maximumCleanupProgramDescriptorBytes =
        Left "cleanup program descriptor exceeds its encoded bound"
    | otherwise =
        bytes
          <$ first
            show
            (decodeAndValidateCleanupProgramDescriptor bytes)

commitCleanupProgramDescriptorAttempt
  :: (Monad m)
  => CleanupProgramDescriptorAuthorityClient m
  -> CleanupProgramDescriptor
  -> m CleanupProgramDescriptorCommitResult
commitCleanupProgramDescriptorAttempt
  (CleanupProgramDescriptorAuthorityClient authority adapter)
  descriptor =
    case descriptorCoordinate authority (cleanupProgramDescriptorRunId descriptor) of
      Left detail -> pure (commitUnavailable "coordinate" detail)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate
          ModelBObserved _ bytes -> pure (existingDisposition bytes)
          ModelBCorrupt detail -> pure (commitUnavailable "corrupt" detail)
          ModelBEndpointUnready detail ->
            pure (commitUnavailable "endpoint-unready" detail)
          ModelBUnobservable detail ->
            pure (commitUnavailable "unobservable" detail)
   where
    expectedBytes = cleanupProgramDescriptorBytes descriptor

    initialize coordinate = do
      attempted <-
        modelBCompareAndSwap adapter (ModelBInitialize coordinate expectedBytes)
      pure $ case attempted of
        ModelBCasApplied _ bytes
          | bytes == expectedBytes -> CleanupProgramDescriptorCommitCreated
          | otherwise -> CleanupProgramDescriptorCommitConflict
        ModelBCasConflict observation -> conflictDisposition observation
        ModelBCasRefusedCorrupt detail -> commitUnavailable "cas-corrupt" detail
        ModelBCasEndpointUnready detail ->
          commitUnavailable "cas-endpoint-unready" detail
        ModelBCasUnobservable detail ->
          CleanupProgramDescriptorCommitResponseLost
            (repositoryFailure "cas-response-unobservable" detail)

    existingDisposition bytes
      | bytes == expectedBytes = CleanupProgramDescriptorCommitExactReplay
      | otherwise = CleanupProgramDescriptorCommitConflict

    conflictDisposition observation = case observation of
      ModelBObserved _ bytes -> existingDisposition bytes
      ModelBMissing ->
        CleanupProgramDescriptorCommitResponseLost
          (repositoryFailure "cas-conflict-missing" "conflict value is missing")
      ModelBCorrupt detail -> commitUnavailable "cas-conflict-corrupt" detail
      ModelBEndpointUnready detail ->
        CleanupProgramDescriptorCommitResponseLost
          (repositoryFailure "cas-conflict-endpoint-unready" detail)
      ModelBUnobservable detail ->
        CleanupProgramDescriptorCommitResponseLost
          (repositoryFailure "cas-conflict-unobservable" detail)

independentlyReadBackCommittedCleanupProgramDescriptor
  :: (Monad m)
  => CleanupProgramDescriptorAuthorityClient m
  -> CleanupRunId
  -> m
       ( Either
           CleanupProgramDescriptorRepositoryError
           CommittedCleanupProgramDescriptor
       )
independentlyReadBackCommittedCleanupProgramDescriptor
  (CleanupProgramDescriptorAuthorityClient authority adapter)
  expectedRunId =
    case descriptorCoordinate authority expectedRunId of
      Left detail ->
        pure
          (Left (CleanupProgramDescriptorRepositoryCoordinateInvalid detail))
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Left CleanupProgramDescriptorRepositoryMissing
          ModelBObserved _ bytes ->
            confirmCommittedCleanupProgramDescriptorBytes expectedRunId bytes
          ModelBCorrupt detail ->
            Left (CleanupProgramDescriptorRepositoryCorrupt detail)
          ModelBEndpointUnready detail ->
            Left
              ( CleanupProgramDescriptorRepositoryUnobservable
                  (repositoryFailure "endpoint-unready" detail)
              )
          ModelBUnobservable detail ->
            Left
              ( CleanupProgramDescriptorRepositoryUnobservable
                  (repositoryFailure "unobservable" detail)
              )

-- | Package-private codec bridge for bytes obtained from the authenticated
-- Lifecycle Authority readback endpoint. A caller-supplied payload cannot use
-- this seam: only the trusted CleanupRun transport client imports this module.
confirmCommittedCleanupProgramDescriptorBytes
  :: CleanupRunId
  -> ByteString.ByteString
  -> Either
       CleanupProgramDescriptorRepositoryError
       CommittedCleanupProgramDescriptor
confirmCommittedCleanupProgramDescriptorBytes expectedRunId bytes
  | ByteString.length bytes > maximumCleanupProgramDescriptorBytes =
      Left
        ( CleanupProgramDescriptorRepositoryUnbounded
            (ByteString.length bytes)
            maximumCleanupProgramDescriptorBytes
        )
  | otherwise = do
      descriptor <-
        first
          CleanupProgramDescriptorRepositoryDescriptorInvalid
          (decodeAndValidateCleanupProgramDescriptor bytes)
      let observedRunId = cleanupProgramDescriptorRunId descriptor
      if observedRunId == expectedRunId
        then Right (CommittedCleanupProgramDescriptor descriptor)
        else
          Left
            ( CleanupProgramDescriptorRepositoryRunIdMismatch
                expectedRunId
                observedRunId
            )

descriptorCoordinate
  :: LongLivedCheckpointAuthority
  -> CleanupRunId
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
descriptorCoordinate authority runId =
  first
    (Text.pack . show)
    ( mkClusterRetainedCoordinate
        authority
        (cleanupProgramDescriptorAuthorityLogicalName runId)
    )

commitUnavailable
  :: Text -> Text -> CleanupProgramDescriptorCommitResult
commitUnavailable category detail =
  CleanupProgramDescriptorCommitUnavailable
    (repositoryFailure category detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    ("cleanup-program-descriptor/" <> category <> ":" <> detail)

-- | A fixed, non-parameterised regression result.  It deliberately carries no
-- repository, adapter, descriptor bytes, committed value, or proof-making
-- callback across the public facade.
data CleanupProgramDescriptorRepositoryRegression
  = CleanupProgramDescriptorRepositoryRegression
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool

data RegressionInputs = RegressionInputs
  { regressionInputsAuthority :: !LongLivedCheckpointAuthority
  , regressionInputsModelBVersion :: !ModelBObjectVersion
  , regressionInputsRunId :: !CleanupRunId
  , regressionInputsAlternateRunId :: !CleanupRunId
  , regressionInputsOwner :: !CleanupOwnerId
  }

fixedCleanupProgramDescriptorRepositoryRegression
  :: IO (Either Text CleanupProgramDescriptorRepositoryRegression)
fixedCleanupProgramDescriptorRepositoryRegression =
  case regressionInputsAndFixture of
    Left detail -> pure (Left detail)
    Right (inputs, compiled, initialRun, candidate) -> do
      durable <-
        newRegressionDurable
          (regressionInputsModelBVersion inputs)
          True
      let authority = regressionInputsAuthority inputs
          runId = regressionInputsRunId inputs
          owner = regressionInputsOwner inputs
          client = regressionClient authority durable
          observedBytes =
            ModelBObserved (regressionInputsModelBVersion inputs)
          readBackFromObservation observation =
            independentlyReadBackCommittedCleanupProgramDescriptor
              (constantRegressionClient authority observation)
              runId
      firstAttempt <- commitCleanupProgramDescriptorAttempt client candidate
      recovered <-
        independentlyReadBackCommittedCleanupProgramDescriptor
          client
          runId
      replayed <- commitCleanupProgramDescriptorAttempt client candidate
      alternate <-
        pure
          ( regressionCandidate
              owner
              CascadeSurface
              runId
              alternateFoundation
              (Just regressionAwsScope)
          )
      conflict <- case alternate of
        Left _ -> pure CleanupProgramDescriptorCommitCreated
        Right alternateCandidate ->
          commitCleanupProgramDescriptorAttempt client alternateCandidate
      ordinaryTamperingRefused <- case tamperedCandidates candidate of
        Left _ -> pure False
        Right tampered ->
          and
            <$> mapM
              (fmap isLeft . readBackFromObservation . observedBytes)
              tampered
      zoneTamperingRefused <-
        case ( mkHostedZoneId "Z0123456789ABCDEFGHIJ"
             , mkHostedZoneId "ZABCDEFGHIJ0123456789"
             ) of
          (Right originalZone, Right replacementZone) ->
            case regressionCandidateWithDnsZone
              owner
              CascadeSurface
              runId
              regressionFoundation
              (Just regressionAwsScope)
              (Just originalZone) of
              Left _ -> pure False
              Right zonedCandidate ->
                case replaceFirst
                  (TextEncoding.encodeUtf8 (hostedZoneIdText originalZone))
                  (TextEncoding.encodeUtf8 (hostedZoneIdText replacementZone))
                  (cleanupProgramDescriptorBytes zonedCandidate) of
                  Left _ -> pure False
                  Right tampered ->
                    isLeft <$> readBackFromObservation (observedBytes tampered)
          _ -> pure False
      legacyV1RestartReadable <-
        case legacyV1CleanupProgramDescriptorBytesForRegression candidate of
          Left _ -> pure False
          Right legacyBytes ->
            isRight <$> readBackFromObservation (observedBytes legacyBytes)
      missingRefused <-
        isLeft <$> readBackFromObservation ModelBMissing
      unobservableRefused <-
        isLeft
          <$> readBackFromObservation
            (ModelBUnobservable "fixed transport ambiguity")
      wrongRunCandidate <-
        pure
          ( regressionCandidate
              owner
              CascadeSurface
              (regressionInputsAlternateRunId inputs)
              regressionFoundation
              (Just regressionAwsScope)
          )
      wrongRunRefused <- case wrongRunCandidate of
        Left _ -> pure False
        Right wrong ->
          isLeft
            <$> readBackFromObservation
              (observedBytes (cleanupProgramDescriptorBytes wrong))
      let transitioned =
            recordPrimaryOutcome
              owner
              (cleanupLeaseFence (cleanupRunLease initialRun))
              CleanupPrimarySucceeded
              initialRun
          initialStateRefused = case transitioned of
            Left _ -> False
            Right nonInitial ->
              isLeft (captureCleanupProgramDescriptor compiled nonInitial)
          responseLossRecovered =
            isResponseLost firstAttempt
              && committedMatchesRun runId recovered
          exactReplayPreserved =
            replayed == CleanupProgramDescriptorCommitExactReplay
          conflictPreserved =
            conflict == CleanupProgramDescriptorCommitConflict
          tamperingRefused =
            ordinaryTamperingRefused && zoneTamperingRefused
          restartReconstructionValidated = case recovered of
            Left _ -> False
            Right committed ->
              case withCommittedCleanupProgramDescriptor committed $ \witness rebuilt rebuiltRun ->
                cleanupSurfaceFromWitness witness
                  == cleanupProgramDescriptorSurface candidate
                  && compiledDesiredAbsenceGraph rebuilt
                    == compiledDesiredAbsenceGraph compiled
                  && rebuiltRun == initialRun of
                Right True -> True
                _ -> False
      pure
        ( Right
            ( CleanupProgramDescriptorRepositoryRegression
                (allSurfacesCaptured inputs)
                initialStateRefused
                responseLossRecovered
                exactReplayPreserved
                conflictPreserved
                tamperingRefused
                (missingRefused && unobservableRefused)
                wrongRunRefused
                restartReconstructionValidated
                legacyV1RestartReadable
            )
        )
 where
  committedMatchesRun runId result = case result of
    Right committed ->
      committedCleanupProgramDescriptorRunId committed == runId
    Left _ -> False

  isResponseLost result = case result of
    CleanupProgramDescriptorCommitResponseLost _ -> True
    _ -> False

regressionInputsAndFixture
  :: Either
       Text
       ( RegressionInputs
       , TeardownGraph.CompiledDesiredAbsenceProgram 'Cascade
       , CleanupRun.CleanupRun
       , CleanupProgramDescriptor
       )
regressionInputsAndFixture = do
  inputs <- regressionInputs
  compiled <-
    first
      (Text.pack . show)
      ( compileDesiredAbsenceGraph
          (regressionInputsRunId inputs)
          regressionFoundation
          (Just regressionAwsScope)
          Nothing
          CascadeSurface
      )
  initialRun <-
    first
      (Text.pack . show)
      ( newCleanupRun
          (regressionInputsRunId inputs)
          (compiledDesiredAbsenceGraph compiled)
          (regressionInputsOwner inputs)
          1
          1000
      )
  candidate <-
    first
      (Text.pack . show)
      (captureCleanupProgramDescriptor compiled initialRun)
  Right (inputs, compiled, initialRun, candidate)

regressionInputs :: Either Text RegressionInputs
regressionInputs = do
  authority <-
    first
      (Text.pack . show)
      ( mkLongLivedCheckpointAuthority
          "home-linux-rke2"
          "prodbox-authority"
          "authority"
          "secret/lifecycle"
      )
  version <-
    first
      (Text.pack . show)
      (mkModelBObjectVersion "descriptor-version-1")
  runId <- first (Text.pack . show) (mkCleanupRunId "descriptor-regression")
  alternateRun <-
    first (Text.pack . show) (mkCleanupRunId "descriptor-other-run")
  owner <-
    first (Text.pack . show) (mkCleanupOwnerId "descriptor-authority")
  Right
    RegressionInputs
      { regressionInputsAuthority = authority
      , regressionInputsModelBVersion = version
      , regressionInputsRunId = runId
      , regressionInputsAlternateRunId = alternateRun
      , regressionInputsOwner = owner
      }

cleanupProgramDescriptorRegressionAllSurfacesCaptured
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionAllSurfacesCaptured
  (CleanupProgramDescriptorRepositoryRegression value _ _ _ _ _ _ _ _ _) = value

cleanupProgramDescriptorRegressionInitialStateRefused
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionInitialStateRefused
  (CleanupProgramDescriptorRepositoryRegression _ value _ _ _ _ _ _ _ _) = value

cleanupProgramDescriptorRegressionResponseLossRecovered
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionResponseLossRecovered
  (CleanupProgramDescriptorRepositoryRegression _ _ value _ _ _ _ _ _ _) = value

cleanupProgramDescriptorRegressionExactReplayPreserved
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionExactReplayPreserved
  (CleanupProgramDescriptorRepositoryRegression _ _ _ value _ _ _ _ _ _) = value

cleanupProgramDescriptorRegressionConflictPreserved
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionConflictPreserved
  (CleanupProgramDescriptorRepositoryRegression _ _ _ _ value _ _ _ _ _) = value

cleanupProgramDescriptorRegressionTamperingRefused
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionTamperingRefused
  (CleanupProgramDescriptorRepositoryRegression _ _ _ _ _ value _ _ _ _) = value

cleanupProgramDescriptorRegressionUnknownStatesRefused
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionUnknownStatesRefused
  (CleanupProgramDescriptorRepositoryRegression _ _ _ _ _ _ value _ _ _) = value

cleanupProgramDescriptorRegressionWrongRunRefused
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionWrongRunRefused
  (CleanupProgramDescriptorRepositoryRegression _ _ _ _ _ _ _ value _ _) = value

cleanupProgramDescriptorRegressionRestartReconstructionValidated
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionRestartReconstructionValidated
  (CleanupProgramDescriptorRepositoryRegression _ _ _ _ _ _ _ _ value _) = value

cleanupProgramDescriptorRegressionLegacyV1RestartReadable
  :: CleanupProgramDescriptorRepositoryRegression -> Bool
cleanupProgramDescriptorRegressionLegacyV1RestartReadable
  (CleanupProgramDescriptorRepositoryRegression _ _ _ _ _ _ _ _ _ value) = value

allSurfacesCaptured :: RegressionInputs -> Bool
allSurfacesCaptured inputs =
  and
    [ regressionSurfaceCaptured inputs LocalOnlySurface "descriptor-local" Nothing
    , regressionSurfaceCaptured
        inputs
        CascadeSurface
        "descriptor-cascade"
        (Just regressionAwsScope)
    , regressionSurfaceCaptured
        inputs
        ExplicitPerRunSurface
        "descriptor-per-run"
        (Just regressionAwsScope)
    , regressionSurfaceCaptured
        inputs
        OperationalTeardownSurface
        "descriptor-operational"
        (Just regressionAwsScope)
    , regressionSurfaceCaptured
        inputs
        ExplicitLongLivedSurface
        "descriptor-long-lived"
        (Just regressionAwsScope)
    , regressionSurfaceCaptured
        inputs
        TotalDecommissionSurface
        "descriptor-decommission"
        (Just regressionAwsScope)
    ]

regressionSurfaceCaptured
  :: RegressionInputs
  -> CleanupSurfaceWitness surface
  -> Text
  -> Maybe AwsScope
  -> Bool
regressionSurfaceCaptured inputs surface rawRunId awsScope =
  case mkCleanupRunId rawRunId of
    Left _ -> False
    Right runId ->
      isRight
        ( regressionCandidate
            (regressionInputsOwner inputs)
            surface
            runId
            regressionFoundation
            awsScope
        )

regressionCandidate
  :: CleanupOwnerId
  -> CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Either Text CleanupProgramDescriptor
regressionCandidate owner surface runId foundation awsScope =
  regressionCandidateWithDnsZone
    owner
    surface
    runId
    foundation
    awsScope
    Nothing

regressionCandidateWithDnsZone
  :: CleanupOwnerId
  -> CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> Either Text CleanupProgramDescriptor
regressionCandidateWithDnsZone owner surface runId foundation awsScope awsDnsZone = do
  compiled <-
    first
      (Text.pack . show)
      (compileDesiredAbsenceGraph runId foundation awsScope awsDnsZone surface)
  initialRun <-
    first
      (Text.pack . show)
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          owner
          1
          1000
      )
  first
    (Text.pack . show)
    (captureCleanupProgramDescriptor compiled initialRun)

tamperedCandidates
  :: CleanupProgramDescriptor
  -> Either Text [ByteString.ByteString]
tamperedCandidates candidate = do
  semanticTamper <-
    replaceFirst
      "observe/aws-eks"
      "observe/aws-eXs"
      (cleanupProgramDescriptorBytes candidate)
  versionTamper <-
    replaceFirst
      (TextEncoding.encodeUtf8 cleanupProgramDescriptorOperationIdentityVersion)
      "lifecycle-cleanup-operation/v2"
      (cleanupProgramDescriptorBytes candidate)
  Right [semanticTamper, versionTamper]

replaceFirst
  :: ByteString.ByteString
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> Either Text ByteString.ByteString
replaceFirst needle replacement haystack
  | ByteString.length needle /= ByteString.length replacement =
      Left "fixed replacement length differs"
  | ByteString.null suffix = Left "fixed replacement needle is missing"
  | otherwise =
      Right
        ( prefix
            <> replacement
            <> ByteString.drop (ByteString.length needle) suffix
        )
 where
  (prefix, suffix) = ByteString.breakSubstring needle haystack

data RegressionDurable = RegressionDurable
  { regressionDurableAdapter
      :: !(ModelBCasAdapter 'ClusterRetained IO ByteString.ByteString)
  }

newRegressionDurable :: ModelBObjectVersion -> Bool -> IO RegressionDurable
newRegressionDurable version loseFirstResponse = do
  valuesRef <- newIORef Map.empty
  loseRef <- newIORef loseFirstResponse
  let adapter =
        ModelBCasAdapter
          { modelBObserve = observeRegression valuesRef
          , modelBCompareAndSwap =
              compareAndSwapRegression version valuesRef loseRef
          }
  pure (RegressionDurable adapter)

observeRegression
  :: IORef (Map.Map Text (ModelBObjectVersion, ByteString.ByteString))
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (ModelBObservation ByteString.ByteString)
observeRegression valuesRef coordinate = do
  values <- readIORef valuesRef
  pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
    Nothing -> ModelBMissing
    Just (version, bytes) -> ModelBObserved version bytes

compareAndSwapRegression
  :: ModelBObjectVersion
  -> IORef (Map.Map Text (ModelBObjectVersion, ByteString.ByteString))
  -> IORef Bool
  -> ModelBCasRequest 'ClusterRetained ByteString.ByteString
  -> IO (ModelBCasResult ByteString.ByteString)
compareAndSwapRegression version valuesRef loseRef request = case request of
  ModelBInitialize coordinate bytes -> do
    let key = modelBObjectLogicalName coordinate
    values <- readIORef valuesRef
    case Map.lookup key values of
      Just (existingVersion, existing) ->
        pure (ModelBCasConflict (ModelBObserved existingVersion existing))
      Nothing -> do
        modifyIORef'
          valuesRef
          (Map.insert key (version, bytes))
        lose <- atomicModifyIORef' loseRef (False,)
        pure $
          if lose
            then ModelBCasUnobservable "fixed response loss after apply"
            else ModelBCasApplied version bytes
  ModelBReplace {} -> unexpectedRegressionRequest
  ModelBInitializeGuarded {} -> unexpectedRegressionRequest
  ModelBReplaceGuarded {} -> unexpectedRegressionRequest

unexpectedRegressionRequest :: IO (ModelBCasResult ByteString.ByteString)
unexpectedRegressionRequest =
  pure (ModelBCasUnobservable "unexpected fixed regression request")

regressionClient
  :: LongLivedCheckpointAuthority
  -> RegressionDurable
  -> CleanupProgramDescriptorAuthorityClient IO
regressionClient authority durable =
  modelBCleanupProgramDescriptorRepository
    authority
    (regressionDurableAdapter durable)

constantRegressionClient
  :: LongLivedCheckpointAuthority
  -> ModelBObservation ByteString.ByteString
  -> CleanupProgramDescriptorAuthorityClient IO
constantRegressionClient authority observation =
  modelBCleanupProgramDescriptorRepository
    authority
    ModelBCasAdapter
      { modelBObserve = const (pure observation)
      , modelBCompareAndSwap = const unexpectedRegressionRequest
      }

regressionFoundation :: LinuxRke2FoundationId
regressionFoundation = LinuxRke2FoundationId "foundation/home"

alternateFoundation :: LinuxRke2FoundationId
alternateFoundation = LinuxRke2FoundationId "foundation/other"

regressionAwsScope :: AwsScope
regressionAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion canonicalRegressionAwsRegion)
