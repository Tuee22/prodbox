{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

-- | Closed, operation-indexed Bootstrap Broker programs.  This is the only
-- executable vocabulary exposed to a broker interpreter: there is no generic
-- Vault path, KV coordinate, MinIO key, provider command, authority CAS, DNS,
-- mesh, SES, Pulumi, or target-secret constructor.
module Prodbox.Bootstrap.Broker.Program
  ( BootstrapStatus (..)
  , BootstrapMutationReceipt (..)
  , RotationKind (..)
  , VaultPkiStatus (..)
  , PkiIssueRequest
  , mkPkiIssueRequest
  , pkiIssueCommonName
  , pkiIssueTtlSeconds
  , BrokerProgram (..)
  , BrokerCapabilityRefs
  , mkBrokerCapabilityRefs
  , brokerProgramCapabilityRef
  , brokerProgramCapabilityOp
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types
  ( AccessorAbsenceAttestation
  , ArtifactDigest
  , BaselineReadBackReceipt
  , ChildAttestation
  , ChildCustodyBinding
  , ChildRecoveryDelivery
  , DeliveryNonce
  , InitAmbiguity
  , ParentCustodyAcknowledgement
  , PostUnsealConsumer
  , PostUnsealHandoffReceipt
  , PristineResetProof
  , PristineStorageProof
  , ProvisionerLoginReceipt
  , RecoveryCustodyReceipt
  , RootAccessorInventory
  , VaultStorageGeneration
  )
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind (..)
  , CapabilityOp (..)
  )
import Prodbox.ControlPlane.CapabilityRef
  ( CapabilityRef
  , mkCapabilityRef
  )
import Prodbox.ControlPlane.Coordinate (CapabilityCoordinate)
import Prodbox.Tls.CertScope
  ( Fqdn
  , fqdnText
  , mkFqdn
  , renderScopeError
  )

data BootstrapStatus = BootstrapStatus
  { bootstrapStatusInitialized :: !Bool
  , bootstrapStatusSealed :: !Bool
  , bootstrapStatusRecoveryCustodyDurable :: !Bool
  , bootstrapStatusInitializationAmbiguous :: !Bool
  , bootstrapStatusRootSessionActive :: !Bool
  , bootstrapStatusHandoffObserved :: !Bool
  }
  deriving (Eq, Show)

data RotationKind
  = UnlockBundleRotation
  | TransitKeyRotation
  deriving (Eq, Ord, Show, Enum, Bounded)

data BootstrapMutationReceipt = BootstrapMutationReceipt
  { bootstrapMutationDigest :: !ArtifactDigest
  , bootstrapMutationChanged :: !Bool
  }
  deriving (Eq, Show)

data VaultPkiStatus
  = VaultPkiBaselineAbsent
  | VaultPkiBaselineReady
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The only PKI issuance the bootstrap service admits is a bounded test
-- certificate.  The role is compiled into the interpreter, so callers cannot
-- select an arbitrary Vault role/path.
data PkiIssueRequest = PkiIssueRequest !Fqdn !Natural
  deriving (Eq, Show)

mkPkiIssueRequest :: Text -> Natural -> Either String PkiIssueRequest
mkPkiIssueRequest rawCommonName ttlSeconds
  | Text.null commonName = Left "PKI test common name must not be empty"
  | Text.length commonName > 253 = Left "PKI test common name exceeds 253 characters"
  | any ((> 63) . Text.length) labels =
      Left "PKI test common name contains a label exceeding 63 characters"
  | looksLikeIpv4 labels = Left "PKI test common name must be a DNS name, not an IPv4 literal"
  | ttlSeconds == 0 = Left "PKI test certificate TTL must be positive"
  | ttlSeconds > 3600 = Left "PKI test certificate TTL must not exceed 3600 seconds"
  | otherwise =
      case mkFqdn commonName of
        Left failure -> Left ("PKI test common name is invalid: " ++ renderScopeError failure)
        Right fqdn -> Right (PkiIssueRequest fqdn ttlSeconds)
 where
  commonName = Text.strip rawCommonName
  labels = Text.splitOn (Text.singleton '.') commonName

  looksLikeIpv4 candidateLabels =
    length candidateLabels == 4
      && all
        (\label -> not (Text.null label) && Text.all isDigit label)
        candidateLabels

pkiIssueCommonName :: PkiIssueRequest -> Text
pkiIssueCommonName (PkiIssueRequest fqdn _) = fqdnText fqdn

pkiIssueTtlSeconds :: PkiIssueRequest -> Natural
pkiIssueTtlSeconds (PkiIssueRequest _ ttlSeconds) = ttlSeconds

data BrokerProgram (operation :: CapabilityKind) result where
  ObserveBootstrapStatus
    :: BrokerProgram 'VaultBootstrapObserve BootstrapStatus
  ObserveBrokerHealth
    :: BrokerProgram 'VaultBootstrapObserve Bool
  ObserveBrokerReadiness
    :: BrokerProgram 'VaultBootstrapObserve Bool
  ObserveChildRecoveryDelivery
    :: ChildCustodyBinding
    -> DeliveryNonce
    -> BrokerProgram 'VaultBootstrapObserve (Maybe ChildRecoveryDelivery)
  InitializeVault
    :: PristineStorageProof
    -> BrokerProgram 'VaultBootstrapMutate RecoveryCustodyReceipt
  UnsealVault
    :: RecoveryCustodyReceipt
    -> BrokerProgram 'VaultBootstrapMutate BootstrapMutationReceipt
  SealVault
    :: BrokerProgram 'VaultBootstrapMutate BootstrapMutationReceipt
  RotateUnlockBundle
    :: RecoveryCustodyReceipt
    -> BrokerProgram 'VaultBootstrapMutate BootstrapMutationReceipt
  RotateTransitKey
    :: BrokerProgram 'VaultBootstrapMutate BootstrapMutationReceipt
  ResetAmbiguousInitialization
    :: InitAmbiguity
    -> PristineResetProof
    -> BrokerProgram 'VaultBootstrapMutate BootstrapMutationReceipt
  InventoryRootAccessors
    :: BrokerProgram 'VaultBootstrapMutate RootAccessorInventory
  ProveRootAccessorsAbsent
    :: RootAccessorInventory
    -> BrokerProgram 'VaultBootstrapMutate AccessorAbsenceAttestation
  CommitChildCustody
    :: ChildCustodyBinding
    -> BrokerProgram 'VaultBootstrapMutate ParentCustodyAcknowledgement
  DeliverChildRecovery
    :: ChildCustodyBinding
    -> DeliveryNonce
    -> ChildAttestation
    -> BrokerProgram 'VaultBootstrapMutate ChildRecoveryDelivery
  ObservePostUnsealHandoff
    :: VaultStorageGeneration
    -> PostUnsealConsumer
    -> BrokerProgram 'VaultBootstrapObserve (Maybe PostUnsealHandoffReceipt)
  ReconcileAllowlistedBaseline
    :: RecoveryCustodyReceipt
    -> BrokerProgram 'VaultBaselineReconcile BaselineReadBackReceipt
  VerifyProvisionerLogin
    :: ProvisionerLoginReceipt
    -> BrokerProgram 'VaultBaselineReconcile ProvisionerLoginReceipt
  ObserveVaultPkiStatus
    :: BrokerProgram 'VaultPkiOperate VaultPkiStatus
  IssueVaultPkiTestCertificate
    :: PkiIssueRequest
    -> BrokerProgram 'VaultPkiOperate BootstrapMutationReceipt

-- | The four exact operation-indexed references admitted to one Broker
-- interpreter.  The constructor is private so call sites cannot relabel a
-- coordinate by storing a reference under the wrong operation field.
data BrokerCapabilityRefs = BrokerCapabilityRefs
  { bootstrapObserveRef :: !(CapabilityRef 'VaultBootstrapObserve)
  , bootstrapMutateRef :: !(CapabilityRef 'VaultBootstrapMutate)
  , baselineReconcileRef :: !(CapabilityRef 'VaultBaselineReconcile)
  , pkiOperateRef :: !(CapabilityRef 'VaultPkiOperate)
  }

mkBrokerCapabilityRefs
  :: CapabilityCoordinate
  -> CapabilityCoordinate
  -> CapabilityCoordinate
  -> CapabilityCoordinate
  -> BrokerCapabilityRefs
mkBrokerCapabilityRefs observeCoordinate mutateCoordinate baselineCoordinate pkiCoordinate =
  BrokerCapabilityRefs
    { bootstrapObserveRef = mkCapabilityRef observeCoordinate
    , bootstrapMutateRef = mkCapabilityRef mutateCoordinate
    , baselineReconcileRef = mkCapabilityRef baselineCoordinate
    , pkiOperateRef = mkCapabilityRef pkiCoordinate
    }

-- | Select the same indexed reference that admission and execution must carry.
-- Exhaustive GADT matching makes a cross-operation reference a type error.
brokerProgramCapabilityRef
  :: BrokerCapabilityRefs
  -> BrokerProgram operation result
  -> CapabilityRef operation
brokerProgramCapabilityRef references program = case program of
  ObserveBootstrapStatus -> bootstrapObserveRef references
  ObserveBrokerHealth -> bootstrapObserveRef references
  ObserveBrokerReadiness -> bootstrapObserveRef references
  ObserveChildRecoveryDelivery _ _ -> bootstrapObserveRef references
  InitializeVault _ -> bootstrapMutateRef references
  UnsealVault _ -> bootstrapMutateRef references
  SealVault -> bootstrapMutateRef references
  RotateUnlockBundle _ -> bootstrapMutateRef references
  RotateTransitKey -> bootstrapMutateRef references
  ResetAmbiguousInitialization _ _ -> bootstrapMutateRef references
  InventoryRootAccessors -> bootstrapMutateRef references
  ProveRootAccessorsAbsent _ -> bootstrapMutateRef references
  CommitChildCustody _ -> bootstrapMutateRef references
  DeliverChildRecovery {} -> bootstrapMutateRef references
  ObservePostUnsealHandoff _ _ -> bootstrapObserveRef references
  ReconcileAllowlistedBaseline _ -> baselineReconcileRef references
  VerifyProvisionerLogin _ -> baselineReconcileRef references
  ObserveVaultPkiStatus -> pkiOperateRef references
  IssueVaultPkiTestCertificate _ -> pkiOperateRef references

brokerProgramCapabilityOp :: BrokerProgram operation result -> CapabilityOp
brokerProgramCapabilityOp program = case program of
  ObserveBootstrapStatus -> OpVaultBootstrapObserve
  ObserveBrokerHealth -> OpVaultBootstrapObserve
  ObserveBrokerReadiness -> OpVaultBootstrapObserve
  ObserveChildRecoveryDelivery _ _ -> OpVaultBootstrapObserve
  InitializeVault _ -> OpVaultBootstrapMutate
  UnsealVault _ -> OpVaultBootstrapMutate
  SealVault -> OpVaultBootstrapMutate
  RotateUnlockBundle _ -> OpVaultBootstrapMutate
  RotateTransitKey -> OpVaultBootstrapMutate
  ResetAmbiguousInitialization _ _ -> OpVaultBootstrapMutate
  InventoryRootAccessors -> OpVaultBootstrapMutate
  ProveRootAccessorsAbsent _ -> OpVaultBootstrapMutate
  CommitChildCustody _ -> OpVaultBootstrapMutate
  DeliverChildRecovery {} -> OpVaultBootstrapMutate
  ObservePostUnsealHandoff _ _ -> OpVaultBootstrapObserve
  ReconcileAllowlistedBaseline _ -> OpVaultBaselineReconcile
  VerifyProvisionerLogin _ -> OpVaultBaselineReconcile
  ObserveVaultPkiStatus -> OpVaultPkiOperate
  IssueVaultPkiTestCertificate _ -> OpVaultPkiOperate
