{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Reusable host-side coordinator for the external ACME EAB ingress.
--
-- The Lifecycle Authority commits the secret-free intent, the host creates and
-- observes the exact immutable Job, and the Authority signs only that observed
-- Pod binding.  The secret-bearing frame is attached once to the attested Pod;
-- it never traverses the control plane or Kubernetes object storage.  Every
-- attempted Job lifecycle ends with deletion and a positive absence proof.
module Prodbox.ControlPlane.ExternalMaterialIngressWorkflow
  ( ExternalMaterialIngressWorkflowRequest (..)
  , ExternalMaterialIngressWorkflowError (..)
  , ExternalMaterialJobBoundary (..)
  , kubernetesExternalMaterialJobBoundary
  , runExternalMaterialIngressWorkflow
  , runExternalMaterialIngressWorkflowWithDelivery
  )
where

import Control.Exception
  ( AsyncException
  , IOException
  , SomeException
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ExternalMaterialIngressClient
  ( ExternalMaterialIngressClient
  , ExternalMaterialIngressClientError
  , authorizeExternalMaterialIngress
  , completeExternalMaterialIngress
  , observeExternalMaterialIngress
  , prepareExternalMaterialIngress
  )
import Prodbox.ControlPlane.ExternalMaterialIngressEndpoint
  ( ExternalMaterialIngressAction (..)
  , ExternalMaterialIngressChallenge (..)
  , ExternalMaterialIngressObservation (..)
  , ExternalMaterialPodObservation (..)
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryClient
  ( RetainedMaterialDeliveryClient
  , RetainedMaterialDeliveryClientError
  , requestRetainedMaterialDelivery
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( retainedMaterialDeliveryWireRequest
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( SRetainedMaterialSchema (SRetainedAcmeEabMaterial)
  , mkRetainedMaterialRef
  , mkRetainedMaterialSource
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressIntent
  , ExternalMaterialIngressPhase (..)
  , ExternalMaterialTargetReceipt
  , externalMaterialIngressIntentDeadline
  , externalMaterialIngressIntentImageDigest
  , externalMaterialIngressIntentPermitId
  , externalMaterialIngressIntentRequest
  , externalMaterialIngressJobIntent
  , externalMaterialTargetReceiptCiphertextDigest
  , externalMaterialTargetReceiptCommitment
  , externalMaterialTargetReceiptDigest
  , externalMaterialTargetReceiptGeneration
  , externalMaterialTargetReceiptPermitId
  , externalMaterialTargetReceiptReadBackVersion
  , mkExternalMaterialIngressIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerJobUid
  , RawCredentialProvisionerPodObservation (..)
  , credentialProvisionerImageDigestText
  , credentialProvisionerIntentServiceAccount
  , credentialProvisionerJobName
  , credentialProvisionerServiceAccountText
  , mkCredentialProvisionerImageDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection
  , CredentialProvisionerJobCreateRecovery (..)
  , CredentialProvisionerJobError (..)
  , ExternalMaterialJobAttestation
  , attachCredentialProvisionerExternalIngress
  , createCredentialProvisionerExternalJob
  , deleteCredentialProvisionerExternalJob
  , externalMaterialJobPodObservation
  , observeCredentialProvisionerExternalJob
  , observeCredentialProvisionerExternalJobAbsent
  , recoverCredentialProvisionerExternalIngress
  , recoverCredentialProvisionerExternalJob
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialAction (..)
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermitId
  , operatorMaterialPermitIdText
  , operatorMaterialRequestDigest
  , operatorMaterialRequestGeneration
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , mkCredentialGeneration
  , targetValueDigestText
  )

data ExternalMaterialIngressWorkflowRequest = ExternalMaterialIngressWorkflowRequest
  { externalMaterialWorkflowAction :: !ExternalMaterialIngressAction
  , externalMaterialWorkflowOperationId :: !Text
  , externalMaterialWorkflowGeneration :: !Natural
  , externalMaterialWorkflowImageRepository :: !Text
  , externalMaterialWorkflowImageDigest :: !Text
  , externalMaterialWorkflowDeadline :: !AuthorityTime
  , externalMaterialWorkflowHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show)

data ExternalMaterialIngressWorkflowError
  = ExternalMaterialWorkflowAuthorityFailed !ExternalMaterialIngressClientError
  | ExternalMaterialWorkflowChallengeInvalid !Text
  | ExternalMaterialWorkflowJobFailed !CredentialProvisionerJobError
  | ExternalMaterialWorkflowReceiptMismatch
  | ExternalMaterialWorkflowAuthorityObservationMismatch
  | ExternalMaterialWorkflowCommittedJobLost
  | ExternalMaterialWorkflowClockUnavailable
  | ExternalMaterialWorkflowUnhandledException
  | ExternalMaterialWorkflowCleanupFailed !CredentialProvisionerJobError
  | ExternalMaterialWorkflowDeliveryFailed !RetainedMaterialDeliveryClientError
  | ExternalMaterialWorkflowDeliveryBindingInvalid !Text
  deriving stock (Eq, Show)

data ExternalMaterialJobBoundary m = ExternalMaterialJobBoundary
  { createExternalMaterialJob
      :: Text
      -> Natural
      -> ExternalMaterialIngressIntent
      -> m (Either CredentialProvisionerJobError CredentialProvisionerJobUid)
  , recoverExternalMaterialJob
      :: ExternalMaterialIngressIntent
      -> m
           ( Either
               CredentialProvisionerJobError
               CredentialProvisionerJobCreateRecovery
           )
  , observeExternalMaterialJob
      :: ExternalMaterialIngressIntent
      -> CredentialProvisionerJobUid
      -> m (Either CredentialProvisionerJobError ExternalMaterialJobAttestation)
  , attachExternalMaterialIngress
      :: ExternalMaterialJobAttestation
      -> ByteString
      -> ByteString
      -> m (Either CredentialProvisionerJobError ExternalMaterialTargetReceipt)
  , recoverExternalMaterialReceipt
      :: ExternalMaterialJobAttestation
      -> m (Either CredentialProvisionerJobError ExternalMaterialTargetReceipt)
  , deleteExternalMaterialJob
      :: ExternalMaterialIngressIntent
      -> CredentialProvisionerJobUid
      -> m (Either CredentialProvisionerJobError ())
  , observeExternalMaterialJobAbsent
      :: ExternalMaterialIngressIntent
      -> CredentialProvisionerJobUid
      -> m (Either CredentialProvisionerJobError ())
  }

kubernetesExternalMaterialJobBoundary
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialJobBoundary IO
kubernetesExternalMaterialJobBoundary connection =
  ExternalMaterialJobBoundary
    { createExternalMaterialJob =
        createCredentialProvisionerExternalJob connection
    , recoverExternalMaterialJob =
        recoverCredentialProvisionerExternalJob connection
    , observeExternalMaterialJob =
        \intent jobUid -> do
          now <- currentAuthorityTime
          case now of
            Left _ ->
              pure
                ( Left
                    ( CredentialProvisionerJobObservationFailed
                        "authority clock is unavailable"
                    )
                )
            Right observedAt ->
              observeCredentialProvisionerExternalJob
                connection
                observedAt
                intent
                jobUid
    , attachExternalMaterialIngress =
        attachCredentialProvisionerExternalIngress connection
    , recoverExternalMaterialReceipt =
        recoverCredentialProvisionerExternalIngress connection
    , deleteExternalMaterialJob =
        deleteCredentialProvisionerExternalJob connection
    , observeExternalMaterialJobAbsent =
        observeCredentialProvisionerExternalJobAbsent connection
    }

runExternalMaterialIngressWorkflow
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
runExternalMaterialIngressWorkflow authority jobs request ingressFrame = do
  prepared <-
    prepareExternalMaterialIngress
      authority
      (externalMaterialWorkflowAction request)
      (externalMaterialWorkflowOperationId request)
      (externalMaterialWorkflowGeneration request)
      (externalMaterialWorkflowImageDigest request)
      (authorityTimeMicros (externalMaterialWorkflowDeadline request))
  case prepared of
    Left err -> pure (Left (ExternalMaterialWorkflowAuthorityFailed err))
    Right challenge -> case intentFromChallenge request challenge of
      Left err -> pure (Left (ExternalMaterialWorkflowChallengeInvalid err))
      Right intent -> do
        observed <-
          observeExternalMaterialIngress
            authority
            (externalMaterialWorkflowOperationId request)
        case observed of
          Left err -> pure (Left (ExternalMaterialWorkflowAuthorityFailed err))
          Right observation
            | not (observationMatchesChallenge challenge observation) ->
                pure (Left ExternalMaterialWorkflowAuthorityObservationMismatch)
            | otherwise ->
                dispatchObservedPhase
                  authority
                  jobs
                  request
                  intent
                  observation
                  ingressFrame

runExternalMaterialIngressWorkflowWithDelivery
  :: ExternalMaterialIngressClient IO
  -> RetainedMaterialDeliveryClient IO
  -> Text
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
runExternalMaterialIngressWorkflowWithDelivery authority delivery target jobs request ingressFrame = do
  ingress <- runExternalMaterialIngressWorkflow authority jobs request ingressFrame
  case ingress of
    Left err -> pure (Left err)
    Right receipt -> do
      nowResult <- currentAuthorityTime
      case nowResult of
        Left _ -> pure (Left ExternalMaterialWorkflowClockUnavailable)
        Right now -> case deliveryRequest now receipt of
          Left detail -> pure (Left (ExternalMaterialWorkflowDeliveryBindingInvalid detail))
          Right boundRequest -> do
            delivered <- requestRetainedMaterialDelivery delivery boundRequest
            pure $ case delivered of
              Left err -> Left (ExternalMaterialWorkflowDeliveryFailed err)
              Right _ -> Right receipt
 where
  deliveryRequest now receipt = do
    let permitId = operatorMaterialPermitIdText (externalMaterialTargetReceiptPermitId receipt)
    operationId <- mkRetainedMaterialRef permitId
    sourceReceipt <- mkRetainedMaterialRef permitId
    commitment <- mkRetainedMaterialRef (externalMaterialTargetReceiptCommitment receipt)
    source <-
      mkRetainedMaterialSource
        (externalMaterialTargetReceiptGeneration receipt)
        operationId
        sourceReceipt
        (externalMaterialTargetReceiptCiphertextDigest receipt)
        commitment
        (externalMaterialTargetReceiptReadBackVersion receipt)
        now
    pure
      ( retainedMaterialDeliveryWireRequest
          SRetainedAcmeEabMaterial
          source
          ("delivery-" <> externalMaterialWorkflowOperationId request)
          target
          (credentialGenerationValue (externalMaterialTargetReceiptGeneration receipt))
          (targetValueDigestText (externalMaterialTargetReceiptDigest receipt))
          (externalMaterialWorkflowDeadline request)
      )

dispatchObservedPhase
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressIntent
  -> ExternalMaterialIngressObservation
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
dispatchObservedPhase authority jobs request intent observation ingressFrame =
  case ( externalMaterialObservedPhase observation
       , externalMaterialObservedReceipt observation
       ) of
    (ExternalMaterialIngressReceiptCommitted, Just receipt) ->
      finishRecoveredReceipt jobs intent receipt
    (ExternalMaterialIngressReceiptCommitted, Nothing) -> mismatch
    (_, Just _) -> mismatch
    (ExternalMaterialIngressIntentCommitted, Nothing) ->
      acquireAndRunJob authority jobs request intent False ingressFrame
    (ExternalMaterialIngressAttestationCommitted, Nothing) ->
      acquireAndRunJob authority jobs request intent True ingressFrame
    (ExternalMaterialIngressPermitCommitted, Nothing) ->
      acquireAndRunJob authority jobs request intent True ingressFrame
    (ExternalMaterialIngressIdle, Nothing) -> mismatch
 where
  mismatch = pure (Left ExternalMaterialWorkflowAuthorityObservationMismatch)

finishRecoveredReceipt
  :: ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressIntent
  -> ExternalMaterialTargetReceipt
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
finishRecoveredReceipt jobs intent receipt = do
  recovered <- recoverExternalMaterialJob jobs intent
  case recovered of
    Left err -> pure (Left (ExternalMaterialWorkflowCleanupFailed err))
    Right CredentialProvisionerJobCreateStablyAbsent -> pure (Right receipt)
    Right (CredentialProvisionerJobCreateRecovered jobUid) ->
      finishWithCleanup jobs intent jobUid (Right receipt)

acquireAndRunJob
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressIntent
  -> Bool
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
acquireAndRunJob authority jobs request intent priorAttestationCommitted ingressFrame =
  mask $ \restore -> do
    existing <- tryAny (restore (recoverExternalMaterialJob jobs intent))
    case existing of
      Left exception
        | isAsyncException exception -> throwIO exception
      Left _ -> pure (Left ExternalMaterialWorkflowUnhandledException)
      Right (Left err) -> pure (Left (ExternalMaterialWorkflowJobFailed err))
      Right (Right (CredentialProvisionerJobCreateRecovered jobUid)) ->
        executeExactJob authority jobs request intent jobUid ingressFrame
      Right (Right CredentialProvisionerJobCreateStablyAbsent)
        | priorAttestationCommitted ->
            pure (Left ExternalMaterialWorkflowCommittedJobLost)
        | otherwise -> do
            created <-
              tryAny
                ( restore
                    ( createExternalMaterialJob
                        jobs
                        (externalMaterialWorkflowImageRepository request)
                        (externalMaterialWorkflowHeartbeatMicros request)
                        intent
                    )
                )
            resolveCreate authority jobs request intent ingressFrame created

resolveCreate
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressIntent
  -> ByteString
  -> Either
       SomeException
       (Either CredentialProvisionerJobError CredentialProvisionerJobUid)
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
resolveCreate authority jobs request intent ingressFrame created = case created of
  Right (Right jobUid) ->
    executeExactJob authority jobs request intent jobUid ingressFrame
  _ -> do
    recovered <- tryAny (recoverExternalMaterialJob jobs intent)
    case recovered of
      Right (Right (CredentialProvisionerJobCreateRecovered jobUid)) ->
        case created of
          Left exception
            | isAsyncException exception -> do
                _ <- tryAny (cleanupExactJob jobs intent jobUid)
                throwIO exception
          _ -> executeExactJob authority jobs request intent jobUid ingressFrame
      Right (Right CredentialProvisionerJobCreateStablyAbsent) -> case created of
        Left exception
          | isAsyncException exception -> throwIO exception
        Left _ -> pure (Left ExternalMaterialWorkflowUnhandledException)
        Right (Left err) -> pure (Left (ExternalMaterialWorkflowJobFailed err))
      Right (Left err) -> pure (Left (ExternalMaterialWorkflowJobFailed err))
      Left exception
        | isAsyncException exception -> throwIO exception
      Left _ -> pure (Left ExternalMaterialWorkflowUnhandledException)

executeExactJob
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
executeExactJob authority jobs request intent jobUid ingressFrame =
  mask $ \restore -> do
    attempted <-
      tryAny
        ( restore
            (runAttestedIngress authority jobs request intent jobUid ingressFrame)
        )
    resolved <- case attempted of
      Right result -> pure (Right result)
      Left _ ->
        tryAny (recoverCommittedOutcome authority jobs request intent jobUid)
    let outcome = case resolved of
          Left _ -> Left ExternalMaterialWorkflowUnhandledException
          Right result -> result
    cleaned <- tryAny (finishWithCleanup jobs intent jobUid outcome)
    case asyncExceptionFrom attempted of
      Just exception -> throwIO exception
      Nothing -> case asyncExceptionFrom resolved of
        Just exception -> throwIO exception
        Nothing -> case cleaned of
          Left exception
            | isAsyncException exception -> throwIO exception
          Left _ -> pure (Left ExternalMaterialWorkflowUnhandledException)
          Right result -> pure result

runAttestedIngress
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
runAttestedIngress authority jobs request intent jobUid ingressFrame = do
  attested <-
    observeExternalMaterialJob
      jobs
      intent
      jobUid
  case attested of
    Left err -> pure (Left (ExternalMaterialWorkflowJobFailed err))
    Right exactPod -> do
      authorized <-
        authorizeExternalMaterialIngress
          authority
          (externalMaterialWorkflowOperationId request)
          (podObservationForAuthority exactPod)
      case authorized of
        Left err -> do
          recoveredPermit <- recoverCommittedPermit authority request
          case recoveredPermit of
            Left _ -> pure (Left (ExternalMaterialWorkflowAuthorityFailed err))
            Right signedPermit ->
              attachAndCommit authority jobs request exactPod signedPermit ingressFrame
        Right signedPermit ->
          attachAndCommit authority jobs request exactPod signedPermit ingressFrame

attachAndCommit
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialJobAttestation
  -> ByteString
  -> ByteString
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
attachAndCommit authority jobs request exactPod signedPermit ingressFrame = do
  attached <-
    attachExternalMaterialIngress
      jobs
      exactPod
      signedPermit
      ingressFrame
  receipt <- case attached of
    Right value -> pure (Right value)
    Left _ -> do
      recovered <- recoverExternalMaterialReceipt jobs exactPod
      pure (first ExternalMaterialWorkflowJobFailed recovered)
  case receipt of
    Left err -> pure (Left err)
    Right value -> commitReceiptWithRecovery authority request value

commitReceiptWithRecovery
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialTargetReceipt
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
commitReceiptWithRecovery authority request receipt = do
  completed <-
    completeExternalMaterialIngress
      authority
      (externalMaterialWorkflowOperationId request)
      receipt
  case completed of
    Right confirmed
      | confirmed == receipt -> pure (Right receipt)
      | otherwise -> pure (Left ExternalMaterialWorkflowReceiptMismatch)
    Left original -> do
      observed <-
        observeExternalMaterialIngress
          authority
          (externalMaterialWorkflowOperationId request)
      pure $ case observed of
        Right observation
          | externalMaterialObservedPhase observation
              == ExternalMaterialIngressReceiptCommitted
          , externalMaterialObservedReceipt observation == Just receipt ->
              Right receipt
        _ -> Left (ExternalMaterialWorkflowAuthorityFailed original)

recoverCommittedPermit
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialIngressWorkflowRequest
  -> IO (Either ExternalMaterialIngressWorkflowError ByteString)
recoverCommittedPermit authority request = do
  observed <-
    observeExternalMaterialIngress
      authority
      (externalMaterialWorkflowOperationId request)
  pure $ case observed of
    Left err -> Left (ExternalMaterialWorkflowAuthorityFailed err)
    Right observation -> case externalMaterialObservedPermit observation of
      Just permit
        | externalMaterialObservedPhase observation
            `elem` [ ExternalMaterialIngressPermitCommitted
                   , ExternalMaterialIngressReceiptCommitted
                   ] ->
            Right permit
      _ -> Left ExternalMaterialWorkflowAuthorityObservationMismatch

recoverCommittedOutcome
  :: ExternalMaterialIngressClient IO
  -> ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
recoverCommittedOutcome authority jobs request intent jobUid = do
  observed <-
    observeExternalMaterialIngress
      authority
      (externalMaterialWorkflowOperationId request)
  case observed of
    Right observation
      | externalMaterialObservedPhase observation
          == ExternalMaterialIngressReceiptCommitted
      , Just receipt <- externalMaterialObservedReceipt observation ->
          pure (Right receipt)
    _ -> do
      attested <- observeExternalMaterialJob jobs intent jobUid
      case attested of
        Left _ -> pure (Left ExternalMaterialWorkflowUnhandledException)
        Right exactPod -> do
          recovered <- recoverExternalMaterialReceipt jobs exactPod
          case recovered of
            Left _ -> pure (Left ExternalMaterialWorkflowUnhandledException)
            Right receipt -> commitReceiptWithRecovery authority request receipt

finishWithCleanup
  :: ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> Either ExternalMaterialIngressWorkflowError ExternalMaterialTargetReceipt
  -> IO
       ( Either
           ExternalMaterialIngressWorkflowError
           ExternalMaterialTargetReceipt
       )
finishWithCleanup jobs intent jobUid outcome = do
  cleaned <- cleanupExactJob jobs intent jobUid
  pure $ case cleaned of
    Left err -> Left err
    Right () -> outcome

cleanupExactJob
  :: ExternalMaterialJobBoundary IO
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO (Either ExternalMaterialIngressWorkflowError ())
cleanupExactJob jobs intent jobUid =
  mask $ \_ -> do
    deleted <- tryAny (deleteExternalMaterialJob jobs intent jobUid)
    firstAbsence <- tryAny (observeExternalMaterialJobAbsent jobs intent jobUid)
    confirmedAbsence <- case asyncExceptionFrom firstAbsence of
      Just _ -> tryAny (observeExternalMaterialJobAbsent jobs intent jobUid)
      Nothing -> pure firstAbsence
    case firstCleanupCancellation deleted firstAbsence confirmedAbsence of
      Just exception -> throwIO exception
      Nothing -> pure $ case confirmedAbsence of
        Right (Right ()) -> Right ()
        Left _ -> Left ExternalMaterialWorkflowUnhandledException
        Right (Left err) -> Left (ExternalMaterialWorkflowCleanupFailed err)

intentFromChallenge
  :: ExternalMaterialIngressWorkflowRequest
  -> ExternalMaterialIngressChallenge
  -> Either Text ExternalMaterialIngressIntent
intentFromChallenge request challenge = do
  unless
    ( externalMaterialChallengeOperationId challenge
        == externalMaterialWorkflowOperationId request
        && externalMaterialChallengeGeneration challenge
          == externalMaterialWorkflowGeneration request
        && externalMaterialChallengeImageDigest challenge
          == externalMaterialWorkflowImageDigest request
        && externalMaterialChallengeDeadlineMicros challenge
          == authorityTimeMicros (externalMaterialWorkflowDeadline request)
    )
    (Left "Authority challenge does not match the requested EAB ingress")
  operationId <-
    first
      (showText "operation ID")
      (mkOperatorMaterialOperationId (externalMaterialChallengeOperationId challenge))
  generation <-
    first
      (showText "generation")
      (mkCredentialGeneration (externalMaterialChallengeGeneration challenge))
  permitId <-
    first
      (showText "permit ID")
      (mkOperatorMaterialPermitId (externalMaterialChallengePermitId challenge))
  image <-
    first
      (showText "image digest")
      (mkCredentialProvisionerImageDigest (externalMaterialChallengeImageDigest challenge))
  intent <-
    first
      (showText "intent")
      ( mkExternalMaterialIngressIntent
          (workflowOperatorAction (externalMaterialWorkflowAction request))
          operationId
          generation
          permitId
          image
          (authorityTimeFromMicros (externalMaterialChallengeDeadlineMicros challenge))
      )
  validateChallengeDerivedFields challenge intent
  pure intent

validateChallengeDerivedFields
  :: ExternalMaterialIngressChallenge
  -> ExternalMaterialIngressIntent
  -> Either Text ()
validateChallengeDerivedFields challenge intent =
  unless
    ( externalMaterialChallengePermitId challenge
        == operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
        && externalMaterialChallengeRequestDigest challenge
          == targetValueDigestText
            (operatorMaterialRequestDigest (externalMaterialIngressIntentRequest intent))
        && externalMaterialChallengeGeneration challenge
          == credentialGenerationValue
            (operatorMaterialRequestGeneration (externalMaterialIngressIntentRequest intent))
        && externalMaterialChallengeJobName challenge
          == credentialProvisionerJobName jobIntent
        && externalMaterialChallengeImageDigest challenge
          == credentialProvisionerImageDigestText
            (externalMaterialIngressIntentImageDigest intent)
        && externalMaterialChallengeServiceAccount challenge
          == credentialProvisionerServiceAccountText
            (credentialProvisionerIntentServiceAccount jobIntent)
        && externalMaterialChallengeDeadlineMicros challenge
          == authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    )
    (Left "Authority challenge derived fields are inconsistent")
 where
  jobIntent = externalMaterialIngressJobIntent intent

workflowOperatorAction :: ExternalMaterialIngressAction -> OperatorMaterialAction
workflowOperatorAction action = case action of
  ExternalMaterialInstall -> InstallOperatorMaterial
  ExternalMaterialRotate -> RotateOperatorMaterial

podObservationForAuthority
  :: ExternalMaterialJobAttestation -> ExternalMaterialPodObservation
podObservationForAuthority attestation =
  ExternalMaterialPodObservation
    { externalMaterialPodJobName = rawCredentialProvisionerJobName raw
    , externalMaterialPodJobUid = rawCredentialProvisionerJobUid raw
    , externalMaterialPodUid = rawCredentialProvisionerPodUid raw
    , externalMaterialPodImageDigest = rawCredentialProvisionerImageDigest raw
    , externalMaterialPodServiceAccount = rawCredentialProvisionerServiceAccount raw
    , externalMaterialPodServiceAccountUid =
        rawCredentialProvisionerServiceAccountUid raw
    , externalMaterialPodPermitId = rawCredentialProvisionerPermitId raw
    , externalMaterialPodRequestDigest =
        targetValueDigestText (rawCredentialProvisionerRequestDigest raw)
    , externalMaterialPodDeadlineMicros =
        authorityTimeMicros (rawCredentialProvisionerDeadline raw)
    , externalMaterialPodHeartbeatMicros =
        authorityTimeMicros (rawCredentialProvisionerHeartbeat raw)
    , externalMaterialPodPhase = rawCredentialProvisionerPhase raw
    , externalMaterialPodContainerReady = rawCredentialProvisionerContainerReady raw
    , externalMaterialPodRestartCount = rawCredentialProvisionerRestartCount raw
    , externalMaterialPodDeletionTimestamp =
        rawCredentialProvisionerDeletionTimestamp raw
    }
 where
  raw = externalMaterialJobPodObservation attestation

observationMatchesChallenge
  :: ExternalMaterialIngressChallenge
  -> ExternalMaterialIngressObservation
  -> Bool
observationMatchesChallenge challenge observation =
  externalMaterialObservedOperationId observation
    == externalMaterialChallengeOperationId challenge
    && externalMaterialObservedChallenge observation == challenge

currentAuthorityTime :: IO (Either ExternalMaterialIngressWorkflowError AuthorityTime)
currentAuthorityTime = do
  attempted <- try getPOSIXTime :: IO (Either IOException POSIXTime)
  pure $ case attempted of
    Left _ -> Left ExternalMaterialWorkflowClockUnavailable
    Right value
      | value < 0 -> Left ExternalMaterialWorkflowClockUnavailable
      | otherwise ->
          Right
            ( authorityTimeFromMicros
                (fromInteger (floor (value * 1000000)))
            )

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

asyncExceptionFrom :: Either SomeException value -> Maybe SomeException
asyncExceptionFrom attempted = case attempted of
  Left exception
    | isAsyncException exception -> Just exception
  _ -> Nothing

firstCleanupCancellation
  :: Either SomeException deleted
  -> Either SomeException firstAbsence
  -> Either SomeException confirmedAbsence
  -> Maybe SomeException
firstCleanupCancellation deleted firstAbsence confirmedAbsence =
  case asyncExceptionFrom deleted of
    Just exception -> Just exception
    Nothing -> case asyncExceptionFrom firstAbsence of
      Just exception -> Just exception
      Nothing -> asyncExceptionFrom confirmedAbsence

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe AsyncException)

showText :: (Show errorValue) => Text -> errorValue -> Text
showText label err = label <> " is invalid: " <> Text.pack (show err)
