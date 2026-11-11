{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The sole closed wire vocabulary of the Authority control route. Existing
-- constructor order is preserved. Only the exact canonical promotion observer
-- is eligible for fresh-nonce read replay; all other requests retain their
-- established response semantics.
module Prodbox.ControlPlane.AuthorityControlProtocol
  ( AuthorityControlPayload (..)
  , isEpochPromotionObservationRequest
  , isEpochPromotionObservationForRole
  , isSignedEpochPromotionObservationForRole
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleAuthorityControl))
import Prodbox.Lifecycle.Authority.BackupRepair (BackupRepairCommand)
import Prodbox.Lifecycle.Authority.Genesis (AuthorityGenesisCommand)
import Prodbox.Lifecycle.Authority.Migration (MigrationForwardCommand)
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , CascadeTerminalAuditReceipt
  , ProviderCredentialRevocationReceipt
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthorityControlPayload
  = AuthorityControlGenesis !AuthorityGenesisCommand
  | AuthorityControlBackupRepair !BackupRepairCommand
  | AuthorityControlBeginMigration
  | AuthorityControlForwardMigration !MigrationForwardCommand
  | -- | Sprint 4.85: bind the serving Lifecycle-provider generation. Appended
    -- so every earlier constructor keeps its @Serialise@ index and no
    -- historical request re-decodes as a different payload.
    AuthorityControlBindProviderGeneration !Natural
  | -- | Sprint 4.85: fence fresh Provider submissions and reserve the terminal
    -- audit's own submission. This is the route whose absence
    -- @GlobalProviderAdmissionFreezeUnavailable@ named: the transition and the
    -- reservation-honouring gate landed first, and until this constructor
    -- existed no authenticated caller could reach either.
    AuthorityControlFreezeProviderAdmissionForCascadeAudit
      !CascadeAuditFreezeBinding
  | -- | Sprint 7.36: make the terminal audit's verdict durable against the
    -- reservation that admitted it. Appended for the same reason as the two
    -- constructors above: every earlier one keeps its @Serialise@ index.
    AuthorityControlRecordCascadeTerminalAuditReceipt
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
  | -- | Sprint 7.36: end the cascade's Provider credential. Appended for the
    -- same reason as every constructor above it.
    AuthorityControlRevokeCascadeProviderCredential
      !CascadeAuditFreezeBinding
      !ProviderCredentialRevocationReceipt
  | -- | Bind and freeze in the same aggregate CAS; no partial serving bind
    -- survives a refused reservation. Earlier constructor indices stay fixed.
    AuthorityControlFreezeProviderAdmissionAtGeneration
      !Natural
      !CascadeAuditFreezeBinding
  | -- | Read the durable phase and original reservation attempt without CAS.
    AuthorityControlObserveProviderAdmissionRecovery !CascadeAuditFreezeBinding
  | AuthorityControlObserveProviderBootstrapPredecessor
  | AuthorityControlObserveEpochPromotion
  | AuthorityControlObserveSignedEpochPromotion
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

isEpochPromotionObservationForRole :: RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isEpochPromotionObservationForRole role route body =
  role == LifecycleAuthorityRuntime
    && route == LifecycleAuthorityControl
    && isEpochPromotionObservationRequest body

isSignedEpochPromotionObservationForRole :: RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isSignedEpochPromotionObservationForRole role route body =
  role == LifecycleAuthorityRuntime
    && route == LifecycleAuthorityControl
    && case decodeControlPlaneRequest 64 (LazyByteString.fromStrict body) of
      Right AuthorityControlObserveSignedEpochPromotion -> True
      _ -> False

isEpochPromotionObservationRequest :: ByteString -> Bool
isEpochPromotionObservationRequest body =
  case decodeControlPlaneRequest 64 (LazyByteString.fromStrict body) of
    Right AuthorityControlObserveEpochPromotion -> True
    Right AuthorityControlObserveSignedEpochPromotion -> True
    Right AuthorityControlGenesis {} -> False
    Right AuthorityControlBackupRepair {} -> False
    Right AuthorityControlBeginMigration -> False
    Right AuthorityControlForwardMigration {} -> False
    Right AuthorityControlBindProviderGeneration {} -> False
    Right AuthorityControlFreezeProviderAdmissionForCascadeAudit {} -> False
    Right AuthorityControlRecordCascadeTerminalAuditReceipt {} -> False
    Right AuthorityControlRevokeCascadeProviderCredential {} -> False
    Right AuthorityControlFreezeProviderAdmissionAtGeneration {} -> False
    Right AuthorityControlObserveProviderAdmissionRecovery {} -> False
    Right AuthorityControlObserveProviderBootstrapPredecessor -> False
    Left _ -> False
