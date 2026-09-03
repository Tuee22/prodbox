{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production composition of the Lifecycle Authority's purpose-bound
-- aggregate export with the physically separate Authority Backup Adapter.
module Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( copyGenesisAggregateForAdmission
  , copyRepairAggregateForAdmission
  , observeRetainedAuthorityBackupHealth
  , targetGenerationReceiptFromAwsAdminWorker
  , retainedTargetGeneration
  , GenesisAwsAdminIntentParameters (..)
  , compileGenesisAwsAdminIntent
  , compileFirstReconcileAwsAdminIntent
  , compileFirstReconcileContinuationAwsAdminIntent
  , normalAwsAdminOperationIdForScope
  , compileNormalAwsAdminIntentForScope
  , reconcileRemainingFirstReconcileCredentials
  , reconcileRemainingFirstReconcileCredentialsWith
  , compileBackupRepairPermit
  , compileRepairAwsAdminIntent
  , productionAuthorityBackupReconcileBoundary
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Read qualified as TextRead
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload (..)
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupReceipt (authorityBackupReceiptDigest)
  , authorityBackupDigestText
  )
import Prodbox.ControlPlane.AuthorityBackupExportClient
  ( AuthorityBackupExportClient
  , exportAuthorityBackupAggregate
  )
import Prodbox.ControlPlane.AuthorityBackupExportEndpoint
  ( AuthorityBackupExportPurpose (..)
  )
import Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClient (submitAuthorityControl)
  )
import Prodbox.ControlPlane.AuthorityObservationClient
  ( observeLifecycleAuthorityAuthenticated
  )
import Prodbox.ControlPlane.AuthorityObservationEndpoint
  ( LifecycleAuthorityObservation (observedAuthorityAdmission)
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminProvisionerClient
  , observeAwsAdminFirstReconcile
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminFirstReconcileProjection (..)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (..)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution (TargetAgentIdentity)
import Prodbox.ControlPlane.TargetSecretWorker
  ( decodeTargetWorkerReceipt
  , targetWorkerReceiptCommitment
  , targetWorkerReceiptVaultVersion
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommand (..)
  )
import Prodbox.Lifecycle.Authority.BackupRepair (BackupHealth (..))
import Prodbox.Lifecycle.Authority.BootstrapReconcile
  ( AuthorityBackupReconcileBoundary (..)
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , BackupReceipt (..)
  , BackupRepairPermit (..)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  , authorityEpochValue
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminKubernetesBoundary
  , coordinateAwsAdminProvisioning
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  , awsAdminWorkerReceiptGeneration
  , awsAdminWorkerReceiptRequestDigest
  , awsAdminWorkerReceiptTargetReadBack
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , CredentialIamParameters
  , mkBackupRepairAwsAdminPermitIntent
  , mkBackupRepairFrozenBinding
  , mkBackupRepairFrozenPermit
  , mkGenesisAwsAdminPermitIntent
  , mkNormalAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , FirstReconcilePlanAction (..)
  , FirstReconcilePlanMember
  , OperatorMaterialAction (InstallOperatorMaterial, RotateOperatorMaterial)
  , defaultFirstReconcileProvisioningPlan
  , firstReconcilePlanMemberAction
  , initialFirstReconcileCursor
  , mkAwsOperatorMaterialRequest
  , mkGenesisBackupPermit
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermit
  , mkOperatorMaterialPermitId
  , operatorMaterialOperationIdText
  , operatorMaterialPermitPlanBinding
  , operatorMaterialPermitRequestDigest
  , withGenesisBackupOperatorPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( mkPreparedCredentialTargetObservation
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )
import Prodbox.Settings (Credentials)

copyGenesisAggregateForAdmission
  :: AuthorityBackupExportClient IO
  -> AuthorityAggregateBackupClient IO
  -> GenesisPlan
  -> IO (Either Text BackupReceipt)
copyGenesisAggregateForAdmission exportClient backupClient plan =
  copyPurpose
    exportClient
    backupClient
    (ExportGenesisAggregate (genesisPlanDigest plan))

copyRepairAggregateForAdmission
  :: AuthorityBackupExportClient IO
  -> AuthorityAggregateBackupClient IO
  -> BackupRepairPermit
  -> IO (Either Text BackupReceipt)
copyRepairAggregateForAdmission exportClient backupClient permit =
  copyPurpose
    exportClient
    backupClient
    (ExportRepairAggregate (backupRepairPermitDigest permit))

observeRetainedAuthorityBackupHealth
  :: AuthorityAggregateBackupClient IO
  -> BackupReceipt
  -> IO (Either Text BackupHealth)
observeRetainedAuthorityBackupHealth backupClient (BackupReceipt digest) = do
  observed <- observeAuthorityAggregateBackup backupClient digest
  pure $ case observed of
    Left err -> Left (boundedShow err)
    Right AuthorityAggregateBackupMissing -> Right BackupPositivelyAbsent
    Right (AuthorityAggregateBackupCorrupt _) -> Right BackupPolicyDrift
    Right (AuthorityAggregateBackupCurrent _ _) -> Right BackupHealthy

targetGenerationReceiptFromAwsAdminWorker
  :: AwsAdminWorkerReceipt
  -> Either Text TargetAgentGenerationReceipt
targetGenerationReceiptFromAwsAdminWorker receipt = do
  targetReceipt <-
    either
      (Left . ("target read-back receipt is invalid: " <>) . boundedShow)
      Right
      (decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt))
  pure
    ( TargetAgentGenerationReceipt
        ( Text.intercalate
            ":"
            [ "aws-admin-target-v1"
            , Text.pack (show (credentialGenerationValue (awsAdminWorkerReceiptGeneration receipt)))
            , Text.pack (show (targetWorkerReceiptVaultVersion targetReceipt))
            , targetWorkerReceiptCommitment targetReceipt
            , targetValueDigestText (awsAdminWorkerReceiptRequestDigest receipt)
            ]
        )
    )

retainedTargetGeneration
  :: TargetAgentGenerationReceipt
  -> Either Text Natural
retainedTargetGeneration (TargetAgentGenerationReceipt encoded) =
  case Text.splitOn ":" encoded of
    "aws-admin-target-v1" : rawGeneration : _ ->
      case TextRead.decimal rawGeneration of
        Right (generation, remainder)
          | Text.null remainder && generation > 0 -> Right generation
        _ -> Left "retained target generation receipt is malformed"
    _ -> Left "retained target generation receipt is not a production AWS-admin receipt"

data GenesisAwsAdminIntentParameters = GenesisAwsAdminIntentParameters
  { genesisIntentIamParameters :: !CredentialIamParameters
  , genesisIntentImageDigest :: !Text
  , genesisIntentAuthorityScope :: !Text
  , genesisIntentAuthorityEndpoint :: !Text
  , genesisIntentSelectedAgent :: !TargetAgentIdentity
  , genesisIntentDeadline :: !AuthorityTime
  }

compileGenesisAwsAdminIntent
  :: GenesisAwsAdminIntentParameters
  -> GenesisPlan
  -> Either Text AwsAdminPermitIntent
compileGenesisAwsAdminIntent parameters plan = do
  permitId <- mapShow (mkOperatorMaterialPermitId ("genesis-" <> identityDigest))
  operationId <- mapShow (mkOperatorMaterialOperationId ("genesis-" <> identityDigest))
  generation <- mapShow (mkCredentialGeneration 1)
  genesisPermit <-
    mapShow
      ( mkGenesisBackupPermit
          plan
          firstPlan
          (initialFirstReconcileCursor firstPlan)
          permitId
          operationId
          generation
          (genesisIntentDeadline parameters)
          "authenticated-genesis-intent-v1"
      )
  withGenesisBackupOperatorPermit genesisPermit $ \operatorPermit -> do
    prepared <-
      mapShow
        ( mkPreparedCredentialTargetObservation
            ("genesis-" <> identityDigest)
            1
            (genesisIntentSelectedAgent parameters)
            (TargetAwsCredential AwsAuthorityBackupStore)
            generation
            (operatorMaterialPermitRequestDigest operatorPermit)
            (operatorMaterialPermitRequestDigest operatorPermit)
            (operatorMaterialPermitPlanBinding operatorPermit)
            (genesisIntentDeadline parameters)
        )
    mapShow
      ( mkGenesisAwsAdminPermitIntent
          genesisPermit
          (genesisIntentIamParameters parameters)
          (genesisIntentImageDigest parameters)
          (genesisIntentAuthorityScope parameters)
          (genesisIntentAuthorityEndpoint parameters)
          prepared
      )
 where
  firstPlan = defaultFirstReconcileProvisioningPlan (genesisIntentDeadline parameters)
  identityDigest = Text.take 48 (digestText (genesisPlanDigest plan))

-- | Compile one non-genesis member of the retained first-reconcile plan. The
-- Lifecycle Authority replaces the provisional plan binding, fence, deadline,
-- and prepared-target receipt from its exact retained journal before signing.
compileFirstReconcileAwsAdminIntent
  :: GenesisAwsAdminIntentParameters
  -> FirstReconcilePlanMember
  -> CredentialIamParameters
  -> Either Text AwsAdminPermitIntent
compileFirstReconcileAwsAdminIntent parameters member iamParameters = do
  credentialClass <- case firstReconcilePlanMemberAction member of
    EstablishAuthorityBackupMember ->
      Left "genesis member zero requires the exceptional genesis compiler"
    ProvisionAwsCredentialMember value -> Right value
  compileFirstReconcileClassIntent
    parameters
    credentialClass
    (genesisIntentDeadline parameters)
    iamParameters

compileFirstReconcileContinuationAwsAdminIntent
  :: GenesisAwsAdminIntentParameters
  -> AwsAdminFirstReconcileProjection
  -> CredentialIamParameters
  -> Either Text AwsAdminPermitIntent
compileFirstReconcileContinuationAwsAdminIntent parameters continuation iamParameters = do
  if awsAdminFirstReconcileMemberIndex continuation == 0
    then Left "post-genesis first-reconcile continuation cannot select member zero"
    else pure ()
  _ <- mapShow (mkTargetValueDigest (awsAdminFirstReconcileMemberDigest continuation))
  compileFirstReconcileClassIntent
    parameters
    (awsAdminFirstReconcileClass continuation)
    (genesisIntentDeadline parameters)
    iamParameters

compileFirstReconcileClassIntent
  :: GenesisAwsAdminIntentParameters
  -> AwsCredentialClass
  -> AuthorityTime
  -> CredentialIamParameters
  -> Either Text AwsAdminPermitIntent
compileFirstReconcileClassIntent parameters credentialClass deadline iamParameters = do
  let identity =
        Text.take
          48
          ( digestText
              ( "first-reconcile-v1:"
                  <> genesisIntentAuthorityScope parameters
                  <> ":"
                  <> Text.pack (show credentialClass)
              )
          )
  permitId <- mapShow (mkOperatorMaterialPermitId ("first-reconcile-" <> identity))
  operationId <- mapShow (mkOperatorMaterialOperationId ("first-reconcile-" <> identity))
  generation <- mapShow (mkCredentialGeneration 1)
  request <-
    mapShow
      ( mkAwsOperatorMaterialRequest
          credentialClass
          InstallOperatorMaterial
          operationId
          generation
      )
  permit <-
    mapShow
      ( mkOperatorMaterialPermit
          permitId
          request
          deadline
          Nothing
          "authenticated-first-reconcile-intent-v1"
      )
  prepared <-
    mapShow
      ( mkPreparedCredentialTargetObservation
          ("first-reconcile-" <> identity)
          1
          (genesisIntentSelectedAgent parameters)
          (awsCredentialTarget credentialClass)
          generation
          (operatorMaterialPermitRequestDigest permit)
          (operatorMaterialPermitRequestDigest permit)
          Nothing
          deadline
      )
  mapShow
    ( mkNormalAwsAdminPermitIntent
        permit
        iamParameters
        (genesisIntentImageDigest parameters)
        (genesisIntentAuthorityScope parameters)
        (genesisIntentAuthorityEndpoint parameters)
        prepared
    )

-- | A retry-stable operation coordinate for one ordinary credential action.
-- The action is deliberately absent from the coordinate: after a Target write
-- and response loss, observing the now-present generation must recover the
-- original install operation rather than derive a different rotate operation.
normalAwsAdminOperationIdForScope
  :: Text
  -> AwsCredentialClass
  -> Natural
  -> Either Text Text
normalAwsAdminOperationIdForScope operationScope credentialClass generation = do
  _ <- mapShow (mkCredentialGeneration generation)
  operationId <-
    mapShow
      ( mkOperatorMaterialOperationId
          ("normal-" <> operationIdentity operationScope credentialClass generation)
      )
  pure (operatorMaterialOperationIdText operationId)

-- | Compile one normal post-genesis Credential Provisioner request. The
-- retained Authority replaces the draft owner/fence with its current exact
-- admission context before it signs anything. A stable caller scope plus
-- generation makes retries recover the same operation and lets a later cycle
-- select the next generation without sharing an allocator.
compileNormalAwsAdminIntentForScope
  :: GenesisAwsAdminIntentParameters
  -> Text
  -> AwsCredentialClass
  -> OperatorMaterialAction
  -> Natural
  -> CredentialIamParameters
  -> Either Text AwsAdminPermitIntent
compileNormalAwsAdminIntentForScope parameters operationScope credentialClass action generationValue iamParameters = do
  let identity = operationIdentity operationScope credentialClass generationValue
  permitId <- mapShow (mkOperatorMaterialPermitId ("normal-" <> identity))
  operationId <- mapShow (mkOperatorMaterialOperationId ("normal-" <> identity))
  generation <- mapShow (mkCredentialGeneration generationValue)
  request <-
    mapShow
      ( mkAwsOperatorMaterialRequest
          credentialClass
          action
          operationId
          generation
      )
  permit <-
    mapShow
      ( mkOperatorMaterialPermit
          permitId
          request
          (genesisIntentDeadline parameters)
          Nothing
          "authenticated-normal-intent-v1"
      )
  prepared <-
    mapShow
      ( mkPreparedCredentialTargetObservation
          ("normal-" <> identity)
          1
          (genesisIntentSelectedAgent parameters)
          (awsCredentialTarget credentialClass)
          generation
          (operatorMaterialPermitRequestDigest permit)
          (operatorMaterialPermitRequestDigest permit)
          Nothing
          (genesisIntentDeadline parameters)
      )
  mapShow
    ( mkNormalAwsAdminPermitIntent
        permit
        iamParameters
        (genesisIntentImageDigest parameters)
        (genesisIntentAuthorityScope parameters)
        (genesisIntentAuthorityEndpoint parameters)
        prepared
    )

operationIdentity :: Text -> AwsCredentialClass -> Natural -> Text
operationIdentity operationScope credentialClass generation =
  Text.take
    48
    ( digestText
        ( Text.intercalate
            ":"
            [ "normal-aws-admin-v1"
            , operationScope
            , Text.pack (show credentialClass)
            , Text.pack (show generation)
            ]
        )
    )

reconcileRemainingFirstReconcileCredentials
  :: AwsAdminProvisionerClient IO
  -> AwsAdminKubernetesBoundary IO
  -> IO (Either Text Credentials)
  -> GenesisAwsAdminIntentParameters
  -> (Credentials -> AwsCredentialClass -> IO (Either Text CredentialIamParameters))
  -> IO (Either Text ())
reconcileRemainingFirstReconcileCredentials provisionerClient kubernetes loadCredentials parameters resolveIam =
  reconcileRemainingFirstReconcileCredentialsWith
    (mapError <$> observeAwsAdminFirstReconcile provisionerClient)
    loadCredentials
    parameters
    resolveIam
    coordinate
 where
  mapError = either (Left . boundedShow) Right
  coordinate credentials intent = do
    coordinated <-
      coordinateAwsAdminProvisioning
        provisionerClient
        kubernetes
        credentials
        intent
    pure (either (Left . boundedShow) (const (Right ())) coordinated)

reconcileRemainingFirstReconcileCredentialsWith
  :: IO (Either Text (Maybe AwsAdminFirstReconcileProjection))
  -> IO (Either Text Credentials)
  -> GenesisAwsAdminIntentParameters
  -> (Credentials -> AwsCredentialClass -> IO (Either Text CredentialIamParameters))
  -> (Credentials -> AwsAdminPermitIntent -> IO (Either Text ()))
  -> IO (Either Text ())
reconcileRemainingFirstReconcileCredentialsWith observeContinuation loadCredentials parameters resolveIam coordinate =
  go (8 :: Int)
 where
  go remaining
    | remaining <= 0 = pure (Left "first-reconcile continuation exceeded its finite member bound")
    | otherwise = do
        observed <- observeContinuation
        case observed of
          Left detail -> pure (Left detail)
          Right Nothing -> pure (Right ())
          Right (Just continuation) -> do
            credentials <- loadCredentials
            case credentials of
              Left detail -> pure (Left detail)
              Right value -> do
                iamResult <- resolveIam value (awsAdminFirstReconcileClass continuation)
                case iamResult
                  >>= compileFirstReconcileContinuationAwsAdminIntent
                    parameters
                    continuation of
                  Left detail -> pure (Left detail)
                  Right intent -> do
                    coordinated <- coordinate value intent
                    case coordinated of
                      Left detail -> pure (Left detail)
                      Right () -> go (remaining - 1)

awsCredentialTarget :: AwsCredentialClass -> TargetSecretId
awsCredentialTarget credentialClass = case credentialClass of
  LifecycleProviderCredential -> TargetAwsCredential AwsLifecycleProvider
  AuthorityBackupStoreCredential -> TargetAwsCredential AwsAuthorityBackupStore
  TlsRetentionStoreCredential -> TargetAwsCredential AwsTlsRetentionStore
  GatewayDnsCredential -> TargetAwsCredential AwsGatewayDns
  HomeCertManagerDns01Credential -> TargetAwsCredential AwsHomeCertManagerDns01
  AwsRunCertManagerDns01Credential -> TargetAwsCredential AwsRunCertManagerDns01
  SesSmtpRetainedCustodyCredential -> TargetSesSmtp

compileBackupRepairPermit
  :: Text
  -> AuthorityEpoch
  -> TargetAgentGenerationReceipt
  -> BackupReceipt
  -> BackupRepairPermit
compileBackupRepairPermit coordinate epoch generation previousBackup =
  BackupRepairPermit
    { backupRepairPermitDigest =
        digestText
          ( Text.intercalate
              ":"
              [ "authority-backup-repair-v1"
              , Text.pack (show (authorityEpochValue epoch))
              , retainedGenerationText generation
              , backupReceiptText previousBackup
              , coordinate
              ]
          )
    , backupRepairPermitBackupStoreCoordinate = coordinate
    , backupRepairPermitAuthorityEpoch = epoch
    , backupRepairPermitLostGeneration = generation
    , backupRepairPermitPreviousBackup = previousBackup
    }

compileRepairAwsAdminIntent
  :: GenesisAwsAdminIntentParameters
  -> BackupRepairPermit
  -> Either Text AwsAdminPermitIntent
compileRepairAwsAdminIntent parameters permit = do
  lostGeneration <- retainedTargetGeneration (backupRepairPermitLostGeneration permit)
  lostCredentialGeneration <- mapShow (mkCredentialGeneration lostGeneration)
  nextGeneration <- mapShow (mkCredentialGeneration (lostGeneration + 1))
  planDigest <- mapShow (mkTargetValueDigest (backupRepairPermitDigest permit))
  observationDigest <-
    mapShow
      (mkTargetValueDigest (backupReceiptText (backupRepairPermitPreviousBackup permit)))
  binding <-
    mapShow
      ( mkBackupRepairFrozenBinding
          (authorityEpochValue (backupRepairPermitAuthorityEpoch permit))
          planDigest
          observationDigest
          lostCredentialGeneration
      )
  permitId <- mapShow (mkOperatorMaterialPermitId ("repair-" <> identityDigest))
  operationId <- mapShow (mkOperatorMaterialOperationId ("repair-" <> identityDigest))
  request <-
    mapShow
      ( mkAwsOperatorMaterialRequest
          AuthorityBackupStoreCredential
          RotateOperatorMaterial
          operationId
          nextGeneration
      )
  operatorPermit <-
    mapShow
      ( mkOperatorMaterialPermit
          permitId
          request
          (genesisIntentDeadline parameters)
          Nothing
          "authenticated-repair-intent-v1"
      )
  repairPermit <- mapShow (mkBackupRepairFrozenPermit binding operatorPermit)
  prepared <-
    mapShow
      ( mkPreparedCredentialTargetObservation
          ("repair-" <> identityDigest)
          (authorityEpochValue (backupRepairPermitAuthorityEpoch permit) + 1)
          (genesisIntentSelectedAgent parameters)
          (TargetAwsCredential AwsAuthorityBackupStore)
          nextGeneration
          (operatorMaterialPermitRequestDigest operatorPermit)
          (operatorMaterialPermitRequestDigest operatorPermit)
          (operatorMaterialPermitPlanBinding operatorPermit)
          (genesisIntentDeadline parameters)
      )
  mapShow
    ( mkBackupRepairAwsAdminPermitIntent
        repairPermit
        (genesisIntentIamParameters parameters)
        (genesisIntentImageDigest parameters)
        (genesisIntentAuthorityScope parameters)
        (genesisIntentAuthorityEndpoint parameters)
        prepared
    )
 where
  identityDigest = Text.take 48 (backupRepairPermitDigest permit)

retainedGenerationText :: TargetAgentGenerationReceipt -> Text
retainedGenerationText (TargetAgentGenerationReceipt value) = value

backupReceiptText :: BackupReceipt -> Text
backupReceiptText (BackupReceipt value) = value

productionAuthorityBackupReconcileBoundary
  :: Text
  -> Text
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityControlClient IO
  -> AuthorityBackupExportClient IO
  -> AuthorityAggregateBackupClient IO
  -> AwsAdminProvisionerClient IO
  -> AwsAdminKubernetesBoundary IO
  -> IO (Either Text Credentials)
  -> GenesisAwsAdminIntentParameters
  -> AuthorityBackupReconcileBoundary IO
productionAuthorityBackupReconcileBoundary
  authorityScope
  backupCoordinate
  authorityTransport
  controlClient
  exportClient
  backupClient
  provisionerClient
  kubernetes
  loadCredentials
  intentParameters =
    AuthorityBackupReconcileBoundary
      { observeAuthorityAdmissionState = do
          observed <-
            observeLifecycleAuthorityAuthenticated authorityTransport authorityScope
          pure $ do
            projection <- either (Left . boundedShow) Right observed
            maybe
              (Left "Lifecycle Authority omitted its retained admission projection")
              Right
              (observedAuthorityAdmission projection)
      , submitAuthorityAdmissionControl = submitControl
      , compileGenesisPlan = pure (Right genesisPlan)
      , establishGenesisTargetGeneration = establishGenesis
      , copyGenesisAuthorityBackup =
          copyGenesisAggregateForAdmission exportClient backupClient
      , observeAuthorityBackupHealth =
          observeRetainedAuthorityBackupHealth backupClient
      , mintAuthorityBackupRepairPermit = \epoch generation receipt ->
          pure
            ( Right
                (compileBackupRepairPermit backupCoordinate epoch generation receipt)
            )
      , establishRepairTargetGeneration = establishRepair
      , copyRepairedAuthorityBackup =
          copyRepairAggregateForAdmission exportClient backupClient
      }
   where
    genesisPlan =
      GenesisPlan
        { genesisPlanDigest =
            digestText ("authority-backup-genesis-v1:" <> backupCoordinate)
        , genesisPlanBackupStoreCoordinate = backupCoordinate
        }
    submitControl command = case controlPayload command of
      Left detail -> pure (Left detail)
      Right payload ->
        either (Left . boundedShow) (const (Right ()))
          <$> submitAuthorityControl controlClient payload
    establishGenesis plan =
      establishCompiled (compileGenesisAwsAdminIntent intentParameters plan)
    establishRepair permit =
      establishCompiled (compileRepairAwsAdminIntent intentParameters permit)
    establishCompiled compiled = case compiled of
      Left detail -> pure (Left detail)
      Right intent -> do
        provisioned <- coordinate intent
        pure (provisioned >>= targetGenerationReceiptFromAwsAdminWorker)
    coordinate intent = do
      loaded <- loadCredentials
      case loaded of
        Left detail -> pure (Left detail)
        Right credentials ->
          either (Left . boundedShow) Right
            <$> coordinateAwsAdminProvisioning
              provisionerClient
              kubernetes
              credentials
              intent

controlPayload :: AuthorityAdmissionCommand -> Either Text AuthorityControlPayload
controlPayload command = case command of
  ApplyAuthorityGenesis genesis -> Right (AuthorityControlGenesis genesis)
  ApplyAuthorityBackupRepair repair -> Right (AuthorityControlBackupRepair repair)
  BeginAuthorityMigration -> Left "backup reconciler cannot begin migration"
  ApplyAuthorityMigration _ -> Left "backup reconciler cannot apply migration"
  ApplyAuthorityMigrationImport _ -> Left "backup reconciler cannot import migration"
  ApplyAuthorityForwardMigration _ -> Left "backup reconciler cannot forward migration"
  BindProviderAdmissionGeneration _ ->
    Left "backup reconciler cannot bind the Provider admission generation"
  FreezeProviderAdmissionForCascadeAudit _ ->
    Left "backup reconciler cannot freeze Provider admission for the Cascade audit"
  RecordCascadeTerminalAuditReceipt _ _ ->
    Left "backup reconciler cannot record the Cascade terminal-audit receipt"
  RevokeCascadeProviderCredential _ _ ->
    Left "backup reconciler cannot revoke the Cascade Provider credential"

mapShow :: (Show err) => Either err value -> Either Text value
mapShow = either (Left . boundedShow) Right

digestText :: Text -> Text
digestText =
  Text.pack
    . concatMap byteHex
    . ByteString.unpack
    . SHA256.hash
    . TextEncoding.encodeUtf8
 where
  byteHex byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered

copyPurpose
  :: AuthorityBackupExportClient IO
  -> AuthorityAggregateBackupClient IO
  -> AuthorityBackupExportPurpose
  -> IO (Either Text BackupReceipt)
copyPurpose exportClient backupClient purpose = do
  exported <- exportAuthorityBackupAggregate exportClient purpose
  case exported of
    Left err -> pure (Left (boundedShow err))
    Right envelope -> do
      copied <- copyAuthorityAggregateBackup backupClient envelope
      pure
        ( BackupReceipt . authorityBackupDigestText . authorityBackupReceiptDigest
            <$> either (Left . boundedShow) Right copied
        )

boundedShow :: (Show value) => value -> Text
boundedShow = Text.take 4096 . Text.pack . show
