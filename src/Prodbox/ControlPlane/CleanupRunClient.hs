{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Closed authenticated client for the Lifecycle Authority cleanup-run
-- namespace. The wire command contains only logical run identities; the
-- physical Model-B and backup coordinates remain server-owned.
module Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClient (..)
  , DescriptorBoundCleanupRunClient (..)
  , CleanupRunClientError (..)
  , DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunLease
  , descriptorBoundCleanupRunPrimaryOutcome
  , descriptorBoundCleanupRunNodeStates
  , descriptorBoundCleanupRunTerminal
  , descriptorBoundCleanupRunReport
  , withDescriptorBoundCleanupProgram
  , deriveDescriptorBoundRecoveryRequirement
  , cleanupRunClient
  , descriptorBoundCleanupRunClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
  ( CleanupProgramDescriptorRepositoryError
  , committedCleanupProgramDescriptorDigest
  , committedCleanupProgramDescriptorRunId
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
  ( confirmCommittedCleanupProgramDescriptorBytes
  , withCommittedCleanupProgramDescriptor
  )
import Prodbox.ControlPlane.CleanupRunClient.Internal
  ( DescriptorBoundCleanupRun (..)
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (CleanupRunCompact, CleanupRunDescriptorBound, CleanupRunScan)
  , CleanupRunDescriptorCommand (..)
  , CleanupRunDescriptorRefusal (..)
  , CleanupRunDescriptorResponse (..)
  , cleanupRunMaximumBytes
  , decodeCleanupRunDescriptorResponse
  , decodeCleanupRunScanResponse
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleCleanupRunRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (..)
  , replyStatusCode
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupGraph
  , CleanupLease
  , CleanupNodeId
  , CleanupNodeOutcome
  , CleanupNodeState
  , CleanupOwnerId
  , CleanupPrimaryOutcome
  , CleanupRun (..)
  , CleanupRunCodecError
  , CleanupRunError
  , CleanupRunId
  , CleanupRunReport
  , cleanupAttemptIdText
  , cleanupDigestText
  , cleanupNodeIdText
  , cleanupOwnerIdText
  , cleanupRunIdText
  , cleanupRunTerminal
  , compactCleanupRun
  , decodeCleanupRun
  , decodeCleanupRunReport
  , mkCleanupDigest
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorRunId
  )
import Prodbox.Lifecycle.Teardown.Graph (CompiledDesiredAbsenceProgram)
import Prodbox.Lifecycle.Teardown.Model (CleanupSurfaceWitness)
import Prodbox.Lifecycle.Teardown.RecoveryRequirement
  ( DerivedOrdinaryTeardownRecoveryRequirement
  , RecoveryRequirementError
  )
import Prodbox.Lifecycle.Teardown.RecoveryRequirement.Internal
  ( deriveOrdinaryTeardownRecoveryRequirementInternal
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data CleanupRunClient m = CleanupRunClient
  -- Compatibility-only raw commands remain available for the pre-cutover
  -- runner.
  { executeCleanupRunCommand
      :: CleanupRunCommand
      -> m (Either CleanupRunClientError (Maybe CleanupRun))
  , scanNonterminalCleanupRuns
      :: m (Either CleanupRunClientError [Text])
  , compactTerminalCleanupRun
      :: Text
      -> Natural
      -> Natural
      -> m (Either CleanupRunClientError CleanupRunReport)
  }

data DescriptorBoundCleanupRunClient m = DescriptorBoundCleanupRunClient
  { createDescriptorBoundCleanupRun
      :: CleanupProgramDescriptor
      -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
  , observeDescriptorBoundCleanupRun
      :: CleanupRunId
      -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
  , scanDescriptorBoundCleanupRuns
      :: m (Either CleanupRunClientError [DescriptorBoundCleanupRun])
  , claimDescriptorBoundCleanupRun
      :: DescriptorBoundCleanupRun
      -> CleanupOwnerId
      -> Natural
      -> Natural
      -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
  , recordDescriptorBoundCleanupPrimary
      :: DescriptorBoundCleanupRun
      -> CleanupOwnerId
      -> Natural
      -> CleanupPrimaryOutcome
      -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
  , beginDescriptorBoundCleanupNode
      :: DescriptorBoundCleanupRun
      -> CleanupOwnerId
      -> Natural
      -> CleanupNodeId
      -> CleanupAttemptId
      -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
  , completeDescriptorBoundCleanupNode
      :: DescriptorBoundCleanupRun
      -> CleanupOwnerId
      -> Natural
      -> CleanupNodeId
      -> CleanupAttemptId
      -> CleanupNodeOutcome
      -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
  , compactDescriptorBoundCleanupRun
      :: DescriptorBoundCleanupRun
      -> Natural
      -> Natural
      -> m (Either CleanupRunClientError CleanupRunReport)
  }

data CleanupRunClientError
  = CleanupRunClientTransportFailed !AuthenticatedClientError
  | CleanupRunClientHttpStatus !Int !Text
  | CleanupRunClientResponseInvalid !CleanupRunCodecError
  | CleanupRunClientScanResponseInvalid !Text
  | CleanupRunClientDescriptorResponseInvalid !Text
  | CleanupRunClientDescriptorRefused !CleanupRunDescriptorRefusal
  | CleanupRunClientDescriptorMissing
  | CleanupRunClientDescriptorTombstoned !CleanupDigest !CleanupDigest
  | CleanupRunClientDescriptorBindingMismatch !Text
  | CleanupRunClientDescriptorRepositoryFailed
      !CleanupProgramDescriptorRepositoryError
  | CleanupRunClientDescriptorRecoveryRequirementFailed
      !RecoveryRequirementError
  deriving stock (Eq, Show)

-- | Opaque authenticated join of a positively read-back committed cleanup
-- descriptor and the exact independently observed per-run aggregate.
descriptorBoundCleanupRunId :: DescriptorBoundCleanupRun -> CleanupRunId
descriptorBoundCleanupRunId = cleanupRunId . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunDescriptorDigest
  :: DescriptorBoundCleanupRun -> CleanupDigest
descriptorBoundCleanupRunDescriptorDigest =
  committedCleanupProgramDescriptorDigest
    . internalDescriptorBoundCleanupRunDescriptor

descriptorBoundCleanupRunGraph :: DescriptorBoundCleanupRun -> CleanupGraph
descriptorBoundCleanupRunGraph = cleanupRunGraph . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunGraphDigest
  :: DescriptorBoundCleanupRun -> CleanupDigest
descriptorBoundCleanupRunGraphDigest =
  cleanupRunGraphDigest . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunLease :: DescriptorBoundCleanupRun -> CleanupLease
descriptorBoundCleanupRunLease = cleanupRunLease . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunPrimaryOutcome
  :: DescriptorBoundCleanupRun -> Maybe CleanupPrimaryOutcome
descriptorBoundCleanupRunPrimaryOutcome =
  cleanupRunPrimaryOutcome . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunNodeStates
  :: DescriptorBoundCleanupRun -> Map CleanupNodeId CleanupNodeState
descriptorBoundCleanupRunNodeStates =
  cleanupRunNodeStates . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunTerminal :: DescriptorBoundCleanupRun -> Bool
descriptorBoundCleanupRunTerminal =
  cleanupRunTerminal . internalDescriptorBoundCleanupRunValue

descriptorBoundCleanupRunReport
  :: DescriptorBoundCleanupRun -> Either CleanupRunError CleanupRunReport
descriptorBoundCleanupRunReport =
  compactCleanupRun . internalDescriptorBoundCleanupRunValue

-- | Revalidate the exact committed descriptor/observed-run join before
-- exposing the closed recompiled program. The callback receives only the
-- opaque run handle, never a public raw CleanupRun remint path.
withDescriptorBoundCleanupProgram
  :: DescriptorBoundCleanupRun
  -> ( forall surface
        . CleanupSurfaceWitness surface
       -> CompiledDesiredAbsenceProgram surface
       -> DescriptorBoundCleanupRun
       -> result
     )
  -> Either CleanupRunClientError result
withDescriptorBoundCleanupProgram bound consume
  | committedCleanupProgramDescriptorRunId committed
      /= descriptorBoundCleanupRunId bound =
      Left
        ( CleanupRunClientDescriptorBindingMismatch
            "committed descriptor and cleanup run identities differ"
        )
  | committedCleanupProgramDescriptorDigest committed
      /= descriptorBoundCleanupRunDescriptorDigest bound =
      Left
        ( CleanupRunClientDescriptorBindingMismatch
            "committed descriptor and cleanup run descriptor digests differ"
        )
  | otherwise = do
      joined <-
        first
          CleanupRunClientDescriptorRepositoryFailed
          ( withCommittedCleanupProgramDescriptor committed $ \witness compiled initialRun ->
              if sameImmutablePlan initialRun (internalDescriptorBoundCleanupRunValue bound)
                then Right (consume witness compiled bound)
                else
                  Left
                    ( CleanupRunClientDescriptorBindingMismatch
                        "observed cleanup run differs from its recompiled descriptor"
                    )
          )
      joined
 where
  committed = internalDescriptorBoundCleanupRunDescriptor bound

  sameImmutablePlan initial current =
    cleanupRunId initial == cleanupRunId current
      && cleanupRunGraphDigest initial == cleanupRunGraphDigest current
      && cleanupRunGraph initial == cleanupRunGraph current

deriveDescriptorBoundRecoveryRequirement
  :: DescriptorBoundCleanupRun
  -> Either
       CleanupRunClientError
       DerivedOrdinaryTeardownRecoveryRequirement
deriveDescriptorBoundRecoveryRequirement bound = do
  derived <-
    withDescriptorBoundCleanupProgram
      bound
      ( \_ compiled _ ->
          deriveOrdinaryTeardownRecoveryRequirementInternal
            compiled
            (internalDescriptorBoundCleanupRunValue bound)
      )
  first CleanupRunClientDescriptorRecoveryRequirementFailed derived

cleanupRunClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CleanupRunClient IO
cleanupRunClient transport =
  CleanupRunClient
    { executeCleanupRunCommand = execute
    , scanNonterminalCleanupRuns = scan
    , compactTerminalCleanupRun = compact
    }
 where
  execute command = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleCleanupRunRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest command))
    pure $ do
      ControlPlaneResponse status body <-
        first CleanupRunClientTransportFailed attempted
      case status of
        200 ->
          Just
            <$> first
              CleanupRunClientResponseInvalid
              (decodeCleanupRun cleanupRunMaximumBytes body)
        404 -> Right Nothing
        _ ->
          Left
            ( CleanupRunClientHttpStatus
                status
                (TextEncoding.decodeUtf8Lenient body)
            )
  scan = do
    attempted <- call CleanupRunScan
    pure $ do
      ControlPlaneResponse status body <- first CleanupRunClientTransportFailed attempted
      if status /= 200
        then Left (CleanupRunClientHttpStatus status (TextEncoding.decodeUtf8Lenient body))
        else first CleanupRunClientScanResponseInvalid (decodeCleanupRunScanResponse body)

  compact runId now retention = do
    attempted <- call (CleanupRunCompact runId now retention)
    pure $ do
      ControlPlaneResponse status body <- first CleanupRunClientTransportFailed attempted
      if status /= 200
        then Left (CleanupRunClientHttpStatus status (TextEncoding.decodeUtf8Lenient body))
        else first CleanupRunClientResponseInvalid (decodeCleanupRunReport cleanupRunMaximumBytes body)

  call command =
    callAuthenticatedClientTransport
      transport
      LifecycleCleanupRunRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest command))

descriptorBoundCleanupRunClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupRunClient IO
descriptorBoundCleanupRunClient transport =
  DescriptorBoundCleanupRunClient
    { createDescriptorBoundCleanupRun = createDescriptor
    , observeDescriptorBoundCleanupRun = observeDescriptor
    , scanDescriptorBoundCleanupRuns = scanDescriptors
    , claimDescriptorBoundCleanupRun = claimDescriptor
    , recordDescriptorBoundCleanupPrimary = recordDescriptorPrimary
    , beginDescriptorBoundCleanupNode = beginDescriptorNode
    , completeDescriptorBoundCleanupNode = completeDescriptorNode
    , compactDescriptorBoundCleanupRun = compactDescriptor
    }
 where
  call command =
    callAuthenticatedClientTransport
      transport
      LifecycleCleanupRunRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest command))

  createDescriptor descriptor =
    expectDescriptorPresent
      (Just (cleanupProgramDescriptorRunId descriptor))
      Nothing
      =<< callDescriptor
        ( CleanupRunDescriptorCreate
            (cleanupRunIdText (cleanupProgramDescriptorRunId descriptor))
            (cleanupProgramDescriptorBytes descriptor)
        )

  observeDescriptor runId =
    expectDescriptorPresent (Just runId) Nothing
      =<< callDescriptor (CleanupRunDescriptorObserve (cleanupRunIdText runId))

  scanDescriptors = do
    response <- callDescriptor CleanupRunDescriptorScan
    case response of
      Left failure -> pure (Left failure)
      Right (CleanupRunDescriptorScanned entries) ->
        fmap sequence (mapM descriptorHandleFromEntry entries)
      Right other -> pure (descriptorResponseError other)

  claimDescriptor bound owner now expires =
    transitionDescriptor
      bound
      ( CleanupRunDescriptorClaim
          (boundRunIdText bound)
          (boundDescriptorDigestText bound)
          (cleanupOwnerIdText owner)
          now
          expires
      )

  recordDescriptorPrimary bound owner fence outcome =
    transitionDescriptor
      bound
      ( CleanupRunDescriptorRecordPrimary
          (boundRunIdText bound)
          (boundDescriptorDigestText bound)
          (cleanupOwnerIdText owner)
          fence
          outcome
      )

  beginDescriptorNode bound owner fence node attempt =
    transitionDescriptor
      bound
      ( CleanupRunDescriptorBeginNode
          (boundRunIdText bound)
          (boundDescriptorDigestText bound)
          (cleanupOwnerIdText owner)
          fence
          (cleanupNodeIdText node)
          (cleanupAttemptIdText attempt)
      )

  completeDescriptorNode bound owner fence node attempt outcome =
    transitionDescriptor
      bound
      ( CleanupRunDescriptorCompleteNode
          (boundRunIdText bound)
          (boundDescriptorDigestText bound)
          (cleanupOwnerIdText owner)
          fence
          (cleanupNodeIdText node)
          (cleanupAttemptIdText attempt)
          outcome
      )

  compactDescriptor bound now retention = do
    response <-
      callDescriptor
        ( CleanupRunDescriptorCompact
            (boundRunIdText bound)
            (boundDescriptorDigestText bound)
            now
            retention
        )
    pure $
      response >>= \case
        CleanupRunDescriptorCompacted rawDescriptorDigest reportBytes -> do
          descriptorDigest <-
            first
              CleanupRunClientDescriptorResponseInvalid
              (mkCleanupDigest rawDescriptorDigest)
          if descriptorDigest /= descriptorBoundCleanupRunDescriptorDigest bound
            then
              Left
                ( CleanupRunClientDescriptorBindingMismatch
                    "compaction response descriptor digest differs"
                )
            else
              first
                CleanupRunClientResponseInvalid
                (decodeCleanupRunReport cleanupRunMaximumBytes reportBytes)
        other -> descriptorResponseError other

  transitionDescriptor bound command =
    expectDescriptorPresent
      (Just (descriptorBoundCleanupRunId bound))
      (Just (descriptorBoundCleanupRunDescriptorDigest bound))
      =<< callDescriptor command

  callDescriptor command = do
    attempted <- call (CleanupRunDescriptorBound command)
    pure $ do
      ControlPlaneResponse status body <-
        first CleanupRunClientTransportFailed attempted
      response <-
        first
          CleanupRunClientDescriptorResponseInvalid
          (decodeCleanupRunDescriptorResponse body)
      if replyStatusCode (descriptorResponseStatus response) == status
        then Right response
        else
          Left
            ( CleanupRunClientHttpStatus
                status
                "descriptor-bound cleanup response/status mismatch"
            )

  expectDescriptorPresent expectedRunId expectedDescriptorDigest response =
    case response of
      Left failure -> pure (Left failure)
      Right (CleanupRunDescriptorPresent rawRunId rawDescriptorDigest runBytes) -> do
        minted <-
          descriptorHandleFromEntry
            (rawRunId, rawDescriptorDigest, runBytes)
        pure $ do
          handle <- minted
          case expectedRunId of
            Just expected
              | descriptorBoundCleanupRunId handle /= expected ->
                  Left
                    ( CleanupRunClientDescriptorBindingMismatch
                        "descriptor-bound cleanup response has the wrong run id"
                    )
            _ -> Right ()
          case expectedDescriptorDigest of
            Just expected
              | descriptorBoundCleanupRunDescriptorDigest handle /= expected ->
                  Left
                    ( CleanupRunClientDescriptorBindingMismatch
                        "descriptor-bound cleanup response has the wrong descriptor digest"
                    )
            _ -> Right ()
          Right handle
      Right other -> pure (descriptorResponseError other)

  descriptorHandleFromEntry entry = case decodeDescriptorRunEntry entry of
    Left failure -> pure (Left failure)
    Right (runId, descriptorDigest, run) -> do
      readBack <- readBackDescriptorProgram runId descriptorDigest
      pure $ do
        committed <- readBack
        let handle = DescriptorBoundCleanupRun committed run
        _ <- withDescriptorBoundCleanupProgram handle (\_ _ _ -> ())
        Right handle

  decodeDescriptorRunEntry (rawRunId, rawDescriptorDigest, runBytes) = do
    runId <-
      first CleanupRunClientDescriptorResponseInvalid (mkCleanupRunId rawRunId)
    descriptorDigest <-
      first
        CleanupRunClientDescriptorResponseInvalid
        (mkCleanupDigest rawDescriptorDigest)
    run <-
      first
        CleanupRunClientResponseInvalid
        (decodeCleanupRun cleanupRunMaximumBytes runBytes)
    if cleanupRunId run /= runId
      then
        Left
          ( CleanupRunClientDescriptorBindingMismatch
              "descriptor-bound cleanup response run id/body mismatch"
          )
      else Right (runId, descriptorDigest, run)

  readBackDescriptorProgram runId expectedDescriptorDigest = do
    response <-
      callDescriptor
        (CleanupRunDescriptorReadBackProgram (cleanupRunIdText runId))
    pure $ do
      observed <- response
      case observed of
        CleanupRunDescriptorProgramPresent
          rawRunId
          rawDescriptorDigest
          descriptorBytes -> do
            observedRunId <-
              first
                CleanupRunClientDescriptorResponseInvalid
                (mkCleanupRunId rawRunId)
            observedDigest <-
              first
                CleanupRunClientDescriptorResponseInvalid
                (mkCleanupDigest rawDescriptorDigest)
            if observedRunId /= runId
              then
                Left
                  ( CleanupRunClientDescriptorBindingMismatch
                      "descriptor readback response has the wrong run id"
                  )
              else Right ()
            if observedDigest /= expectedDescriptorDigest
              then
                Left
                  ( CleanupRunClientDescriptorBindingMismatch
                      "descriptor readback response has the wrong digest"
                  )
              else Right ()
            committed <-
              first
                CleanupRunClientDescriptorRepositoryFailed
                ( confirmCommittedCleanupProgramDescriptorBytes
                    runId
                    descriptorBytes
                )
            if committedCleanupProgramDescriptorDigest committed
              == expectedDescriptorDigest
              then Right committed
              else
                Left
                  ( CleanupRunClientDescriptorBindingMismatch
                      "descriptor readback bytes have the wrong digest"
                  )
        other -> descriptorResponseError other

  descriptorResponseError response = case response of
    CleanupRunDescriptorRefused refusal ->
      Left (CleanupRunClientDescriptorRefused refusal)
    CleanupRunDescriptorNotFound -> Left CleanupRunClientDescriptorMissing
    CleanupRunDescriptorTombstoned rawDescriptorDigest rawReportDigest -> do
      descriptorDigest <-
        first
          CleanupRunClientDescriptorResponseInvalid
          (mkCleanupDigest rawDescriptorDigest)
      reportDigest <-
        first
          CleanupRunClientDescriptorResponseInvalid
          (mkCleanupDigest rawReportDigest)
      Left
        ( CleanupRunClientDescriptorTombstoned
            descriptorDigest
            reportDigest
        )
    _ ->
      Left
        ( CleanupRunClientDescriptorResponseInvalid
            "unexpected descriptor-bound cleanup response kind"
        )

  descriptorResponseStatus response = case response of
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

  boundRunIdText = cleanupRunIdText . descriptorBoundCleanupRunId
  boundDescriptorDigestText =
    cleanupDigestText . descriptorBoundCleanupRunDescriptorDigest
