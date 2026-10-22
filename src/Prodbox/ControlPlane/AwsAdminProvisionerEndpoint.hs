{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle-Authority endpoint for AWS-admin Credential
-- Provisioner permits. All request and response values are secret-free: the
-- elevated AWS credential is delivered only to the attested Job over its
-- bounded stdin frame and can never enter this API or retained Authority
-- state.
module Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminProvisionerRequest (..)
  , AwsAdminPodObservation (..)
  , AwsAdminProvisionerChallenge (..)
  , AwsAdminProvisionerPhase (..)
  , AwsAdminProvisionerObservation (..)
  , AwsAdminFirstReconcileProjection (..)
  , AwsAdminProvisionerResponse (..)
  , AwsAdminAuthorityRepositoryResolver
  , AwsAdminProviderCredentialBoundary (..)
  , awsAdminProvisionerAuthenticatedHandler
  , awsAdminProvisionerMaximumBytes
  , awsAdminProvisionerResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
  ( AwsAdminPrepareAuthorityPhase (..)
  , AwsAdminPreparedTargetLifecycle (..)
  , FirstReconcileContinuation (..)
  , awsAdminPreparedTargetPrepareErrorCause
  , renderAwsAdminPreparedTargetPrepareCause
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (..))
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  , verifiedCallerSlotPrincipal
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , layerRoleReadinessSource
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAwsAdminProvisioner)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch (ProviderCredentialRecoveryView)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAttestedRecoveryProof
  , AwsAdminAuthorityRepository
  , AwsAdminAuthorityRepositoryError (..)
  , AwsAdminAuthorityState (..)
  , AwsAdminAuthorityStateError (AwsAdminAuthorityTransitionRefused)
  , AwsAdminAuthorizedRecoveryError (..)
  , AwsAdminAuthorizedRecoveryProof
  , AwsAdminPreparedTargetBoundary (..)
  , attestAwsAdminAuthority
  , authorizeAwsAdminAuthority
  , awsAdminAuthorityCurrentIntent
  , bindAwsAdminAuthorizedRecoveryIntent
  , bindAwsAdminPreparedRenewalIntent
  , completeAwsAdminAuthority
  , observeAwsAdminAuthority
  , prepareAwsAdminAuthority
  , prepareAwsAdminAuthorityAttestedRecovery
  , prepareAwsAdminAuthorityAuthorizedRecovery
  , prepareAwsAdminAuthorityRenewal
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( decodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitIntent
  , SignedAwsAdminPermit
  , awsAdminJobNameForPermit
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentRequestDigest
  , awsAdminWorkerServiceAccount
  , decodeAwsAdminPermitIntent
  , decodeSignedAwsAdminPermit
  , encodeAwsAdminJobBinding
  , encodeAwsAdminPermitIntent
  , encodeSignedAwsAdminPermit
  , mkAwsAdminJobBinding
  , signedAwsAdminPermitIntent
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( preparedCredentialTargetId
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport (AuthorityManifestSigner)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , targetValueDigestText
  )

data AwsAdminProvisionerRequest
  = PrepareAwsAdminProvisioning !ByteString
  | AttestAwsAdminProvisioning !Text !AwsAdminPodObservation
  | AuthorizeAwsAdminProvisioning !Text
  | CompleteAwsAdminProvisioning !Text !ByteString !ByteString
  | ObserveAwsAdminProvisioning !Text
  | ObserveAwsAdminFirstReconcile
  | ObserveAwsAdminProviderCredentialOperation
  | ObserveAwsAdminProvisioningMetadata !Text
  | ObserveAwsAdminProviderCredentialRecovery
  | ObserveAwsAdminFirstReconcileRecovery
  | SettleAwsAdminFirstReconcileRecovery
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminPreparationTransition
  = AwsAdminPreparationStandard
  | AwsAdminPreparationPreparedRenewal !AuthorityTime !AwsAdminPermitIntent
  | AwsAdminPreparationAuthorizedRecovery
      !AwsAdminAuthorizedRecoveryProof
      !AuthorityTime
      !AwsAdminPermitIntent
  | AwsAdminPreparationAttestedRecovery
      !AwsAdminAttestedRecoveryProof
      !AuthorityTime
      !AwsAdminPermitIntent

-- | Exact Kubernetes GET readback. Job and Pod UIDs are both mandatory so
-- name-reuse and owner-reference substitution cannot satisfy attestation.
data AwsAdminPodObservation = AwsAdminPodObservation
  { awsAdminObservedJobName :: !Text
  , awsAdminObservedJobUid :: !Text
  , awsAdminObservedPodName :: !Text
  , awsAdminObservedPodUid :: !Text
  , awsAdminObservedImageDigest :: !Text
  , awsAdminObservedServiceAccount :: !Text
  , awsAdminObservedServiceAccountUid :: !Text
  , awsAdminObservedHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminProvisionerChallenge = AwsAdminProvisionerChallenge
  { awsAdminChallengeOperationId :: !Text
  , awsAdminChallengePermitId :: !Text
  , awsAdminChallengeRequestDigest :: !Text
  , awsAdminChallengeGeneration :: !Natural
  , awsAdminChallengeTarget :: !TargetSecretId
  , awsAdminChallengeJobName :: !Text
  , awsAdminChallengeImageDigest :: !Text
  , awsAdminChallengeServiceAccount :: !Text
  , awsAdminChallengeAuthorityScope :: !Text
  , awsAdminChallengeAuthorityEndpoint :: !Text
  , awsAdminChallengeDeadlineMicros :: !Natural
  , awsAdminChallengeCanonicalIntent :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminProvisionerPhase
  = AwsAdminProvisionerPrepared
  | AwsAdminProvisionerAttested
  | AwsAdminProvisionerAuthorized
  | AwsAdminProvisionerCompleted
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminProvisionerObservation = AwsAdminProvisionerObservation
  { awsAdminObservedChallenge :: !AwsAdminProvisionerChallenge
  , awsAdminObservedPhase :: !AwsAdminProvisionerPhase
  , awsAdminObservedPermit :: !(Maybe ByteString)
  , awsAdminObservedReceipt :: !(Maybe ByteString)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminFirstReconcileProjection = AwsAdminFirstReconcileProjection
  { awsAdminFirstReconcileClass :: !AwsCredentialClass
  , awsAdminFirstReconcileMemberIndex :: !Natural
  , awsAdminFirstReconcileMemberDigest :: !Text
  , awsAdminFirstReconcileDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminProvisionerResponse
  = AwsAdminProvisioningPrepared !AwsAdminProvisionerChallenge
  | AwsAdminProvisioningAttested !ByteString
  | AwsAdminProvisioningAuthorized !ByteString
  | AwsAdminProvisioningCompleted !ByteString
  | AwsAdminProvisioningObserved !AwsAdminProvisionerObservation
  | AwsAdminFirstReconcileObserved !(Maybe AwsAdminFirstReconcileProjection)
  | AwsAdminProvisioningRefused !Text
  | AwsAdminProvisioningUnavailable !Text
  | AwsAdminProviderCredentialOperationObserved !(Maybe Text)
  | AwsAdminProviderCredentialRecoveryObserved !ProviderCredentialRecoveryView
  | AwsAdminFirstReconcileRecoveryObserved !Bool
  | AwsAdminFirstReconcileRecoverySettled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

type AwsAdminAuthorityRepositoryResolver m revision =
  Text -> Either Text (AwsAdminAuthorityRepository m revision)

-- | Authority-owned lifecycle effects. These consume metadata only; the
-- production interpreter captures its own retained repositories and Agent.
data AwsAdminProviderCredentialBoundary m = AwsAdminProviderCredentialBoundary
  { reserveAwsAdminProviderCredential :: AwsAdminPermitIntent -> m (Either Text ())
  , admitAwsAdminProviderPermit :: SignedAwsAdminPermit -> m (Either Text ())
  , settleAwsAdminProviderCredential :: AwsAdminPermitIntent -> m (Either Text ())
  , observePendingAwsAdminProviderCredential :: m (Either Text (Maybe Text))
  , observeAwsAdminProviderCredentialRecovery :: m (Either Text ProviderCredentialRecoveryView)
  , confirmAwsAdminProviderCredentialServing :: m (Either Text ())
  }

awsAdminProvisionerMaximumBytes :: Int
awsAdminProvisionerMaximumBytes = 256 * 1024

awsAdminProvisionerResponseMaximumBytes :: Int
awsAdminProvisionerResponseMaximumBytes = 256 * 1024

awsAdminProvisionerAuthenticatedHandler
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> m (Either Text AuthorityTime)
  -> AwsAdminAuthorityRepositoryResolver m revision
  -> AwsAdminPreparedTargetLifecycle m
  -> AwsAdminProviderCredentialBoundary m
  -> AuthorityManifestSigner m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
awsAdminProvisionerAuthenticatedHandler
  maximumBytes
  readiness
  observeNow
  resolveRepository
  targetLifecycle
  providerCredential
  signer
  fallback =
    AuthenticatedRoleHandler
      { authenticatedHandlerReadiness =
          layerRoleReadinessSource readiness (authenticatedHandlerReadiness fallback)
      , authenticatedHandlerHandle = handle
      }
   where
    handle caller route body = case route of
      LifecycleAwsAdminProvisioner -> Just <$> serve caller body
      _ -> authenticatedHandlerHandle fallback caller route body

    serve caller body = case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
      Left _ -> pure (ReplyBadRequest, responseBody (refused "request-codec-rejected"))
      Right request
        | not (callerAllowed caller request) ->
            pure (ReplyForbidden, responseBody (refused "caller-refused"))
        | otherwise -> do
            response <- runRequest request
            pure (responseStatus response, responseBody response)

    runRequest request = case request of
      PrepareAwsAdminProvisioning intentBytes ->
        case decodeAwsAdminPermitIntent intentBytes of
          Left _ -> pure (refused "intent-codec-rejected")
          Right draft ->
            withIntentRepository draft (prepareRequest draft)
      AttestAwsAdminProvisioning operationId observation ->
        withOperationRepository operationId $ \repository -> do
          current <- observeAwsAdminAuthority repository
          case current >>= intentForOperation operationId of
            Left err -> pure (responseForError err)
            Right intent -> do
              nowResult <- observeNow
              case nowResult of
                Left _ -> pure (unavailable "authority-time-unavailable")
                Right now -> case bindingFromObservation now intent observation of
                  Left detail -> pure (refused detail)
                  Right binding -> do
                    result <- attestAwsAdminAuthority repository binding
                    pure $ case result of
                      Left err -> responseForError err
                      Right _ ->
                        AwsAdminProvisioningAttested
                          (encodeAwsAdminJobBinding binding)
      AuthorizeAwsAdminProvisioning operationId ->
        withOperationRepository operationId $ \repository -> do
          current <- observeAwsAdminAuthority repository
          case current >>= intentForOperation operationId of
            Left err -> pure (responseForError err)
            Right intent -> do
              -- Read immediately before Transit signing. The value is never
              -- captured across Job polling and cannot extend the deadline.
              nowResult <- observeNow
              case nowResult of
                Left _ -> pure (unavailable "authority-time-unavailable")
                Right now -> do
                  reserved <- reserveAwsAdminProviderCredential providerCredential intent
                  case reserved of
                    Left detail -> pure (unavailable ("provider-credential/reserve/" <> detail))
                    Right () -> authorizeAndAdmit repository now
      CompleteAwsAdminProvisioning operationId permitBytes receiptBytes ->
        withOperationRepository
          operationId
          (completeProvisioning operationId permitBytes receiptBytes)
      ObserveAwsAdminProvisioning operationId ->
        withOperationRepository operationId $ \repository -> do
          result <- observeAwsAdminAuthority repository
          case result of
            Left err -> pure (responseForError err)
            Right state -> do
              recovered <- recoverCompletedJournal repository state
              case recovered of
                Left response -> pure response
                Right current -> observeSettled operationId current
      ObserveAwsAdminProvisioningMetadata operationId ->
        withOperationRepository operationId $ \repository -> do
          observed <- observeAwsAdminAuthority repository
          pure $ case observed of
            Left cause -> responseForError cause
            Right state -> case observationFor operationId state of
              Left detail -> refused detail
              Right metadata -> AwsAdminProvisioningObserved metadata
      ObserveAwsAdminFirstReconcile -> do
        observed <- observeAwsAdminFirstReconcileContinuation targetLifecycle
        pure $ case observed of
          Left _ -> unavailable "first-reconcile-journal-unavailable"
          Right continuation ->
            AwsAdminFirstReconcileObserved (continuationProjection <$> continuation)
      ObserveAwsAdminFirstReconcileRecovery -> do
        observed <- observeAwsAdminFirstReconcileRecoveryPending targetLifecycle
        pure $
          either
            (const (unavailable "first-reconcile-recovery-unavailable"))
            AwsAdminFirstReconcileRecoveryObserved
            observed
      SettleAwsAdminFirstReconcileRecovery -> do
        confirmed <- confirmAwsAdminProviderCredentialServing providerCredential
        case confirmed of
          Left detail -> pure (unavailable ("first-reconcile-provider/" <> detail))
          Right () -> do
            settled <- settleAwsAdminFirstReconcileRecovery targetLifecycle
            pure $
              either
                (const (unavailable "first-reconcile-settlement-unavailable"))
                (const AwsAdminFirstReconcileRecoverySettled)
                settled
      ObserveAwsAdminProviderCredentialOperation -> do
        pending <- observePendingAwsAdminProviderCredential providerCredential
        pure $ case pending of
          Left detail -> unavailable ("provider-credential/pending/" <> detail)
          Right operation -> AwsAdminProviderCredentialOperationObserved operation
      ObserveAwsAdminProviderCredentialRecovery -> do
        observed <- observeAwsAdminProviderCredentialRecovery providerCredential
        pure $ case observed of
          Left detail -> unavailable ("provider-credential/recovery/" <> detail)
          Right view -> AwsAdminProviderCredentialRecoveryObserved view

    withIntentRepository intent action =
      withOperationRepository (operationIdForIntent intent) action

    prepareRequest draft repository = do
      current <- observeAwsAdminAuthority repository
      case current of
        Left err -> pure (responseForError err)
        Right state -> do
          recordAwsAdminPrepareAuthorityPhase targetLifecycle (prepareAuthorityPhase state)
          case state of
            AwsAdminAuthorityCompleted permit receipt -> completedPreparation draft permit receipt
            AwsAdminAuthorityCompletedWithLineage permit receipt _ -> completedPreparation draft permit receipt
            _ -> do
              transitionResult <- transitionForState state
              case transitionResult of
                Left response -> pure response
                Right transition -> prepareTargetAndState repository transition draft

    completedPreparation draft permit receipt
      | signedAwsAdminPermitIntent permit == draft =
          do
            settled <- ensureCompletedReceipt permit receipt
            pure $ case settled of
              Left detail -> unavailable ("provider-credential/settle/" <> detail)
              Right () -> AwsAdminProvisioningPrepared (challengeFor (signedAwsAdminPermitIntent permit))
      | otherwise = pure (refused "completed-operation-mismatch")

    transitionForState state = case state of
      AwsAdminAuthorityAttested retained binding -> do
        nowResult <- observeNow
        case nowResult of
          Left _ -> pure (Left (unavailable "authority-time-unavailable"))
          Right now
            | authorityTimeMicros now < authorityTimeMicros (awsAdminPermitIntentDeadline retained) ->
                pure (Right AwsAdminPreparationStandard)
            | otherwise -> do
                proof <- proveAwsAdminAttestedAttemptRecovery targetLifecycle now retained binding
                pure $ case proof of
                  Left cause -> Left (unavailable ("attempt-recovery/" <> renderAwsAdminAuthorizedRecoveryError cause))
                  Right evidence -> Right (AwsAdminPreparationAttestedRecovery evidence now retained)
      AwsAdminAuthorityPrepared retained -> do
        nowResult <- observeNow
        pure $ case nowResult of
          Left _ -> Left (unavailable "authority-time-unavailable")
          Right now
            | authorityTimeMicros (awsAdminPermitIntentDeadline retained)
                <= authorityTimeMicros now ->
                Right (AwsAdminPreparationPreparedRenewal now retained)
            | otherwise -> Right AwsAdminPreparationStandard
      AwsAdminAuthorityAuthorized permit -> do
        nowResult <- observeNow
        case nowResult of
          Left _ -> pure (Left (unavailable "authority-time-unavailable"))
          Right now
            | authorityTimeMicros now
                < authorityTimeMicros
                  (awsAdminPermitIntentDeadline (signedAwsAdminPermitIntent permit)) ->
                pure (Right AwsAdminPreparationStandard)
            | otherwise -> do
                proofResult <-
                  proveAwsAdminAuthorizedAttemptRecovery
                    targetLifecycle
                    now
                    permit
                pure $ case proofResult of
                  Left err ->
                    Left
                      ( unavailable
                          ( "attempt-recovery/"
                              <> renderAwsAdminAuthorizedRecoveryError err
                          )
                      )
                  Right proof ->
                    Right
                      ( AwsAdminPreparationAuthorizedRecovery
                          proof
                          now
                          (signedAwsAdminPermitIntent permit)
                      )
      _ -> pure (Right AwsAdminPreparationStandard)

    prepareAuthorityPhase state = case state of
      AwsAdminAuthorityVacant -> AwsAdminPrepareAuthorityVacant
      AwsAdminAuthorityPrepared _ -> AwsAdminPrepareAuthorityPrepared
      AwsAdminAuthorityAttested _ _ -> AwsAdminPrepareAuthorityAttested
      AwsAdminAuthorityAuthorized _ -> AwsAdminPrepareAuthorityAuthorized
      AwsAdminAuthorityCompleted _ _ -> AwsAdminPrepareAuthorityCompleted
      AwsAdminAuthorityCompletedWithLineage {} -> AwsAdminPrepareAuthorityCompleted

    prepareTargetAndState repository transition draft = do
      case intentForTransition transition draft of
        Left _ -> pure (unavailable "recovery-intent-rejected")
        Right transitionDraft -> do
          prepared <-
            prepareAndReadBackAwsAdminPreparedTarget
              targetLifecycle
              (outboxRenewal transition)
              transitionDraft
          case prepared of
            Left err ->
              pure
                ( unavailable
                    ( "prepared-target/"
                        <> renderAwsAdminPreparedTargetPrepareCause
                          (awsAdminPreparedTargetPrepareErrorCause err)
                    )
                )
            Right intent -> prepareOperationAndReserve repository transition intent

    prepareOperationAndReserve repository transition intent = do
      result <- case transition of
        AwsAdminPreparationStandard ->
          prepareAwsAdminAuthority repository targetBoundary intent
        AwsAdminPreparationPreparedRenewal now retained ->
          prepareAwsAdminAuthorityRenewal
            repository
            targetBoundary
            now
            retained
            intent
        AwsAdminPreparationAuthorizedRecovery proof _ _ ->
          prepareAwsAdminAuthorityAuthorizedRecovery
            repository
            targetBoundary
            proof
            intent
        AwsAdminPreparationAttestedRecovery proof _ _ ->
          prepareAwsAdminAuthorityAttestedRecovery repository targetBoundary proof intent
      case result of
        Left err -> pure (responseForError err)
        Right _ -> do
          -- Persist the canonical operation before the global fence. A crash
          -- after reservation can then discover and resume its exact intent.
          reserved <- reserveAwsAdminProviderCredential providerCredential intent
          pure $ case reserved of
            Left detail -> unavailable ("provider-credential/reserve/" <> detail)
            Right () -> AwsAdminProvisioningPrepared (challengeFor intent)

    intentForTransition transition draft = case transition of
      AwsAdminPreparationStandard -> Right draft
      AwsAdminPreparationPreparedRenewal _ retained ->
        bindAwsAdminPreparedRenewalIntent retained draft
      AwsAdminPreparationAuthorizedRecovery proof _ _ ->
        bindAwsAdminAuthorizedRecoveryIntent proof draft
      AwsAdminPreparationAttestedRecovery _ _ retained ->
        bindAwsAdminPreparedRenewalIntent retained draft

    completeProvisioning operationId permitBytes receiptBytes repository =
      case (decodeSignedAwsAdminPermit permitBytes, decodeAwsAdminWorkerReceipt receiptBytes) of
        (Right somePermit, Right receipt) ->
          withSomeSignedAwsAdminPermit somePermit $ \permit ->
            if operationIdForIntent (signedAwsAdminPermitIntent permit) /= operationId
              then pure (refused "operation-mismatch")
              else do
                recorded <- commitCompletionRecord repository permit receipt
                case recorded of
                  Left response -> pure response
                  Right _ -> do
                    settled <- settleAwsAdminProviderCredential providerCredential (signedAwsAdminPermitIntent permit)
                    pure $ case settled of
                      Left detail -> unavailable ("provider-credential/settle/" <> detail)
                      Right () -> AwsAdminProvisioningCompleted (encodeAwsAdminWorkerReceipt receipt)
        _ -> pure (refused "completion-codec-rejected")

    withOperationRepository operationId action = case resolveRepository operationId of
      Left _ -> pure (refused "operation-coordinate-rejected")
      Right repository -> action repository

    targetBoundary =
      AwsAdminPreparedTargetBoundary
        (reobserveRetainedAwsAdminPreparedTarget targetLifecycle)

    authorizeAndAdmit repository now = do
      result <- authorizeAwsAdminAuthority repository signer now
      case result of
        Left err -> pure (responseForError err)
        Right (_, permit) -> do
          admitted <- admitAwsAdminProviderPermit providerCredential permit
          pure $ case admitted of
            Left detail -> unavailable ("provider-credential/permit/" <> detail)
            Right () -> AwsAdminProvisioningAuthorized (encodeSignedAwsAdminPermit permit)

    settleCompletedState state = case state of
      AwsAdminAuthorityCompleted permit receipt -> ensureCompletedReceipt permit receipt
      AwsAdminAuthorityCompletedWithLineage permit receipt _ -> ensureCompletedReceipt permit receipt
      _ -> pure (Right ())

    ensureCompletedReceipt permit receipt = do
      journaled <- commitAwsAdminFirstReconcileReceipt targetLifecycle permit receipt
      case journaled of
        Left _ -> pure (Left "first-reconcile-journal-unavailable")
        Right () -> settleAwsAdminProviderCredential providerCredential (signedAwsAdminPermitIntent permit)

    observeSettled operationId state = do
      settled <- settleCompletedState state
      pure $ case settled of
        Left detail -> unavailable ("provider-credential/settle/" <> detail)
        Right () -> case observationFor operationId state of
          Left detail -> refused detail
          Right observed -> AwsAdminProvisioningObserved observed

    recoverCompletedJournal repository state = case state of
      AwsAdminAuthorityAuthorized permit -> do
        observed <- observeAwsAdminCompletedWorkerReceipt targetLifecycle permit
        case observed of
          Left detail -> pure (Left (unavailable ("worker-completion/" <> detail)))
          Right Nothing -> pure (Right state)
          Right (Just receipt) -> do
            recorded <- completeAwsAdminAuthority repository permit receipt
            pure (first responseForError recorded)
      _ -> pure (Right state)

    commitCompletionRecord repository permit receipt = do
      result <- completeAwsAdminAuthority repository permit receipt
      case result of
        Left cause -> pure (Left (responseForError cause))
        Right state -> do
          journaled <- commitAwsAdminFirstReconcileReceipt targetLifecycle permit receipt
          pure $ case journaled of
            Left _ -> Left (unavailable "first-reconcile-journal-unavailable")
            Right () -> Right state

outboxRenewal
  :: AwsAdminPreparationTransition
  -> Maybe (AuthorityTime, AwsAdminPermitIntent)
outboxRenewal transition = case transition of
  AwsAdminPreparationStandard -> Nothing
  AwsAdminPreparationPreparedRenewal now retained -> Just (now, retained)
  AwsAdminPreparationAuthorizedRecovery _ now retained -> Just (now, retained)
  AwsAdminPreparationAttestedRecovery _ now retained -> Just (now, retained)

renderAwsAdminAuthorizedRecoveryError
  :: AwsAdminAuthorizedRecoveryError -> Text
renderAwsAdminAuthorizedRecoveryError err = case err of
  AwsAdminAuthorizedRecoveryNotAuthorized -> "state-not-authorized"
  AwsAdminAuthorizedRecoveryNotAttested -> "state-not-attested"
  AwsAdminAuthorizedRecoveryDeadlineActive -> "deadline-active"
  AwsAdminAuthorizedRecoveryJobPresent -> "job-present"
  AwsAdminAuthorizedRecoveryJobUnobservable -> "job-unobservable"
  AwsAdminAuthorizedRecoveryPodPresent -> "pod-present"
  AwsAdminAuthorizedRecoveryPodUnobservable -> "pod-unobservable"
  AwsAdminAuthorizedRecoveryJournalPresent -> "journal-present"
  AwsAdminAuthorizedRecoveryJournalUnobservable -> "journal-unobservable"

intentForOperation
  :: Text
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityRepositoryError AwsAdminPermitIntent
intentForOperation operationId state = case awsAdminAuthorityCurrentIntent state of
  Just intent
    | operationIdForIntent intent == operationId -> Right intent
    | otherwise -> Left AwsAdminAuthorityRepositoryPermitMismatch
  Nothing ->
    Left
      ( AwsAdminAuthorityRepositoryStateRejected
          AwsAdminAuthorityTransitionRefused
      )

bindingFromObservation
  :: AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminPodObservation
  -> Either Text AwsAdminJobBinding
bindingFromObservation now intent observed = do
  let nowMicros = authorityTimeMicros now
      heartbeat = awsAdminObservedHeartbeatMicros observed
      deadline = authorityTimeMicros (awsAdminPermitIntentDeadline intent)
  if nowMicros >= deadline
    then Left "permit-deadline-expired"
    else
      if heartbeat > nowMicros || nowMicros - heartbeat > maximumHeartbeatAgeMicros
        then Left "pod-heartbeat-stale"
        else
          first
            (const "pod-attestation-rejected")
            ( mkAwsAdminJobBinding
                intent
                (awsAdminObservedJobName observed)
                (awsAdminObservedJobUid observed)
                (awsAdminObservedPodName observed)
                (awsAdminObservedPodUid observed)
                (awsAdminObservedImageDigest observed)
                (awsAdminObservedServiceAccount observed)
                (awsAdminObservedServiceAccountUid observed)
                (authorityTimeFromMicros heartbeat)
            )

observationFor
  :: Text
  -> AwsAdminAuthorityState
  -> Either Text AwsAdminProvisionerObservation
observationFor operationId state = case state of
  AwsAdminAuthorityVacant -> Left "operation-not-found"
  AwsAdminAuthorityPrepared intent -> observed intent AwsAdminProvisionerPrepared Nothing Nothing
  AwsAdminAuthorityAttested intent _ -> observed intent AwsAdminProvisionerAttested Nothing Nothing
  AwsAdminAuthorityAuthorized permit ->
    observed
      (signedAwsAdminPermitIntent permit)
      AwsAdminProvisionerAuthorized
      (Just (encodeSignedAwsAdminPermit permit))
      Nothing
  AwsAdminAuthorityCompleted permit receipt ->
    observed
      (signedAwsAdminPermitIntent permit)
      AwsAdminProvisionerCompleted
      (Just (encodeSignedAwsAdminPermit permit))
      (Just (encodeAwsAdminWorkerReceipt receipt))
  AwsAdminAuthorityCompletedWithLineage permit receipt _ ->
    observed
      (signedAwsAdminPermitIntent permit)
      AwsAdminProvisionerCompleted
      (Just (encodeSignedAwsAdminPermit permit))
      (Just (encodeAwsAdminWorkerReceipt receipt))
 where
  observed intent phase permit receipt
    | operationIdForIntent intent /= operationId = Left "operation-mismatch"
    | otherwise =
        Right
          AwsAdminProvisionerObservation
            { awsAdminObservedChallenge = challengeFor intent
            , awsAdminObservedPhase = phase
            , awsAdminObservedPermit = permit
            , awsAdminObservedReceipt = receipt
            }

challengeFor :: AwsAdminPermitIntent -> AwsAdminProvisionerChallenge
challengeFor intent =
  AwsAdminProvisionerChallenge
    { awsAdminChallengeOperationId = operationIdForIntent intent
    , awsAdminChallengePermitId =
        operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
    , awsAdminChallengeRequestDigest =
        targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
    , awsAdminChallengeGeneration =
        credentialGenerationValue (awsAdminPermitIntentGeneration intent)
    , awsAdminChallengeTarget =
        preparedCredentialTargetId (awsAdminPermitIntentPreparedTarget intent)
    , awsAdminChallengeJobName =
        awsAdminJobNameForPermit (awsAdminPermitIntentPermitId intent)
    , awsAdminChallengeImageDigest = awsAdminPermitIntentImageDigest intent
    , awsAdminChallengeServiceAccount = awsAdminWorkerServiceAccount
    , awsAdminChallengeAuthorityScope = awsAdminPermitIntentAuthorityScope intent
    , awsAdminChallengeAuthorityEndpoint = awsAdminPermitIntentAuthorityEndpoint intent
    , awsAdminChallengeDeadlineMicros =
        authorityTimeMicros (awsAdminPermitIntentDeadline intent)
    , awsAdminChallengeCanonicalIntent = encodeAwsAdminPermitIntent intent
    }

operationIdForIntent :: AwsAdminPermitIntent -> Text
operationIdForIntent =
  operatorMaterialOperationIdText . awsAdminPermitIntentOperationId

continuationProjection
  :: FirstReconcileContinuation -> AwsAdminFirstReconcileProjection
continuationProjection continuation =
  AwsAdminFirstReconcileProjection
    { awsAdminFirstReconcileClass = firstReconcileContinuationClass continuation
    , awsAdminFirstReconcileMemberIndex = firstReconcileContinuationMemberIndex continuation
    , awsAdminFirstReconcileMemberDigest = firstReconcileContinuationMemberDigest continuation
    , awsAdminFirstReconcileDeadlineMicros =
        authorityTimeMicros (firstReconcileContinuationDeadline continuation)
    }

callerAllowed :: VerifiedCallerSlot -> AwsAdminProvisionerRequest -> Bool
callerAllowed caller request = case request of
  CompleteAwsAdminProvisioning {} -> principal == CallerCredentialProvisionerCompletion
  _ -> principal == CallerOperatorCli || principal == CallerTestHarness
 where
  principal = verifiedCallerSlotPrincipal caller

responseForError :: AwsAdminAuthorityRepositoryError -> AwsAdminProvisionerResponse
responseForError err = case err of
  AwsAdminAuthorityRepositoryUnavailable _ -> unavailable "authority-unavailable"
  AwsAdminAuthorityPreparedTargetUnavailable _ -> unavailable "target-outbox-unavailable"
  AwsAdminAuthorityRepositoryCommitFailed _ -> unavailable "commit-readback-unavailable"
  AwsAdminAuthorityPreparedTargetMismatch -> refused "target-outbox-mismatch"
  AwsAdminAuthorityRepositoryStateRejected _ -> refused "state-transition-rejected"
  AwsAdminAuthorityRepositoryAuthorizationRejected _ -> refused "authorization-rejected"
  AwsAdminAuthorityRepositoryPermitMismatch -> refused "permit-mismatch"

maximumHeartbeatAgeMicros :: Natural
maximumHeartbeatAgeMicros = 30 * 1000000

refused :: Text -> AwsAdminProvisionerResponse
refused = AwsAdminProvisioningRefused

unavailable :: Text -> AwsAdminProvisionerResponse
unavailable = AwsAdminProvisioningUnavailable

responseStatus :: AwsAdminProvisionerResponse -> ReplyStatus
responseStatus response = case response of
  AwsAdminProvisioningPrepared _ -> ReplyOk
  AwsAdminProvisioningAttested _ -> ReplyOk
  AwsAdminProvisioningAuthorized _ -> ReplyOk
  AwsAdminProvisioningCompleted _ -> ReplyOk
  AwsAdminProvisioningObserved _ -> ReplyOk
  AwsAdminFirstReconcileObserved _ -> ReplyOk
  AwsAdminProvisioningRefused _ -> ReplyConflict
  AwsAdminProvisioningUnavailable _ -> ReplyServiceUnavailable
  AwsAdminProviderCredentialOperationObserved _ -> ReplyOk
  AwsAdminProviderCredentialRecoveryObserved _ -> ReplyOk
  AwsAdminFirstReconcileRecoveryObserved _ -> ReplyOk
  AwsAdminFirstReconcileRecoverySettled -> ReplyOk

responseBody :: AwsAdminProvisionerResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
