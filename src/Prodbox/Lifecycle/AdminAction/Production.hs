{-# LANGUAGE OverloadedStrings #-}

-- | Production-only composition of the three closed Admin Action interpreters.
-- Elevated AWS bytes remain in the one-shot process; standing services receive
-- only the signed permit and authenticated exact-plan requests.
module Prodbox.Lifecycle.AdminAction.Production
  ( loadProductionAdminActionInterpreters
  )
where

import Control.Monad qualified
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Aws.CredentialHandle
  ( mkBaseCredentialHandle
  )
import Prodbox.Aws.Native.ServiceQuotas
  ( QuotaIncreaseRequest (..)
  , RequestStatus (..)
  , RequestedQuotaChange (..)
  , RequestedQuotaChangeHistoryItem (..)
  , ServiceQuotaValue (..)
  , ServiceQuotasClient (..)
  , newServiceQuotasClient
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (AwsAmbiguousOutcome)
  , httpSend
  )
import Prodbox.ControlPlane.AdminActionAuthorityExecutionClient
  ( callAdvanceAdminQuotaJournal
  , callConfirmAdminLegacySourceAbsent
  , callObserveAdminLegacyMigration
  , callObserveAdminQuotaJournal
  , callPublishAdminLegacyMigration
  , callRecordAdminQuotaProviderResponse
  )
import Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityResponse (..)
  )
import Prodbox.ControlPlane.AdminActionTargetClient
  ( callAdminCustodyTombstone
  , callAdminTargetGenerationTombstone
  )
import Prodbox.ControlPlane.AdminActionTargetEndpoint
  ( AdminCustodyTombstoneResponse (..)
  , AdminTargetTombstoneResponse (..)
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders
  , AuthenticatedTransportBounds
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerAdminActionRunner)
  )
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.RetainedAuthentication
  ( readRetainedAuthorityEpoch
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
import Prodbox.Infra.AwsSesDecommission
  ( applyAwsSesSmtpIamDestroyPrimitive
  , awsSesSmtpIamDestroyPrimitive
  , observeAwsSesSmtpIamDestroyPrimitive
  )
import Prodbox.Infra.AwsSesStack
  ( awsSesLegacyPulumiBackend
  )
import Prodbox.Lifecycle.AdminAction.Execution
  ( AdminAbsenceObservation (..)
  , AdminActionInterpreters
  , AdminResultObservation (..)
  , mkAdminActionInterpreters
  , mkDestroyAwsSesInterpreter
  , mkMigrateLegacyBackendInterpreter
  , mkReconcileQuotaInterpreter
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminDestroyAwsSesPlan (..)
  , AdminLegacyBackendPlan (..)
  , AdminLegacyMigrationReadBack
  , AdminQuotaItemReadBack
  , AdminQuotaRequest (..)
  , AdminRetainedCustodyMember
  , AdminTargetGenerationReadBack
  , SignedAdminActionPermit
  , adminActionPermitAuthorityScope
  , adminRetainedCustodyTargetId
  , adminTargetGenerationTargetId
  , signedAdminActionPermitCore
  )
import Prodbox.Lifecycle.AdminAction.QuotaJournal
  ( QuotaAttemptIntent (..)
  , QuotaExternalObservation (..)
  , QuotaHistoryObservation (..)
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( RetainedCustodyTombstoneAction (..)
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneAction (..)
  )
import Prodbox.Lifecycle.Lease (authorityDurationFromMicros)
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , renderResidueUnreachableReason
  )
import Prodbox.Pulumi.EncryptedBackend
  ( exportLegacyPulumiCheckpoint
  , removeLegacyPulumiStack
  )
import Prodbox.Settings (Credentials (..))
import Prodbox.Vault.Session (VaultSession)
import System.FilePath ((</>))
import Text.Read (readMaybe)

loadProductionAdminActionInterpreters
  :: FilePath
  -> Credentials
  -> VaultSession
  -> SignedAdminActionPermit
  -> IO (Either Text (AdminActionInterpreters IO))
loadProductionAdminActionInterpreters repoRoot credentials session permit = do
  signerResult <-
    resolveTransitRequestSigningCapability
      session
      CallerAdminActionRunner
      (controlPlaneSigningKeyRefFor CallerAdminActionRunner)
  smtpPrimitive <- awsSesSmtpIamDestroyPrimitive repoRoot credentials
  pure $ do
    signer <- signerResult
    bounds <-
      mapLeft
        (Text.pack . show)
        (mkAuthenticatedTransportBounds frameMaximum metadataMaximum envelopeMaximum)
    lifetime <-
      mapLeft
        (Text.pack . show)
        (authorityDurationFromMicros authenticationLifetimeMicros)
    authorityIdentity <- adminPermitAuthorityScope permit
    let providersFor targetIdentity = do
          scope <- mapLeft (Text.pack . show) (mkAuthorityScope targetIdentity)
          Right
            ( transitAuthenticatedClientProviders
                signer
                (pure (Right scope))
                (readRetainedAuthorityEpoch session)
                lifetime
            )
        authorityProviders = providersFor authorityIdentity
        destroy =
          mkDestroyAwsSesInterpreter
            (\plan _ -> pure (AdminObservedAbsent (adminDestroyConsumerReceiptDigest plan)))
            (\plan _ -> pure (AdminObservedAbsent (adminDestroyProviderAbsenceReceiptDigest plan)))
            ( \_ operationId -> residueObservation <$> observeAwsSesSmtpIamDestroyPrimitive smtpPrimitive operationId
            )
            (\_ operationId -> applyAwsSesSmtpIamDestroyPrimitive smtpPrimitive operationId)
            (observeTargets bounds providersFor permit)
            (destroyTargets bounds providersFor permit)
            (observeCustody bounds providersFor permit)
            (destroyCustody bounds providersFor permit)
        migration =
          mkMigrateLegacyBackendInterpreter
            (observeLegacyMigration bounds authorityProviders permit)
            (applyLegacyMigration repoRoot credentials bounds authorityProviders permit)
        quota =
          mkReconcileQuotaInterpreter
            (observeQuotaReconcile bounds authorityProviders permit)
            (applyQuotaReconcile credentials bounds authorityProviders permit)
    Right (mkAdminActionInterpreters destroy migration quota)

adminPermitAuthorityScope :: SignedAdminActionPermit -> Either Text Text
adminPermitAuthorityScope permit =
  Right
    ( adminActionPermitAuthorityScope
        (signedAdminActionPermitCore permit)
    )

observeLegacyMigration
  :: AuthenticatedTransportBounds
  -> Either Text (AuthenticatedClientProviders IO)
  -> SignedAdminActionPermit
  -> AdminLegacyBackendPlan
  -> Text
  -> IO (AdminResultObservation AdminLegacyMigrationReadBack)
observeLegacyMigration bounds providersResult permit _plan _operationId =
  case providersResult of
    Left detail -> pure (AdminResultUnavailable detail)
    Right providers -> do
      observed <- callObserveAdminLegacyMigration bounds providers permit
      pure $ case mapLeft (Text.pack . show) observed of
        Left detail -> AdminResultUnavailable detail
        Right response -> migrationObservation response

applyLegacyMigration
  :: FilePath
  -> Credentials
  -> AuthenticatedTransportBounds
  -> Either Text (AuthenticatedClientProviders IO)
  -> SignedAdminActionPermit
  -> AdminLegacyBackendPlan
  -> Text
  -> IO (Either Text ())
applyLegacyMigration repoRoot credentials bounds providersResult permit _plan _operationId =
  case providersResult of
    Left detail -> pure (Left detail)
    Right providers -> do
      maybeLegacy <-
        awsSesLegacyPulumiBackend
          repoRoot
          (repoRoot </> "pulumi" </> "aws-ses")
          credentials
      case maybeLegacy of
        Nothing -> pure (Left "registered legacy aws-ses backend is unavailable")
        Just legacy -> do
          exported <- exportLegacyPulumiCheckpoint legacy
          case exported of
            Left detail -> pure (Left (Text.pack detail))
            Right Nothing ->
              confirmLegacySourceAbsence bounds providers permit
            Right (Just sourceBytes) -> do
              published <-
                callPublishAdminLegacyMigration
                  bounds
                  providers
                  permit
                  sourceBytes
              case mapLeft (Text.pack . show) published >>= requireMigrationStored of
                Left detail -> pure (Left detail)
                Right () -> do
                  removed <- removeLegacyPulumiStack legacy
                  case removed of
                    Left detail -> pure (Left (Text.pack detail))
                    Right () -> do
                      readBack <- exportLegacyPulumiCheckpoint legacy
                      case readBack of
                        Left detail -> pure (Left (Text.pack detail))
                        Right (Just _) ->
                          pure (Left "legacy aws-ses source remained after deletion")
                        Right Nothing ->
                          confirmLegacySourceAbsence bounds providers permit

confirmLegacySourceAbsence
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> IO (Either Text ())
confirmLegacySourceAbsence bounds providers permit = do
  confirmed <-
    callConfirmAdminLegacySourceAbsent
      bounds
      providers
      permit
      "legacy-source-observed-absent"
  pure (mapLeft (Text.pack . show) confirmed >>= requireMigrationCompleted)

migrationObservation
  :: AdminActionAuthorityResponse
  -> AdminResultObservation AdminLegacyMigrationReadBack
migrationObservation response = case response of
  AdminActionAuthorityMigrationCompleted readBack -> AdminResultCompleted readBack
  AdminActionAuthorityMigrationPending detail -> AdminResultPending detail
  AdminActionAuthorityMigrationStored _ ->
    AdminResultPending "legacy-destination-stored-source-not-confirmed-absent"
  AdminActionAuthorityRefused detail -> AdminResultUnavailable detail
  AdminActionAuthorityUnavailable detail -> AdminResultUnavailable detail
  _ -> AdminResultUnavailable "admin-action-authority-response-kind-mismatch"

requireMigrationStored :: AdminActionAuthorityResponse -> Either Text ()
requireMigrationStored response = case response of
  AdminActionAuthorityMigrationStored _ -> Right ()
  AdminActionAuthorityMigrationCompleted _ -> Right ()
  AdminActionAuthorityMigrationPending detail -> Left detail
  AdminActionAuthorityRefused detail -> Left detail
  AdminActionAuthorityUnavailable detail -> Left detail
  _ -> Left "admin-action-authority-response-kind-mismatch"

requireMigrationCompleted :: AdminActionAuthorityResponse -> Either Text ()
requireMigrationCompleted response = case response of
  AdminActionAuthorityMigrationCompleted _ -> Right ()
  AdminActionAuthorityMigrationPending detail -> Left detail
  AdminActionAuthorityMigrationStored _ ->
    Left "legacy destination is stored but source absence was not committed"
  AdminActionAuthorityRefused detail -> Left detail
  AdminActionAuthorityUnavailable detail -> Left detail
  _ -> Left "admin-action-authority-response-kind-mismatch"

observeQuotaReconcile
  :: AuthenticatedTransportBounds
  -> Either Text (AuthenticatedClientProviders IO)
  -> SignedAdminActionPermit
  -> [AdminQuotaRequest]
  -> Text
  -> IO (AdminResultObservation [AdminQuotaItemReadBack])
observeQuotaReconcile bounds providersResult permit _requests _operationId =
  case providersResult of
    Left detail -> pure (AdminResultUnavailable detail)
    Right providers -> do
      observed <- callObserveAdminQuotaJournal bounds providers permit
      pure $ case mapLeft (Text.pack . show) observed of
        Left detail -> AdminResultUnavailable detail
        Right response -> quotaObservation response

applyQuotaReconcile
  :: Credentials
  -> AuthenticatedTransportBounds
  -> Either Text (AuthenticatedClientProviders IO)
  -> SignedAdminActionPermit
  -> [AdminQuotaRequest]
  -> Text
  -> IO (Either Text ())
applyQuotaReconcile credentials bounds providersResult permit requests _operationId =
  case providersResult of
    Left detail -> pure (Left detail)
    Right providers -> do
      observed <- observeQuotaInventory credentials requests
      case observed of
        Left detail -> pure (Left detail)
        Right observations -> do
          advanced <-
            callAdvanceAdminQuotaJournal bounds providers permit observations
          case mapLeft (Text.pack . show) advanced of
            Left detail -> pure (Left detail)
            Right response ->
              applyQuotaOutcome
                credentials
                bounds
                providers
                permit
                requests
                response

applyQuotaOutcome
  :: Credentials
  -> AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> [AdminQuotaRequest]
  -> AdminActionAuthorityResponse
  -> IO (Either Text ())
applyQuotaOutcome credentials bounds providers permit requests response =
  case response of
    AdminActionAuthorityQuotaCompleted _ -> pure (Right ())
    AdminActionAuthorityQuotaPending _ -> pure (Right ())
    AdminActionAuthorityQuotaDispatch intent -> do
      let request = quotaAttemptRequest intent
      case serviceQuotasClientFor credentials request of
        Left detail -> pure (Left detail)
        Right client -> case desiredQuotaValue request of
          Left detail -> pure (Left detail)
          Right desired -> do
            requested <-
              requestServiceQuotaIncrease
                client
                QuotaIncreaseRequest
                  { quotaReqServiceCode = adminQuotaRequestServiceCode request
                  , quotaReqQuotaCode = adminQuotaRequestCode request
                  , quotaReqDesiredValue = desired
                  }
            case requested of
              Right change -> do
                recorded <-
                  callRecordAdminQuotaProviderResponse
                    bounds
                    providers
                    permit
                    (quotaAttemptIdentity intent)
                    (requestedChangeId change)
                    (quotaStatusText (requestedChangeStatus change))
                pure (mapLeft (Text.pack . show) recorded >>= requireQuotaAccepted)
              Left AwsAmbiguousOutcome {} -> do
                -- The request may have applied.  Persist exactly one
                -- authoritative recovery scan now; no second mutation occurs
                -- until a later invocation observes the second stable absence
                -- and the Authority returns the sole retry intent.
                recovered <- observeQuotaInventory credentials requests
                case recovered of
                  Left detail -> pure (Left detail)
                  Right recoveryObservations -> do
                    recovery <-
                      callAdvanceAdminQuotaJournal
                        bounds
                        providers
                        permit
                        recoveryObservations
                    pure (mapLeft (Text.pack . show) recovery >>= requireNoImmediateRetry)
              Left err -> pure (Left (Text.pack (show err)))
    AdminActionAuthorityRefused detail -> pure (Left detail)
    AdminActionAuthorityUnavailable detail -> pure (Left detail)
    _ -> pure (Left "admin-action-authority-response-kind-mismatch")

quotaObservation
  :: AdminActionAuthorityResponse
  -> AdminResultObservation [AdminQuotaItemReadBack]
quotaObservation response = case response of
  AdminActionAuthorityQuotaCompleted readBack -> AdminResultCompleted readBack
  AdminActionAuthorityQuotaPending detail -> AdminResultPending detail
  AdminActionAuthorityQuotaDispatch _ ->
    AdminResultPending "quota-dispatch-intent-awaits-runner"
  AdminActionAuthorityRefused detail -> AdminResultUnavailable detail
  AdminActionAuthorityUnavailable detail -> AdminResultUnavailable detail
  _ -> AdminResultUnavailable "admin-action-authority-response-kind-mismatch"

requireQuotaAccepted :: AdminActionAuthorityResponse -> Either Text ()
requireQuotaAccepted response = case response of
  AdminActionAuthorityQuotaCompleted _ -> Right ()
  AdminActionAuthorityQuotaPending _ -> Right ()
  AdminActionAuthorityRefused detail -> Left detail
  AdminActionAuthorityUnavailable detail -> Left detail
  AdminActionAuthorityQuotaDispatch _ -> Left "quota response recording returned a dispatch"
  _ -> Left "admin-action-authority-response-kind-mismatch"

requireNoImmediateRetry :: AdminActionAuthorityResponse -> Either Text ()
requireNoImmediateRetry response = case response of
  AdminActionAuthorityQuotaCompleted _ -> Right ()
  AdminActionAuthorityQuotaPending _ -> Right ()
  AdminActionAuthorityQuotaDispatch _ ->
    Left "quota recovery attempted to arm a retry without two stable scans"
  AdminActionAuthorityRefused detail -> Left detail
  AdminActionAuthorityUnavailable detail -> Left detail
  _ -> Left "admin-action-authority-response-kind-mismatch"

observeQuotaInventory
  :: Credentials
  -> [AdminQuotaRequest]
  -> IO (Either Text [QuotaExternalObservation])
observeQuotaInventory credentials = fmap sequence . traverse observeOne
 where
  observeOne request = case serviceQuotasClientFor credentials request of
    Left detail -> pure (Left detail)
    Right client -> do
      current <-
        getServiceQuota
          client
          (adminQuotaRequestServiceCode request)
          (adminQuotaRequestCode request)
      history <-
        listRequestedServiceQuotaChangeHistoryByQuota
          client
          (adminQuotaRequestServiceCode request)
          (adminQuotaRequestCode request)
      pure $ do
        currentQuota <- mapLeft (Text.pack . show) current
        changes <- mapLeft (Text.pack . show) history
        if serviceQuotaCode currentQuota == adminQuotaRequestCode request
          then Right ()
          else Left "Service Quotas current-value response changed quota identity"
        Right
          QuotaExternalObservation
            { quotaExternalRequest = request
            , quotaExternalCurrentValue = serviceQuotaValue currentQuota
            , quotaExternalHistory = fmap historyObservation changes
            }

serviceQuotasClientFor
  :: Credentials
  -> AdminQuotaRequest
  -> Either Text ServiceQuotasClient
serviceQuotasClientFor credentials request = do
  handle <-
    mapLeft
      (Text.pack . show)
      ( mkBaseCredentialHandle
          (TextEncoding.encodeUtf8 (access_key_id credentials))
          (TextEncoding.encodeUtf8 (secret_access_key credentials))
          (TextEncoding.encodeUtf8 <$> session_token credentials)
          (TextEncoding.encodeUtf8 (adminQuotaRequestRegion request))
      )
  Right (newServiceQuotasClient handle httpSend)

desiredQuotaValue :: AdminQuotaRequest -> Either Text Double
desiredQuotaValue request =
  case readMaybe (Text.unpack (adminQuotaRequestDesiredValue request)) of
    Just value | value > 0 && not (isNaN value) && not (isInfinite value) -> Right value
    _ -> Left "quota desired value is invalid"

historyObservation
  :: RequestedQuotaChangeHistoryItem
  -> QuotaHistoryObservation
historyObservation item =
  QuotaHistoryObservation
    { quotaHistoryServiceCode = requestedHistoryServiceCode item
    , quotaHistoryQuotaCode = requestedHistoryQuotaCode item
    , quotaHistoryDesiredValue = requestedHistoryDesiredValue item
    , quotaHistoryProviderRequestIdentity = requestedHistoryId item
    , quotaHistoryStatus = quotaStatusText (requestedHistoryStatus item)
    , quotaHistoryCreatedEpochSeconds = requestedHistoryCreatedEpochSeconds item
    , quotaHistoryLastUpdatedEpochSeconds = requestedHistoryLastUpdatedEpochSeconds item
    }

quotaStatusText :: RequestStatus -> Text
quotaStatusText status = case status of
  QuotaPending -> "PENDING"
  QuotaCaseOpened -> "CASE_OPENED"
  QuotaApproved -> "APPROVED"
  QuotaDenied -> "DENIED"
  QuotaOther detail -> detail

observeTargets
  :: AuthenticatedTransportBounds
  -> (Text -> Either Text (AuthenticatedClientProviders IO))
  -> SignedAdminActionPermit
  -> AdminDestroyAwsSesPlan
  -> Text
  -> IO (AdminResultObservation [AdminTargetGenerationReadBack])
observeTargets bounds providersFor permit plan _ = do
  results <-
    traverse
      (callTarget providersFor ObserveTargetGenerationAbsence)
      (adminDestroyTargetGenerations plan)
  pure (foldTargetObservations results)
 where
  callTarget resolve action member = case resolve (adminTargetGenerationTargetId member) of
    Left detail -> pure (Left detail)
    Right providers ->
      mapLeft (Text.pack . show)
        <$> callAdminTargetGenerationTombstone bounds providers permit member action

destroyTargets
  :: AuthenticatedTransportBounds
  -> (Text -> Either Text (AuthenticatedClientProviders IO))
  -> SignedAdminActionPermit
  -> AdminDestroyAwsSesPlan
  -> Text
  -> IO (Either Text ())
destroyTargets bounds providersFor permit plan _ = do
  results <-
    traverse
      (callTarget providersFor DestroyTargetGeneration)
      (adminDestroyTargetGenerations plan)
  pure (sequence_ results)
 where
  callTarget resolve action member = case resolve (adminTargetGenerationTargetId member) of
    Left detail -> pure (Left detail)
    Right providers ->
      mapLeft (Text.pack . show)
        <$> callAdminTargetGenerationTombstone bounds providers permit member action

observeCustody
  :: AuthenticatedTransportBounds
  -> (Text -> Either Text (AuthenticatedClientProviders IO))
  -> SignedAdminActionPermit
  -> AdminDestroyAwsSesPlan
  -> Text
  -> IO AdminAbsenceObservation
observeCustody bounds providersFor permit plan _ =
  callCustody
    bounds
    providersFor
    permit
    (adminDestroyRetainedCustody plan)
    ObserveRetainedCustodyAbsence

destroyCustody
  :: AuthenticatedTransportBounds
  -> (Text -> Either Text (AuthenticatedClientProviders IO))
  -> SignedAdminActionPermit
  -> AdminDestroyAwsSesPlan
  -> Text
  -> IO (Either Text ())
destroyCustody bounds providersFor permit plan _ = do
  observed <-
    callCustodyResponse
      bounds
      providersFor
      permit
      (adminDestroyRetainedCustody plan)
      DestroyRetainedCustody
  pure (Control.Monad.void observed)

callCustody
  :: AuthenticatedTransportBounds
  -> (Text -> Either Text (AuthenticatedClientProviders IO))
  -> SignedAdminActionPermit
  -> AdminRetainedCustodyMember
  -> RetainedCustodyTombstoneAction
  -> IO AdminAbsenceObservation
callCustody bounds providersFor permit member action = do
  result <- callCustodyResponse bounds providersFor permit member action
  pure $ case result of
    Left detail -> AdminObservationUnavailable detail
    Right response -> case response of
      AdminCustodyTombstoneAbsent evidence ->
        AdminObservedAbsent evidence
      AdminCustodyTombstoneDestroyed evidence ->
        AdminObservedAbsent evidence
      AdminCustodyTombstonePresent ->
        AdminObservedPresent "retained-custody-present"
      AdminCustodyTombstoneRefused detail ->
        AdminObservationUnavailable detail
      AdminCustodyTombstoneUnavailable detail ->
        AdminObservationUnavailable detail

callCustodyResponse
  :: AuthenticatedTransportBounds
  -> (Text -> Either Text (AuthenticatedClientProviders IO))
  -> SignedAdminActionPermit
  -> AdminRetainedCustodyMember
  -> RetainedCustodyTombstoneAction
  -> IO
       ( Either
           Text
           AdminCustodyTombstoneResponse
       )
callCustodyResponse bounds providersFor permit member action =
  case providersFor (adminRetainedCustodyTargetId member) of
    Left detail -> pure (Left detail)
    Right providers ->
      mapLeft (Text.pack . show)
        <$> callAdminCustodyTombstone bounds providers permit member action

foldTargetObservations
  :: [ Either
         Text
         AdminTargetTombstoneResponse
     ]
  -> AdminResultObservation [AdminTargetGenerationReadBack]
foldTargetObservations results = case sequence results of
  Left detail -> AdminResultUnavailable detail
  Right responses
    | any targetPresent responses -> AdminResultPending "target-generation-present"
    | otherwise -> case traverse targetReadBack responses of
        Left detail -> AdminResultUnavailable detail
        Right readBack -> AdminResultCompleted readBack
 where
  targetPresent response = case response of
    AdminTargetTombstonePresent -> True
    _ -> False
  targetReadBack response = case response of
    AdminTargetTombstoneAbsent item -> Right item
    AdminTargetTombstoneDestroyed item -> Right item
    AdminTargetTombstonePresent ->
      Left "target-generation-present"
    AdminTargetTombstoneRefused detail -> Left detail
    AdminTargetTombstoneUnavailable detail -> Left detail

residueObservation :: ResidueStatus -> AdminAbsenceObservation
residueObservation residue = case residue of
  ResidueAbsent -> AdminObservedAbsent "aws-iam:get-user:no-such-entity"
  ResiduePresent details -> AdminObservedPresent (Text.pack (residueEvidence details))
  ResidueUnreachable reason ->
    AdminObservationUnavailable (Text.pack (renderResidueUnreachableReason reason))

frameMaximum :: Int
frameMaximum = 100 * 1024 * 1024

metadataMaximum :: Int
metadataMaximum = 64 * 1024

envelopeMaximum :: Int
envelopeMaximum = frameMaximum - 4096

authenticationLifetimeMicros :: Natural
authenticationLifetimeMicros = 5 * 60 * 1000000

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
