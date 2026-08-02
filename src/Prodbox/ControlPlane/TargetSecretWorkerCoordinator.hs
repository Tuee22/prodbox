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
  , TargetWorkerProvisionalOutcome (..)
  , TargetWorkerKubernetesBoundary (..)
  , TargetWorkerExecutionBoundary (..)
  , TargetWorkerCoordinatorError (..)
  , coordinateDirectTargetMaterialization
  , coordinateRewrappedTargetMaterialization
  , coordinateTargetOneShotOperation
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ServiceSessionJournal (ServiceSessionBinding)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , TargetSecretPayload
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentIdentity
  , TargetAgentRolloutEvidence
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
  , targetWorkerIntentSchema
  , targetWorkerOperationResultMatchesSchema
  , targetWorkerProvisionalAccessor
  , targetWorkerProvisionalRefusal
  , targetWorkerProvisionalResult
  , targetWorkerReceiptMatchesAttestation
  )
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

data TargetWorkerKubernetesBoundary m = TargetWorkerKubernetesBoundary
  { observeSelectedTargetAgentRollout
      :: m (Either Text TargetAgentRolloutEvidence)
  , createTargetWorkerIntent
      :: TargetWorkerIntent
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
  { prepareTargetWorkerSessionAttempt
      :: TargetAgentRolloutEvidence
      -> TargetWorkerAttestation
      -> m (Either Text ServiceSessionBinding)
  , authorizeTargetWorkerExecution
      :: AcceptedTargetAuthority
      -> TargetAgentRolloutEvidence
      -> TargetWorkerAttestation
      -> ServiceSessionBinding
      -> m (Either Text SignedTargetWorkerExecutionPermit)
  , activateTargetWorkerSessionAttempt
      :: TargetWorkerAttestation
      -> ServiceSessionBinding
      -> Text
      -> m (Either Text ())
  , closeTargetWorkerSessionAttempt
      :: ServiceSessionBinding
      -> m (Either Text ())
  }

data TargetWorkerCoordinatorError
  = TargetWorkerCoordinatorAgentIdentityUnavailable !Text
  | TargetWorkerCoordinatorAgentIdentityMismatch
  | TargetWorkerCoordinatorIntentRejected !TargetWorkerIntentError
  | TargetWorkerCoordinatorCreateFailed !Text
  | TargetWorkerCoordinatorObservationFailed !Text
  | TargetWorkerCoordinatorWorkloadAbsent
  | TargetWorkerCoordinatorCleanupBindingInvalid
  | TargetWorkerCoordinatorAttestationFailed !TargetWorkerAttestationError
  | TargetWorkerCoordinatorSessionPrepareFailed !Text
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
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> TargetSecretPayload
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateDirectTargetMaterialization boundary execution accepted now agentIdentity target schema image signed payload =
  fmap materialReceipt $ do
    coordinate
      boundary
      execution
      accepted
      now
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
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> ByteString
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateRewrappedTargetMaterialization boundary execution accepted now agentIdentity target schema image signed envelope =
  fmap materialReceipt $ do
    coordinate
      boundary
      execution
      accepted
      now
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
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> TargetWorkerOperationInput
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerOperationResult)
coordinateTargetOneShotOperation boundary execution accepted now agentIdentity target schema image signed operation =
  coordinate
    boundary
    execution
    accepted
    now
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
coordinate boundary execution accepted now agentIdentity target schema image signed encodeIngress = do
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
  runIntent rollout intent =
    mask $ \restore -> do
      created <- tryAny (restore (createTargetWorkerIntent boundary intent))
      recovered <- case created of
        Right (Right jobUid) ->
          pure (Right (Right (TargetWorkerCreateRecovered jobUid)))
        _ -> tryAny (recoverTargetWorkerIntent boundary intent)
      case resolveCreatedJob created recovered of
        Left (Just async) -> throwIO async
        Left Nothing -> pure (Left (createFailure created recovered))
        Right jobUid -> case asyncFromCreate created of
          Just exception -> do
            _ <-
              tryAny
                (finishWithCleanup boundary intent jobUid Nothing (Right ()))
            throwIO exception
          Nothing -> do
            observed <- tryAny (restore (observeTargetWorkerIntent boundary intent))
            case observed of
              Left exception -> do
                _ <-
                  tryAny
                    ( finishWithCleanup
                        boundary
                        intent
                        jobUid
                        Nothing
                        (Right ())
                    )
                if isAsyncException exception
                  then throwIO exception
                  else pure (Left TargetWorkerCoordinatorUnhandledException)
              Right (Left detail) ->
                finishWithCleanup
                  boundary
                  intent
                  jobUid
                  Nothing
                  (Left (TargetWorkerCoordinatorObservationFailed detail))
              Right (Right Nothing) ->
                finishWithCleanup
                  boundary
                  intent
                  jobUid
                  Nothing
                  (Left TargetWorkerCoordinatorWorkloadAbsent)
              Right (Right (Just raw)) ->
                case cleanupBinding raw of
                  Left err ->
                    finishWithCleanup boundary intent jobUid Nothing (Left err)
                  Right (observedJobUid, podName, podUid)
                    | observedJobUid /= jobUid ->
                        finishWithCleanup
                          boundary
                          intent
                          jobUid
                          Nothing
                          (Left TargetWorkerCoordinatorCleanupBindingInvalid)
                    | otherwise ->
                        case attestTargetWorkerPod now intent raw of
                          Left attestationError ->
                            finishWithCleanup
                              boundary
                              intent
                              jobUid
                              (Just (podName, podUid))
                              (Left (TargetWorkerCoordinatorAttestationFailed attestationError))
                          Right attestation ->
                            runAttested rollout intent jobUid podName podUid attestation

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

  runAttested rollout intent jobUid podName podUid attestation =
    mask $ \restore -> do
      prepared <-
        tryAny
          ( restore
              (prepareTargetWorkerSessionAttempt execution rollout attestation)
          )
      case prepared of
        Left exception -> do
          _ <-
            tryAny
              ( finishWithCleanup
                  boundary
                  intent
                  jobUid
                  (Just (podName, podUid))
                  (Right ())
              )
          if isAsyncException exception
            then throwIO exception
            else pure (Left TargetWorkerCoordinatorUnhandledException)
        Right (Left detail) ->
          finishWithCleanup
            boundary
            intent
            jobUid
            (Just (podName, podUid))
            (Left (TargetWorkerCoordinatorSessionPrepareFailed (Text.take 256 detail)))
        Right (Right sessionBinding) -> do
          attempted <- tryAny (restore (dispatch rollout attestation sessionBinding))
          closed <- tryAny (closeTargetWorkerSessionAttempt execution sessionBinding)
          let outcome = case (attempted, closed) of
                (_, Left _) -> Left (TargetWorkerCoordinatorSessionCleanupFailed "cleanup-threw")
                (_, Right (Left detail)) ->
                  Left (TargetWorkerCoordinatorSessionCleanupFailed (Text.take 256 detail))
                (Left _, Right (Right ())) -> Left TargetWorkerCoordinatorUnhandledException
                (Right result, Right (Right ())) -> result
          cleaned <-
            tryAny
              ( finishWithCleanup
                  boundary
                  intent
                  jobUid
                  (Just (podName, podUid))
                  outcome
              )
          case attempted of
            Left exception
              | isAsyncException exception -> throwIO exception
            _ -> case closed of
              Left exception
                | isAsyncException exception -> throwIO exception
              _ -> case cleaned of
                Left exception
                  | isAsyncException exception -> throwIO exception
                Left _ -> pure (Left TargetWorkerCoordinatorUnhandledException)
                Right result -> pure result
   where
    dispatch rolloutEvidence attested sessionBinding = do
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
        Right signedPermit ->
          case verifyTargetWorkerExecutionPermit accepted now intent signedPermit of
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
                    attached <-
                      attachTargetWorkerIngress
                        boundary
                        attested
                        ingress
                        (classifyAndActivateProvisional attested sessionBinding)
                    pure $ case attached of
                      Left err -> Left err
                      Right (TargetWorkerProvisionalSucceeded result) -> Right result
                      Right (TargetWorkerProvisionalRefused detail) ->
                        Left (TargetWorkerCoordinatorMaterializationRefused detail)

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
  isJust (fromException exception :: Maybe AsyncException)
