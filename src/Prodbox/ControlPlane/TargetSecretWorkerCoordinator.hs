{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One-shot Credential Provisioner coordinator for a Target materializer.
--
-- Kubernetes receives only the secret-free durable intent.  After the exact
-- Pod has been observed and attested, the material frame is attached directly
-- to that Pod's stdin.  Receipt/refusal/codec/attestation paths all converge on
-- UID-preconditioned Job/Pod deletion followed by positive absence read-back.
-- This coordinator is never installed in the long-lived Target HTTP runtime.
module Prodbox.ControlPlane.TargetSecretWorkerCoordinator
  ( TargetWorkerCreateRecovery (..)
  , TargetWorkerPreparedJob
  , TargetWorkerProvisionalOutcome (..)
  , TargetWorkerSessionPrepareCause (..)
  , TargetWorkerKubernetesBoundary (..)
  , TargetWorkerExecutionBoundary (..)
  , TargetWorkerCoordinatorClockFailure (..)
  , TargetWorkerCoordinatorError (..)
  , coordinateDirectTargetMaterialization
  , coordinateRewrappedTargetMaterialization
  , coordinateTargetOneShotOperation
  )
where

import Control.Exception
  ( SomeAsyncException
  , SomeException
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , ServiceSessionCreationReservation
  , ServiceSessionWorkload
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , TargetSecretPayload
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentIdentity
  , TargetAgentRolloutEvidence
  , TargetAgentRolloutObservationCause
  , targetAgentRolloutEvidenceIdentity
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( RawTargetWorkerPodObservation (..)
  , TargetWorkerAttestation
  , TargetWorkerAttestationError
  , TargetWorkerImageDigest
  , TargetWorkerIngressSchema
  , TargetWorkerIntent
  , TargetWorkerIntentError
  , TargetWorkerJobUid
  , TargetWorkerOperationResult (..)
  , TargetWorkerPodUid
  , TargetWorkerProvisionalCompletionError (..)
  , TargetWorkerReceipt
  , attestTargetWorkerPod
  , decodeTargetWorkerProvisionalCompletion
  , mkTargetWorkerJobUid
  , mkTargetWorkerPodUid
  , prepareTargetWorkerIntent
  , targetWorkerAttestedIntent
  , targetWorkerIntentDeadline
  , targetWorkerIntentSchema
  , targetWorkerOperationResultMatchesSchema
  , targetWorkerProvisionalAccessor
  , targetWorkerProvisionalRefusal
  , targetWorkerProvisionalResult
  , targetWorkerReceiptMatchesAttestation
  )
import Prodbox.ControlPlane.TargetSecretWorkerKubernetes (TargetWorkerPreparedJob)
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
  ( TargetWorkerIngressError
  , TargetWorkerOperationInput
  , encodeDirectTargetWorkerIngress
  , encodeRewrappedTargetWorkerIngress
  , encodeTargetWorkerOperationIngress
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( SignedTargetWorkerExecutionPermit
  , TargetWorkerExecutionPermitError
  , VerifiedTargetWorkerExecutionPermit
  , targetWorkerExecutionPermitMatchesObservation
  , verifyTargetWorkerExecutionPermit
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)

-- | Terminal interpretation of an ambiguous Kubernetes create.  Absence is
-- representable only after the production boundary has observed the exact
-- deterministic Job absent twice across its visibility grace; a single
-- @Nothing@ is never enough to abandon cleanup ownership.
data TargetWorkerCreateRecovery
  = TargetWorkerCreateRecovered !TargetWorkerJobUid
  | TargetWorkerCreateStablyAbsent
  deriving stock (Eq, Show)

-- | Secret-free result accepted while the worker session is still active.
-- The Kubernetes boundary may return it only after observing the worker's
-- terminal cleanup acknowledgement.
data TargetWorkerProvisionalOutcome
  = TargetWorkerProvisionalSucceeded !TargetWorkerOperationResult
  | TargetWorkerProvisionalRefused !Text
  deriving stock (Eq, Show)

-- | Closed, value-free projection of retained session allocation/preparation
-- failures. Production maps interpreter errors into this vocabulary before
-- they cross the coordinator boundary; Vault, journal, and audit details are
-- never retained in the diagnostic-bearing error.
data TargetWorkerSessionPrepareCause
  = TargetWorkerSessionPrepareJournalWriteFailed
  | TargetWorkerSessionPrepareJournalUnavailable
  | TargetWorkerSessionPrepareBindingRoleMismatch
  | TargetWorkerSessionPrepareRoleOccupied
  | TargetWorkerSessionPrepareBindingInvalid
  | TargetWorkerSessionPreparePrecleanIdentityInvalid
  | TargetWorkerSessionPreparePrecleanAuditorLoginFailed
  | TargetWorkerSessionPreparePrecleanAuditorEvidenceInvalid
  | TargetWorkerSessionPreparePrecleanObservationFailed
  | TargetWorkerSessionPreparePrecleanClassificationUnavailable
  | TargetWorkerSessionPreparePrecleanClassificationFailed
  | TargetWorkerSessionPreparePrecleanKnownIdentityMismatch
  | TargetWorkerSessionPreparePrecleanRevocationFailed
  | TargetWorkerSessionPreparePrecleanVisibilityWaitFailed
  | TargetWorkerSessionPreparePrecleanStableAbsenceFailed
  | TargetWorkerSessionPrepareLoginFailedCleaned
  | TargetWorkerSessionPrepareLoginAmbiguityCleaned
  | TargetWorkerSessionPrepareAccessorInvalid
  | TargetWorkerSessionPrepareAccessorIdentityMismatch
  | TargetWorkerSessionPrepareCleanupFailed
  | TargetWorkerSessionPrepareCleanupThrew
  | TargetWorkerSessionPrepareCleanupJournalFailed
  | TargetWorkerSessionPrepareActionFailed
  | TargetWorkerSessionPrepareUnhandledException
  | TargetWorkerSessionPrepareRecoveryCompletedRetryRequired
  deriving stock (Bounded, Enum, Eq, Show)

data TargetWorkerKubernetesBoundary m = TargetWorkerKubernetesBoundary
  { observeSelectedTargetAgentRollout
      :: m (Either TargetAgentRolloutObservationCause TargetAgentRolloutEvidence)
  , prepareTargetWorkerJob
      :: TargetWorkerIntent -> m (Either Text TargetWorkerPreparedJob)
  , createTargetWorkerIntent
      :: TargetWorkerIntent
      -> TargetWorkerPreparedJob
      -> m (Either Text TargetWorkerJobUid)
  , recoverTargetWorkerIntent
      :: TargetWorkerIntent
      -> m (Either Text TargetWorkerCreateRecovery)
  , observeTargetWorkerIntent
      :: TargetWorkerIntent
      -> m (Either Text (Maybe RawTargetWorkerPodObservation))
  , attachTargetWorkerIngress
      :: TargetWorkerAttestation
      -> ByteString
      -> ( ByteString
           -> m
                ( Either
                    TargetWorkerCoordinatorError
                    TargetWorkerProvisionalOutcome
                )
         )
      -> m
           ( Either
               TargetWorkerCoordinatorError
               TargetWorkerProvisionalOutcome
           )
  , observeRetiredTargetWorkerAbsent
      :: ServiceSessionWorkload -> m (Either Text Bool)
  , deleteTargetWorkerIntent
      :: TargetWorkerIntent
      -> TargetWorkerJobUid
      -> Maybe (Text, TargetWorkerPodUid)
      -> m (Either Text ())
  , observeTargetWorkerIntentAbsent
      :: TargetWorkerIntent
      -> TargetWorkerJobUid
      -> Maybe (Text, TargetWorkerPodUid)
      -> m (Either Text Bool)
  }

-- | Retained session-attempt allocation and post-observation Authority
-- authorization live outside the one-shot Pod.  The prepare callback must not
-- return until @LoginAttemptCommitted@ is durable; close must prove role-wide
-- absence and release the retained lane.
data TargetWorkerExecutionBoundary m = TargetWorkerExecutionBoundary
  { reserveTargetWorkerCreation
      :: TargetWorkerIntent -> m (Either TargetWorkerSessionPrepareCause ServiceSessionCreationReservation)
  , issueTargetWorkerCreation
      :: ServiceSessionCreationReservation -> m (Either TargetWorkerSessionPrepareCause ())
  , recoverRetiredTargetWorker
      :: (ServiceSessionWorkload -> m (Either Text Bool)) -> m (Either Text Bool)
  , prepareTargetWorkerSessionAttempt
      :: ServiceSessionCreationReservation
      -> TargetAgentRolloutEvidence
      -> TargetWorkerAttestation
      -> m (Either TargetWorkerSessionPrepareCause ServiceSessionBinding)
  , authorizeTargetWorkerExecution
      :: AcceptedTargetAuthority
      -> TargetAgentRolloutEvidence
      -> TargetWorkerAttestation
      -> ServiceSessionBinding
      -> m (Either Text SignedTargetWorkerExecutionPermit)
  , beginTargetWorkerDispatch :: ServiceSessionBinding -> m (Either Text ())
  , settleTargetWorkerDispatch :: ServiceSessionBinding -> m (Either Text ())
  , activateTargetWorkerSessionAttempt
      :: TargetWorkerAttestation
      -> ServiceSessionBinding
      -> Text
      -> m (Either Text ())
  , recordTargetWorkerRetirement
      :: TargetWorkerAttestation -> ServiceSessionBinding -> m (Either Text ())
  , closeTargetWorkerSessionAttempt
      :: ServiceSessionBinding
      -> m (Either Text ())
  }

data TargetWorkerCoordinatorClockFailure
  = TargetWorkerClockUnavailable
  | TargetWorkerClockRegressed
  | TargetWorkerClockDeadlineReached
  deriving stock (Eq, Show)

data TargetWorkerCoordinatorError
  = TargetWorkerCoordinatorAgentIdentityUnavailable !TargetAgentRolloutObservationCause
  | TargetWorkerCoordinatorAgentIdentityMismatch
  | TargetWorkerCoordinatorIntentRejected !TargetWorkerIntentError
  | TargetWorkerCoordinatorCreateFailed !Text
  | TargetWorkerCoordinatorObservationFailed !Text
  | TargetWorkerCoordinatorClockFailed !TargetWorkerCoordinatorClockFailure
  | TargetWorkerCoordinatorWorkloadAbsent
  | TargetWorkerCoordinatorCleanupBindingInvalid
  | TargetWorkerCoordinatorAttestationFailed !TargetWorkerAttestationError
  | TargetWorkerCoordinatorSessionPrepareFailed !TargetWorkerSessionPrepareCause
  | TargetWorkerCoordinatorPermitUnavailable !Text
  | TargetWorkerCoordinatorPermitRejected !TargetWorkerExecutionPermitError
  | TargetWorkerCoordinatorPermitBindingMismatch
  | TargetWorkerCoordinatorFrameRejected !TargetWorkerIngressError
  | TargetWorkerCoordinatorAttachFailed !Text
  | TargetWorkerCoordinatorProvisionalRejected !TargetWorkerProvisionalCompletionError
  | TargetWorkerCoordinatorReceiptBindingMismatch
  | TargetWorkerCoordinatorSessionActivateFailed !Text
  | TargetWorkerCoordinatorMaterializationRefused !Text
  | TargetWorkerCoordinatorSessionCleanupFailed !Text
  | TargetWorkerCoordinatorDeleteFailed !Text
  | TargetWorkerCoordinatorAbsenceUnobservable !Text
  | TargetWorkerCoordinatorStillPresent
  | TargetWorkerCoordinatorUnhandledException
  deriving stock (Eq, Show)

coordinateDirectTargetMaterialization
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> AcceptedTargetAuthority
  -> AuthorityTime
  -> IO (Either Text AuthorityTime)
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> TargetSecretPayload
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateDirectTargetMaterialization boundary execution accepted now readTime agentIdentity target schema image signed payload =
  fmap materialReceipt $ do
    coordinate
      boundary
      execution
      accepted
      now
      readTime
      agentIdentity
      target
      schema
      image
      signed
      (\permit attestation -> encodeDirectTargetWorkerIngress permit attestation payload)

coordinateRewrappedTargetMaterialization
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> AcceptedTargetAuthority
  -> AuthorityTime
  -> IO (Either Text AuthorityTime)
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> ByteString
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateRewrappedTargetMaterialization boundary execution accepted now readTime agentIdentity target schema image signed envelope =
  fmap materialReceipt $ do
    coordinate
      boundary
      execution
      accepted
      now
      readTime
      agentIdentity
      target
      schema
      image
      signed
      (\permit attestation -> encodeRewrappedTargetWorkerIngress permit attestation envelope)

coordinateTargetOneShotOperation
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> AcceptedTargetAuthority
  -> AuthorityTime
  -> IO (Either Text AuthorityTime)
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> TargetWorkerOperationInput
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerOperationResult)
coordinateTargetOneShotOperation boundary execution accepted now readTime agentIdentity target schema image signed operation =
  coordinate
    boundary
    execution
    accepted
    now
    readTime
    agentIdentity
    target
    schema
    image
    signed
    (\permit attestation -> encodeTargetWorkerOperationIngress permit attestation operation)

materialReceipt
  :: Either TargetWorkerCoordinatorError TargetWorkerOperationResult
  -> Either TargetWorkerCoordinatorError TargetWorkerReceipt
materialReceipt result =
  result >>= receiptFromOperationResult
 where
  receiptFromOperationResult operationResult = case operationResult of
    TargetWorkerMaterializedResult receipt -> Right receipt
    _ -> Left TargetWorkerCoordinatorReceiptBindingMismatch

coordinate
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> AcceptedTargetAuthority
  -> AuthorityTime
  -> IO (Either Text AuthorityTime)
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> ( VerifiedTargetWorkerExecutionPermit
       -> TargetWorkerAttestation
       -> Either TargetWorkerIngressError ByteString
     )
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerOperationResult)
coordinate boundary execution accepted now readTime agentIdentity target schema image signed encodeIngress = do
  observedAgent <- observeSelectedTargetAgentRollout boundary
  case observedAgent of
    Left detail -> pure (Left (TargetWorkerCoordinatorAgentIdentityUnavailable detail))
    Right actualRollout
      | targetAgentRolloutEvidenceIdentity actualRollout /= agentIdentity ->
          pure (Left TargetWorkerCoordinatorAgentIdentityMismatch)
      | otherwise -> case prepareTargetWorkerIntent accepted now agentIdentity target schema image signed of
          Left err -> pure (Left (TargetWorkerCoordinatorIntentRejected err))
          Right intent -> runIntent actualRollout intent
 where
  runIntent rollout intent = do
    reserved <- reserveTargetWorkerCreation execution intent
    case reserved of
      Left TargetWorkerSessionPrepareRoleOccupied -> do
        recovered <- recoverRetiredTargetWorker execution (observeRetiredTargetWorkerAbsent boundary)
        case recovered of
          Right True ->
            pure
              ( Left
                  (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareRecoveryCompletedRetryRequired)
              )
          _ -> pure (Left (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareRoleOccupied))
      Left cause -> pure (Left (TargetWorkerCoordinatorSessionPrepareFailed cause))
      Right reservation -> do
        prepared <- tryAny (prepareTargetWorkerJob boundary intent)
        case prepared of
          Left exception
            | isAsyncException exception -> throwIO exception
            | otherwise -> pure (Left TargetWorkerCoordinatorUnhandledException)
          Right (Left _) -> pure (Left (TargetWorkerCoordinatorCreateFailed "Target worker Job preparation failed"))
          Right (Right job) -> do
            fresh <- freshTime now intent
            case fresh of
              Left err -> pure (Left err)
              Right beforeIssue -> do
                issued <- issueTargetWorkerCreation execution reservation
                case issued of
                  Left cause -> pure (Left (TargetWorkerCoordinatorSessionPrepareFailed cause))
                  Right () -> do
                    afterIssue <- freshTime beforeIssue intent
                    case afterIssue of
                      Left err -> pure (Left err)
                      Right createTime -> runReserved reservation rollout intent job createTime

  freshTime previous intent = do
    observed <- tryAny readTime
    case observed of
      Left exception
        | isAsyncException exception -> throwIO exception
        | otherwise ->
            pure (Left (TargetWorkerCoordinatorClockFailed TargetWorkerClockUnavailable))
      Right (Left _) -> pure (Left (TargetWorkerCoordinatorClockFailed TargetWorkerClockUnavailable))
      Right (Right current)
        | current < previous ->
            pure (Left (TargetWorkerCoordinatorClockFailed TargetWorkerClockRegressed))
        | current >= targetWorkerIntentDeadline intent ->
            pure (Left (TargetWorkerCoordinatorClockFailed TargetWorkerClockDeadlineReached))
        | otherwise -> pure (Right current)

  runReserved reservation rollout intent job createTime =
    mask $ \restore -> do
      created <- tryAny (restore (createTargetWorkerIntent boundary intent job))
      recovered <- case created of
        Right (Right jobUid) ->
          pure (Right (Right (TargetWorkerCreateRecovered jobUid)))
        _ -> tryAny (recoverTargetWorkerIntent boundary intent)
      case resolveCreatedJob created recovered of
        Left (Just asyncException) -> throwIO asyncException
        Left Nothing -> pure (Left (createFailure created recovered))
        Right jobUid -> case asyncFromCreate created of
          Just exception -> throwIO exception
          Nothing -> do
            observed <- tryAny (restore (observeTargetWorkerIntent boundary intent))
            case observed of
              Left exception ->
                if isAsyncException exception
                  then throwIO exception
                  else pure (Left TargetWorkerCoordinatorUnhandledException)
              Right (Left detail) -> pure (Left (TargetWorkerCoordinatorObservationFailed detail))
              Right (Right Nothing) -> pure (Left TargetWorkerCoordinatorWorkloadAbsent)
              Right (Right (Just raw)) ->
                case cleanupBinding raw of
                  Left err -> pure (Left err)
                  Right (observedJobUid, podName, podUid)
                    | observedJobUid /= jobUid -> pure (Left TargetWorkerCoordinatorCleanupBindingInvalid)
                    | otherwise -> do
                        current <- freshTime createTime intent
                        case current of
                          Left err -> pure (Left err)
                          Right attestationTime ->
                            case attestTargetWorkerPod attestationTime intent raw of
                              Left attestationError -> pure (Left (TargetWorkerCoordinatorAttestationFailed attestationError))
                              Right attestation ->
                                runAttested reservation rollout intent jobUid podName podUid attestation attestationTime

  resolveCreatedJob created recovered = case recovered of
    Right (Right (TargetWorkerCreateRecovered jobUid)) -> Right jobUid
    Left exception
      | isAsyncException exception -> Left (Just exception)
    _ -> case created of
      Left exception
        | isAsyncException exception -> Left (Just exception)
      _ -> Left Nothing

  asyncFromCreate result = case result of
    Left exception
      | isAsyncException exception -> Just exception
    _ -> Nothing

  createFailure created recovered =
    TargetWorkerCoordinatorCreateFailed
      (boundedDetail (createdDetail created) (recoveredDetail recovered))

  createdDetail result = case result of
    Left _ -> "create-threw"
    Right (Left detail) -> detail
    Right (Right _) -> "create-response-valid"

  recoveredDetail result = case result of
    Left _ -> "recovery-threw"
    Right (Left detail) -> detail
    Right (Right TargetWorkerCreateStablyAbsent) -> "job-stably-absent"
    Right (Right (TargetWorkerCreateRecovered _)) -> "job-recovered"

  runAttested reservation rollout intent jobUid podName podUid attestation attestationTime =
    mask $ \restore -> do
      prepared <-
        tryAny
          ( restore
              (prepareTargetWorkerSessionAttempt execution reservation rollout attestation)
          )
      case prepared of
        -- Preparation may have lost a CAS reply, or another coordinator may
        -- already own this same observed Job and Pod. Neither outcome grants
        -- this caller authority to retire that workload.
        Left exception ->
          if isAsyncException exception
            then throwIO exception
            else pure (Left TargetWorkerCoordinatorUnhandledException)
        Right (Left cause) ->
          pure (Left (TargetWorkerCoordinatorSessionPrepareFailed cause))
        Right (Right sessionBinding) -> do
          dispatchStarted <- newIORef False
          attempted <-
            tryAny (restore (dispatch dispatchStarted rollout attestation sessionBinding attestationTime))
          started <- readIORef dispatchStarted
          let settled = not started
          cleaned <-
            tryAny
              ( finishWithCleanup
                  boundary
                  intent
                  jobUid
                  (Just (podName, podUid))
                  (Right ())
              )
          closed <- case cleaned of
            Right (Right ())
              | settled ->
                  Just
                    <$> tryAny
                      ( do
                          recorded <- recordTargetWorkerRetirement execution attestation sessionBinding
                          case recorded of
                            Left detail -> pure (Left detail)
                            Right () -> closeTargetWorkerSessionAttempt execution sessionBinding
                      )
            _ -> pure Nothing
          case attempted of
            Left exception
              | isAsyncException exception -> throwIO exception
            _ -> case cleaned of
              Left exception
                | isAsyncException exception -> throwIO exception
              Left _ -> pure (Left TargetWorkerCoordinatorUnhandledException)
              Right (Left err) -> pure (Left err)
              Right (Right ()) -> case closed of
                Just (Left exception)
                  | isAsyncException exception -> throwIO exception
                Just (Left _) -> pure (Left (TargetWorkerCoordinatorSessionCleanupFailed "cleanup-threw"))
                Just (Right (Left detail)) ->
                  pure (Left (TargetWorkerCoordinatorSessionCleanupFailed (Text.take 256 detail)))
                Just (Right (Right ())) ->
                  pure (either (const (Left TargetWorkerCoordinatorUnhandledException)) id attempted)
                Nothing -> pure (either (const (Left TargetWorkerCoordinatorUnhandledException)) id attempted)
   where
    dispatch dispatchStarted rolloutEvidence attested sessionBinding previousTime = do
      authorized <-
        authorizeTargetWorkerExecution
          execution
          accepted
          rolloutEvidence
          attested
          sessionBinding
      case authorized of
        Left detail ->
          pure
            (Left (TargetWorkerCoordinatorPermitUnavailable (Text.take 256 detail)))
        Right signedPermit -> do
          current <- freshTime previousTime intent
          case current of
            Left err -> pure (Left err)
            Right permitTime -> verifyPermit permitTime signedPermit
     where
      verifyPermit permitTime signedPermit =
        case verifyTargetWorkerExecutionPermit accepted permitTime intent signedPermit of
          Left err -> pure (Left (TargetWorkerCoordinatorPermitRejected err))
          Right permit
            | not
                ( targetWorkerExecutionPermitMatchesObservation
                    rolloutEvidence
                    attested
                    sessionBinding
                    permit
                ) ->
                pure (Left TargetWorkerCoordinatorPermitBindingMismatch)
            | otherwise -> case encodeIngress permit attested of
                Left err -> pure (Left (TargetWorkerCoordinatorFrameRejected err))
                Right ingress -> do
                  writeIORef dispatchStarted True
                  begun <- beginTargetWorkerDispatch execution sessionBinding
                  case begun of
                    Left _ -> pure (Left (TargetWorkerCoordinatorAttachFailed "worker dispatch journal unavailable"))
                    Right () -> do
                      current <- freshTime permitTime intent
                      case current of
                        Left err -> pure (Left err)
                        Right dispatchTime ->
                          case verifyTargetWorkerExecutionPermit accepted dispatchTime intent signedPermit of
                            Left err -> pure (Left (TargetWorkerCoordinatorPermitRejected err))
                            Right _ -> do
                              attached <-
                                attachTargetWorkerIngress
                                  boundary
                                  attested
                                  ingress
                                  (classifyAndActivateProvisional attested sessionBinding)
                              case attached of
                                Left err -> pure (Left err)
                                Right outcome -> do
                                  committed <- settleTargetWorkerDispatch execution sessionBinding
                                  case committed of
                                    Left _ -> pure (Left (TargetWorkerCoordinatorAttachFailed "worker completion journal unavailable"))
                                    Right () -> do
                                      writeIORef dispatchStarted False
                                      pure $ case outcome of
                                        TargetWorkerProvisionalSucceeded result -> Right result
                                        TargetWorkerProvisionalRefused detail -> Left (TargetWorkerCoordinatorMaterializationRefused detail)

    classifyAndActivateProvisional attested sessionBinding provisionalBytes =
      case decodeTargetWorkerProvisionalCompletion provisionalBytes of
        Left err -> pure (Left (TargetWorkerCoordinatorProvisionalRejected err))
        Right completion -> do
          case classifyProvisionalOutcome attested completion of
            Left err -> pure (Left err)
            Right outcome -> do
              let accessor = targetWorkerProvisionalAccessor completion
              activated <-
                activateTargetWorkerSessionAttempt
                  execution
                  attested
                  sessionBinding
                  accessor
              pure $ case activated of
                Left detail ->
                  Left (TargetWorkerCoordinatorSessionActivateFailed (Text.take 256 detail))
                Right () -> Right outcome

    classifyProvisionalOutcome attested completion =
      case ( targetWorkerProvisionalResult completion
           , targetWorkerProvisionalRefusal completion
           ) of
        (Just result, Nothing)
          | not
              ( targetWorkerOperationResultMatchesSchema
                  (targetWorkerIntentSchema (targetWorkerAttestedIntent attested))
                  result
              ) ->
              Left TargetWorkerCoordinatorReceiptBindingMismatch
          | TargetWorkerMaterializedResult receipt <- result
          , not (targetWorkerReceiptMatchesAttestation attested receipt) ->
              Left TargetWorkerCoordinatorReceiptBindingMismatch
          | otherwise -> Right (TargetWorkerProvisionalSucceeded result)
        (Nothing, Just detail) ->
          Right (TargetWorkerProvisionalRefused detail)
        _ ->
          Left
            ( TargetWorkerCoordinatorProvisionalRejected
                TargetWorkerProvisionalOutcomeInvalid
            )

cleanupBinding
  :: RawTargetWorkerPodObservation
  -> Either
       TargetWorkerCoordinatorError
       (TargetWorkerJobUid, Text, TargetWorkerPodUid)
cleanupBinding raw = do
  jobUid <-
    either
      (const (Left TargetWorkerCoordinatorCleanupBindingInvalid))
      Right
      (mkTargetWorkerJobUid (observedTargetWorkerJobUid raw))
  podUid <-
    either
      (const (Left TargetWorkerCoordinatorCleanupBindingInvalid))
      Right
      (mkTargetWorkerPodUid (observedTargetWorkerPodUid raw))
  if observedTargetWorkerPodName raw == ""
    then Left TargetWorkerCoordinatorCleanupBindingInvalid
    else Right (jobUid, observedTargetWorkerPodName raw, podUid)

finishWithCleanup
  :: (Monad m)
  => TargetWorkerKubernetesBoundary m
  -> TargetWorkerIntent
  -> TargetWorkerJobUid
  -> Maybe (Text, TargetWorkerPodUid)
  -> Either TargetWorkerCoordinatorError value
  -> m (Either TargetWorkerCoordinatorError value)
finishWithCleanup boundary intent jobUid maybePod outcome = do
  deleted <- deleteTargetWorkerIntent boundary intent jobUid maybePod
  case deleted of
    Left detail -> pure (Left (TargetWorkerCoordinatorDeleteFailed detail))
    Right () -> do
      absent <- observeTargetWorkerIntentAbsent boundary intent jobUid maybePod
      pure $ case absent of
        Left detail -> Left (TargetWorkerCoordinatorAbsenceUnobservable detail)
        Right False -> Left TargetWorkerCoordinatorStillPresent
        Right True -> outcome

boundedDetail :: Text -> Text -> Text
boundedDetail left right =
  -- Neither string is allowed to contain secret material by the Kubernetes
  -- boundary contract; the bound keeps error amplification out of receipts.
  mconcat [Text.take 256 left, "; ", Text.take 256 right]

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe SomeAsyncException)
