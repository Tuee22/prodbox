{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority endpoint for the external ACME EAB
-- ingress.  The request vocabulary is secret-free.  It commits the intent and
-- exact Job attestation before signing, commits the signed permit as a durable
-- outbox item before returning it, and completes only against an opaque
-- one-shot custody/target generation read-back receipt.
module Prodbox.ControlPlane.ExternalMaterialIngressEndpoint
  ( ExternalMaterialIngressAction (..)
  , ExternalMaterialIngressRequest (..)
  , ExternalMaterialPodObservation (..)
  , ExternalMaterialIngressChallenge (..)
  , ExternalMaterialIngressObservation (..)
  , ExternalMaterialIngressResponse (..)
  , ExternalMaterialIngressSnapshot (..)
  , ExternalMaterialIngressRepository (..)
  , ExternalMaterialIngressReceiptRecovery (..)
  , ExternalMaterialIngressReceiptRecoveryResult (..)
  , modelBExternalMaterialIngressRepository
  , externalMaterialIngressAuthenticatedHandler
  , externalMaterialIngressMaximumEncodedBytes
  , externalMaterialIngressResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
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
  ( ControlPlaneRoute (LifecycleExternalMaterialIngress)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressIntent
  , ExternalMaterialIngressPhase
    ( ExternalMaterialIngressIntentCommitted
    , ExternalMaterialIngressPermitCommitted
    )
  , ExternalMaterialIngressState
  , ExternalMaterialJobBinding
  , ExternalMaterialTargetReceipt
  , SignedExternalAcmeEabPermit
  , commitExternalMaterialIngressIntent
  , commitExternalMaterialIngressIntentRenewal
  , commitExternalMaterialJobBinding
  , commitExternalMaterialSignedPermit
  , commitExternalMaterialTargetReceipt
  , encodeSignedExternalAcmeEabPermit
  , externalMaterialIngressCurrentIntent
  , externalMaterialIngressCurrentPermit
  , externalMaterialIngressCurrentReceipt
  , externalMaterialIngressIntentDeadline
  , externalMaterialIngressIntentImageDigest
  , externalMaterialIngressIntentPermitId
  , externalMaterialIngressIntentRequest
  , externalMaterialIngressJobIntent
  , externalMaterialIngressPhase
  , externalMaterialPermitSigningPayload
  , initialExternalMaterialIngressState
  , mkExternalMaterialIngressIntent
  , mkExternalMaterialJobBinding
  , mkSignedExternalAcmeEabPermit
  , recoverExternalMaterialIngressAbsentEffect
  , signedExternalMaterialDeadline
  , verifySignedExternalAcmeEabPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( RawCredentialProvisionerPodObservation (..)
  , attestCredentialProvisionerPod
  , credentialProvisionerImageDigestText
  , credentialProvisionerIntentServiceAccount
  , credentialProvisionerJobName
  , credentialProvisionerServiceAccountText
  , mkCredentialProvisionerImageDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialAction (InstallOperatorMaterial, RotateOperatorMaterial)
  , OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  , mkExternalAcmeEabRequest
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermitId
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  , operatorMaterialRequestDigest
  , operatorMaterialRequestGeneration
  , operatorMaterialRequestOperationId
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyBytes)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

data ExternalMaterialIngressAction
  = ExternalMaterialInstall
  | ExternalMaterialRotate
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressRequest
  = PrepareExternalMaterialIngress
      { externalMaterialPrepareAction :: !ExternalMaterialIngressAction
      , externalMaterialPrepareOperationId :: !Text
      , externalMaterialPrepareGeneration :: !Natural
      , externalMaterialPrepareImageDigest :: !Text
      , externalMaterialPrepareDeadlineMicros :: !Natural
      }
  | AuthorizeExternalMaterialIngress
      { externalMaterialAuthorizeOperationId :: !Text
      , externalMaterialAuthorizePod :: !ExternalMaterialPodObservation
      }
  | CompleteExternalMaterialIngress
      { externalMaterialCompleteOperationId :: !Text
      , externalMaterialCompleteReceipt :: !ExternalMaterialTargetReceipt
      }
  | ObserveExternalMaterialIngress
      { externalMaterialObserveOperationId :: !Text
      }
  | ObserveCurrentExternalMaterialIngress
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialPodObservation = ExternalMaterialPodObservation
  { externalMaterialPodJobName :: !Text
  , externalMaterialPodJobUid :: !Text
  , externalMaterialPodUid :: !Text
  , externalMaterialPodImageDigest :: !Text
  , externalMaterialPodServiceAccount :: !Text
  , externalMaterialPodServiceAccountUid :: !Text
  , externalMaterialPodPermitId :: !Text
  , externalMaterialPodRequestDigest :: !Text
  , externalMaterialPodDeadlineMicros :: !Natural
  , externalMaterialPodHeartbeatMicros :: !Natural
  , externalMaterialPodPhase :: !Text
  , externalMaterialPodContainerReady :: !Bool
  , externalMaterialPodRestartCount :: !Natural
  , externalMaterialPodDeletionTimestamp :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressChallenge = ExternalMaterialIngressChallenge
  { externalMaterialChallengeOperationId :: !Text
  , externalMaterialChallengePermitId :: !Text
  , externalMaterialChallengeRequestDigest :: !Text
  , externalMaterialChallengeGeneration :: !Natural
  , externalMaterialChallengeJobName :: !Text
  , externalMaterialChallengeImageDigest :: !Text
  , externalMaterialChallengeServiceAccount :: !Text
  , externalMaterialChallengeDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressObservation = ExternalMaterialIngressObservation
  { externalMaterialObservedOperationId :: !Text
  , externalMaterialObservedPhase :: !ExternalMaterialIngressPhase
  , externalMaterialObservedChallenge :: !ExternalMaterialIngressChallenge
  , externalMaterialObservedPermit :: !(Maybe ByteString)
  , externalMaterialObservedReceipt :: !(Maybe ExternalMaterialTargetReceipt)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressResponse
  = ExternalMaterialIngressPrepared !ExternalMaterialIngressChallenge
  | ExternalMaterialIngressAuthorized !ByteString
  | ExternalMaterialIngressCompleted !ExternalMaterialTargetReceipt
  | ExternalMaterialIngressObserved !ExternalMaterialIngressObservation
  | ExternalMaterialIngressCurrentObserved !(Maybe ExternalMaterialIngressObservation)
  | ExternalMaterialIngressRecovered
      !ExternalMaterialIngressChallenge
      !ExternalMaterialTargetReceipt
  | ExternalMaterialIngressRefused !Text
  | ExternalMaterialIngressUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ExternalMaterialIngressSnapshot revision = ExternalMaterialIngressSnapshot
  { externalMaterialIngressRevision :: !revision
  , externalMaterialIngressSnapshotState :: !ExternalMaterialIngressState
  }
  deriving stock (Eq, Show)

data ExternalMaterialIngressRepository m revision = ExternalMaterialIngressRepository
  { readExternalMaterialIngress
      :: m (Either Text (ExternalMaterialIngressSnapshot revision))
  , compareAndSwapExternalMaterialIngress
      :: revision
      -> ExternalMaterialIngressState
      -> m (Either Text ())
  }

-- | Authority-owned, secret-free recovery of a retained-home custody receipt.
-- The implementation may observe only the permit-bound Target Agent source;
-- it cannot read custody plaintext or create another worker effect.
newtype ExternalMaterialIngressReceiptRecovery m
  = ExternalMaterialIngressReceiptRecovery
  { recoverExternalMaterialIngressReceipt
      :: AuthorityTime
      -> SignedExternalAcmeEabPermit
      -> m (Either Text ExternalMaterialIngressReceiptRecoveryResult)
  }

data ExternalMaterialIngressReceiptRecoveryResult
  = ExternalMaterialIngressReceiptRecovered !ExternalMaterialTargetReceipt
  | ExternalMaterialIngressSourcePositivelyAbsent
  deriving stock (Eq, Show)

data ExpiredPermitRecovery revision
  = ExpiredPermitRecoveryContinue !(ExternalMaterialIngressSnapshot revision)
  | ExpiredPermitRecoveryCompleted
      !ExternalMaterialIngressChallenge
      !ExternalMaterialTargetReceipt

modelBExternalMaterialIngressRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m ExternalMaterialIngressState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> ExternalMaterialIngressRepository m (Maybe ModelBObjectVersion)
modelBExternalMaterialIngressRepository adapter coordinate =
  ExternalMaterialIngressRepository
    { readExternalMaterialIngress = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing ->
            Right
              ExternalMaterialIngressSnapshot
                { externalMaterialIngressRevision = Nothing
                , externalMaterialIngressSnapshotState =
                    initialExternalMaterialIngressState
                }
          ModelBObserved revision state ->
            Right
              ExternalMaterialIngressSnapshot
                { externalMaterialIngressRevision = Just revision
                , externalMaterialIngressSnapshotState = state
                }
          ModelBCorrupt detail ->
            Left ("external material ingress is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("external material ingress is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("external material ingress is unobservable: " <> detail)
    , compareAndSwapExternalMaterialIngress = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "external material ingress CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("external material ingress CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("external material ingress CAS is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("external material ingress CAS is unobservable: " <> detail)
    }

externalMaterialIngressMaximumEncodedBytes :: Int
externalMaterialIngressMaximumEncodedBytes = 256 * 1024

externalMaterialIngressResponseMaximumBytes :: Int
externalMaterialIngressResponseMaximumBytes = 64 * 1024

externalMaterialIngressAuthenticatedHandler
  :: (Monad m)
  => Int
  -> Natural
  -> m (Either Text AuthorityTime)
  -> RoleReadinessSource
  -> ExternalMaterialIngressRepository m revision
  -> ExternalMaterialIngressReceiptRecovery m
  -> AuthorityManifestSigner m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
externalMaterialIngressAuthenticatedHandler
  maximumBytes
  casAttempts
  observeNow
  readiness
  repository
  receiptRecovery
  signer
  fallback =
    AuthenticatedRoleHandler
      { authenticatedHandlerReadiness =
          layerRoleReadinessSource readiness (authenticatedHandlerReadiness fallback)
      , authenticatedHandlerHandle = handle
      }
   where
    handle caller route body = case route of
      LifecycleExternalMaterialIngress -> Just <$> serve caller body
      _ -> authenticatedHandlerHandle fallback caller route body

    serve caller body
      | not (externalCallerAllowed caller) =
          pure (ReplyForbidden, responseBody (ExternalMaterialIngressRefused "caller-refused"))
      | otherwise = case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
          Left _ ->
            pure (ReplyBadRequest, responseBody (ExternalMaterialIngressRefused "request-codec-rejected"))
          Right request -> do
            response <- runRequest request
            pure (responseStatus response, responseBody response)

    runRequest request = case request of
      PrepareExternalMaterialIngress action operationId generation image deadline ->
        case buildIntent action operationId generation image deadline of
          Left detail -> pure (ExternalMaterialIngressRefused detail)
          Right intent -> commitIntentWithReadBack casAttempts intent
      AuthorizeExternalMaterialIngress operationId observed -> do
        nowResult <- observeNow
        case nowResult of
          Left detail -> pure (ExternalMaterialIngressUnavailable detail)
          Right now -> authorizeWithReadBack casAttempts now operationId observed
      CompleteExternalMaterialIngress operationId receipt ->
        completeWithReadBack casAttempts operationId receipt
      ObserveExternalMaterialIngress operationId ->
        observeForOperation operationId
      ObserveCurrentExternalMaterialIngress -> observeCurrent

    commitIntentWithReadBack remaining intent
      | remaining == 0 = pure attemptsExhausted
      | otherwise = do
          observed <- readExternalMaterialIngress repository
          case observed of
            Left detail -> pure (ExternalMaterialIngressUnavailable detail)
            Right snapshot -> do
              recovery <- recoverExpiredPermittedReceipt remaining snapshot intent
              case recovery of
                Left response -> pure response
                Right (ExpiredPermitRecoveryCompleted challenge receipt) ->
                  pure (ExternalMaterialIngressRecovered challenge receipt)
                Right (ExpiredPermitRecoveryContinue recoveredSnapshot) -> do
                  transition <- intentTransition recoveredSnapshot intent
                  case transition of
                    Left response -> pure response
                    Right next
                      | next == externalMaterialIngressSnapshotState recoveredSnapshot ->
                          pure (ExternalMaterialIngressPrepared (challengeFor intent))
                      | otherwise -> do
                          attempted <-
                            compareAndSwapExternalMaterialIngress
                              repository
                              (externalMaterialIngressRevision recoveredSnapshot)
                              next
                          confirmed <- readExternalMaterialIngress repository
                          case confirmed of
                            Right readBack
                              | externalMaterialIngressSnapshotState readBack == next ->
                                  pure (ExternalMaterialIngressPrepared (challengeFor intent))
                            _ -> case attempted of
                              Left _ -> commitIntentWithReadBack (remaining - 1) intent
                              Right () ->
                                pure
                                  ( ExternalMaterialIngressUnavailable
                                      "intent write was not confirmed by read-back"
                                  )

    recoverExpiredPermittedReceipt remaining snapshot intent
      | externalMaterialIngressPhase state /= ExternalMaterialIngressPermitCommitted =
          pure (Right (ExpiredPermitRecoveryContinue snapshot))
      | otherwise = case externalMaterialIngressCurrentPermit state of
          Nothing ->
            pure
              ( Left
                  (ExternalMaterialIngressRefused "permit-committed-state-has-no-permit")
              )
          Just permit -> do
            nowResult <- observeNow
            case nowResult of
              Left detail -> pure (Left (ExternalMaterialIngressUnavailable detail))
              Right now
                | authorityTimeMicros now
                    < authorityTimeMicros (signedExternalMaterialDeadline permit) ->
                    pure (Right (ExpiredPermitRecoveryContinue snapshot))
                | Just retained <- externalMaterialIngressCurrentIntent state
                , not (expiredRecoveryRequestMatches now retained intent) ->
                    pure (Right (ExpiredPermitRecoveryContinue snapshot))
                | otherwise -> do
                    recovered <-
                      recoverExternalMaterialIngressReceipt receiptRecovery now permit
                    case recovered of
                      Left detail ->
                        pure
                          ( Left
                              ( ExternalMaterialIngressUnavailable
                                  ("retained-receipt-recovery/" <> Text.take 192 detail)
                              )
                          )
                      Right recoveryResult -> case recoveryResult of
                        ExternalMaterialIngressReceiptRecovered receipt ->
                          commitRecoveredEffect
                            remaining
                            snapshot
                            intent
                            permit
                            receipt
                        ExternalMaterialIngressSourcePositivelyAbsent ->
                          commitAbsentEffectRetry remaining snapshot intent now
     where
      state = externalMaterialIngressSnapshotState snapshot

    commitRecoveredEffect remaining snapshot intent permit receipt =
      case commitExternalMaterialTargetReceipt
        permit
        receipt
        (externalMaterialIngressSnapshotState snapshot) of
        Left err ->
          pure (Left (ExternalMaterialIngressRefused (Text.pack (show err))))
        Right next ->
          commitRecoveryState
            remaining
            snapshot
            intent
            next
            ( ExpiredPermitRecoveryCompleted
                ( maybe
                    (challengeFor intent)
                    challengeFor
                    ( externalMaterialIngressCurrentIntent
                        (externalMaterialIngressSnapshotState snapshot)
                    )
                )
                receipt
            )

    commitAbsentEffectRetry remaining snapshot intent now =
      case recoverExternalMaterialIngressAbsentEffect
        now
        intent
        (externalMaterialIngressSnapshotState snapshot) of
        Left err ->
          pure (Left (ExternalMaterialIngressRefused (Text.pack (show err))))
        Right next ->
          commitRecoveryState
            remaining
            snapshot
            intent
            next
            (ExpiredPermitRecoveryContinue snapshot)

    commitRecoveryState remaining snapshot intent next success = do
      attempted <-
        compareAndSwapExternalMaterialIngress
          repository
          (externalMaterialIngressRevision snapshot)
          next
      confirmed <- readExternalMaterialIngress repository
      case confirmed of
        Right readBack
          | externalMaterialIngressSnapshotState readBack == next ->
              pure
                ( Right
                    ( case success of
                        ExpiredPermitRecoveryContinue _ ->
                          ExpiredPermitRecoveryContinue readBack
                        ExpiredPermitRecoveryCompleted challenge receipt ->
                          ExpiredPermitRecoveryCompleted challenge receipt
                    )
                )
        _ -> case attempted of
          Left _
            | remaining > 1 -> do
                retry <- readExternalMaterialIngress repository
                case retry of
                  Left detail ->
                    pure (Left (ExternalMaterialIngressUnavailable detail))
                  Right retrySnapshot -> case completedRecoveryForRequest retrySnapshot intent of
                    Just completed -> pure (Right completed)
                    Nothing ->
                      recoverExpiredPermittedReceipt
                        (remaining - 1)
                        retrySnapshot
                        intent
          Left _ -> pure (Left attemptsExhausted)
          Right () ->
            pure
              ( Left
                  ( ExternalMaterialIngressUnavailable
                      "recovered effect write was not confirmed by read-back"
                  )
              )

    expiredRecoveryRequestMatches now retained replacement =
      externalMaterialIngressIntentRequest retained
        == externalMaterialIngressIntentRequest replacement
        && externalMaterialIngressIntentPermitId retained
          == externalMaterialIngressIntentPermitId replacement
        && authorityTimeMicros (externalMaterialIngressIntentDeadline retained)
          <= authorityTimeMicros now
        && authorityTimeMicros now
          < authorityTimeMicros (externalMaterialIngressIntentDeadline replacement)
        && authorityTimeMicros (externalMaterialIngressIntentDeadline retained)
          < authorityTimeMicros (externalMaterialIngressIntentDeadline replacement)

    completedRecoveryForRequest snapshot replacement = do
      retained <-
        externalMaterialIngressCurrentIntent
          (externalMaterialIngressSnapshotState snapshot)
      receipt <-
        externalMaterialIngressCurrentReceipt
          (externalMaterialIngressSnapshotState snapshot)
      if externalMaterialIngressIntentRequest retained
        == externalMaterialIngressIntentRequest replacement
        && externalMaterialIngressIntentPermitId retained
          == externalMaterialIngressIntentPermitId replacement
        then Just (ExpiredPermitRecoveryCompleted (challengeFor retained) receipt)
        else Nothing

    intentTransition snapshot intent =
      case commitExternalMaterialIngressIntent
        intent
        (externalMaterialIngressSnapshotState snapshot) of
        Right next -> pure (Right next)
        Left _
          | externalMaterialIngressPhase (externalMaterialIngressSnapshotState snapshot)
              == ExternalMaterialIngressIntentCommitted
          , Just retained <-
              externalMaterialIngressCurrentIntent
                (externalMaterialIngressSnapshotState snapshot) -> do
              nowResult <- observeNow
              pure $ case nowResult of
                Left detail -> Left (ExternalMaterialIngressUnavailable detail)
                Right now ->
                  first
                    (ExternalMaterialIngressRefused . Text.pack . show)
                    ( commitExternalMaterialIngressIntentRenewal
                        now
                        retained
                        intent
                        (externalMaterialIngressSnapshotState snapshot)
                    )
        Left original ->
          pure (Left (ExternalMaterialIngressRefused (Text.pack (show original))))

    authorizeWithReadBack remaining now operationId observed
      | remaining == 0 = pure attemptsExhausted
      | otherwise = do
          snapshotResult <- readExternalMaterialIngress repository
          case snapshotResult of
            Left detail -> pure (ExternalMaterialIngressUnavailable detail)
            Right snapshot -> case matchingIntent operationId snapshot of
              Left detail -> pure (ExternalMaterialIngressRefused detail)
              Right intent -> case attestObservedPod now intent observed of
                Left detail -> pure (ExternalMaterialIngressRefused detail)
                Right binding -> do
                  attested <- ensureAttestation remaining snapshot intent binding
                  case attested of
                    Left response -> pure response
                    Right confirmed -> case externalMaterialIngressCurrentPermit
                      (externalMaterialIngressSnapshotState confirmed) of
                      Just permit ->
                        pure
                          ( ExternalMaterialIngressAuthorized
                              (encodeSignedExternalAcmeEabPermit permit)
                          )
                      Nothing -> signCommitAndReadBack remaining now confirmed intent binding

    ensureAttestation remaining snapshot intent binding =
      case commitExternalMaterialJobBinding
        intent
        binding
        (externalMaterialIngressSnapshotState snapshot) of
        Left err -> pure (Left (ExternalMaterialIngressRefused (Text.pack (show err))))
        Right next
          | next == externalMaterialIngressSnapshotState snapshot -> pure (Right snapshot)
          | otherwise -> do
              attempted <-
                compareAndSwapExternalMaterialIngress
                  repository
                  (externalMaterialIngressRevision snapshot)
                  next
              confirmed <- readExternalMaterialIngress repository
              case confirmed of
                Right readBack
                  | externalMaterialIngressSnapshotState readBack == next ->
                      pure (Right readBack)
                _ -> case attempted of
                  Left _ -> do
                    retry <- readExternalMaterialIngress repository
                    case retry of
                      Left detail -> pure (Left (ExternalMaterialIngressUnavailable detail))
                      Right retrySnapshot
                        | remaining > 1 -> ensureAttestation (remaining - 1) retrySnapshot intent binding
                      Right _ -> pure (Left attemptsExhausted)
                  Right () ->
                    pure
                      ( Left
                          ( ExternalMaterialIngressUnavailable
                              "attestation write was not confirmed by read-back"
                          )
                      )

    signCommitAndReadBack remaining now snapshot intent binding = do
      publicResult <- readAuthorityManifestPublicKey signer
      case publicResult of
        Left detail -> pure (ExternalMaterialIngressUnavailable detail)
        Right (publicGeneration, publicKey) -> do
          signedResult <-
            signAuthorityManifestPayload
              signer
              (externalMaterialPermitSigningPayload intent binding)
          case signedResult of
            Left detail -> pure (ExternalMaterialIngressUnavailable detail)
            Right (signatureGeneration, signature)
              | signatureGeneration /= publicGeneration ->
                  pure (ExternalMaterialIngressRefused "authority-signing-key-rotated")
              | otherwise -> case mkSignedExternalAcmeEabPermit intent binding signature of
                  Left err -> pure (ExternalMaterialIngressRefused (Text.pack (show err)))
                  Right permit -> case verifySignedExternalAcmeEabPermit
                    (manifestPublicKeyBytes publicKey)
                    now
                    permit of
                    Left err -> pure (ExternalMaterialIngressRefused (Text.pack (show err)))
                    Right () -> commitPermit remaining now snapshot intent binding permit

    commitPermit remaining now snapshot intent binding permit =
      case commitExternalMaterialSignedPermit
        intent
        binding
        permit
        (externalMaterialIngressSnapshotState snapshot) of
        Left err -> pure (ExternalMaterialIngressRefused (Text.pack (show err)))
        Right next -> do
          attempted <-
            compareAndSwapExternalMaterialIngress
              repository
              (externalMaterialIngressRevision snapshot)
              next
          confirmed <- readExternalMaterialIngress repository
          case confirmed of
            Right readBack
              | externalMaterialIngressSnapshotState readBack == next ->
                  pure
                    ( ExternalMaterialIngressAuthorized
                        (encodeSignedExternalAcmeEabPermit permit)
                    )
            _ -> case attempted of
              Left _
                | remaining > 1 -> do
                    retry <- readExternalMaterialIngress repository
                    case retry of
                      Left detail -> pure (ExternalMaterialIngressUnavailable detail)
                      Right retrySnapshot -> case externalMaterialIngressCurrentPermit
                        (externalMaterialIngressSnapshotState retrySnapshot) of
                        Just existing
                          | existing == permit ->
                              pure
                                ( ExternalMaterialIngressAuthorized
                                    (encodeSignedExternalAcmeEabPermit existing)
                                )
                        _ ->
                          signCommitAndReadBack
                            (remaining - 1)
                            now
                            retrySnapshot
                            intent
                            binding
              Left _ -> pure attemptsExhausted
              Right () ->
                pure
                  ( ExternalMaterialIngressUnavailable
                      "permit outbox write was not confirmed by read-back"
                  )

    completeWithReadBack remaining operationId receipt
      | remaining == 0 = pure attemptsExhausted
      | otherwise = do
          snapshotResult <- readExternalMaterialIngress repository
          case snapshotResult of
            Left detail -> pure (ExternalMaterialIngressUnavailable detail)
            Right snapshot -> case matchingIntent operationId snapshot of
              Left detail -> pure (ExternalMaterialIngressRefused detail)
              Right _ -> case externalMaterialIngressCurrentPermit
                (externalMaterialIngressSnapshotState snapshot) of
                Nothing -> pure (ExternalMaterialIngressRefused "permit-not-committed")
                Just permit -> case commitExternalMaterialTargetReceipt
                  permit
                  receipt
                  (externalMaterialIngressSnapshotState snapshot) of
                  Left err -> pure (ExternalMaterialIngressRefused (Text.pack (show err)))
                  Right next
                    | next == externalMaterialIngressSnapshotState snapshot ->
                        pure (ExternalMaterialIngressCompleted receipt)
                    | otherwise -> do
                        attempted <-
                          compareAndSwapExternalMaterialIngress
                            repository
                            (externalMaterialIngressRevision snapshot)
                            next
                        confirmed <- readExternalMaterialIngress repository
                        case confirmed of
                          Right readBack
                            | externalMaterialIngressSnapshotState readBack == next ->
                                pure (ExternalMaterialIngressCompleted receipt)
                          _ -> case attempted of
                            Left _ ->
                              completeWithReadBack (remaining - 1) operationId receipt
                            Right () ->
                              pure
                                ( ExternalMaterialIngressUnavailable
                                    "receipt write was not confirmed by read-back"
                                )

    observeForOperation operationId = do
      observed <- readExternalMaterialIngress repository
      pure $ case observed of
        Left detail -> ExternalMaterialIngressUnavailable detail
        Right snapshot -> case matchingIntent operationId snapshot of
          Left detail -> ExternalMaterialIngressRefused detail
          Right intent -> ExternalMaterialIngressObserved (observationFor snapshot intent)

    observeCurrent = do
      observed <- readExternalMaterialIngress repository
      pure $ case observed of
        Left detail -> ExternalMaterialIngressUnavailable detail
        Right snapshot ->
          ExternalMaterialIngressCurrentObserved
            ( observationFor snapshot
                <$> externalMaterialIngressCurrentIntent
                  (externalMaterialIngressSnapshotState snapshot)
            )

    observationFor snapshot intent =
      ExternalMaterialIngressObservation
        { externalMaterialObservedOperationId = operationIdForIntent intent
        , externalMaterialObservedPhase =
            externalMaterialIngressPhase
              (externalMaterialIngressSnapshotState snapshot)
        , externalMaterialObservedChallenge = challengeFor intent
        , externalMaterialObservedPermit =
            encodeSignedExternalAcmeEabPermit
              <$> externalMaterialIngressCurrentPermit
                (externalMaterialIngressSnapshotState snapshot)
        , externalMaterialObservedReceipt =
            externalMaterialIngressCurrentReceipt
              (externalMaterialIngressSnapshotState snapshot)
        }

    matchingIntent operationId snapshot = case externalMaterialIngressCurrentIntent
      (externalMaterialIngressSnapshotState snapshot) of
      Nothing -> Left "external-material-intent-not-found"
      Just intent
        | operationIdForIntent intent == operationId -> Right intent
        | otherwise -> Left "external-material-operation-mismatch"

    attemptsExhausted =
      ExternalMaterialIngressUnavailable "external-material-ingress-CAS-attempts-exhausted"

buildIntent
  :: ExternalMaterialIngressAction
  -> Text
  -> Natural
  -> Text
  -> Natural
  -> Either Text ExternalMaterialIngressIntent
buildIntent action rawOperationId rawGeneration rawImage rawDeadline = do
  operationId <- first (Text.pack . show) (mkOperatorMaterialOperationId rawOperationId)
  generation <- first (Text.pack . show) (mkCredentialGeneration rawGeneration)
  image <- first (Text.pack . show) (mkCredentialProvisionerImageDigest rawImage)
  let request =
        mkExternalAcmeEabRequest
          ( case action of
              ExternalMaterialInstall -> InstallOperatorMaterial
              ExternalMaterialRotate -> RotateOperatorMaterial
          )
          operationId
          generation
      permitText = "eab-" <> Text.take 64 (targetValueDigestText (operatorMaterialRequestDigest request))
  permitId <- first (Text.pack . show) (mkOperatorMaterialPermitId permitText)
  first
    (Text.pack . show)
    ( mkExternalMaterialIngressIntent
        ( case action of
            ExternalMaterialInstall -> InstallOperatorMaterial
            ExternalMaterialRotate -> RotateOperatorMaterial
        )
        operationId
        generation
        permitId
        image
        (authorityTimeFromMicros rawDeadline)
    )

challengeFor :: ExternalMaterialIngressIntent -> ExternalMaterialIngressChallenge
challengeFor intent =
  ExternalMaterialIngressChallenge
    { externalMaterialChallengeOperationId = operationIdForIntent intent
    , externalMaterialChallengePermitId =
        operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
    , externalMaterialChallengeRequestDigest =
        targetValueDigestText
          (operatorMaterialRequestDigest (externalMaterialIngressIntentRequest intent))
    , externalMaterialChallengeGeneration =
        credentialGenerationValue
          (operatorMaterialRequestGeneration (externalMaterialIngressIntentRequest intent))
    , externalMaterialChallengeJobName = credentialProvisionerJobName jobIntent
    , externalMaterialChallengeImageDigest =
        credentialProvisionerImageDigestText
          (externalMaterialIngressIntentImageDigest intent)
    , externalMaterialChallengeServiceAccount =
        credentialProvisionerServiceAccountText
          (credentialProvisionerIntentServiceAccount jobIntent)
    , externalMaterialChallengeDeadlineMicros =
        authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    }
 where
  jobIntent = externalMaterialIngressJobIntent intent

attestObservedPod
  :: AuthorityTime
  -> ExternalMaterialIngressIntent
  -> ExternalMaterialPodObservation
  -> Either Text ExternalMaterialJobBinding
attestObservedPod now intent observed = do
  requestDigest <-
    first
      (const "Pod request digest is invalid")
      (mkTargetValueDigest (externalMaterialPodRequestDigest observed))
  let raw =
        RawCredentialProvisionerPodObservation
          { rawCredentialProvisionerJobName = externalMaterialPodJobName observed
          , rawCredentialProvisionerJobUid = externalMaterialPodJobUid observed
          , rawCredentialProvisionerPodUid = externalMaterialPodUid observed
          , rawCredentialProvisionerImageDigest = externalMaterialPodImageDigest observed
          , rawCredentialProvisionerServiceAccount = externalMaterialPodServiceAccount observed
          , rawCredentialProvisionerServiceAccountUid =
              externalMaterialPodServiceAccountUid observed
          , rawCredentialProvisionerSchema = ExternalAcmeEabIngress
          , rawCredentialProvisionerPermitId = externalMaterialPodPermitId observed
          , rawCredentialProvisionerRequestDigest = requestDigest
          , rawCredentialProvisionerPlanBinding = Nothing
          , rawCredentialProvisionerDeadline =
              authorityTimeFromMicros (externalMaterialPodDeadlineMicros observed)
          , rawCredentialProvisionerHeartbeat =
              authorityTimeFromMicros (externalMaterialPodHeartbeatMicros observed)
          , rawCredentialProvisionerPhase = externalMaterialPodPhase observed
          , rawCredentialProvisionerContainerReady =
              externalMaterialPodContainerReady observed
          , rawCredentialProvisionerRestartCount =
              externalMaterialPodRestartCount observed
          , rawCredentialProvisionerDeletionTimestamp =
              externalMaterialPodDeletionTimestamp observed
          }
  _ <-
    first
      (Text.pack . show)
      (attestCredentialProvisionerPod now maximumHeartbeatAge jobIntent raw)
  first
    (Text.pack . show)
    ( mkExternalMaterialJobBinding
        (externalMaterialPodJobName observed)
        (externalMaterialPodJobUid observed)
        (externalMaterialPodUid observed)
        (externalMaterialPodImageDigest observed)
        (externalMaterialPodServiceAccount observed)
        (externalMaterialPodServiceAccountUid observed)
        (externalMaterialPodHeartbeatMicros observed)
    )
 where
  jobIntent = externalMaterialIngressJobIntent intent

maximumHeartbeatAge :: Natural
maximumHeartbeatAge = 30 * 1000000

operationIdForIntent :: ExternalMaterialIngressIntent -> Text
operationIdForIntent =
  operatorMaterialOperationIdText
    . operatorMaterialRequestOperationId
    . externalMaterialIngressIntentRequest

externalCallerAllowed :: VerifiedCallerSlot -> Bool
externalCallerAllowed caller = case verifiedCallerSlotPrincipal caller of
  CallerOperatorCli -> True
  CallerTestHarness -> True
  _ -> False

responseStatus :: ExternalMaterialIngressResponse -> ReplyStatus
responseStatus response = case response of
  ExternalMaterialIngressPrepared _ -> ReplyOk
  ExternalMaterialIngressAuthorized _ -> ReplyOk
  ExternalMaterialIngressCompleted _ -> ReplyOk
  ExternalMaterialIngressObserved _ -> ReplyOk
  ExternalMaterialIngressCurrentObserved _ -> ReplyOk
  ExternalMaterialIngressRecovered _ _ -> ReplyOk
  ExternalMaterialIngressRefused _ -> ReplyConflict
  ExternalMaterialIngressUnavailable _ -> ReplyServiceUnavailable

responseBody :: ExternalMaterialIngressResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
