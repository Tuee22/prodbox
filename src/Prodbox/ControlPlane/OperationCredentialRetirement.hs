{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Fixed Lifecycle-provider credential tail for the closed ordinary program.
-- Inputs are captured once; this interpreter has no repository/config loader,
-- authentication constructor, image resolver, nonce source or deadline renewal.
-- Its concrete clients and Kubernetes adapter are owned by the program's
-- interpreter, not supplied as arbitrary callbacks in a controller request.
module Prodbox.ControlPlane.OperationCredentialRetirement
  ( OperationCredentialRetirementInputs
  , OperationCredentialRetirementError (..)
  , mkOperationCredentialRetirementInputs
  , runOperationCredentialRetirement
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientTransport)
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminProvisionerClientError
  , awsAdminProvisionerClient
  , observeAwsAdminProvisioning
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminProvisionerChallenge (awsAdminChallengeCanonicalIntent)
  , AwsAdminProvisionerObservation (..)
  , AwsAdminProvisionerPhase (AwsAdminProvisionerCompleted)
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClientError
  , observeRegisteredTargetMaterial
  , targetMaterialClient
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceiptKind (AwsAdminRevoked)
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptTarget
  , encodeAwsAdminWorkerReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
  ( OperationAwsAdminKubernetesBoundary
  , OperationAwsAdminKubernetesError
  , coordinateOperationAwsAdminProvisioning
  , verifyOperationAwsAdminKubernetesBoundary
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitError
  , CredentialIamParameters
  , awsAdminPermitIntentOperationId
  , credentialIamParametersClass
  , credentialIamParametersRegion
  , decodeAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime))
import Prodbox.Settings (Credentials)
import Prodbox.Settings qualified as Settings
import Prodbox.Subprocess
  ( OperationSubprocessError
  , OperationSubprocesses
  , verifyOperationSubprocessesBeforeEffect
  )

-- No Show instance: the previously prompted credential is an ingress payload,
-- never operational metadata. The lineage and deadline are the request's.
data OperationCredentialRetirementInputs
  = RetirementInputs
      !GenesisAwsAdminIntentParameters
      !CredentialIamParameters
      !HarnessCredentialLineage
      !Credentials

data OperationCredentialRetirementError
  = RetirementCredentialClassMismatch
  | RetirementOriginalDeadlineMismatch
  | RetirementAdminRegionMismatch
  | RetirementParentRefused !OperationSubprocessError
  | RetirementClockUnavailable
  | RetirementOriginalDeadlineReached
  | RetirementBoundaryRefused !Text
  | RetirementTargetReadFailed !TargetMaterialClientError
  | RetirementRecoveryFailed !Text
  | RetirementCoordinateFailed !OperationAwsAdminKubernetesError
  | RetirementRetainedReadFailed !AwsAdminProvisionerClientError
  | RetirementRetainedIntentInvalid !AwsAdminPermitError
  | RetirementRetainedSlotInvalid !Text
  | RetirementRetainedSlotMismatch
  | RetirementRetainedCompletionChanged
  | RetirementReceiptKindMismatch
  | RetirementReceiptTargetMismatch
  | RetirementEvidenceRefused !HarnessCredentialResolutionError
  deriving (Eq, Show)

mkOperationCredentialRetirementInputs
  :: AuthorityTime
  -> GenesisAwsAdminIntentParameters
  -> CredentialIamParameters
  -> HarnessCredentialLineage
  -> Credentials
  -> Either OperationCredentialRetirementError OperationCredentialRetirementInputs
mkOperationCredentialRetirementInputs originalDeadline parameters iam lineage credentials = do
  unless
    (credentialIamParametersClass iam == LifecycleProviderCredential)
    (Left RetirementCredentialClassMismatch)
  unless
    (genesisIntentDeadline parameters == originalDeadline)
    (Left RetirementOriginalDeadlineMismatch)
  unless
    ( credentialIamParametersRegion iam == Settings.region credentials
        && credentialIamParametersRegion (genesisIntentIamParameters parameters) == Settings.region credentials
    )
    (Left RetirementAdminRegionMismatch)
  pure (RetirementInputs parameters iam lineage credentials)

-- Resource convergence and the recorded clean audit precede this call. The
-- caller subsequently confirms the revoked Authority epoch independently;
-- this tail supplies only its exact Provisioner/IAM and Agent confirmation.
runOperationCredentialRetirement
  :: OperationSubprocesses
  -> OperationCredentialRetirementInputs
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> OperationAwsAdminKubernetesBoundary
  -> IO (Either OperationCredentialRetirementError HarnessCredentialRevocationEvidence)
runOperationCredentialRetirement processes (RetirementInputs parameters iam lineage credentials) authority agent kubernetes = runExceptT $ do
  ExceptT
    (first RetirementBoundaryRefused <$> verifyOperationAwsAdminKubernetesBoundary processes kubernetes)
  now <- ExceptT (originalTime processes (genesisIntentDeadline parameters))
  observed <- ExceptT observeTarget
  recovered <-
    ExceptT $
      first (RetirementRecoveryFailed . Text.pack)
        <$> resumePendingHarnessCredentialOperation
          client
          parameters
          iam
          observed
          now
          (fmap void . coordinateText)
  current <- if recovered then ExceptT observeTarget else pure observed
  planned <-
    ExceptT $
      first (RetirementRecoveryFailed . Text.pack)
        <$> resolveHarnessCredentialSubmission
          ( \metadata ->
              first show
                <$> resolveHarnessCredentialSlot client parameters iam lineage HarnessCredentialRevoke metadata now
          )
          coordinateText
          (fmap (first (Text.unpack . renderTargetError)) observeTarget)
          current
  receipt <- case planned of
    HarnessCredentialRevocationAlreadyProven existing -> do
      -- A completed credential receipt does not prove its Job is absent.
      -- Recover the same immutable slot through the coordinator, which reads
      -- the retained permit/UIDs and closes cleanup without creating a Job.
      slot <-
        either
          (throwE . RetirementRetainedSlotInvalid)
          pure
          (harnessCredentialSlotOperationId lineage HarnessCredentialRevoke)
      retained <-
        ExceptT (first RetirementRetainedReadFailed <$> observeAwsAdminProvisioning client slot)
      unless
        ( awsAdminObservedPhase retained == AwsAdminProvisionerCompleted
            && awsAdminObservedReceipt retained == Just (encodeAwsAdminWorkerReceipt existing)
        )
        (throwE RetirementRetainedCompletionChanged)
      intent <-
        either
          (throwE . RetirementRetainedIntentInvalid)
          pure
          (decodeAwsAdminPermitIntent (awsAdminChallengeCanonicalIntent (awsAdminObservedChallenge retained)))
      unless
        (operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent) == slot)
        (throwE RetirementRetainedSlotMismatch)
      confirmed <-
        ExceptT
          ( first RetirementCoordinateFailed
              <$> coordinateOperationAwsAdminProvisioning client kubernetes credentials intent
          )
      unless (confirmed == existing) (throwE RetirementRetainedCompletionChanged)
      pure confirmed
    SubmitHarnessCredentialIntent intent ->
      ExceptT
        ( first RetirementCoordinateFailed
            <$> coordinateOperationAwsAdminProvisioning client kubernetes credentials intent
        )
    RepairHarnessCredentialTarget _ -> throwE (RetirementRecoveryFailed "credential repair did not reach the fixed retirement slot")
  unless (awsAdminWorkerReceiptKind receipt == AwsAdminRevoked) (throwE RetirementReceiptKindMismatch)
  unless
    (awsAdminWorkerReceiptTarget receipt == operationalTarget)
    (throwE RetirementReceiptTargetMismatch)
  readBack <- ExceptT observeTarget
  confirmed <-
    either (throwE . RetirementEvidenceRefused) pure (confirmHarnessCredentialOutcome receipt readBack)
  either
    (throwE . RetirementEvidenceRefused)
    pure
    (confirmHarnessCredentialRevocation lineage confirmed)
 where
  client = awsAdminProvisionerClient authority
  operationalTarget = TargetAwsCredential AwsLifecycleProvider
  observeTarget =
    first RetirementTargetReadFailed
      <$> observeRegisteredTargetMaterial (targetMaterialClient agent) operationalTarget
  coordinateText intent = first show <$> coordinateOperationAwsAdminProvisioning client kubernetes credentials intent
  renderTargetError = Text.pack . show

originalTime
  :: OperationSubprocesses -> AuthorityTime -> IO (Either OperationCredentialRetirementError Natural)
originalTime processes originalDeadline = runExceptT $ do
  ExceptT (first RetirementParentRefused <$> verifyOperationSubprocessesBeforeEffect processes)
  sampled <- liftIO (try getPOSIXTime :: IO (Either IOException POSIXTime))
  value <- either (const (throwE RetirementClockUnavailable)) pure sampled
  let now = fromInteger (max 0 (floor (toRational value * 1000000) :: Integer))
  unless (now < authorityTimeMicros originalDeadline) (throwE RetirementOriginalDeadlineReached)
  pure now
