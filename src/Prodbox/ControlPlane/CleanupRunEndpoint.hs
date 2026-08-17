{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle-Authority endpoint for Sprint 5.18 retained
-- cleanup ownership. Wire identities are rebuilt through smart constructors;
-- callers cannot select a physical object-store coordinate.
module Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (..)
  , CleanupRunDescriptorCommand (..)
  , CleanupRunDescriptorResponse (..)
  , CleanupRunDescriptorRefusal (..)
  , CleanupRunRepositoryProvider (..)
  , CleanupRunEndpointResult (..)
  , cleanupRunMaximumBytes
  , serveCleanupRunRequest
  , cleanupRunEndpointStatus
  , cleanupRunEndpointBody
  , decodeCleanupRunScanResponse
  , encodeCleanupRunDescriptorResponse
  , decodeCleanupRunDescriptorResponse
  , cleanupRunDescriptorResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint (authorityBackupCiphertextBytes)
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
  ( CleanupProgramDescriptorAuthorityClient
  , CleanupProgramDescriptorCommitResult (..)
  , CleanupProgramDescriptorRepositoryError (..)
  , CommittedCleanupProgramDescriptor
  , commitCleanupProgramDescriptorAttempt
  , committedCleanupProgramDescriptorDigest
  , committedCleanupProgramDescriptorRunId
  , independentlyReadBackCommittedCleanupProgramDescriptor
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
  ( committedCleanupProgramDescriptorBytes
  , withCommittedCleanupProgramDescriptor
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupNodeOutcome
  , CleanupOwnerId
  , CleanupPrimaryOutcome
  , CleanupRun
  , CleanupRunError
  , CleanupRunId
  , CleanupRunIndexEntry (..)
  , CleanupRunIndexRepository (..)
  , CleanupRunIndexSnapshot (..)
  , CleanupRunReport
  , CleanupRunRepository (..)
  , CleanupRunSnapshot (..)
  , CleanupRunStoreError
    ( CleanupRunStoreMissing
    , CleanupRunStoreTransitionRejected
    )
  , CleanupRunTombstone
  , DescriptorBoundCleanupRunRepository (..)
  , DescriptorBoundCleanupRunSnapshot (..)
  , applyCleanupRunTransition
  , applyDescriptorBoundCleanupRunTransition
  , beginCleanupNode
  , claimCleanupRun
  , cleanupDigestText
  , cleanupLeaseExpiresAtMicros
  , cleanupRunGraph
  , cleanupRunGraphDigest
  , cleanupRunId
  , cleanupRunIdText
  , cleanupRunIndexEntries
  , cleanupRunLease
  , cleanupRunTerminal
  , cleanupRunTombstoneId
  , cleanupRunTombstoneReportDigest
  , compactCleanupRunDurably
  , compactDescriptorBoundCleanupRunDurably
  , completeCleanupNode
  , createCleanupRunDurably
  , createDescriptorBoundCleanupRunDurably
  , decodeCleanupRun
  , decodeCleanupRunReport
  , encodeCleanupRun
  , encodeCleanupRunReport
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupNodeId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , publishCleanupRunTombstone
  , recordPrimaryOutcome
  , registerCleanupRun
  , registerDescriptorBoundCleanupRun
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorRunId
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal
  ( decodeAndValidateCleanupProgramDescriptor
  )

cleanupRunMaximumBytes :: Int
cleanupRunMaximumBytes = 3 * 1024 * 1024

cleanupRunDescriptorResponseMaximumBytes :: Int
cleanupRunDescriptorResponseMaximumBytes = 2 * 1024 * 1024

data CleanupRunCommand
  = CleanupRunCreate !Text !ByteString
  | CleanupRunObserve !Text
  | CleanupRunClaim !Text !Text !Natural !Natural
  | CleanupRunRecordPrimary !Text !Text !Natural !CleanupPrimaryOutcome
  | CleanupRunBeginNode !Text !Text !Natural !Text !Text
  | CleanupRunCompleteNode !Text !Text !Natural !Text !Text !CleanupNodeOutcome
  | CleanupRunScan
  | CleanupRunCompact !Text !Natural !Natural
  | CleanupRunDescriptorBound !CleanupRunDescriptorCommand
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunDescriptorCommand
  = CleanupRunDescriptorCreate !Text !ByteString
  | CleanupRunDescriptorObserve !Text
  | CleanupRunDescriptorClaim !Text !Text !Text !Natural !Natural
  | CleanupRunDescriptorRecordPrimary
      !Text
      !Text
      !Text
      !Natural
      !CleanupPrimaryOutcome
  | CleanupRunDescriptorBeginNode
      !Text
      !Text
      !Text
      !Natural
      !Text
      !Text
  | CleanupRunDescriptorCompleteNode
      !Text
      !Text
      !Text
      !Natural
      !Text
      !Text
      !CleanupNodeOutcome
  | CleanupRunDescriptorScan
  | CleanupRunDescriptorCompact !Text !Text !Natural !Natural
  | CleanupRunDescriptorReadBackProgram !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunDescriptorRefusal
  = CleanupRunDescriptorLegacyState
  | CleanupRunDescriptorCommitConflict
  | CleanupRunDescriptorMissing
  | CleanupRunDescriptorCorrupt !Text
  | CleanupRunDescriptorUnobservable !Text
  | CleanupRunDescriptorUnbounded !Int !Int
  | CleanupRunDescriptorInvalid !Text
  | CleanupRunDescriptorBindingMismatch !Text
  | CleanupRunDescriptorTransitionRefused !CleanupRunError
  | CleanupRunDescriptorUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunDescriptorResponse
  = CleanupRunDescriptorPresent !Text !Text !ByteString
  | CleanupRunDescriptorScanned ![(Text, Text, ByteString)]
  | CleanupRunDescriptorCompacted !Text !ByteString
  | CleanupRunDescriptorTombstoned !Text !Text
  | CleanupRunDescriptorNotFound
  | CleanupRunDescriptorRefused !CleanupRunDescriptorRefusal
  | CleanupRunDescriptorProgramPresent !Text !Text !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunDescriptorResponseEnvelope
  = CleanupRunDescriptorResponseEnvelope !Word16 !CleanupRunDescriptorResponse
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunRepositoryProvider m revision = CleanupRunRepositoryProvider
  { cleanupRunRepositoryFor :: CleanupRunId -> CleanupRunRepository m revision
  , descriptorBoundCleanupRunRepositoryFor
      :: CleanupRunId -> DescriptorBoundCleanupRunRepository m revision
  , cleanupRunIndexRepository :: CleanupRunIndexRepository m revision
  , cleanupRunAggregateBackup :: AuthorityAggregateBackupClient m
  , cleanupProgramDescriptorAuthorityClient
      :: Maybe (CleanupProgramDescriptorAuthorityClient m)
  }

data CleanupRunEndpointResult
  = CleanupRunEndpointSucceeded !CleanupRun
  | CleanupRunEndpointScanned ![Text]
  | CleanupRunEndpointCompacted !CleanupRunReport
  | CleanupRunEndpointTombstoned !Text
  | CleanupRunEndpointMissing
  | CleanupRunEndpointInvalidIdentity !Text
  | CleanupRunEndpointInvalidState !Text
  | CleanupRunEndpointTransitionRefused !CleanupRunError
  | CleanupRunEndpointUnavailable !Text
  | CleanupRunEndpointBadRequest !ControlPlaneRequestCodecError
  | CleanupRunEndpointDescriptorBound !CleanupRunDescriptorResponse
  deriving stock (Eq, Show)

serveCleanupRunRequest
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> LazyByteString.ByteString
  -> m CleanupRunEndpointResult
serveCleanupRunRequest provider requestBytes =
  case decodeControlPlaneRequest
    cleanupRunMaximumBytes
    requestBytes of
    Left err -> pure (CleanupRunEndpointBadRequest err)
    Right command -> serveCommand provider command

serveCommand
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunCommand
  -> m CleanupRunEndpointResult
serveCommand provider command = case command of
  CleanupRunCreate rawRunId bytes -> case (mkCleanupRunId rawRunId, decodeCleanupRun cleanupRunMaximumBytes bytes) of
    (Left detail, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
    (_, Left detail) -> pure (CleanupRunEndpointInvalidState (render detail))
    (Right runId, Right run)
      | cleanupRunId run /= runId -> pure (CleanupRunEndpointInvalidState "cleanup run id/body mismatch")
      | otherwise -> do
          registered <- registerCleanupRun (cleanupRunIndexRepository provider) run
          case registered of
            Left detail -> pure (CleanupRunEndpointUnavailable detail)
            Right _ ->
              projectStoreResult
                <$> createCleanupRunDurably (cleanupRunRepositoryFor provider runId) run
  CleanupRunObserve rawRunId -> withRunId rawRunId $ \runId -> do
    observed <- readCleanupRun (cleanupRunRepositoryFor provider runId)
    pure $ case observed of
      Left detail -> CleanupRunEndpointUnavailable detail
      Right CleanupRunMissing -> CleanupRunEndpointMissing
      Right (CleanupRunObserved _ run) -> CleanupRunEndpointSucceeded run
      Right (CleanupRunTombstoned _ tombstone) ->
        CleanupRunEndpointTombstoned (cleanupRunTombstoneReportDigest tombstone)
  CleanupRunClaim rawRunId rawOwner now expires ->
    withOwnerTransition rawRunId rawOwner $ \owner -> claimCleanupRun owner now expires
  CleanupRunRecordPrimary rawRunId rawOwner fence outcome ->
    withOwnerTransition rawRunId rawOwner $ \owner -> recordPrimaryOutcome owner fence outcome
  CleanupRunBeginNode rawRunId rawOwner fence rawNode rawAttempt ->
    withNodeTransition rawRunId rawOwner rawNode rawAttempt $ \owner node attempt ->
      beginCleanupNode owner fence node attempt
  CleanupRunCompleteNode rawRunId rawOwner fence rawNode rawAttempt outcome ->
    withNodeTransition rawRunId rawOwner rawNode rawAttempt $ \owner node attempt ->
      completeCleanupNode owner fence node attempt outcome
  CleanupRunScan -> do
    indexed <- readCleanupRunIndex (cleanupRunIndexRepository provider)
    case indexed of
      Left detail -> pure (CleanupRunEndpointUnavailable detail)
      Right CleanupRunIndexMissing -> pure (CleanupRunEndpointScanned [])
      Right (CleanupRunIndexObserved _ index)
        | any descriptorBoundEntry (cleanupRunIndexEntries index) ->
            pure
              ( CleanupRunEndpointInvalidState
                  "legacy cleanup scan refuses descriptor-bound index entries"
              )
        | otherwise -> scanIndexedRuns (activeRuns (cleanupRunIndexEntries index))
  CleanupRunCompact rawRunId now retention -> withRunId rawRunId $ \runId -> do
    observed <- readCleanupRun (cleanupRunRepositoryFor provider runId)
    case observed of
      Left detail -> pure (CleanupRunEndpointUnavailable detail)
      Right CleanupRunMissing -> pure CleanupRunEndpointMissing
      Right (CleanupRunTombstoned _ tombstone) -> do
        report <-
          observeAuthorityAggregateBackup
            (cleanupRunAggregateBackup provider)
            (cleanupRunTombstoneReportDigest tombstone)
        pure $ case report of
          Left detail ->
            CleanupRunEndpointUnavailable
              ("cleanup report backup observation failed: " <> Text.pack (show detail))
          Right AuthorityAggregateBackupMissing ->
            CleanupRunEndpointUnavailable "cleanup report backup is missing"
          Right (AuthorityAggregateBackupCorrupt detail) ->
            CleanupRunEndpointUnavailable ("cleanup report backup is corrupt: " <> detail)
          Right (AuthorityAggregateBackupCurrent ciphertext _) ->
            case decodeCleanupRunReport cleanupRunMaximumBytes (authorityBackupCiphertextBytes ciphertext) of
              Left detail -> CleanupRunEndpointInvalidState (render detail)
              Right reportValue -> CleanupRunEndpointCompacted reportValue
      Right (CleanupRunObserved _ run)
        | not (cleanupRunTerminal run) ->
            pure (CleanupRunEndpointInvalidState "cleanup run is not terminal")
        | now < cleanupLeaseExpiresAtMicros (cleanupRunLease run) + retention ->
            pure (CleanupRunEndpointInvalidState "cleanup run retention window has not elapsed")
        | otherwise -> do
            compacted <-
              compactCleanupRunDurably
                cleanupRunMaximumBytes
                (cleanupRunAggregateBackup provider)
                (cleanupRunRepositoryFor provider runId)
                (cleanupRunIndexRepository provider)
                run
            pure $ either CleanupRunEndpointUnavailable CleanupRunEndpointCompacted compacted
  CleanupRunDescriptorBound descriptorCommand ->
    CleanupRunEndpointDescriptorBound
      <$> serveDescriptorCommand provider descriptorCommand
 where
  activeRuns entries = [run | CleanupRunIndexActive run <- entries]
  descriptorBoundEntry entry = case entry of
    CleanupRunIndexDescriptorBoundActive {} -> True
    CleanupRunIndexDescriptorBoundTombstone {} -> True
    _ -> False
  scanIndexedRuns registeredRuns = do
    observations <- mapM observe registeredRuns
    pure $ case sequence observations of
      Left detail -> CleanupRunEndpointUnavailable detail
      Right runs ->
        CleanupRunEndpointScanned
          [ cleanupRunIdText (cleanupRunId run)
          | Just run <- runs
          ]
  observe registeredRun = do
    let runId = cleanupRunId registeredRun
    result <- readCleanupRun (cleanupRunRepositoryFor provider runId)
    case result of
      Left detail -> pure (Left detail)
      Right CleanupRunMissing -> do
        recovered <- createCleanupRunDurably (cleanupRunRepositoryFor provider runId) registeredRun
        pure $ either (Left . render) (Right . Just) recovered
      Right (CleanupRunObserved _ run) -> pure (Right (Just run))
      Right (CleanupRunTombstoned _ tombstone) -> do
        published <- publishCleanupRunTombstone (cleanupRunIndexRepository provider) tombstone
        pure $ case published of
          Left detail -> Left detail
          Right _ -> Right Nothing
  withRunId rawRunId action = case mkCleanupRunId rawRunId of
    Left detail -> pure (CleanupRunEndpointInvalidIdentity detail)
    Right runId -> action runId
  withOwnerTransition rawRunId rawOwner transition =
    case (mkCleanupRunId rawRunId, mkCleanupOwnerId rawOwner) of
      (Left detail, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, Left detail) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (Right runId, Right owner) ->
        projectStoreResult
          <$> applyCleanupRunTransition (cleanupRunRepositoryFor provider runId) (transition owner)
  withNodeTransition rawRunId rawOwner rawNode rawAttempt transition =
    case ( mkCleanupRunId rawRunId
         , mkCleanupOwnerId rawOwner
         , mkCleanupNodeId rawNode
         , mkCleanupAttemptId rawAttempt
         ) of
      (Left detail, _, _, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, Left detail, _, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, _, Left detail, _) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (_, _, _, Left detail) -> pure (CleanupRunEndpointInvalidIdentity detail)
      (Right runId, Right owner, Right node, Right attempt) ->
        projectStoreResult
          <$> applyCleanupRunTransition
            (cleanupRunRepositoryFor provider runId)
            (transition owner node attempt)

serveDescriptorCommand
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunDescriptorCommand
  -> m CleanupRunDescriptorResponse
serveDescriptorCommand provider command = case command of
  CleanupRunDescriptorCreate rawRunId descriptorBytes ->
    case (mkCleanupRunId rawRunId, decodeAndValidateCleanupProgramDescriptor descriptorBytes) of
      (Left detail, _) -> pure (refusedInvalid detail)
      (_, Left detail) -> pure (refusedInvalid (render detail))
      (Right runId, Right candidate)
        | cleanupProgramDescriptorRunId candidate /= runId ->
            pure
              ( refusedBinding
                  "cleanup program descriptor run id differs from its command identity"
              )
        | cleanupProgramDescriptorBytes candidate /= descriptorBytes ->
            pure (refusedBinding "cleanup program descriptor bytes are not canonical")
        | otherwise -> case cleanupProgramDescriptorAuthorityClient provider of
            Nothing -> pure descriptorRepositoryUnavailable
            Just descriptorClient -> do
              attempted <-
                commitCleanupProgramDescriptorAttempt descriptorClient candidate
              case attempted of
                CleanupProgramDescriptorCommitConflict ->
                  pure
                    ( CleanupRunDescriptorRefused
                        CleanupRunDescriptorCommitConflict
                    )
                CleanupProgramDescriptorCommitUnavailable failure ->
                  pure
                    ( CleanupRunDescriptorRefused
                        (CleanupRunDescriptorUnobservable (render failure))
                    )
                CleanupProgramDescriptorCommitCreated ->
                  createAfterDescriptorReadBack
                    provider
                    runId
                    (cleanupProgramDescriptorDigest candidate)
                CleanupProgramDescriptorCommitExactReplay ->
                  createAfterDescriptorReadBack
                    provider
                    runId
                    (cleanupProgramDescriptorDigest candidate)
                CleanupProgramDescriptorCommitResponseLost _ ->
                  createAfterDescriptorReadBack
                    provider
                    runId
                    (cleanupProgramDescriptorDigest candidate)
  CleanupRunDescriptorObserve rawRunId ->
    withDescriptorRunId rawRunId $ \runId -> do
      descriptor <- readCommittedInitial provider runId Nothing
      case descriptor of
        Left refusal -> pure (CleanupRunDescriptorRefused refusal)
        Right (descriptorDigest, initialRun) ->
          observeDescriptorBoundRun provider descriptorDigest initialRun
  CleanupRunDescriptorClaim rawRunId rawDescriptorDigest rawOwner now expires ->
    withDescriptorOwnerTransition
      provider
      rawRunId
      rawDescriptorDigest
      rawOwner
      (\owner -> claimCleanupRun owner now expires)
  CleanupRunDescriptorRecordPrimary
    rawRunId
    rawDescriptorDigest
    rawOwner
    fence
    outcome ->
      withDescriptorOwnerTransition
        provider
        rawRunId
        rawDescriptorDigest
        rawOwner
        (\owner -> recordPrimaryOutcome owner fence outcome)
  CleanupRunDescriptorBeginNode
    rawRunId
    rawDescriptorDigest
    rawOwner
    fence
    rawNode
    rawAttempt ->
      withDescriptorNodeTransition
        provider
        rawRunId
        rawDescriptorDigest
        rawOwner
        rawNode
        rawAttempt
        (\owner node attempt -> beginCleanupNode owner fence node attempt)
  CleanupRunDescriptorCompleteNode
    rawRunId
    rawDescriptorDigest
    rawOwner
    fence
    rawNode
    rawAttempt
    outcome ->
      withDescriptorNodeTransition
        provider
        rawRunId
        rawDescriptorDigest
        rawOwner
        rawNode
        rawAttempt
        (\owner node attempt -> completeCleanupNode owner fence node attempt outcome)
  CleanupRunDescriptorScan -> scanDescriptorBoundRuns provider
  CleanupRunDescriptorCompact rawRunId rawDescriptorDigest now retention ->
    withDescriptorIdentity rawRunId rawDescriptorDigest $ \runId descriptorDigest -> do
      descriptor <- readCommittedInitial provider runId (Just descriptorDigest)
      case descriptor of
        Left refusal -> pure (CleanupRunDescriptorRefused refusal)
        Right (_, initialRun) -> do
          observed <-
            readDescriptorBoundCleanupRun
              (descriptorBoundCleanupRunRepositoryFor provider runId)
          case validateDescriptorBoundObservation descriptorDigest initialRun observed of
            Left response -> pure response
            Right (Left tombstone) ->
              pure
                ( CleanupRunDescriptorTombstoned
                    (cleanupDigestText descriptorDigest)
                    (cleanupRunTombstoneReportDigest tombstone)
                )
            Right (Right run)
              | not (cleanupRunTerminal run) ->
                  pure (refusedBinding "descriptor-bound cleanup run is not terminal")
              | now < cleanupLeaseExpiresAtMicros (cleanupRunLease run) + retention ->
                  pure
                    ( refusedBinding
                        "descriptor-bound cleanup run retention window has not elapsed"
                    )
              | otherwise -> do
                  compacted <-
                    compactDescriptorBoundCleanupRunDurably
                      cleanupRunDescriptorResponseMaximumBytes
                      (cleanupRunAggregateBackup provider)
                      (descriptorBoundCleanupRunRepositoryFor provider runId)
                      (cleanupRunIndexRepository provider)
                      descriptorDigest
                      run
                  pure $ case compacted of
                    Left detail ->
                      CleanupRunDescriptorRefused
                        (CleanupRunDescriptorUnavailable detail)
                    Right report -> descriptorCompacted descriptorDigest report
  CleanupRunDescriptorReadBackProgram rawRunId ->
    withDescriptorRunId rawRunId $ \runId ->
      case cleanupProgramDescriptorAuthorityClient provider of
        Nothing -> pure descriptorRepositoryUnavailable
        Just descriptorClient -> do
          observed <-
            independentlyReadBackCommittedCleanupProgramDescriptor
              descriptorClient
              runId
          pure $ case observed of
            Left failure ->
              CleanupRunDescriptorRefused
                (descriptorRepositoryRefusal failure)
            Right committed -> descriptorProgramPresent committed

createAfterDescriptorReadBack
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunId
  -> CleanupDigest
  -> m CleanupRunDescriptorResponse
createAfterDescriptorReadBack provider runId expectedDescriptorDigest = do
  descriptor <-
    readCommittedInitial provider runId (Just expectedDescriptorDigest)
  case descriptor of
    Left refusal -> pure (CleanupRunDescriptorRefused refusal)
    Right (descriptorDigest, initialRun) -> do
      registered <-
        registerDescriptorBoundCleanupRun
          (cleanupRunIndexRepository provider)
          descriptorDigest
          initialRun
      case registered of
        Left detail ->
          pure
            ( CleanupRunDescriptorRefused
                (CleanupRunDescriptorUnavailable detail)
            )
        Right _ -> do
          created <-
            createDescriptorBoundCleanupRunDurably
              (descriptorBoundCleanupRunRepositoryFor provider runId)
              descriptorDigest
              initialRun
          pure $ case created of
            Left detail -> projectDescriptorStoreError detail
            Right observedRun -> descriptorPresent descriptorDigest observedRun

readCommittedInitial
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunId
  -> Maybe CleanupDigest
  -> m (Either CleanupRunDescriptorRefusal (CleanupDigest, CleanupRun))
readCommittedInitial provider runId expectedDigest =
  case cleanupProgramDescriptorAuthorityClient provider of
    Nothing -> pure (Left (CleanupRunDescriptorUnavailable "descriptor repository is unavailable"))
    Just descriptorClient -> do
      observed <-
        independentlyReadBackCommittedCleanupProgramDescriptor
          descriptorClient
          runId
      pure $ do
        committed <- either (Left . descriptorRepositoryRefusal) Right observed
        let descriptorDigest = committedCleanupProgramDescriptorDigest committed
        case expectedDigest of
          Just expected
            | expected /= descriptorDigest ->
                Left
                  ( CleanupRunDescriptorBindingMismatch
                      "cleanup program descriptor digest differs from the command binding"
                  )
          _ -> Right ()
        initialRun <-
          either
            (Left . descriptorRepositoryRefusal)
            Right
            (withCommittedCleanupProgramDescriptor committed (\_ _ run -> run))
        if cleanupRunId initialRun /= runId
          then
            Left
              ( CleanupRunDescriptorBindingMismatch
                  "recompiled descriptor initial run has the wrong run id"
              )
          else Right (descriptorDigest, initialRun)

descriptorRepositoryRefusal
  :: CleanupProgramDescriptorRepositoryError
  -> CleanupRunDescriptorRefusal
descriptorRepositoryRefusal err = case err of
  CleanupProgramDescriptorRepositoryMissing -> CleanupRunDescriptorMissing
  CleanupProgramDescriptorRepositoryCorrupt detail ->
    CleanupRunDescriptorCorrupt detail
  CleanupProgramDescriptorRepositoryUnobservable failure ->
    CleanupRunDescriptorUnobservable (render failure)
  CleanupProgramDescriptorRepositoryUnbounded actual maximumBytes ->
    CleanupRunDescriptorUnbounded actual maximumBytes
  CleanupProgramDescriptorRepositoryCoordinateInvalid detail ->
    CleanupRunDescriptorInvalid detail
  CleanupProgramDescriptorRepositoryDescriptorInvalid detail ->
    CleanupRunDescriptorInvalid (render detail)
  CleanupProgramDescriptorRepositoryRunIdMismatch expected actual ->
    CleanupRunDescriptorBindingMismatch
      ( "descriptor run mismatch: expected "
          <> cleanupRunIdText expected
          <> ", observed "
          <> cleanupRunIdText actual
      )

observeDescriptorBoundRun
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupDigest
  -> CleanupRun
  -> m CleanupRunDescriptorResponse
observeDescriptorBoundRun provider descriptorDigest initialRun = do
  observed <-
    readDescriptorBoundCleanupRun
      (descriptorBoundCleanupRunRepositoryFor provider (cleanupRunId initialRun))
  pure $ case validateDescriptorBoundObservation descriptorDigest initialRun observed of
    Left response -> response
    Right (Left tombstone) ->
      CleanupRunDescriptorTombstoned
        (cleanupDigestText descriptorDigest)
        (cleanupRunTombstoneReportDigest tombstone)
    Right (Right run) -> descriptorPresent descriptorDigest run

validateDescriptorBoundObservation
  :: CleanupDigest
  -> CleanupRun
  -> Either Text (DescriptorBoundCleanupRunSnapshot revision)
  -> Either CleanupRunDescriptorResponse (Either CleanupRunTombstone CleanupRun)
validateDescriptorBoundObservation descriptorDigest initialRun observed = case observed of
  Left detail ->
    Left
      ( CleanupRunDescriptorRefused
          (CleanupRunDescriptorUnobservable detail)
      )
  Right DescriptorBoundCleanupRunMissing -> Left CleanupRunDescriptorNotFound
  Right (DescriptorBoundCleanupRunLegacyState _) ->
    Left (CleanupRunDescriptorRefused CleanupRunDescriptorLegacyState)
  Right (DescriptorBoundCleanupRunObserved _ actualDigest run)
    | actualDigest /= descriptorDigest ->
        Left (refusedBinding "stored cleanup descriptor digest differs")
    | not (sameImmutablePlan initialRun run) ->
        Left (refusedBinding "stored cleanup run differs from the descriptor program")
    | otherwise -> Right (Right run)
  Right (DescriptorBoundCleanupRunTombstoned _ actualDigest tombstone)
    | actualDigest /= descriptorDigest ->
        Left (refusedBinding "stored cleanup tombstone descriptor digest differs")
    | cleanupRunTombstoneId tombstone /= cleanupRunId initialRun ->
        Left (refusedBinding "stored cleanup tombstone has the wrong run id")
    | otherwise -> Right (Left tombstone)

sameImmutablePlan :: CleanupRun -> CleanupRun -> Bool
sameImmutablePlan initial current =
  cleanupRunId initial == cleanupRunId current
    && cleanupRunGraphDigest initial == cleanupRunGraphDigest current
    && cleanupRunGraph initial == cleanupRunGraph current

withDescriptorOwnerTransition
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> Text
  -> Text
  -> Text
  -> (CleanupOwnerId -> CleanupRun -> Either CleanupRunError CleanupRun)
  -> m CleanupRunDescriptorResponse
withDescriptorOwnerTransition provider rawRunId rawDescriptorDigest rawOwner transition =
  case mkCleanupOwnerId rawOwner of
    Left detail -> pure (refusedInvalid detail)
    Right owner ->
      withDescriptorTransition
        provider
        rawRunId
        rawDescriptorDigest
        (transition owner)

withDescriptorNodeTransition
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> ( CleanupOwnerId
       -> CleanupNodeId
       -> CleanupAttemptId
       -> CleanupRun
       -> Either CleanupRunError CleanupRun
     )
  -> m CleanupRunDescriptorResponse
withDescriptorNodeTransition
  provider
  rawRunId
  rawDescriptorDigest
  rawOwner
  rawNode
  rawAttempt
  transition =
    case (mkCleanupOwnerId rawOwner, mkCleanupNodeId rawNode, mkCleanupAttemptId rawAttempt) of
      (Left detail, _, _) -> pure (refusedInvalid detail)
      (_, Left detail, _) -> pure (refusedInvalid detail)
      (_, _, Left detail) -> pure (refusedInvalid detail)
      (Right owner, Right node, Right attempt) ->
        withDescriptorTransition
          provider
          rawRunId
          rawDescriptorDigest
          (transition owner node attempt)

withDescriptorTransition
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> Text
  -> Text
  -> (CleanupRun -> Either CleanupRunError CleanupRun)
  -> m CleanupRunDescriptorResponse
withDescriptorTransition provider rawRunId rawDescriptorDigest transition =
  withDescriptorIdentity rawRunId rawDescriptorDigest $ \runId descriptorDigest -> do
    descriptor <- readCommittedInitial provider runId (Just descriptorDigest)
    case descriptor of
      Left refusal -> pure (CleanupRunDescriptorRefused refusal)
      Right (_, initialRun) -> do
        transitioned <-
          applyDescriptorBoundCleanupRunTransition
            (descriptorBoundCleanupRunRepositoryFor provider runId)
            descriptorDigest
            initialRun
            transition
        pure $ case transitioned of
          Left detail -> projectDescriptorStoreError detail
          Right run -> descriptorPresent descriptorDigest run

withDescriptorRunId
  :: (Monad m)
  => Text
  -> (CleanupRunId -> m CleanupRunDescriptorResponse)
  -> m CleanupRunDescriptorResponse
withDescriptorRunId rawRunId consume = case mkCleanupRunId rawRunId of
  Left detail -> pure (refusedInvalid detail)
  Right runId -> consume runId

withDescriptorIdentity
  :: (Monad m)
  => Text
  -> Text
  -> (CleanupRunId -> CleanupDigest -> m CleanupRunDescriptorResponse)
  -> m CleanupRunDescriptorResponse
withDescriptorIdentity rawRunId rawDescriptorDigest consume =
  case (mkCleanupRunId rawRunId, mkCleanupDigest rawDescriptorDigest) of
    (Left detail, _) -> pure (refusedInvalid detail)
    (_, Left detail) -> pure (refusedInvalid detail)
    (Right runId, Right descriptorDigest) -> consume runId descriptorDigest

scanDescriptorBoundRuns
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> m CleanupRunDescriptorResponse
scanDescriptorBoundRuns provider = do
  indexed <- readCleanupRunIndex (cleanupRunIndexRepository provider)
  case indexed of
    Left detail ->
      pure (CleanupRunDescriptorRefused (CleanupRunDescriptorUnobservable detail))
    Right CleanupRunIndexMissing -> pure (CleanupRunDescriptorScanned [])
    Right (CleanupRunIndexObserved _ index)
      | any legacyEntry (cleanupRunIndexEntries index) ->
          pure (CleanupRunDescriptorRefused CleanupRunDescriptorLegacyState)
      | otherwise -> do
          observations <- mapM scanEntry (cleanupRunIndexEntries index)
          pure $ case sequence observations of
            Left refusal -> CleanupRunDescriptorRefused refusal
            Right entries -> CleanupRunDescriptorScanned (concat entries)
 where
  legacyEntry entry = case entry of
    CleanupRunIndexActive _ -> True
    CleanupRunIndexTombstone _ -> True
    _ -> False

  scanEntry entry = case entry of
    CleanupRunIndexDescriptorBoundActive descriptorDigest indexedInitial -> do
      descriptor <-
        readCommittedInitial
          provider
          (cleanupRunId indexedInitial)
          (Just descriptorDigest)
      case descriptor of
        Left refusal -> pure (Left refusal)
        Right (_, recompiledInitial)
          | recompiledInitial /= indexedInitial ->
              pure
                ( Left
                    ( CleanupRunDescriptorBindingMismatch
                        "indexed initial run differs from the recompiled descriptor"
                    )
                )
          | otherwise -> do
              let repository =
                    descriptorBoundCleanupRunRepositoryFor
                      provider
                      (cleanupRunId indexedInitial)
              observed <- readDescriptorBoundCleanupRun repository
              case observed of
                Right DescriptorBoundCleanupRunMissing -> do
                  repaired <-
                    createDescriptorBoundCleanupRunDurably
                      repository
                      descriptorDigest
                      recompiledInitial
                  pure $ case repaired of
                    Left detail -> Left (storeErrorRefusal detail)
                    Right run -> (: []) <$> descriptorWireEntry descriptorDigest run
                _ ->
                  pure $ case validateDescriptorBoundObservation descriptorDigest recompiledInitial observed of
                    Left response -> Left (responseRefusal response)
                    Right (Right run) -> (: []) <$> descriptorWireEntry descriptorDigest run
                    Right (Left tombstone) ->
                      Left
                        ( CleanupRunDescriptorBindingMismatch
                            ( "active index points at tombstoned primary: "
                                <> cleanupRunTombstoneReportDigest tombstone
                            )
                        )
    CleanupRunIndexDescriptorBoundTombstone descriptorDigest tombstone -> do
      descriptor <-
        readCommittedInitial
          provider
          (cleanupRunTombstoneId tombstone)
          (Just descriptorDigest)
      case descriptor of
        Left refusal -> pure (Left refusal)
        Right (_, initialRun) -> do
          observed <-
            readDescriptorBoundCleanupRun
              ( descriptorBoundCleanupRunRepositoryFor
                  provider
                  (cleanupRunTombstoneId tombstone)
              )
          pure $ case validateDescriptorBoundObservation descriptorDigest initialRun observed of
            Right (Left observedTombstone)
              | observedTombstone == tombstone -> Right []
            Right (Left _) ->
              Left (CleanupRunDescriptorBindingMismatch "index and primary tombstones differ")
            Right (Right _) ->
              Left (CleanupRunDescriptorBindingMismatch "tombstone index points at active primary")
            Left response -> Left (responseRefusal response)
    _ -> pure (Left CleanupRunDescriptorLegacyState)

  responseRefusal response = case response of
    CleanupRunDescriptorRefused refusal -> refusal
    CleanupRunDescriptorNotFound -> CleanupRunDescriptorMissing
    _ -> CleanupRunDescriptorBindingMismatch "unexpected descriptor scan response"

descriptorWireEntry
  :: CleanupDigest
  -> CleanupRun
  -> Either CleanupRunDescriptorRefusal (Text, Text, ByteString)
descriptorWireEntry descriptorDigest run =
  case encodeCleanupRun cleanupRunDescriptorResponseMaximumBytes run of
    Left detail -> Left (CleanupRunDescriptorInvalid (render detail))
    Right bytes ->
      Right
        ( cleanupRunIdText (cleanupRunId run)
        , cleanupDigestText descriptorDigest
        , bytes
        )

descriptorPresent :: CleanupDigest -> CleanupRun -> CleanupRunDescriptorResponse
descriptorPresent descriptorDigest run =
  case encodeCleanupRun cleanupRunDescriptorResponseMaximumBytes run of
    Left detail -> refusedInvalid (render detail)
    Right bytes ->
      CleanupRunDescriptorPresent
        (cleanupRunIdText (cleanupRunId run))
        (cleanupDigestText descriptorDigest)
        bytes

descriptorCompacted
  :: CleanupDigest -> CleanupRunReport -> CleanupRunDescriptorResponse
descriptorCompacted descriptorDigest report =
  case encodeCleanupRunReport cleanupRunDescriptorResponseMaximumBytes report of
    Left detail -> refusedInvalid (render detail)
    Right bytes ->
      CleanupRunDescriptorCompacted (cleanupDigestText descriptorDigest) bytes

descriptorProgramPresent
  :: CommittedCleanupProgramDescriptor -> CleanupRunDescriptorResponse
descriptorProgramPresent committed =
  CleanupRunDescriptorProgramPresent
    (cleanupRunIdText (committedCleanupProgramDescriptorRunId committed))
    (cleanupDigestText (committedCleanupProgramDescriptorDigest committed))
    (committedCleanupProgramDescriptorBytes committed)

projectDescriptorStoreError
  :: CleanupRunStoreError -> CleanupRunDescriptorResponse
projectDescriptorStoreError err = case err of
  CleanupRunStoreMissing -> CleanupRunDescriptorNotFound
  CleanupRunStoreTransitionRejected refusal ->
    CleanupRunDescriptorRefused (CleanupRunDescriptorTransitionRefused refusal)
  _ -> CleanupRunDescriptorRefused (storeErrorRefusal err)

storeErrorRefusal :: CleanupRunStoreError -> CleanupRunDescriptorRefusal
storeErrorRefusal err =
  let detail = render err
   in if "legacy protocol" `Text.isInfixOf` detail
        then CleanupRunDescriptorLegacyState
        else CleanupRunDescriptorUnavailable detail

refusedInvalid :: Text -> CleanupRunDescriptorResponse
refusedInvalid = CleanupRunDescriptorRefused . CleanupRunDescriptorInvalid

refusedBinding :: Text -> CleanupRunDescriptorResponse
refusedBinding = CleanupRunDescriptorRefused . CleanupRunDescriptorBindingMismatch

descriptorRepositoryUnavailable :: CleanupRunDescriptorResponse
descriptorRepositoryUnavailable =
  CleanupRunDescriptorRefused
    (CleanupRunDescriptorUnavailable "descriptor repository is unavailable")

projectStoreResult :: Either CleanupRunStoreError CleanupRun -> CleanupRunEndpointResult
projectStoreResult result = case result of
  Right run -> CleanupRunEndpointSucceeded run
  Left err -> case err of
    CleanupRunStoreMissing -> CleanupRunEndpointMissing
    CleanupRunStoreTransitionRejected refusal ->
      CleanupRunEndpointTransitionRefused refusal
    _ -> CleanupRunEndpointUnavailable (render err)

cleanupRunEndpointStatus :: CleanupRunEndpointResult -> ReplyStatus
cleanupRunEndpointStatus result = case result of
  CleanupRunEndpointSucceeded _ -> ReplyOk
  CleanupRunEndpointScanned _ -> ReplyOk
  CleanupRunEndpointCompacted _ -> ReplyOk
  CleanupRunEndpointTombstoned _ -> ReplyGone
  CleanupRunEndpointMissing -> ReplyNotFound
  CleanupRunEndpointInvalidIdentity _ -> ReplyBadRequest
  CleanupRunEndpointInvalidState _ -> ReplyBadRequest
  CleanupRunEndpointTransitionRefused _ -> ReplyConflict
  CleanupRunEndpointUnavailable _ -> ReplyServiceUnavailable
  CleanupRunEndpointBadRequest _ -> ReplyBadRequest
  CleanupRunEndpointDescriptorBound response ->
    cleanupRunDescriptorResponseStatus response

cleanupRunEndpointBody :: CleanupRunEndpointResult -> ByteString
cleanupRunEndpointBody result = case result of
  CleanupRunEndpointSucceeded run ->
    either (const mempty) id (encodeCleanupRun cleanupRunMaximumBytes run)
  CleanupRunEndpointScanned runIds -> LazyByteString.toStrict (serialise runIds)
  CleanupRunEndpointCompacted report ->
    either (const mempty) id (encodeCleanupRunReport cleanupRunMaximumBytes report)
  CleanupRunEndpointTombstoned digest -> textBytes digest
  CleanupRunEndpointMissing -> mempty
  CleanupRunEndpointInvalidIdentity detail -> textBytes detail
  CleanupRunEndpointInvalidState detail -> textBytes detail
  CleanupRunEndpointTransitionRefused detail -> textBytes (render detail)
  CleanupRunEndpointUnavailable detail -> textBytes detail
  CleanupRunEndpointBadRequest detail -> textBytes (render detail)
  CleanupRunEndpointDescriptorBound response ->
    either (const mempty) id (encodeCleanupRunDescriptorResponse response)

cleanupRunDescriptorResponseStatus :: CleanupRunDescriptorResponse -> ReplyStatus
cleanupRunDescriptorResponseStatus response = case response of
  CleanupRunDescriptorPresent {} -> ReplyOk
  CleanupRunDescriptorScanned {} -> ReplyOk
  CleanupRunDescriptorCompacted {} -> ReplyOk
  CleanupRunDescriptorTombstoned {} -> ReplyGone
  CleanupRunDescriptorNotFound -> ReplyNotFound
  CleanupRunDescriptorProgramPresent {} -> ReplyOk
  CleanupRunDescriptorRefused refusal -> case refusal of
    CleanupRunDescriptorCommitConflict -> ReplyConflict
    CleanupRunDescriptorTransitionRefused _ -> ReplyConflict
    CleanupRunDescriptorMissing -> ReplyNotFound
    CleanupRunDescriptorInvalid _ -> ReplyBadRequest
    CleanupRunDescriptorUnbounded _ _ -> ReplyBadRequest
    CleanupRunDescriptorBindingMismatch _ -> ReplyConflict
    CleanupRunDescriptorLegacyState -> ReplyConflict
    CleanupRunDescriptorCorrupt _ -> ReplyServiceUnavailable
    CleanupRunDescriptorUnobservable _ -> ReplyServiceUnavailable
    CleanupRunDescriptorUnavailable _ -> ReplyServiceUnavailable

textBytes :: Text -> ByteString
textBytes = TextEncoding.encodeUtf8

render :: (Show value) => value -> Text
render = Text.pack . show

decodeCleanupRunScanResponse :: ByteString -> Either Text [Text]
decodeCleanupRunScanResponse bytes =
  case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left detail -> Left (Text.pack (show detail))
    Right runIds
      | LazyByteString.toStrict (serialise runIds) /= bytes ->
          Left "cleanup scan response is non-canonical"
      | length runIds > 256 -> Left "cleanup scan response exceeds 256 entries"
      | otherwise -> Right runIds

encodeCleanupRunDescriptorResponse
  :: CleanupRunDescriptorResponse -> Either Text ByteString
encodeCleanupRunDescriptorResponse response = do
  validateCleanupRunDescriptorResponse response
  let version = if descriptorResponseUsesV2 response then 2 else 1
      bytes =
        LazyByteString.toStrict
          (serialise (CleanupRunDescriptorResponseEnvelope version response))
  if ByteString.length bytes > cleanupRunDescriptorResponseMaximumBytes
    then Left "descriptor-bound cleanup response exceeds its encoded bound"
    else Right bytes

decodeCleanupRunDescriptorResponse
  :: ByteString -> Either Text CleanupRunDescriptorResponse
decodeCleanupRunDescriptorResponse bytes
  | ByteString.length bytes > cleanupRunDescriptorResponseMaximumBytes =
      Left "descriptor-bound cleanup response exceeds its encoded bound"
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left detail -> Left (Text.pack (show detail))
      Right envelope@(CleanupRunDescriptorResponseEnvelope version response)
        | version /= 1 && version /= 2 ->
            Left "descriptor-bound cleanup response version is unsupported"
        | LazyByteString.toStrict (serialise envelope) /= bytes ->
            Left "descriptor-bound cleanup response is non-canonical"
        | version == 1 && descriptorResponseUsesV2 response ->
            Left "descriptor-bound cleanup response v1 contains v2 state"
        | otherwise -> response <$ validateCleanupRunDescriptorResponse response

descriptorResponseUsesV2 :: CleanupRunDescriptorResponse -> Bool
descriptorResponseUsesV2 response = case response of
  CleanupRunDescriptorProgramPresent {} -> True
  _ -> False

validateCleanupRunDescriptorResponse
  :: CleanupRunDescriptorResponse -> Either Text ()
validateCleanupRunDescriptorResponse response = case response of
  CleanupRunDescriptorPresent rawRunId rawDescriptorDigest runBytes ->
    validateWireRun rawRunId rawDescriptorDigest runBytes
  CleanupRunDescriptorScanned entries
    | length entries > 256 ->
        Left "descriptor-bound cleanup scan exceeds 256 entries"
    | otherwise -> do
        mapM_ (\(runId, digest, bytes) -> validateWireRun runId digest bytes) entries
        let runIds = [runId | (runId, _, _) <- entries]
        if length runIds == length (nub runIds)
          then Right ()
          else Left "descriptor-bound cleanup scan contains duplicate run ids"
  CleanupRunDescriptorCompacted rawDescriptorDigest reportBytes -> do
    _ <- mkCleanupDigest rawDescriptorDigest
    _ <- firstShow (decodeCleanupRunReport cleanupRunDescriptorResponseMaximumBytes reportBytes)
    Right ()
  CleanupRunDescriptorTombstoned rawDescriptorDigest rawReportDigest -> do
    _ <- mkCleanupDigest rawDescriptorDigest
    _ <- mkCleanupDigest rawReportDigest
    Right ()
  CleanupRunDescriptorNotFound -> Right ()
  CleanupRunDescriptorRefused refusal -> validateRefusal refusal
  CleanupRunDescriptorProgramPresent rawRunId rawDescriptorDigest descriptorBytes -> do
    runId <- mkCleanupRunId rawRunId
    descriptorDigest <- mkCleanupDigest rawDescriptorDigest
    descriptor <-
      firstShow (decodeAndValidateCleanupProgramDescriptor descriptorBytes)
    if cleanupProgramDescriptorRunId descriptor /= runId
      then Left "descriptor readback response run id/body mismatch"
      else
        if cleanupProgramDescriptorDigest descriptor /= descriptorDigest
          then Left "descriptor readback response digest/body mismatch"
          else
            if cleanupProgramDescriptorBytes descriptor /= descriptorBytes
              then Left "descriptor readback response bytes are not canonical"
              else Right ()
 where
  validateWireRun rawRunId rawDescriptorDigest runBytes = do
    runId <- mkCleanupRunId rawRunId
    _ <- mkCleanupDigest rawDescriptorDigest
    run <- firstShow (decodeCleanupRun cleanupRunDescriptorResponseMaximumBytes runBytes)
    if cleanupRunId run == runId
      then Right ()
      else Left "descriptor-bound cleanup response run id/body mismatch"

  validateRefusal refusal = case refusal of
    CleanupRunDescriptorCorrupt detail -> boundedDetail detail
    CleanupRunDescriptorUnobservable detail -> boundedDetail detail
    CleanupRunDescriptorInvalid detail -> boundedDetail detail
    CleanupRunDescriptorBindingMismatch detail -> boundedDetail detail
    CleanupRunDescriptorUnavailable detail -> boundedDetail detail
    CleanupRunDescriptorUnbounded actual maximumBytes
      | actual < 0 || maximumBytes < 0 -> Left "descriptor response has an invalid bound"
      | otherwise -> Right ()
    _ -> Right ()

  boundedDetail detail
    | Text.length detail > 4096 = Left "descriptor response detail exceeds 4096 characters"
    | otherwise = Right ()

  firstShow :: (Show error) => Either error value -> Either Text value
  firstShow = either (Left . render) Right
