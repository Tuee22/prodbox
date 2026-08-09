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
  ( AwsAdminPreparedTargetLifecycle (..)
  , FirstReconcileContinuation (..)
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
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAuthorityRepository
  , AwsAdminAuthorityRepositoryError (..)
  , AwsAdminAuthorityState (..)
  , AwsAdminAuthorityStateError (AwsAdminAuthorityTransitionRefused)
  , AwsAdminPreparedTargetBoundary (..)
  , attestAwsAdminAuthority
  , authorizeAwsAdminAuthority
  , awsAdminAuthorityCurrentIntent
  , completeAwsAdminAuthority
  , observeAwsAdminAuthority
  , prepareAwsAdminAuthority
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( decodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitIntent
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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

type AwsAdminAuthorityRepositoryResolver m revision =
  Text -> Either Text (AwsAdminAuthorityRepository m revision)

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
  -> AuthorityManifestSigner m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
awsAdminProvisionerAuthenticatedHandler
  maximumBytes
  readiness
  observeNow
  resolveRepository
  targetLifecycle
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
      Left _ -> pure (400, responseBody (refused "request-codec-rejected"))
      Right request
        | not (callerAllowed caller request) ->
            pure (403, responseBody (refused "caller-refused"))
        | otherwise -> do
            response <- runRequest request
            pure (responseStatus response, responseBody response)

    runRequest request = case request of
      PrepareAwsAdminProvisioning intentBytes ->
        case decodeAwsAdminPermitIntent intentBytes of
          Left _ -> pure (refused "intent-codec-rejected")
          Right draft -> do
            prepared <- prepareAndReadBackAwsAdminPreparedTarget targetLifecycle draft
            case prepared of
              Left _ -> pure (unavailable "target-outbox-unavailable")
              Right intent -> withIntentRepository intent $ \repository -> do
                result <- prepareAwsAdminAuthority repository targetBoundary intent
                pure $ case result of
                  Left err -> responseForError err
                  Right _ -> AwsAdminProvisioningPrepared (challengeFor intent)
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
            Right _ -> do
              -- Read immediately before Transit signing. The value is never
              -- captured across Job polling and cannot extend the deadline.
              nowResult <- observeNow
              case nowResult of
                Left _ -> pure (unavailable "authority-time-unavailable")
                Right now -> do
                  result <- authorizeAwsAdminAuthority repository signer now
                  pure $ case result of
                    Left err -> responseForError err
                    Right (_, permit) ->
                      AwsAdminProvisioningAuthorized
                        (encodeSignedAwsAdminPermit permit)
      CompleteAwsAdminProvisioning operationId permitBytes receiptBytes ->
        withOperationRepository
          operationId
          (completeProvisioning operationId permitBytes receiptBytes)
      ObserveAwsAdminProvisioning operationId ->
        withOperationRepository operationId $ \repository -> do
          result <- observeAwsAdminAuthority repository
          pure $ case result of
            Left err -> responseForError err
            Right state -> case observationFor operationId state of
              Left detail -> refused detail
              Right observed -> AwsAdminProvisioningObserved observed
      ObserveAwsAdminFirstReconcile -> do
        observed <- observeAwsAdminFirstReconcileContinuation targetLifecycle
        pure $ case observed of
          Left _ -> unavailable "first-reconcile-journal-unavailable"
          Right continuation ->
            AwsAdminFirstReconcileObserved (continuationProjection <$> continuation)

    withIntentRepository intent action =
      withOperationRepository (operationIdForIntent intent) action

    completeProvisioning operationId permitBytes receiptBytes repository =
      case (decodeSignedAwsAdminPermit permitBytes, decodeAwsAdminWorkerReceipt receiptBytes) of
        (Right somePermit, Right receipt) ->
          withSomeSignedAwsAdminPermit somePermit $ \permit ->
            if operationIdForIntent (signedAwsAdminPermitIntent permit) /= operationId
              then pure (refused "operation-mismatch")
              else do
                result <- completeAwsAdminAuthority repository permit receipt
                case result of
                  Left err -> pure (responseForError err)
                  Right _ -> do
                    journaled <-
                      commitAwsAdminFirstReconcileReceipt
                        targetLifecycle
                        permit
                        receipt
                    pure $ case journaled of
                      Left _ -> unavailable "first-reconcile-journal-unavailable"
                      Right () ->
                        AwsAdminProvisioningCompleted
                          (encodeAwsAdminWorkerReceipt receipt)
        _ -> pure (refused "completion-codec-rejected")

    withOperationRepository operationId action = case resolveRepository operationId of
      Left _ -> pure (refused "operation-coordinate-rejected")
      Right repository -> action repository

    targetBoundary =
      AwsAdminPreparedTargetBoundary
        (reobserveRetainedAwsAdminPreparedTarget targetLifecycle)

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
  CompleteAwsAdminProvisioning {} -> principal == CallerCredentialProvisioner
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

responseStatus :: AwsAdminProvisionerResponse -> Int
responseStatus response = case response of
  AwsAdminProvisioningPrepared _ -> 200
  AwsAdminProvisioningAttested _ -> 200
  AwsAdminProvisioningAuthorized _ -> 200
  AwsAdminProvisioningCompleted _ -> 200
  AwsAdminProvisioningObserved _ -> 200
  AwsAdminFirstReconcileObserved _ -> 200
  AwsAdminProvisioningRefused _ -> 409
  AwsAdminProvisioningUnavailable _ -> 503

responseBody :: AwsAdminProvisionerResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
