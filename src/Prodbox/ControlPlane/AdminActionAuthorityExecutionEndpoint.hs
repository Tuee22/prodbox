{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Runner-only Lifecycle Authority boundary for the two Admin Action effects
-- that must not touch retained authority storage directly.  A request carries
-- the complete signed, backup-bound, Pod-bound permit and one closed command.
-- The endpoint verifies that permit with the live Transit public generation,
-- fixes legacy migration to the registered @aws-ses@ checkpoint, and persists
-- every quota attempt intent before returning permission to dispatch AWS's
-- non-idempotent quota-increase API.
module Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityCommand (..)
  , AdminActionAuthorityRequest (..)
  , AdminActionAuthorityResponse (..)
  , AdminLegacyDestinationObservation (..)
  , AdminLegacyDestinationPublication (..)
  , AdminLegacyDestinationBoundary (..)
  , AdminActionAuthorityExecutionBoundary (..)
  , AdminActionEffectState
  , AdminActionEffectSnapshot (..)
  , AdminActionEffectRepository (..)
  , modelBAdminActionEffectRepository
  , adminActionEffectStateCodec
  , serveAdminActionAuthorityExecutionRequest
  , adminActionAuthorityExecutionResponseStatus
  , adminActionAuthorityExecutionResponseBody
  , adminActionAuthorityExecutionMaximumBytes
  , adminActionAuthorityExecutionResponseMaximumBytes
  , adminActionEffectMaximumEncodedBytes
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.AdminAction.Authority qualified as Authority
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionPlan (..)
  , AdminActionReceipt
  , AdminLegacyBackendPlan (..)
  , AdminLegacyMigrationReadBack (..)
  , AdminQuotaItemReadBack
  , AdminQuotaRequest
  , SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionPermitAuthorityEndpoint
  , adminActionPermitAuthorityScope
  , adminActionPermitDeadline
  , adminActionPermitOperationId
  , adminActionPermitPlan
  , adminLegacyAwsSesDestinationCoordinate
  , adminLegacyAwsSesSourceCoordinate
  , adminQuotaRequestAuthorityEndpoint
  , adminQuotaRequestAuthorityScope
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  , signedAdminActionPermitSignerGeneration
  , verifySignedAdminActionPermit
  )
import Prodbox.Lifecycle.AdminAction.QuotaJournal
  ( QuotaAttemptIntent
  , QuotaExternalObservation
  , QuotaJournalOutcome (..)
  , QuotaJournalState
  , advanceQuotaJournal
  , initialQuotaJournal
  , quotaJournalOperationIdValue
  , quotaJournalReadBack
  , quotaJournalRequestInventory
  , recordQuotaProviderResponse
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( manifestPublicKeyBytes
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( pulumiCheckpointMaximumBytes
  )

data AdminActionAuthorityCommand
  = ObserveAdminLegacyMigration
  | PublishAdminLegacyMigration !ByteString
  | ConfirmAdminLegacySourceAbsent !Text
  | ObserveAdminQuotaJournal
  | AdvanceAdminQuotaJournal ![QuotaExternalObservation]
  | RecordAdminQuotaProviderResponse !Text !Text !Text
  | CommitAdminActionCompletion !AdminActionReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionAuthorityRequest = AdminActionAuthorityRequest
  { adminAuthorityRequestPermit :: !SignedAdminActionPermit
  , adminAuthorityRequestOperationId :: !Text
  , adminAuthorityRequestPodName :: !Text
  , adminAuthorityRequestPodUid :: !Text
  , adminAuthorityRequestCommand :: !AdminActionAuthorityCommand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionAuthorityResponse
  = AdminActionAuthorityMigrationPending !Text
  | AdminActionAuthorityMigrationStored !Text
  | AdminActionAuthorityMigrationCompleted !AdminLegacyMigrationReadBack
  | AdminActionAuthorityQuotaPending !Text
  | AdminActionAuthorityQuotaDispatch !QuotaAttemptIntent
  | AdminActionAuthorityQuotaCompleted ![AdminQuotaItemReadBack]
  | AdminActionAuthorityCompletionCommitted !AdminActionReceipt
  | AdminActionAuthorityRefused !Text
  | AdminActionAuthorityUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminLegacyDestinationObservation
  = AdminLegacyDestinationMissing
  | AdminLegacyDestinationCurrent !Text !Text
  | AdminLegacyDestinationCorrupt !Text
  | AdminLegacyDestinationUnavailable !Text
  deriving stock (Eq, Show)

data AdminLegacyDestinationPublication
  = AdminLegacyDestinationPublished !Text !Text
  | AdminLegacyDestinationAlreadyCurrent !Text !Text
  | AdminLegacyDestinationPublicationRefused !Text
  | AdminLegacyDestinationPublicationUnavailable !Text
  deriving stock (Eq, Show)

data AdminLegacyDestinationBoundary m = AdminLegacyDestinationBoundary
  { observeAdminLegacyDestination
      :: AdminLegacyBackendPlan
      -> m AdminLegacyDestinationObservation
  , publishAdminLegacySource
      :: AdminLegacyBackendPlan
      -> Text
      -> ByteString
      -> m AdminLegacyDestinationPublication
  }

data AdminActionAuthorityExecutionBoundary m = AdminActionAuthorityExecutionBoundary
  { adminExecutionAuthoritySigner :: !(AuthorityManifestSigner m)
  , adminExecutionCurrentTime :: !(m (Either Text AuthorityTime))
  , adminExecutionLocalAuthorityScope :: !Text
  , adminExecutionLocalAuthorityEndpoint :: !Text
  , adminExecutionLegacyDestination :: !(AdminLegacyDestinationBoundary m)
  }

data AdminLegacyEffectPhase
  = AdminLegacyEffectPrepared
  | AdminLegacyEffectStored !Text !Text
  | AdminLegacyEffectCompleted !AdminLegacyMigrationReadBack
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionEffectState
  = AdminActionLegacyEffect !AdminLegacyBackendPlan !AdminLegacyEffectPhase
  | AdminActionQuotaEffect ![AdminQuotaRequest] !QuotaJournalState
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionEffectSnapshot revision = AdminActionEffectSnapshot
  { adminActionEffectRevision :: !(Maybe revision)
  , adminActionEffectObservedState :: !(Maybe AdminActionEffectState)
  }
  deriving stock (Eq, Show)

data AdminActionEffectRepository m revision = AdminActionEffectRepository
  { readAdminActionEffect
      :: m (Either Text (AdminActionEffectSnapshot revision))
  , compareAndSwapAdminActionEffect
      :: Maybe revision
      -> AdminActionEffectState
      -> m (Either Text ())
  }

modelBAdminActionEffectRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m AdminActionEffectState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AdminActionEffectRepository m ModelBObjectVersion
modelBAdminActionEffectRepository adapter coordinate =
  AdminActionEffectRepository
    { readAdminActionEffect = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right (AdminActionEffectSnapshot Nothing Nothing)
          ModelBObserved revision state ->
            Right (AdminActionEffectSnapshot (Just revision) (Just state))
          ModelBCorrupt detail -> Left ("admin action effect state is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("admin action effect state is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("admin action effect state is unobservable: " <> detail)
    , compareAndSwapAdminActionEffect = \expected state -> do
        attempted <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case attempted of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "admin action effect CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("admin action effect CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("admin action effect CAS is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("admin action effect CAS is unobservable: " <> detail)
    }

adminActionEffectStateCodec :: Int -> ModelBCodec AdminActionEffectState
adminActionEffectStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = \state -> do
        validateEffectState state
        let encoded = LazyByteString.toStrict (serialise state)
        if ByteString.length encoded <= maximumBytes
          then Right encoded
          else Left "admin action effect state exceeds encoded-size bound"
    , decodeModelBValue = \bytes -> do
        if ByteString.length bytes <= maximumBytes
          then Right ()
          else Left "admin action effect state exceeds encoded-size bound"
        state <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
          Left _ -> Left "admin action effect state decode failed"
          Right value -> Right value
        if LazyByteString.toStrict (serialise state) == bytes
          then validateEffectState state >> Right state
          else Left "admin action effect state is not canonical"
    }

serveAdminActionAuthorityExecutionRequest
  :: (Monad m)
  => Int
  -> AdminActionAuthorityExecutionBoundary m
  -> (Text -> Either Text (AdminActionEffectRepository m effectRevision))
  -> (Text -> Either Text (Authority.AdminActionAuthorityRepository m authorityRevision))
  -> LazyByteString.ByteString
  -> m AdminActionAuthorityResponse
serveAdminActionAuthorityExecutionRequest maximumBytes boundary resolveEffectRepository resolveAuthorityRepository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure (AdminActionAuthorityRefused "request-codec-rejected")
    Right request -> do
      verified <- verifyAdminAuthorityRequest boundary request
      case verified of
        Left detail -> pure (AdminActionAuthorityRefused detail)
        Right (now, plan) -> case adminAuthorityRequestCommand request of
          CommitAdminActionCompletion receipt ->
            case resolveAuthorityRepository (adminAuthorityRequestOperationId request) of
              Left detail -> pure (AdminActionAuthorityUnavailable detail)
              Right repository -> do
                completed <-
                  Authority.completeAdminActionForPermit
                    repository
                    (adminAuthorityRequestPermit request)
                    receipt
                pure $ case completed of
                  Left err -> completionErrorResponse err
                  Right confirmed -> AdminActionAuthorityCompletionCommitted confirmed
          _ ->
            case resolveEffectRepository (adminAuthorityRequestOperationId request) of
              Left detail -> pure (AdminActionAuthorityUnavailable detail)
              Right repository -> dispatchVerified boundary repository now plan request

dispatchVerified
  :: (Monad m)
  => AdminActionAuthorityExecutionBoundary m
  -> AdminActionEffectRepository m revision
  -> AuthorityTime
  -> AdminActionPlan
  -> AdminActionAuthorityRequest
  -> m AdminActionAuthorityResponse
dispatchVerified boundary repository now plan request =
  case (plan, adminAuthorityRequestCommand request) of
    (AdminMigrateLegacyBackendPlanAction legacy, ObserveAdminLegacyMigration) ->
      observeLegacyState repository legacy
    (AdminMigrateLegacyBackendPlanAction legacy, PublishAdminLegacyMigration sourceBytes) ->
      publishLegacy boundary repository legacy operationId sourceBytes
    (AdminMigrateLegacyBackendPlanAction legacy, ConfirmAdminLegacySourceAbsent evidence) ->
      confirmLegacySourceAbsent repository legacy evidence
    (AdminReconcileQuotaPlanAction requests, ObserveAdminQuotaJournal) ->
      observeQuotaState repository requests operationId
    (AdminReconcileQuotaPlanAction requests, AdvanceAdminQuotaJournal observations) ->
      advanceQuotaState repository now deadline operationId requests observations
    ( AdminReconcileQuotaPlanAction requests
      , RecordAdminQuotaProviderResponse attemptIdentity providerIdentity status
      ) ->
        recordQuotaState
          repository
          operationId
          requests
          attemptIdentity
          providerIdentity
          status
    _ -> pure (AdminActionAuthorityRefused "permit-command-action-mismatch")
 where
  core = signedAdminActionPermitCore (adminAuthorityRequestPermit request)
  operationId = adminActionPermitOperationId core
  deadline = adminActionPermitDeadline core

verifyAdminAuthorityRequest
  :: (Monad m)
  => AdminActionAuthorityExecutionBoundary m
  -> AdminActionAuthorityRequest
  -> m (Either Text (AuthorityTime, AdminActionPlan))
verifyAdminAuthorityRequest boundary request = do
  publicResult <- readAuthorityManifestPublicKey (adminExecutionAuthoritySigner boundary)
  nowResult <- adminExecutionCurrentTime boundary
  pure $ do
    (publicGeneration, publicKey) <- publicResult
    now <- nowResult
    let permit = adminAuthorityRequestPermit request
        core = signedAdminActionPermitCore permit
        binding = signedAdminActionPermitBinding permit
        plan = adminActionPermitPlan core
    if publicGeneration == signedAdminActionPermitSignerGeneration permit
      then Right ()
      else Left "authority-signer-generation-mismatch"
    mapLeft (const "permit-signature-rejected") $
      verifySignedAdminActionPermit (manifestPublicKeyBytes publicKey) now permit
    if adminActionPermitOperationId core == adminAuthorityRequestOperationId request
      && adminActionJobPodName binding == adminAuthorityRequestPodName request
      && adminActionJobPodUid binding == adminAuthorityRequestPodUid request
      then Right ()
      else Left "permit-operation-pod-binding-mismatch"
    if adminActionPermitAuthorityScope core == adminExecutionLocalAuthorityScope boundary
      && adminActionPermitAuthorityEndpoint core == adminExecutionLocalAuthorityEndpoint boundary
      then Right ()
      else Left "permit-authority-binding-mismatch"
    case adminAuthorityRequestCommand request of
      CommitAdminActionCompletion _ -> Right ()
      _ -> case plan of
        AdminMigrateLegacyBackendPlanAction legacy -> validateLocalMigration boundary legacy
        AdminReconcileQuotaPlanAction requests -> validateLocalQuota boundary requests
        AdminDestroyAwsSesPlanAction _ -> Left "permit-action-refused"
    Right (now, plan)

completionErrorResponse :: Authority.AdminActionAuthorityError -> AdminActionAuthorityResponse
completionErrorResponse err = case err of
  Authority.AdminActionAuthorityUnavailable _ -> AdminActionAuthorityUnavailable "completion-state-unavailable"
  Authority.AdminActionAuthorityCommitFailed _ -> AdminActionAuthorityUnavailable "completion-commit-unconfirmed"
  Authority.AdminActionAuthorityProtocolRejected _ -> AdminActionAuthorityRefused "completion-receipt-rejected"
  Authority.AdminActionAuthorityOperationMismatch -> AdminActionAuthorityRefused "completion-operation-mismatch"
  Authority.AdminActionAuthorityStateConflict -> AdminActionAuthorityRefused "completion-attempt-conflict"
  Authority.AdminActionAuthorityBackupFailed _ -> AdminActionAuthorityRefused "completion-boundary-invalid"
  Authority.AdminActionAuthoritySignerFailed _ -> AdminActionAuthorityRefused "completion-boundary-invalid"
  Authority.AdminActionAuthoritySignerGenerationChanged _ _ ->
    AdminActionAuthorityRefused "completion-boundary-invalid"

validateLocalMigration
  :: AdminActionAuthorityExecutionBoundary m
  -> AdminLegacyBackendPlan
  -> Either Text ()
validateLocalMigration boundary plan
  | adminLegacyAuthorityScope plan /= adminExecutionLocalAuthorityScope boundary =
      Left "legacy-authority-scope-mismatch"
  | adminLegacyAuthorityEndpoint plan /= adminExecutionLocalAuthorityEndpoint boundary =
      Left "legacy-authority-endpoint-mismatch"
  | adminLegacySourceCoordinate plan /= adminLegacyAwsSesSourceCoordinate =
      Left "legacy-source-coordinate-refused"
  | adminLegacyDestinationCoordinate plan /= adminLegacyAwsSesDestinationCoordinate =
      Left "legacy-destination-coordinate-refused"
  | otherwise = Right ()

validateLocalQuota
  :: AdminActionAuthorityExecutionBoundary m
  -> [AdminQuotaRequest]
  -> Either Text ()
validateLocalQuota boundary requests
  | all
      (\request -> adminQuotaRequestAuthorityScope request == adminExecutionLocalAuthorityScope boundary)
      requests
      && all
        ( \request -> adminQuotaRequestAuthorityEndpoint request == adminExecutionLocalAuthorityEndpoint boundary
        )
        requests =
      Right ()
  | otherwise = Left "quota-authority-binding-mismatch"

observeLegacyState
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> AdminLegacyBackendPlan
  -> m AdminActionAuthorityResponse
observeLegacyState repository plan = do
  observed <- readAdminActionEffect repository
  pure $ case observed of
    Left detail -> AdminActionAuthorityUnavailable detail
    Right snapshot -> case adminActionEffectObservedState snapshot of
      Nothing -> AdminActionAuthorityMigrationPending "legacy-destination-not-prepared"
      Just (AdminActionLegacyEffect existing phase)
        | existing /= plan -> AdminActionAuthorityRefused "legacy-plan-state-mismatch"
        | otherwise -> migrationPhaseResponse phase
      Just AdminActionQuotaEffect {} ->
        AdminActionAuthorityRefused "admin-action-effect-kind-mismatch"

publishLegacy
  :: (Monad m)
  => AdminActionAuthorityExecutionBoundary m
  -> AdminActionEffectRepository m revision
  -> AdminLegacyBackendPlan
  -> Text
  -> ByteString
  -> m AdminActionAuthorityResponse
publishLegacy boundary repository plan operationId sourceBytes
  | ByteString.null sourceBytes =
      pure (AdminActionAuthorityRefused "legacy-source-empty")
  | ByteString.length sourceBytes > pulumiCheckpointMaximumBytes =
      pure (AdminActionAuthorityRefused "legacy-source-too-large")
  | sha256Text sourceBytes /= adminLegacySourceDigest plan =
      pure (AdminActionAuthorityRefused "legacy-source-digest-mismatch")
  | otherwise = do
      prepared <- ensureLegacyPrepared repository plan
      case prepared of
        Left response -> pure response
        Right phase -> case phase of
          AdminLegacyEffectCompleted readBack ->
            pure (AdminActionAuthorityMigrationCompleted readBack)
          AdminLegacyEffectStored _ reference ->
            pure (AdminActionAuthorityMigrationStored reference)
          AdminLegacyEffectPrepared -> do
            published <-
              publishAdminLegacySource
                (adminExecutionLegacyDestination boundary)
                plan
                operationId
                sourceBytes
            case published of
              AdminLegacyDestinationPublicationRefused detail ->
                pure (AdminActionAuthorityRefused detail)
              AdminLegacyDestinationPublicationUnavailable detail ->
                pure (AdminActionAuthorityUnavailable detail)
              AdminLegacyDestinationPublished digest reference ->
                commitStored digest reference
              AdminLegacyDestinationAlreadyCurrent digest reference ->
                commitStored digest reference
 where
  commitStored digest reference = do
    committed <-
      transitionEffectState
        repository
        (AdminActionLegacyEffect plan AdminLegacyEffectPrepared)
        (AdminActionLegacyEffect plan (AdminLegacyEffectStored digest reference))
    pure $ case committed of
      Left detail -> AdminActionAuthorityUnavailable detail
      Right () -> AdminActionAuthorityMigrationStored reference

ensureLegacyPrepared
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> AdminLegacyBackendPlan
  -> m (Either AdminActionAuthorityResponse AdminLegacyEffectPhase)
ensureLegacyPrepared repository plan = do
  observed <- readAdminActionEffect repository
  case observed of
    Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
    Right snapshot -> case adminActionEffectObservedState snapshot of
      Nothing -> do
        let prepared = AdminActionLegacyEffect plan AdminLegacyEffectPrepared
        committed <- persistEffectState repository snapshot prepared
        pure $ case committed of
          Left detail -> Left (AdminActionAuthorityUnavailable detail)
          Right () -> Right AdminLegacyEffectPrepared
      Just (AdminActionLegacyEffect existing phase)
        | existing == plan -> pure (Right phase)
        | otherwise -> pure (Left (AdminActionAuthorityRefused "legacy-plan-state-mismatch"))
      Just AdminActionQuotaEffect {} ->
        pure (Left (AdminActionAuthorityRefused "admin-action-effect-kind-mismatch"))

confirmLegacySourceAbsent
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> AdminLegacyBackendPlan
  -> Text
  -> m AdminActionAuthorityResponse
confirmLegacySourceAbsent repository plan evidence
  | Text.null (Text.strip evidence) || Text.length evidence > 512 =
      pure (AdminActionAuthorityRefused "legacy-source-absence-evidence-invalid")
  | otherwise = do
      observed <- readAdminActionEffect repository
      case observed of
        Left detail -> pure (AdminActionAuthorityUnavailable detail)
        Right snapshot -> case adminActionEffectObservedState snapshot of
          Just (AdminActionLegacyEffect existing (AdminLegacyEffectCompleted readBack))
            | existing == plan -> pure (AdminActionAuthorityMigrationCompleted readBack)
          Just (AdminActionLegacyEffect existing (AdminLegacyEffectStored digest reference))
            | existing == plan -> do
                let readBack =
                      AdminLegacyMigrationReadBack
                        { adminLegacyReadBackSourceCoordinate = adminLegacySourceCoordinate plan
                        , adminLegacyReadBackDestinationCoordinate =
                            adminLegacyDestinationCoordinate plan
                        , adminLegacyImportReference = reference
                        , adminLegacyCompatibilityEvidence =
                            "source-sha256:"
                              <> adminLegacySourceDigest plan
                              <> ";destination-sha256:"
                              <> digest
                              <> ";"
                              <> evidence
                        }
                    completed =
                      AdminActionLegacyEffect
                        plan
                        (AdminLegacyEffectCompleted readBack)
                committed <- persistEffectState repository snapshot completed
                pure $ case committed of
                  Left detail -> AdminActionAuthorityUnavailable detail
                  Right () -> AdminActionAuthorityMigrationCompleted readBack
          Just (AdminActionLegacyEffect existing _)
            | existing /= plan -> pure (AdminActionAuthorityRefused "legacy-plan-state-mismatch")
          _ -> pure (AdminActionAuthorityRefused "legacy-destination-not-stored")

observeQuotaState
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> [AdminQuotaRequest]
  -> Text
  -> m AdminActionAuthorityResponse
observeQuotaState repository requests operationId = do
  observed <- readAdminActionEffect repository
  pure $ case observed of
    Left detail -> AdminActionAuthorityUnavailable detail
    Right snapshot -> case adminActionEffectObservedState snapshot of
      Nothing -> AdminActionAuthorityQuotaPending "quota-journal-not-initialized"
      Just (AdminActionQuotaEffect existing journal)
        | existing /= requests
            || quotaJournalOperationIdValue journal /= operationId
            || quotaJournalRequestInventory journal /= requests ->
            AdminActionAuthorityRefused "quota-journal-plan-mismatch"
        | otherwise -> case quotaJournalReadBack journal of
            Nothing -> AdminActionAuthorityQuotaPending "quota-journal-incomplete"
            Just readBack -> AdminActionAuthorityQuotaCompleted readBack
      Just AdminActionLegacyEffect {} ->
        AdminActionAuthorityRefused "admin-action-effect-kind-mismatch"

advanceQuotaState
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> AuthorityTime
  -> AuthorityTime
  -> Text
  -> [AdminQuotaRequest]
  -> [QuotaExternalObservation]
  -> m AdminActionAuthorityResponse
advanceQuotaState repository now deadline operationId requests observations = do
  initialized <- ensureQuotaInitialized repository operationId requests
  case initialized of
    Left response -> pure response
    Right () -> do
      observed <- readAdminActionEffect repository
      case observed of
        Left detail -> pure (AdminActionAuthorityUnavailable detail)
        Right snapshot -> case adminActionEffectObservedState snapshot of
          Just (AdminActionQuotaEffect existing journal)
            | existing == requests
                && quotaJournalOperationIdValue journal == operationId
                && quotaJournalRequestInventory journal == requests ->
                case advanceQuotaJournal now deadline observations journal of
                  Left err -> pure (AdminActionAuthorityRefused (Text.pack (show err)))
                  Right (next, outcome) -> do
                    committed <-
                      if next == journal
                        then pure (Right ())
                        else
                          persistEffectState
                            repository
                            snapshot
                            (AdminActionQuotaEffect requests next)
                    pure $ case committed of
                      Left detail -> AdminActionAuthorityUnavailable detail
                      Right () -> quotaOutcomeResponse outcome
            | otherwise -> pure (AdminActionAuthorityRefused "quota-journal-plan-mismatch")
          _ -> pure (AdminActionAuthorityRefused "admin-action-effect-kind-mismatch")

ensureQuotaInitialized
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> Text
  -> [AdminQuotaRequest]
  -> m (Either AdminActionAuthorityResponse ())
ensureQuotaInitialized repository operationId requests = do
  observed <- readAdminActionEffect repository
  case observed of
    Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
    Right snapshot -> case adminActionEffectObservedState snapshot of
      Nothing -> case initialQuotaJournal operationId requests of
        Left err -> pure (Left (AdminActionAuthorityRefused (Text.pack (show err))))
        Right journal -> do
          persisted <-
            persistEffectState repository snapshot (AdminActionQuotaEffect requests journal)
          pure (either (Left . AdminActionAuthorityUnavailable) (const (Right ())) persisted)
      Just (AdminActionQuotaEffect existing journal)
        | existing == requests
            && quotaJournalOperationIdValue journal == operationId
            && quotaJournalRequestInventory journal == requests ->
            pure (Right ())
        | otherwise -> pure (Left (AdminActionAuthorityRefused "quota-journal-plan-mismatch"))
      Just AdminActionLegacyEffect {} ->
        pure (Left (AdminActionAuthorityRefused "admin-action-effect-kind-mismatch"))

recordQuotaState
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> Text
  -> [AdminQuotaRequest]
  -> Text
  -> Text
  -> Text
  -> m AdminActionAuthorityResponse
recordQuotaState repository operationId requests attemptIdentity providerIdentity status = do
  observed <- readAdminActionEffect repository
  case observed of
    Left detail -> pure (AdminActionAuthorityUnavailable detail)
    Right snapshot -> case adminActionEffectObservedState snapshot of
      Just (AdminActionQuotaEffect existing journal)
        | existing == requests
            && quotaJournalOperationIdValue journal == operationId
            && quotaJournalRequestInventory journal == requests ->
            case recordQuotaProviderResponse attemptIdentity providerIdentity status journal of
              Left err -> pure (AdminActionAuthorityRefused (Text.pack (show err)))
              Right next -> do
                committed <-
                  persistEffectState
                    repository
                    snapshot
                    (AdminActionQuotaEffect requests next)
                pure $ case committed of
                  Left detail -> AdminActionAuthorityUnavailable detail
                  Right () -> case quotaJournalReadBack next of
                    Nothing -> AdminActionAuthorityQuotaPending "quota-journal-incomplete"
                    Just readBack -> AdminActionAuthorityQuotaCompleted readBack
        | otherwise -> pure (AdminActionAuthorityRefused "quota-journal-plan-mismatch")
      _ -> pure (AdminActionAuthorityRefused "quota-journal-not-initialized")

transitionEffectState
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> AdminActionEffectState
  -> AdminActionEffectState
  -> m (Either Text ())
transitionEffectState repository expected next = do
  observed <- readAdminActionEffect repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot
      | adminActionEffectObservedState snapshot /= Just expected ->
          pure (Left "admin action effect state changed before transition")
      | otherwise -> persistEffectState repository snapshot next

persistEffectState
  :: (Monad m)
  => AdminActionEffectRepository m revision
  -> AdminActionEffectSnapshot revision
  -> AdminActionEffectState
  -> m (Either Text ())
persistEffectState repository snapshot next = do
  attempted <-
    compareAndSwapAdminActionEffect
      repository
      (adminActionEffectRevision snapshot)
      next
  readBack <- readAdminActionEffect repository
  pure $ case readBack of
    Right confirmed
      | adminActionEffectObservedState confirmed == Just next -> Right ()
    Left detail -> Left (attemptDetail attempted <> "; read-back failed: " <> detail)
    _ -> Left (attemptDetail attempted <> "; state was not confirmed by read-back")

migrationPhaseResponse :: AdminLegacyEffectPhase -> AdminActionAuthorityResponse
migrationPhaseResponse phase = case phase of
  AdminLegacyEffectPrepared ->
    AdminActionAuthorityMigrationPending "legacy-destination-prepared"
  AdminLegacyEffectStored _ reference ->
    AdminActionAuthorityMigrationStored reference
  AdminLegacyEffectCompleted readBack ->
    AdminActionAuthorityMigrationCompleted readBack

quotaOutcomeResponse :: QuotaJournalOutcome -> AdminActionAuthorityResponse
quotaOutcomeResponse outcome = case outcome of
  QuotaJournalDispatch intent -> AdminActionAuthorityQuotaDispatch intent
  QuotaJournalAwaitingHistory _ scans ->
    AdminActionAuthorityQuotaPending
      ("quota-history-absence-scan-" <> Text.pack (show scans))
  QuotaJournalCompleted readBack -> AdminActionAuthorityQuotaCompleted readBack
  QuotaJournalRefused detail -> AdminActionAuthorityRefused detail

validateEffectState :: AdminActionEffectState -> Either String ()
validateEffectState state = case state of
  AdminActionLegacyEffect plan phase -> do
    if adminLegacySourceCoordinate plan == adminLegacyAwsSesSourceCoordinate
      && adminLegacyDestinationCoordinate plan == adminLegacyAwsSesDestinationCoordinate
      then Right ()
      else Left "admin action legacy coordinates are not registered"
    case phase of
      AdminLegacyEffectPrepared -> Right ()
      AdminLegacyEffectStored digest reference ->
        validateDigest digest >> validateEvidence reference
      AdminLegacyEffectCompleted readBack -> do
        if adminLegacyReadBackSourceCoordinate readBack == adminLegacySourceCoordinate plan
          && adminLegacyReadBackDestinationCoordinate readBack
            == adminLegacyDestinationCoordinate plan
          then Right ()
          else Left "admin action legacy read-back coordinates diverged"
        validateEvidence (adminLegacyImportReference readBack)
        validateEvidence (adminLegacyCompatibilityEvidence readBack)
  AdminActionQuotaEffect requests journal
    | requests == quotaJournalRequestInventory journal -> Right ()
    | otherwise -> Left "admin action quota journal inventory diverged"
 where
  validateDigest value
    | Text.length value == 64
        && Text.all (\character -> character `elem` ['0' .. '9'] || character `elem` ['a' .. 'f']) value =
        Right ()
    | otherwise = Left "admin action effect digest is invalid"
  validateEvidence value
    | Text.null (Text.strip value) || Text.length value > 512 =
        Left "admin action effect evidence is invalid"
    | otherwise = Right ()

adminActionAuthorityExecutionResponseStatus :: AdminActionAuthorityResponse -> ReplyStatus
adminActionAuthorityExecutionResponseStatus response = case response of
  AdminActionAuthorityRefused _ -> ReplyForbidden
  AdminActionAuthorityUnavailable _ -> ReplyServiceUnavailable
  _ -> ReplyOk

adminActionAuthorityExecutionResponseBody :: AdminActionAuthorityResponse -> ByteString
adminActionAuthorityExecutionResponseBody =
  LazyByteString.toStrict . encodeControlPlaneResponse

adminActionAuthorityExecutionMaximumBytes :: Int
adminActionAuthorityExecutionMaximumBytes = pulumiCheckpointMaximumBytes + 512 * 1024

adminActionAuthorityExecutionResponseMaximumBytes :: Int
adminActionAuthorityExecutionResponseMaximumBytes = 512 * 1024

adminActionEffectMaximumEncodedBytes :: Int
adminActionEffectMaximumEncodedBytes = 2 * 1024 * 1024

attemptDetail :: Either Text () -> Text
attemptDetail attempted = case attempted of
  Left detail -> detail
  Right () -> "CAS response was not confirmed"

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
