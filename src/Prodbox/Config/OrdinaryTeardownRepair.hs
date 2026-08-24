{-# LANGUAGE LambdaCase #-}

-- | Recovery-only repair rendering for the ordinary teardown control plane.
--
-- "Prodbox.Config.OrdinaryTeardownRecovery" answers /which components/ the
-- smallest resumable control plane contains.  This module answers the two
-- questions that remained open once that closure existed:
--
--   * what a repair of that closure must do from each observed local substrate
--     state, and
--   * which retained bytes that repair is allowed to read.
--
-- The second question is the load-bearing one.  The recovery closure
-- deliberately excludes the steady-state image Registry, and the ordinary
-- install path resolves the substrate installer over the network at install
-- time.  Neither an ambient network fetch nor a host container cache is an
-- authority, so a repair plan may only name artifacts that a validated,
-- versioned, architecture-specific inventory says are retained.  When the
-- inventory does not cover what the observed state requires, the plan is a
-- typed refusal naming the exact missing artifacts rather than a silent
-- fallback.
--
-- Everything here is pure.  Phase 4 owns executing a rendered plan; this module
-- never performs an effect and never mints an artifact reference that did not
-- come out of a validated inventory.
module Prodbox.Config.OrdinaryTeardownRepair
  ( -- * Versioned retained artifact inventory
    RetainedArtifactArchitecture (..)
  , retainedArtifactArchitectureText
  , RetainedArtifactKind (..)
  , retainedArtifactKindText
  , RetainedArtifactRole (..)
  , retainedArtifactRole
  , RetainedArtifactEntry (..)
  , RetainedArtifactInventory
  , retainedArtifactInventoryArchitecture
  , retainedArtifactInventoryKinds
  , RetainedArtifactRef
  , retainedArtifactRefKind
  , retainedArtifactRefArchitecture
  , retainedArtifactRefVersion
  , retainedArtifactRefDigest
  , retainedArtifactRefRelativePath
  , RetainedArtifactInventoryError (..)
  , renderRetainedArtifactInventoryError
  , retainedArtifactInventory
  , lookupRetainedArtifact

    -- * Artifact obligations derived from the recovery closure
  , retainedArtifactPolicy
  , requiredRetainedArtifacts

    -- * Pinned acquisition sources
  , RetainedArtifactLocator (..)
  , retainedArtifactLocatorText
  , RetainedArtifactSourceEntry (..)
  , RetainedArtifactSource
  , retainedArtifactSourceKind
  , retainedArtifactSourceArchitecture
  , retainedArtifactSourceDigest
  , retainedArtifactSourceLocator
  , RetainedArtifactSourceCatalog
  , retainedArtifactSourceCatalogArchitecture
  , retainedArtifactSourceCatalogKinds
  , RetainedArtifactSourceError (..)
  , renderRetainedArtifactSourceError
  , retainedArtifactSourceCatalog
  , lookupRetainedArtifactSource

    -- * The operator-declared Tier-0 section
  , RetainedArtifactDeclaration (..)
  , RetainedArtifactsSection (..)
  , emptyRetainedArtifactsSection
  , DeclaredRetainedArtifacts
  , declaredRetainedArtifactInventory
  , declaredRetainedArtifactCatalog
  , RetainedArtifactDeclarationError (..)
  , renderRetainedArtifactDeclarationError
  , declaredRetainedArtifacts

    -- * The stopped/absent/healthy repair matrix
  , RecoveryPlatformComponent (..)
  , OrdinaryTeardownRepairStep (..)
  , OrdinaryTeardownRepairPlan
  , ordinaryTeardownRepairPlanState
  , ordinaryTeardownRepairPlanArchitecture
  , ordinaryTeardownRepairPlanSteps
  , OrdinaryTeardownRepairError (..)
  , renderOrdinaryTeardownRepairError
  , ordinaryTeardownRepairPlan

    -- * Deletion-survivor projection
  , RecoveryPlaneResource (..)
  , recoveryPlaneResourceText
  , RecoveryPlaneResourceOwner (..)
  , recoveryPlaneResourceOwner
  , recoveryPlaneResources
  , DeletionScope (..)
  , gatewayAndApplicationDeletionScope
  , DeletionSurvivorProjection
  , deletionSurvivorSurvivors
  , deletionSurvivorCasualties
  , projectDeletionSurvivors
  )
where

import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Prodbox.Config.ComponentGraph
  ( ComponentId (..)
  , chartNameForComponent
  , componentIdText
  , component_id
  , defaultComponentGraph
  )
import Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryStateView (..)
  )
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownRecovery
  , OrdinaryTeardownRecoveryComponent (..)
  , ordinaryTeardownRecoveryChartNames
  , ordinaryTeardownRecoveryComponentIds
  , ordinaryTeardownRecoveryComponents
  )
import Prodbox.Config.RetainedArtifacts

-- ---------------------------------------------------------------------------
-- Artifact obligations derived from the recovery closure
-- ---------------------------------------------------------------------------

-- | Which retained artifacts a recovery-closure member consumes in a given
-- observed state.  @Nothing@ means the member has no declared artifact policy
-- at all: admitting a component to the recovery closure without saying where
-- its bytes come from is refused rather than defaulted to \"none\".
--
-- The substrate obligation is the only state-dependent arm.  Image obligations
-- do not vary with substrate state, because the recovery closure excludes the
-- image Registry in every state and the observation surface says nothing about
-- what the node's content store already holds.
retainedArtifactPolicy
  :: LocalRke2RecoveryStateView
  -> OrdinaryTeardownRecoveryComponent
  -> Maybe [RetainedArtifactKind]
retainedArtifactPolicy state = \case
  -- A ServiceAccount, Role, and RoleBinding rendered by the Bootstrap Broker
  -- release.  It runs no image of its own.
  RecoveryBootstrapCoreExternalCli -> Just []
  RecoveryGraphComponent component -> case component of
    ComponentClusterBase -> Just (substrateObligation state)
    ComponentMinio -> Just [RetainedObjectStoreImage]
    ComponentVaultWorkload -> Just [RetainedSecretStoreImage]
    -- A readiness state of the already-obligated Vault workload, not a second
    -- deployable.
    ComponentVaultUnsealed -> Just []
    ComponentChartBootstrapBroker -> Just [RetainedProdboxRuntimeImage]
    ComponentChartTargetSecretAgent -> Just [RetainedProdboxRuntimeImage]
    ComponentChartLifecycleAuthority -> Just [RetainedProdboxRuntimeImage]
    ComponentChartAuthorityBackup -> Just [RetainedProdboxRuntimeImage]
    ComponentChartProviderWorker -> Just [RetainedProdboxRuntimeImage]
    _ -> Nothing

-- | Reinstalling the local substrate is required exactly when it is absent.
--
-- All four substrate kinds, because the offline install reads them as one
-- artifact directory: the installer script, the release tarball it unpacks, the
-- checksum file it verifies that tarball against, and the system-images archive
-- the node loads instead of pulling. An obligation naming fewer of them would
-- render a plan that admits against the store and then refuses at its first
-- step on a real host.
substrateObligation :: LocalRke2RecoveryStateView -> [RetainedArtifactKind]
substrateObligation = \case
  LocalRke2RecoveryHealthy -> []
  LocalRke2RecoveryStopped -> []
  LocalRke2RecoveryAbsent ->
    [ RetainedSubstrateInstaller
    , RetainedSubstrateReleaseTarball
    , RetainedSubstrateChecksum
    , RetainedSubstrateSystemImages
    ]

-- | The artifact obligation of a whole recovery closure, in derived dependency
-- order with duplicates collapsed at first occurrence.
requiredRetainedArtifacts
  :: LocalRke2RecoveryStateView
  -> OrdinaryTeardownRecovery
  -> Either OrdinaryTeardownRepairError [RetainedArtifactKind]
requiredRetainedArtifacts state recovery =
  fmap (nub . concat) (traverse policyFor (ordinaryTeardownRecoveryComponents recovery))
 where
  policyFor component = case retainedArtifactPolicy state component of
    Just kinds -> Right kinds
    Nothing -> Left (OrdinaryTeardownRepairUnpolicedComponent component)

-- ---------------------------------------------------------------------------
-- The stopped/absent/healthy repair matrix
-- ---------------------------------------------------------------------------

-- | One step of a rendered repair.  Every step that touches bytes carries a
-- validated inventory reference; none of them names a network location.
data OrdinaryTeardownRepairStep
  = RepairInstallSubstrateFromRetained !(NonEmpty RetainedArtifactRef)
  | RepairStartSubstrateService
  | RepairAwaitSubstrateApi
  | RepairLoadRetainedImage !RetainedArtifactRef
  | RepairReconcileRecoveryPlatform !RecoveryPlatformComponent
  | RepairReconcileRecoveryChart !String
  deriving (Eq, Show)

-- | Non-chart workloads in the minimal recovery closure.  Their image bytes
-- were always retained and loaded, but before Sprint @6.5@ the repair plan had
-- no step that recreated either workload after a vendor uninstall.  Keeping
-- the two possibilities closed prevents a recovery caller from widening the
-- platform it may install with an arbitrary name.
data RecoveryPlatformComponent
  = RecoveryPlatformMinio
  | RecoveryPlatformVault
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Opaque rendered repair.  Construction proves the plan covers exactly the
-- observed state's obligation out of one validated inventory.
data OrdinaryTeardownRepairPlan = OrdinaryTeardownRepairPlan
  { ordinaryTeardownRepairPlanState :: !LocalRke2RecoveryStateView
  , ordinaryTeardownRepairPlanArchitecture :: !RetainedArtifactArchitecture
  , ordinaryTeardownRepairPlanSteps :: ![OrdinaryTeardownRepairStep]
  }
  deriving (Eq, Show)

data OrdinaryTeardownRepairError
  = -- | A recovery-closure member has no declared retained-artifact policy.
    OrdinaryTeardownRepairUnpolicedComponent !OrdinaryTeardownRecoveryComponent
  | -- | The observed state requires artifacts the inventory does not retain.
    -- This is the honest answer for an absent substrate against a repository
    -- that retains no installer or system images.
    OrdinaryTeardownRepairUnretainedArtifacts
      !LocalRke2RecoveryStateView
      !RetainedArtifactArchitecture
      !(NonEmpty RetainedArtifactKind)
  deriving (Eq, Show)

renderOrdinaryTeardownRepairError :: OrdinaryTeardownRepairError -> String
renderOrdinaryTeardownRepairError = \case
  OrdinaryTeardownRepairUnpolicedComponent component ->
    "Ordinary teardown repair cannot render `"
      ++ renderRecoveryComponentName component
      ++ "`: the recovery closure admits it, but no retained-artifact policy \
         \declares where its bytes come from."
  OrdinaryTeardownRepairUnretainedArtifacts state architecture missing ->
    "Ordinary teardown repair of a "
      ++ recoveryStateText state
      ++ " local substrate needs retained "
      ++ retainedArtifactArchitectureText architecture
      ++ " artifacts that are not retained: "
      ++ commaSeparated (fmap retainedArtifactKindText (NonEmpty.toList missing))
      ++ ". An ambient network fetch or host image cache is not an authority \
         \for them, so no repair plan is rendered."

recoveryStateText :: LocalRke2RecoveryStateView -> String
recoveryStateText = \case
  LocalRke2RecoveryHealthy -> "healthy"
  LocalRke2RecoveryStopped -> "stopped"
  LocalRke2RecoveryAbsent -> "absent"

renderRecoveryComponentName :: OrdinaryTeardownRecoveryComponent -> String
renderRecoveryComponentName = \case
  RecoveryGraphComponent component -> componentIdText component
  RecoveryBootstrapCoreExternalCli -> "bootstrap_core_external_cli"

commaSeparated :: [String] -> String
commaSeparated = \case
  [] -> ""
  [single] -> single
  first : remaining -> first ++ ", " ++ commaSeparated remaining

-- | Render the repair for one observed local substrate state.
--
-- The matrix differs only in its substrate arm: an absent substrate is
-- reinstalled from retained bytes and started, a stopped substrate is started,
-- and a healthy substrate is neither.  Retained image loads and recovery chart
-- reconciliation are common to all three, because the recovery closure has no
-- Registry in any state.
ordinaryTeardownRepairPlan
  :: RetainedArtifactInventory
  -> OrdinaryTeardownRecovery
  -> LocalRke2RecoveryStateView
  -> Either OrdinaryTeardownRepairError OrdinaryTeardownRepairPlan
ordinaryTeardownRepairPlan inventory recovery state = do
  requiredKinds <- requiredRetainedArtifacts state recovery
  resolved <- resolveRetained inventory state requiredKinds
  let substrateRefs =
        [ ref
        | ref <- resolved
        , retainedArtifactRole (retainedArtifactRefKind ref) == RetainedSubstrateArtifact
        ]
      imageRefs =
        [ ref
        | ref <- resolved
        , retainedArtifactRole (retainedArtifactRefKind ref) == RetainedImageArtifact
        ]
      installSteps =
        case NonEmpty.nonEmpty substrateRefs of
          Nothing -> []
          Just refs -> [RepairInstallSubstrateFromRetained refs]
      serviceSteps = case state of
        LocalRke2RecoveryHealthy -> []
        LocalRke2RecoveryStopped -> [RepairStartSubstrateService, RepairAwaitSubstrateApi]
        LocalRke2RecoveryAbsent -> [RepairStartSubstrateService, RepairAwaitSubstrateApi]
      platformSteps =
        [ RepairReconcileRecoveryPlatform platform
        | (component, platform) <-
            [ (ComponentMinio, RecoveryPlatformMinio)
            , (ComponentVaultWorkload, RecoveryPlatformVault)
            ]
        , component `elem` ordinaryTeardownRecoveryComponentIds recovery
        ]
  pure
    OrdinaryTeardownRepairPlan
      { ordinaryTeardownRepairPlanState = state
      , ordinaryTeardownRepairPlanArchitecture =
          retainedArtifactInventoryArchitecture inventory
      , ordinaryTeardownRepairPlanSteps =
          installSteps
            ++ serviceSteps
            ++ fmap RepairLoadRetainedImage imageRefs
            ++ platformSteps
            ++ fmap RepairReconcileRecoveryChart (ordinaryTeardownRecoveryChartNames recovery)
      }

-- | Resolve every required kind, reporting the complete missing set rather
-- than the first hole, so an operator learns the whole retention obligation in
-- one refusal.
resolveRetained
  :: RetainedArtifactInventory
  -> LocalRke2RecoveryStateView
  -> [RetainedArtifactKind]
  -> Either OrdinaryTeardownRepairError [RetainedArtifactRef]
resolveRetained inventory state requiredKinds =
  case NonEmpty.nonEmpty missing of
    Just missingKinds ->
      Left
        ( OrdinaryTeardownRepairUnretainedArtifacts
            state
            (retainedArtifactInventoryArchitecture inventory)
            missingKinds
        )
    Nothing -> Right resolved
 where
  attempted =
    [ (kind, lookupRetainedArtifact kind inventory)
    | kind <- requiredKinds
    ]
  missing = [kind | (kind, Nothing) <- attempted]
  resolved = [ref | (_, Just ref) <- attempted]

-- ---------------------------------------------------------------------------
-- Deletion-survivor projection
-- ---------------------------------------------------------------------------

-- | A recovery-plane resource whose survival across Gateway and application
-- deletion has to be provable from ownership, not from operator habit.
data RecoveryPlaneResource
  = RecoveryPlaneChartRelease !ComponentId
  | RecoveryPlaneCallerServiceAccount
  | RecoveryPlaneCallerSelfTokenRequestRole
  | RecoveryPlaneCallerSelfTokenRequestRoleBinding
  deriving (Eq, Ord, Show)

recoveryPlaneResourceText :: RecoveryPlaneResource -> String
recoveryPlaneResourceText = \case
  RecoveryPlaneChartRelease component -> componentIdText component
  RecoveryPlaneCallerServiceAccount ->
    "bootstrap_core_external_cli_service_account"
  RecoveryPlaneCallerSelfTokenRequestRole ->
    "bootstrap_core_external_cli_self_tokenrequest_role"
  RecoveryPlaneCallerSelfTokenRequestRoleBinding ->
    "bootstrap_core_external_cli_self_tokenrequest_rolebinding"

-- | The Helm release and namespace that own a resource's lifetime.
data RecoveryPlaneResourceOwner = RecoveryPlaneResourceOwner
  { recoveryPlaneResourceOwnerRelease :: !String
  , recoveryPlaneResourceOwnerNamespace :: !String
  }
  deriving (Eq, Ord, Show)

-- | Ownership is derived from the one chart-name registry, and the namespace
-- mirrors the chart platform's root-chart namespace rule.  Nothing here is a
-- copied literal, so a chart rename cannot leave this projection asserting a
-- stale survival claim.
recoveryPlaneResourceOwner :: RecoveryPlaneResource -> Maybe RecoveryPlaneResourceOwner
recoveryPlaneResourceOwner = \case
  RecoveryPlaneChartRelease component -> ownerForChartComponent component
  RecoveryPlaneCallerServiceAccount -> bootstrapCoreOwner
  RecoveryPlaneCallerSelfTokenRequestRole -> bootstrapCoreOwner
  RecoveryPlaneCallerSelfTokenRequestRoleBinding -> bootstrapCoreOwner

ownerForChartComponent :: ComponentId -> Maybe RecoveryPlaneResourceOwner
ownerForChartComponent component = fmap ownerOf (chartNameForComponent component)
 where
  ownerOf chartName =
    RecoveryPlaneResourceOwner
      { recoveryPlaneResourceOwnerRelease = chartName
      , recoveryPlaneResourceOwnerNamespace = chartName
      }

-- | The teardown caller identity lives with bootstrap core.  Its owner is the
-- Bootstrap Broker release, derived from the same registry, never Gateway or
-- an application release.
bootstrapCoreOwner :: Maybe RecoveryPlaneResourceOwner
bootstrapCoreOwner = ownerForChartComponent ComponentChartBootstrapBroker

-- | Every recovery-plane resource whose survival matters, derived from the
-- recovery closure itself.
recoveryPlaneResources :: OrdinaryTeardownRecovery -> [RecoveryPlaneResource]
recoveryPlaneResources recovery =
  [ RecoveryPlaneChartRelease component
  | component <- ordinaryTeardownRecoveryComponentIds recovery
  , Just _ <- [chartNameForComponent component]
  ]
    ++ callerResources
 where
  callerResources
    | RecoveryBootstrapCoreExternalCli
        `elem` ordinaryTeardownRecoveryComponents recovery =
        [ RecoveryPlaneCallerServiceAccount
        , RecoveryPlaneCallerSelfTokenRequestRole
        , RecoveryPlaneCallerSelfTokenRequestRoleBinding
        ]
    | otherwise = []

-- | A deletion expressed the way teardown actually performs it: named Helm
-- releases and named namespaces.
data DeletionScope = DeletionScope
  { deletionScopeReleases :: ![String]
  , deletionScopeNamespaces :: ![String]
  }
  deriving (Eq, Show)

-- | Everything ordinary teardown removes before recovery has to run: every
-- chart component the normal registry knows that the recovery closure does not
-- admit.  Deriving the complement means a new application chart is covered
-- without editing this projection.
gatewayAndApplicationDeletionScope :: OrdinaryTeardownRecovery -> DeletionScope
gatewayAndApplicationDeletionScope recovery =
  DeletionScope
    { deletionScopeReleases = removedChartNames
    , deletionScopeNamespaces = removedChartNames
    }
 where
  retainedChartNames = ordinaryTeardownRecoveryChartNames recovery
  removedChartNames =
    [ chartName
    | node <- defaultComponentGraph
    , Just chartName <- [chartNameForComponent (component_id node)]
    , chartName `notElem` retainedChartNames
    ]

-- | Which recovery-plane resources outlive a deletion, and which do not.
data DeletionSurvivorProjection = DeletionSurvivorProjection
  { deletionSurvivorSurvivors :: ![RecoveryPlaneResource]
  , deletionSurvivorCasualties :: ![RecoveryPlaneResource]
  }
  deriving (Eq, Show)

-- | A resource with no derivable owner is projected as a casualty rather than
-- a survivor: an unattributable lifetime is exactly the defect this projection
-- exists to catch.
projectDeletionSurvivors
  :: OrdinaryTeardownRecovery -> DeletionScope -> DeletionSurvivorProjection
projectDeletionSurvivors recovery scope =
  DeletionSurvivorProjection
    { deletionSurvivorSurvivors = survivors
    , deletionSurvivorCasualties = casualties
    }
 where
  resources = recoveryPlaneResources recovery
  survivors = filter survives resources
  casualties = filter (not . survives) resources
  survives resource = case recoveryPlaneResourceOwner resource of
    Nothing -> False
    Just owner ->
      recoveryPlaneResourceOwnerRelease owner `notElem` deletionScopeReleases scope
        && recoveryPlaneResourceOwnerNamespace owner `notElem` deletionScopeNamespaces scope
