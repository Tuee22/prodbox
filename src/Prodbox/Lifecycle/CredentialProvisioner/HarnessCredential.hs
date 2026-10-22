{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-free identities and recovery decisions for the harness's one
-- Operational credential. A new invocation has a fresh lineage, including
-- when it resumes an older cleanup run. Both slots are stable within it; the
-- revoke slot never depends on whether the Target survived its last attempt.
module Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
  ( HarnessCredentialLineage
  , HarnessCredentialLineageError (..)
  , mkHarnessCredentialLineage
  , HarnessCredentialSlot (..)
  , harnessCredentialSlotScope
  , harnessCredentialSlotOperationId
  , HarnessCredentialResolution (..)
  , HarnessCredentialResolutionError (..)
  , resolveHarnessCredentialSlot
  , resolveHarnessCredentialSubmission
  , resumePendingHarnessCredentialOperation
  , reconcileFirstReconcileProviderRecovery
  , compileHarnessCredentialCleanupChild
  , confirmHarnessCredentialReceipt
  , HarnessCredentialConfirmation
  , confirmHarnessCredentialOutcome
  , harnessCredentialConfirmationGeneration
  , HarnessCredentialRevocationEvidence
  , confirmHarnessCredentialRevocation
  , harnessCredentialRevocationOperationId
  , harnessCredentialRevocationReceipt
  , harnessCredentialRevocationEpochReceipt
  )
where

import Control.Monad (unless, void)
import Data.Bifunctor (first)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  , compileNormalAwsAdminIntentForScope
  , normalAwsAdminOperationIdForScope
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError (AwsAdminProvisionerClientRefused)
  , observeAwsAdminProviderCredentialRecoveryView
  , observeAwsAdminProvisioning
  , observeAwsAdminProvisioningMetadata
  , observePendingAwsAdminProviderCredentialOperation
  , settleAwsAdminFirstReconcileRecovery
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminProvisionerChallenge (..)
  , AwsAdminProvisionerObservation (..)
  , AwsAdminProvisionerPhase (AwsAdminProvisionerAuthorized, AwsAdminProvisionerCompleted)
  )
import Prodbox.ControlPlane.TargetMaterialClient (targetWorkerReceiptFromMaterialObservation)
import Prodbox.ControlPlane.TargetMaterialEndpoint (TargetMaterialObservation (..))
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.ControlPlane.TargetSecretWorker (decodeTargetWorkerReceipt)
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderAdmissionEpochError
  , ProviderCredentialRecoveryView (..)
  , ProviderCredentialRevocationReceipt
  , mkProviderCredentialMutationReservation
  , mkProviderCredentialRevocationReceipt
  , providerCredentialCleanupOperationId
  )
import Prodbox.Lifecycle.CleanupRun (cleanupDigestOfBytes)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  , AwsAdminWorkerReceiptKind (AwsAdminInstalled, AwsAdminRevoked)
  , awsAdminWorkerReceiptGeneration
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptPermitId
  , awsAdminWorkerReceiptRequestDigest
  , awsAdminWorkerReceiptTarget
  , awsAdminWorkerReceiptTargetReadBack
  , decodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceipt
  , validateAwsAdminWorkerReceiptForPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , CredentialIamParameters
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitIntentTarget
  , decodeAwsAdminPermitIntent
  , decodeSignedAwsAdminPermit
  , mkNormalAwsAdminPermitIntent
  , renewAwsAdminProviderPermitIntent
  , signedAwsAdminPermitIntent
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , OperatorMaterialAction (..)
  , mkAwsOperatorMaterialRequest
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermit
  , mkOperatorMaterialPermitId
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  , operatorMaterialPermitRequestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( mkPreparedCredentialTargetObservation
  )
import Prodbox.Lifecycle.CredentialProvisioner.ProviderRolePolicyOperationScope
  ( providerRolePolicyOperationScope
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (credentialGenerationValue, mkCredentialGeneration)

newtype HarnessCredentialLineage = HarnessCredentialLineage Text
  deriving stock (Eq, Show)

data HarnessCredentialLineageError
  = HarnessCredentialSuiteInvalid
  | HarnessCredentialNonceInvalid
  deriving stock (Eq, Show)

-- | The caller obtains fresh 256-bit entropy at the command boundary. Tests
-- supply deterministic bytes; suite/substrate identity remains explicit.
mkHarnessCredentialLineage
  :: Text -> ByteString -> Either HarnessCredentialLineageError HarnessCredentialLineage
mkHarnessCredentialLineage suite nonce = do
  unless
    ( not (Text.null suite)
        && Text.length suite <= 256
        && Text.strip suite == suite
        && not (Text.any isControl suite)
    )
    (Left HarnessCredentialSuiteInvalid)
  unless (ByteString.length nonce == 32) (Left HarnessCredentialNonceInvalid)
  pure
    ( HarnessCredentialLineage
        ("test-harness:" <> suite <> ":" <> TextEncoding.decodeUtf8 (convertToBase Base16 nonce))
    )

data HarnessCredentialSlot = HarnessCredentialInstall | HarnessCredentialRevoke
  deriving stock (Eq, Show)

harnessCredentialSlotScope :: HarnessCredentialLineage -> HarnessCredentialSlot -> Text
harnessCredentialSlotScope (HarnessCredentialLineage lineage) slot =
  providerRolePolicyOperationScope
    ( lineage <> case slot of
        HarnessCredentialInstall -> ":install"
        HarnessCredentialRevoke -> ":revoke"
    )

-- | The slot coordinate uses a fixed index. The actual Target generation is
-- carried by the intent, so losing the Target cannot change this lookup key.
harnessCredentialSlotOperationId
  :: HarnessCredentialLineage -> HarnessCredentialSlot -> Either Text Text
harnessCredentialSlotOperationId lineage slot =
  normalAwsAdminOperationIdForScope
    (harnessCredentialSlotScope lineage slot)
    LifecycleProviderCredential
    1

data HarnessCredentialResolution
  = SubmitHarnessCredentialIntent !AwsAdminPermitIntent
  | HarnessCredentialRevocationAlreadyProven !AwsAdminWorkerReceipt
  | RepairHarnessCredentialTarget !AwsAdminPermitIntent
  deriving stock (Eq, Show)

data HarnessCredentialResolutionError
  = HarnessCredentialOperationInvalid
  | HarnessCredentialObservationUnavailable
  | HarnessCredentialRetainedIntentInvalid
  | HarnessCredentialForeignOperation
  | HarnessCredentialClassMismatch
  | HarnessCredentialActionMismatch
  | HarnessCredentialIamParametersMismatch
  | HarnessCredentialTargetGenerationMismatch
  | HarnessCredentialCompletedReceiptInvalid
  | HarnessCredentialCompletedReceiptKindMismatch
  | HarnessCredentialInstalledTargetMissing
  | HarnessCredentialRevokedTargetStillPresent
  | HarnessCredentialPendingRecoveryRequired
  | HarnessCredentialAuthorityClosed
  deriving stock (Eq, Show)

-- | Discover the globally reserved operation before selecting a fresh run
-- lineage. The callback uses the same attested coordinator and admin ingress
-- as ordinary provisioning. A renewed draft still requires server-owned
-- expiry, resource-absence and journal evidence.
resumePendingHarnessCredentialOperation
  :: AwsAdminProvisionerClient IO
  -> GenesisAwsAdminIntentParameters
  -> CredentialIamParameters
  -> Maybe TargetMaterialObservation
  -> Natural
  -> (AwsAdminPermitIntent -> IO (Either String ()))
  -> IO (Either String Bool)
resumePendingHarnessCredentialOperation client parameters iam observedTarget now resume = do
  pending <- observePendingAwsAdminProviderCredentialOperation client
  case pending of
    Left cause -> pure (Left ("observe reserved Lifecycle-provider operation: " <> show cause))
    Right Nothing -> pure (Right False)
    Right (Just operationId) -> do
      settled <- observeAwsAdminProvisioning client operationId
      (metadataOnly, observed) <- case settled of
        Right metadata -> pure (False, Right metadata)
        Left _ -> do
          metadata <- observeAwsAdminProvisioningMetadata client operationId
          pure (True, metadata)
      case first
        (\cause -> "observe reserved operation " <> Text.unpack operationId <> ": " <> show cause)
        observed
        >>= retainedIntent metadataOnly operationId of
        Left detail -> pure (Left detail)
        Right intent -> (True <$) <$> resume intent
 where
  retainedIntent metadataOnly operationId observation = do
    intent <-
      first
        show
        ( decodeAwsAdminPermitIntent
            (awsAdminChallengeCanonicalIntent (awsAdminObservedChallenge observation))
        )
    unless
      ( operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent) == operationId
          && awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential
          && awsAdminPermitIntentTarget intent == operationalTarget
          && awsAdminPermitIntentIamParameters intent == iam
      )
      ( Left
          ("reserved Lifecycle-provider operation has different coordinates: " <> Text.unpack operationId)
      )
    if ( awsAdminObservedPhase observation == AwsAdminProvisionerAuthorized
           || (metadataOnly && awsAdminObservedPhase observation == AwsAdminProvisionerCompleted)
       )
      && authorityTimeMicros (awsAdminPermitIntentDeadline intent) <= now
      && awsAdminPermitIntentAction intent /= RevokeOperatorMaterial
      then first show (compileHarnessCredentialCleanupChild parameters intent observedTarget)
      else
        if awsAdminObservedPhase observation == AwsAdminProvisionerCompleted
          || authorityTimeMicros (awsAdminPermitIntentDeadline intent) > now
          then Right intent
          else
            first
              show
              ( renewAwsAdminProviderPermitIntent
                  (genesisIntentDeadline parameters)
                  (genesisIntentImageDigest parameters)
                  (genesisIntentSelectedAgent parameters)
                  intent
              )

-- | Called only while the retained first-reconcile recovery marker is pending.
-- The member loop may already be complete: an interrupted cleanup/reinstall
-- still has to finish before that marker can be settled.
reconcileFirstReconcileProviderRecovery
  :: AwsAdminProvisionerClient IO
  -> GenesisAwsAdminIntentParameters
  -> CredentialIamParameters
  -> IO (Either String (Maybe TargetMaterialObservation))
  -> IO Natural
  -> (AwsAdminPermitIntent -> IO (Either String AwsAdminWorkerReceipt))
  -> IO (Either String ())
  -> IO (Either String ())
reconcileFirstReconcileProviderRecovery client parameters iam observeTarget observeNow coordinate continueMembers = do
  initial <- observeTarget
  case initial of
    Left detail -> pure (Left detail)
    Right metadata -> do
      now <- observeNow
      resumed <-
        resumePendingHarnessCredentialOperation
          client
          parameters
          iam
          metadata
          now
          (fmap void . coordinate)
      case resumed of
        Left detail -> pure (Left detail)
        Right _ -> do
          repaired <- ensureProvider (2 :: Int)
          case repaired of
            Left detail -> pure (Left detail)
            Right () -> do
              continued <- continueMembers
              case continued of
                Left detail -> pure (Left detail)
                Right () -> first show <$> settleAwsAdminFirstReconcileRecovery client
 where
  ensureProvider remaining = do
    observed <- observeTarget
    recovery <- observeAwsAdminProviderCredentialRecoveryView client
    case (observed, recovery) of
      (Left detail, _) -> pure (Left detail)
      (_, Left cause) -> pure (Left (show cause))
      (Right metadata, Right view) -> case view of
        ProviderCredentialRecoveryIdle -> pure (Right ())
        ProviderCredentialRecoveryServing _ _ | metadata /= Nothing -> pure (Right ())
        ProviderCredentialRecoveryServing generation scope ->
          submit remaining ("credential-target-repair/" <> scope) RevokeOperatorMaterial generation
        ProviderCredentialRecoveryRetired _ scope
          | metadata == Nothing ->
              submit remaining ("first-reconcile-reinstall/" <> scope) InstallOperatorMaterial 1
          | otherwise -> pure (Left "retired Provider credential still has a Target generation")
        ProviderCredentialRecoveryPending _ -> pure (Left "Provider recovery remains pending after one reserved-operation resume")
        ProviderCredentialRecoveryClosed -> pure (Left "Provider credential authority is frozen")
        ProviderCredentialRecoveryRevoked -> pure (Left "first-reconcile recovery cannot replace a cascade-revoked predecessor")
        ProviderCredentialRecoveryRecorded _ -> pure (Left "Provider credential authority has recorded its cascade audit")
  submit remaining scope action generation
    | remaining <= 0 = pure (Left "first-reconcile Provider recovery exceeded its finite repair bound")
    | otherwise = case compileNormalAwsAdminIntentForScope
        parameters
        scope
        LifecycleProviderCredential
        action
        generation
        iam of
        Left detail -> pure (Left (Text.unpack detail))
        Right intent -> do
          coordinated <- coordinate intent
          case coordinated of
            Left detail -> pure (Left detail)
            Right receipt
              | not (receiptMatches intent receipt) ->
                  pure (Left "first-reconcile Provider recovery returned a foreign receipt")
              | otherwise -> do
                  fresh <- observeTarget
                  case fresh >>= first show . confirmHarnessCredentialOutcome receipt of
                    Left detail -> pure (Left detail)
                    Right _ -> ensureProvider (remaining - 1)
  receiptMatches intent receipt =
    awsAdminWorkerReceiptPermitId receipt
      == operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
      && awsAdminWorkerReceiptRequestDigest receipt == awsAdminPermitIntentRequestDigest intent
      && awsAdminWorkerReceiptTarget receipt == operationalTarget
      && awsAdminWorkerReceiptGeneration receipt == awsAdminPermitIntentGeneration intent
      && awsAdminWorkerReceiptKind receipt == case awsAdminPermitIntentAction intent of
        RevokeOperatorMaterial -> AwsAdminRevoked
        InstallOperatorMaterial -> AwsAdminInstalled
        RotateOperatorMaterial -> AwsAdminInstalled

-- | One deterministic revoke-only child. The server independently checks its
-- parent, expiry, workload absence, scope and exact observed generation.
compileHarnessCredentialCleanupChild
  :: GenesisAwsAdminIntentParameters
  -> AwsAdminPermitIntent
  -> Maybe TargetMaterialObservation
  -> Either Text AwsAdminPermitIntent
compileHarnessCredentialCleanupChild parameters parent observed = do
  unless
    ( awsAdminPermitIntentCredentialClass parent == LifecycleProviderCredential
        && genesisIntentAuthorityScope parameters == awsAdminPermitIntentAuthorityScope parent
        && genesisIntentAuthorityEndpoint parameters == awsAdminPermitIntentAuthorityEndpoint parent
    )
    (Left "cleanup parent differs from the configured Lifecycle-provider authority")
  reservation <-
    first
      (Text.pack . show)
      ( mkProviderCredentialMutationReservation
          (awsAdminPermitIntentAction parent)
          (awsAdminPermitIntentOperationId parent)
          (awsAdminPermitIntentGeneration parent)
          (awsAdminPermitIntentRequestDigest parent)
      )
  operation <- providerCredentialCleanupOperationId reservation
  let ceilingGeneration = credentialGenerationValue (awsAdminPermitIntentGeneration parent)
      actualGeneration = maybe ceilingGeneration targetMaterialObservedGeneration observed
      operationText = operatorMaterialOperationIdText operation
      deadline = genesisIntentDeadline parameters
  unless
    (actualGeneration <= ceilingGeneration)
    (Left "cleanup Target generation exceeds the parent reservation")
  generation <- first (Text.pack . show) (mkCredentialGeneration actualGeneration)
  permitId <- first (Text.pack . show) (mkOperatorMaterialPermitId operationText)
  request <-
    first
      (Text.pack . show)
      (mkAwsOperatorMaterialRequest LifecycleProviderCredential RevokeOperatorMaterial operation generation)
  permit <-
    first
      (Text.pack . show)
      (mkOperatorMaterialPermit permitId request deadline Nothing "authenticated-provider-cleanup-v1")
  prepared <-
    first
      (Text.pack . show)
      ( mkPreparedCredentialTargetObservation
          operationText
          1
          (genesisIntentSelectedAgent parameters)
          operationalTarget
          generation
          (operatorMaterialPermitRequestDigest permit)
          (operatorMaterialPermitRequestDigest permit)
          Nothing
          deadline
      )
  first
    (Text.pack . show)
    ( mkNormalAwsAdminPermitIntent
        permit
        (awsAdminPermitIntentIamParameters parent)
        (genesisIntentImageDigest parameters)
        (genesisIntentAuthorityScope parameters)
        (genesisIntentAuthorityEndpoint parameters)
        prepared
    )

resolveHarnessCredentialSlot
  :: AwsAdminProvisionerClient IO
  -> GenesisAwsAdminIntentParameters
  -> CredentialIamParameters
  -> HarnessCredentialLineage
  -> HarnessCredentialSlot
  -> Maybe TargetMaterialObservation
  -> Natural
  -> IO (Either HarnessCredentialResolutionError HarnessCredentialResolution)
resolveHarnessCredentialSlot client parameters iam lineage slot observed now =
  case harnessCredentialSlotOperationId lineage slot of
    Left _ -> pure (Left HarnessCredentialOperationInvalid)
    Right operationId -> do
      retained <- observeAwsAdminProvisioning client operationId
      case retained of
        Left (AwsAdminProvisionerClientRefused "operation-not-found") ->
          do
            hint <- observeAwsAdminProviderCredentialRecoveryView client
            pure $ case hint of
              Left _ -> Left HarnessCredentialObservationUnavailable
              Right view -> freshResolution view
        Left _ -> pure (Left HarnessCredentialObservationUnavailable)
        Right observation -> pure (resolveRetained operationId observation)
 where
  freshResolution view = case view of
    ProviderCredentialRecoveryClosed -> Left HarnessCredentialAuthorityClosed
    ProviderCredentialRecoveryRevoked
      | slot == HarnessCredentialInstall -> fresh Nothing
      | otherwise -> Left HarnessCredentialAuthorityClosed
    ProviderCredentialRecoveryRecorded generation
      | slot == HarnessCredentialRevoke -> fresh (Just generation)
      | otherwise -> Left HarnessCredentialAuthorityClosed
    ProviderCredentialRecoveryPending _ -> Left HarnessCredentialPendingRecoveryRequired
    ProviderCredentialRecoveryServing generation scope
      | slot == HarnessCredentialInstall && observed == Nothing ->
          RepairHarnessCredentialTarget
            <$> first
              (const HarnessCredentialOperationInvalid)
              ( compileNormalAwsAdminIntentForScope
                  parameters
                  ("credential-target-repair/" <> scope)
                  LifecycleProviderCredential
                  RevokeOperatorMaterial
                  generation
                  iam
              )
    ProviderCredentialRecoveryServing generation _ -> fresh (Just generation)
    ProviderCredentialRecoveryRetired generation _ -> fresh (Just generation)
    ProviderCredentialRecoveryIdle -> fresh Nothing
  fresh generation = SubmitHarnessCredentialIntent <$> freshIntent parameters iam lineage slot observed generation
  resolveRetained operationId observation = do
    let challenge = awsAdminObservedChallenge observation
    intent <-
      first
        (const HarnessCredentialRetainedIntentInvalid)
        (decodeAwsAdminPermitIntent (awsAdminChallengeCanonicalIntent challenge))
    unless
      ( awsAdminChallengeOperationId challenge == operationId
          && operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent) == operationId
      )
      (Left HarnessCredentialForeignOperation)
    unless
      ( awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential
          && awsAdminPermitIntentTarget intent == operationalTarget
      )
      (Left HarnessCredentialClassMismatch)
    unless
      (actionBelongsToSlot slot (awsAdminPermitIntentAction intent))
      (Left HarnessCredentialActionMismatch)
    unless
      (awsAdminPermitIntentIamParameters intent == iam)
      (Left HarnessCredentialIamParametersMismatch)
    if awsAdminObservedPhase observation == AwsAdminProvisionerCompleted
      then resolveCompleted slot observed observation intent
      else do
        validateUnfinishedGeneration slot observed intent
        submitted <-
          if authorityTimeMicros (awsAdminPermitIntentDeadline intent) > now
            then Right intent
            else
              compileIntent
                parameters
                iam
                lineage
                slot
                (awsAdminPermitIntentAction intent)
                (credentialGenerationValue (awsAdminPermitIntentGeneration intent))
        pure (SubmitHarnessCredentialIntent submitted)

actionBelongsToSlot :: HarnessCredentialSlot -> OperatorMaterialAction -> Bool
actionBelongsToSlot slot action = case (slot, action) of
  (HarnessCredentialInstall, InstallOperatorMaterial) -> True
  (HarnessCredentialInstall, RotateOperatorMaterial) -> True
  (HarnessCredentialInstall, RevokeOperatorMaterial) -> False
  (HarnessCredentialRevoke, InstallOperatorMaterial) -> False
  (HarnessCredentialRevoke, RotateOperatorMaterial) -> False
  (HarnessCredentialRevoke, RevokeOperatorMaterial) -> True

freshIntent
  :: GenesisAwsAdminIntentParameters
  -> CredentialIamParameters
  -> HarnessCredentialLineage
  -> HarnessCredentialSlot
  -> Maybe TargetMaterialObservation
  -> Maybe Natural
  -> Either HarnessCredentialResolutionError AwsAdminPermitIntent
freshIntent parameters iam lineage slot observed retainedGeneration =
  let (action, generation) = case (slot, observed) of
        (HarnessCredentialInstall, Nothing) -> (InstallOperatorMaterial, 1)
        (HarnessCredentialInstall, Just metadata) -> (RotateOperatorMaterial, targetMaterialObservedGeneration metadata + 1)
        (HarnessCredentialRevoke, Nothing) -> (RevokeOperatorMaterial, maybe 1 id retainedGeneration)
        (HarnessCredentialRevoke, Just metadata) -> (RevokeOperatorMaterial, targetMaterialObservedGeneration metadata)
   in compileIntent parameters iam lineage slot action generation

compileIntent
  :: GenesisAwsAdminIntentParameters
  -> CredentialIamParameters
  -> HarnessCredentialLineage
  -> HarnessCredentialSlot
  -> OperatorMaterialAction
  -> Natural
  -> Either HarnessCredentialResolutionError AwsAdminPermitIntent
compileIntent parameters iam lineage slot action generationValue = first (const HarnessCredentialOperationInvalid) $ do
  identity <- harnessCredentialSlotOperationId lineage slot
  operation <- mapShow (mkOperatorMaterialOperationId identity)
  permitId <- mapShow (mkOperatorMaterialPermitId identity)
  generation <- mapShow (mkCredentialGeneration generationValue)
  request <-
    mapShow (mkAwsOperatorMaterialRequest LifecycleProviderCredential action operation generation)
  permit <-
    mapShow
      ( mkOperatorMaterialPermit
          permitId
          request
          (genesisIntentDeadline parameters)
          Nothing
          "authenticated-harness-credential-v1"
      )
  prepared <-
    mapShow
      ( mkPreparedCredentialTargetObservation
          identity
          1
          (genesisIntentSelectedAgent parameters)
          operationalTarget
          generation
          (operatorMaterialPermitRequestDigest permit)
          (operatorMaterialPermitRequestDigest permit)
          Nothing
          (genesisIntentDeadline parameters)
      )
  mapShow
    ( mkNormalAwsAdminPermitIntent
        permit
        iam
        (genesisIntentImageDigest parameters)
        (genesisIntentAuthorityScope parameters)
        (genesisIntentAuthorityEndpoint parameters)
        prepared
    )
 where
  mapShow :: (Show err) => Either err value -> Either Text value
  mapShow = first (Text.pack . show)

-- | At most one serving repair precedes the invocation's ordinary slot.
-- The real coordinator receipt and a subsequent Agent absence read both
-- precede resolving the fresh install. A second repair request fails closed.
resolveHarnessCredentialSubmission
  :: (Maybe TargetMaterialObservation -> IO (Either String HarnessCredentialResolution))
  -> (AwsAdminPermitIntent -> IO (Either String AwsAdminWorkerReceipt))
  -> IO (Either String (Maybe TargetMaterialObservation))
  -> Maybe TargetMaterialObservation
  -> IO (Either String HarnessCredentialResolution)
resolveHarnessCredentialSubmission resolve coordinate observeTarget initial = do
  planned <- resolve initial
  case planned of
    Right (RepairHarnessCredentialTarget intent)
      | not (validRepairIntent intent) ->
          pure (Left "serving credential repair must revoke the Lifecycle-provider Target")
    Right (RepairHarnessCredentialTarget intent) -> do
      completed <- coordinate intent
      case completed of
        Left detail -> pure (Left detail)
        Right receipt
          | not (validRepair intent receipt) ->
              pure (Left "serving credential repair returned a mismatched revoke receipt")
          | otherwise -> do
              observed <- observeTarget
              case observed of
                Left detail -> pure (Left detail)
                Right (Just _) -> pure (Left "serving credential repair did not prove Target absence")
                Right Nothing -> do
                  next <- resolve Nothing
                  pure $ case next of
                    Right (RepairHarnessCredentialTarget _) -> Left "serving credential repair did not reach ordinary retirement"
                    other -> other
    other -> pure other
 where
  validRepair intent receipt =
    validRepairIntent intent
      && awsAdminWorkerReceiptKind receipt == AwsAdminRevoked
      && awsAdminWorkerReceiptPermitId receipt
        == operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
      && awsAdminWorkerReceiptRequestDigest receipt == awsAdminPermitIntentRequestDigest intent
      && awsAdminWorkerReceiptTarget receipt == awsAdminPermitIntentTarget intent
      && awsAdminWorkerReceiptGeneration receipt == awsAdminPermitIntentGeneration intent
  validRepairIntent intent =
    awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential
      && awsAdminPermitIntentAction intent == RevokeOperatorMaterial
      && awsAdminPermitIntentTarget intent == operationalTarget

validateUnfinishedGeneration
  :: HarnessCredentialSlot
  -> Maybe TargetMaterialObservation
  -> AwsAdminPermitIntent
  -> Either HarnessCredentialResolutionError ()
validateUnfinishedGeneration slot observed intent = case observed of
  Nothing -> Right ()
  Just metadata ->
    let actual = targetMaterialObservedGeneration metadata
        expected = credentialGenerationValue (awsAdminPermitIntentGeneration intent)
     in unless
          ( case slot of
              HarnessCredentialInstall -> actual <= expected
              HarnessCredentialRevoke -> actual == expected
          )
          (Left HarnessCredentialTargetGenerationMismatch)

resolveCompleted
  :: HarnessCredentialSlot
  -> Maybe TargetMaterialObservation
  -> AwsAdminProvisionerObservation
  -> AwsAdminPermitIntent
  -> Either HarnessCredentialResolutionError HarnessCredentialResolution
resolveCompleted slot observed observation intent = do
  permitBytes <-
    maybe (Left HarnessCredentialCompletedReceiptInvalid) Right (awsAdminObservedPermit observation)
  somePermit <-
    first (const HarnessCredentialCompletedReceiptInvalid) (decodeSignedAwsAdminPermit permitBytes)
  let permit = withSomeSignedAwsAdminPermit somePermit id
  unless (signedAwsAdminPermitIntent permit == intent) (Left HarnessCredentialCompletedReceiptInvalid)
  receiptBytes <-
    maybe (Left HarnessCredentialCompletedReceiptInvalid) Right (awsAdminObservedReceipt observation)
  receipt <-
    first (const HarnessCredentialCompletedReceiptInvalid) (decodeAwsAdminWorkerReceipt receiptBytes)
  let expectedKind = case slot of
        HarnessCredentialInstall -> AwsAdminInstalled
        HarnessCredentialRevoke -> AwsAdminRevoked
  unless
    (awsAdminWorkerReceiptKind receipt == expectedKind)
    (Left HarnessCredentialCompletedReceiptKindMismatch)
  first
    (const HarnessCredentialCompletedReceiptInvalid)
    (validateAwsAdminWorkerReceiptForPermit permit receipt)
  _ <- confirmHarnessCredentialReceipt receipt observed
  pure $ case slot of
    HarnessCredentialRevoke -> HarnessCredentialRevocationAlreadyProven receipt
    HarnessCredentialInstall -> SubmitHarnessCredentialIntent intent

-- | Close an already authenticated worker receipt with a fresh Agent read.
-- The command uses this after both a new execution and a retained completion.
confirmHarnessCredentialReceipt
  :: AwsAdminWorkerReceipt
  -> Maybe TargetMaterialObservation
  -> Either HarnessCredentialResolutionError Natural
confirmHarnessCredentialReceipt receipt observed = do
  case awsAdminWorkerReceiptKind receipt of
    AwsAdminRevoked -> case observed of
      Nothing -> Right ()
      Just _ -> Left HarnessCredentialRevokedTargetStillPresent
    AwsAdminInstalled -> do
      metadata <- maybe (Left HarnessCredentialInstalledTargetMissing) Right observed
      actual <-
        first
          (const HarnessCredentialCompletedReceiptInvalid)
          (targetWorkerReceiptFromMaterialObservation (awsAdminWorkerReceiptTarget receipt) metadata)
      expected <-
        first
          (const HarnessCredentialCompletedReceiptInvalid)
          (decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt))
      unless (actual == expected) (Left HarnessCredentialTargetGenerationMismatch)
  pure (credentialGenerationValue (awsAdminWorkerReceiptGeneration receipt))

operationalTarget :: TargetSecretId
operationalTarget = TargetAwsCredential AwsLifecycleProvider

-- | Metadata from a completed authenticated Provisioner operation and its
-- independent Agent read-back. The receipt remains available to the lifecycle
-- composition instead of being reduced to a successful process exit.
data HarnessCredentialConfirmation
  = HarnessCredentialConfirmation
      !AwsAdminWorkerReceipt
      !Natural
  deriving stock (Eq, Show)

confirmHarnessCredentialOutcome
  :: AwsAdminWorkerReceipt
  -> Maybe TargetMaterialObservation
  -> Either HarnessCredentialResolutionError HarnessCredentialConfirmation
confirmHarnessCredentialOutcome receipt observed =
  HarnessCredentialConfirmation receipt <$> confirmHarnessCredentialReceipt receipt observed

harnessCredentialConfirmationGeneration :: HarnessCredentialConfirmation -> Natural
harnessCredentialConfirmationGeneration (HarnessCredentialConfirmation _ generation) = generation

data HarnessCredentialRevocationEvidence
  = HarnessCredentialRevocationEvidence
      !Text
      !AwsAdminWorkerReceipt
  deriving stock (Eq, Show)

-- | Narrow a confirmed result to the exact invocation's LCP revoke slot.
-- IAM absence is attested by the revoked worker receipt; the confirmation
-- additionally requires the independent Agent observation to be absent.
confirmHarnessCredentialRevocation
  :: HarnessCredentialLineage
  -> HarnessCredentialConfirmation
  -> Either HarnessCredentialResolutionError HarnessCredentialRevocationEvidence
confirmHarnessCredentialRevocation lineage (HarnessCredentialConfirmation receipt _) = do
  unless
    (awsAdminWorkerReceiptKind receipt == AwsAdminRevoked)
    (Left HarnessCredentialCompletedReceiptKindMismatch)
  unless
    (awsAdminWorkerReceiptTarget receipt == operationalTarget)
    (Left HarnessCredentialClassMismatch)
  operationId <-
    first
      (const HarnessCredentialOperationInvalid)
      (harnessCredentialSlotOperationId lineage HarnessCredentialRevoke)
  unless
    (awsAdminWorkerReceiptPermitId receipt == operationId)
    (Left HarnessCredentialForeignOperation)
  pure (HarnessCredentialRevocationEvidence operationId receipt)

harnessCredentialRevocationOperationId :: HarnessCredentialRevocationEvidence -> Text
harnessCredentialRevocationOperationId (HarnessCredentialRevocationEvidence operationId _) = operationId

harnessCredentialRevocationReceipt :: HarnessCredentialRevocationEvidence -> AwsAdminWorkerReceipt
harnessCredentialRevocationReceipt (HarnessCredentialRevocationEvidence _ receipt) = receipt

-- | Preserve the two actual evidence origins, rather than naming one proof
-- twice. The authenticated revoked worker attests the IAM-family absence;
-- its carried Agent evidence identifies the separate Target revocation. This
-- narrowing is available only after the fresh Agent absence confirmation.
harnessCredentialRevocationEpochReceipt
  :: HarnessCredentialRevocationEvidence
  -> Either ProviderAdmissionEpochError ProviderCredentialRevocationReceipt
harnessCredentialRevocationEpochReceipt evidence =
  mkProviderCredentialRevocationReceipt
    (cleanupDigestOfBytes (encodeAwsAdminWorkerReceipt receipt))
    (cleanupDigestOfBytes (awsAdminWorkerReceiptTargetReadBack receipt))
 where
  receipt = harnessCredentialRevocationReceipt evidence
