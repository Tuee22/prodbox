{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.21: the IO-bearing managed-resource registry and the
-- 'reconcileAbsent' teardown reconciler that
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md § 3.1@
-- prescribes. Decorates the pure 'Prodbox.Lifecycle.ResourceClass'
-- facts with the @destroy@ action for each resource.
--
-- This sprint wires the per-run subset into
-- 'Prodbox.CLI.Rke2.runNativeDeleteCascade' as a behavior-preserving
-- refactor: 'reconcileAbsent' destroys exactly the per-run stacks the
-- cascade already destroyed, in the same canonical order, using the
-- same 'PulumiCommand's. The long-lived ('aws-ses') and 'Operational'
-- (IAM user, @aws.*@ config) destroy actions land with their consumers
-- in Sprints 7.8 / nuke.
module Prodbox.Lifecycle.ResourceRegistry
  ( ManagedResource (..)
  , AbsentReconcileOutcome (..)
  , capacityScaledManagedResources
  , PerRunStackIdentity (..)
  , perRunStackIdentities
  , perRunManagedResourceFor
  , perRunManagedResources
  , PerRunResidueAnswers (..)
  , perRunResidueAnswerFor
  , longLivedManagedResources
  , desiredPresentManagedResources
  , desiredAbsentManagedResources
  , legacyHarborHelmResource
  , awsSesPulumiResource
  , pulsarTopicManagedResource
  , OperationalResourceIdentity (..)
  , operationalResourceIdentities
  , operationalResourceName
  , operationalManagedResourceFor
  , effectRegistryStaticIdentities
  , effectRegistryLifecycleClassViolations
  , pairPerRunResidue
  , pairAwsSesResidue
  , resourcesToDestroy
  , resourcesObservedAbsent
  , resourcesUnobserved
  , reconcileScopeLabel
  , residueGateRefusalList
  , absentReconcileExitCode
  , reconcileAbsent
  , managedDestroyCapability
  )
where

import Control.Monad (foldM, unless)
import Data.List (intercalate, nub)
import Data.Text qualified as Text
import Prodbox.CLI.Command
  ( PlanOptions (..)
  , PulumiCommand (..)
  )
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.ControlPlane.CapabilityKind (CapabilityKind (ManagedDestroy))
import Prodbox.ControlPlane.CapabilityRef (CapabilityRef, mkCapabilityRef)
import Prodbox.ControlPlane.Coordinate
  ( mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.Lifecycle.HelmRelease qualified as HelmRelease
import Prodbox.Lifecycle.LiveResidue
  ( destroyRetainedPublicEdgeTls
  , publicEdgeTlsResourceName
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus
  , isResidueAbsent
  , isResiduePresent
  , isResidueUnreachable
  , residueBlocksTeardownGate
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..), resourceLifecycleClasses)
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import Prodbox.Pulsar.TopicResidue
  ( ManagedTopic (..)
  , PulsarTopicBroker
  , deleteTopic
  , managedTopicResourceName
  , renderTopicUnobservableReason
  )
import Prodbox.Scaling.Autoscaler qualified as Autoscaler
import System.Exit (ExitCode (..))

-- | One managed resource: its canonical name, lifecycle class (from the
-- 'Prodbox.Lifecycle.ResourceClass' SSoT facts), the canonical operator
-- command that destroys it (the single source of truth for the
-- @(stack-name, destroy-command)@ pairs the teardown refusal surfaces),
-- and the action that destroys it idempotently (the underlying @pulumi
-- destroy@ / delete is a no-op when the resource is already gone).
data ManagedResource = ManagedResource
  { resourceName :: String
  , resourceClass :: LifecycleClass
  , resourceEnsureCommand :: Maybe String
  , resourceEnsurePresent :: Maybe (FilePath -> IO ExitCode)
  , resourceDestroyCommand :: String
  , resourceDestroyCapability :: Either String (CapabilityRef 'ManagedDestroy)
  , resourceDestroy :: FilePath -> IO ExitCode
  }

managedDestroyCapability :: String -> Either String (CapabilityRef 'ManagedDestroy)
managedDestroyCapability logical = do
  service <- firstShow (mkServiceIdentity "lifecycle-provider-worker")
  scope <- firstShow (mkAuthorityScope "home/prodbox")
  endpoint <- firstShow (mkCapabilityEndpoint "provider-worker:8443")
  name <- firstShow (mkLogicalName (Text.pack logical))
  generation <- firstShow (mkCredentialGeneration 1)
  pure (mkCapabilityRef (mkCoordinate service scope endpoint name generation))
 where
  firstShow :: (Show errorType) => Either errorType value -> Either String value
  firstShow = either (Left . show) Right

-- | Sprint 4.34: the chart workloads whose replica counts are governed by the
-- pure autoscaler planner. Their live scale-up / scale-down interpreter is
-- separate from the Pulumi-stack destroy registry, but exposing the names here
-- keeps capacity-scaled resources discoverable from the lifecycle registry
-- surface.
capacityScaledManagedResources :: [String]
capacityScaledManagedResources = Autoscaler.capacityScaledResourceNames

-- | The per-run Pulumi stacks as managed resources, in the canonical
-- teardown order @aws-eks → aws-eks-subzone → aws-test@ (so dependent
-- VPC / subnet residue tears down before the broader network
-- substrate). The destroy actions are exactly the 'PulumiCommand's the
-- cascade ran before Sprint 4.21, so wiring them in is behavior-
-- preserving.
-- | Sprint 4.84: the closed set of per-run AWS stacks the cascade owns.
--
-- It exists so the registry entry for a stack and the residue answer /about/
-- that stack are selected by the same value. 'pairPerRunResidue' previously
-- @zip@ped two independently written lists, so the pairing was correct only
-- while their orders happened to agree: reordering the registry, or adding a
-- fourth stack, would have attached one stack\'s observation to another
-- stack\'s destroy command with nothing to catch it. Both directions are now
-- total functions of this type, so adding a stack is an exhaustiveness failure
-- rather than a silent misalignment.
--
-- Constructor order is the documented teardown order — @aws-eks →
-- aws-eks-subzone → aws-test@, so dependent VPC\/subnet residue tears down
-- before the broader network substrate — and a focused case pins it.
data PerRunStackIdentity
  = PerRunAwsEks
  | PerRunAwsEksSubzone
  | PerRunAwsTest
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Every per-run stack, in teardown order.
perRunStackIdentities :: [PerRunStackIdentity]
perRunStackIdentities = [minBound .. maxBound]

perRunManagedResourceFor :: PerRunStackIdentity -> ManagedResource
perRunManagedResourceFor identity = case identity of
  PerRunAwsEks ->
    ManagedResource
      { resourceName = "aws-eks"
      , resourceClass = PerRun
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws stack eks destroy --yes"
      , resourceDestroyCapability = managedDestroyCapability "aws-eks"
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiEksDestroy True noPlan)
      }
  PerRunAwsEksSubzone ->
    ManagedResource
      { resourceName = "aws-eks-subzone"
      , resourceClass = PerRun
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws stack aws-subzone destroy --yes"
      , resourceDestroyCapability = managedDestroyCapability "aws-eks-subzone"
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiAwsSubzoneDestroy True noPlan)
      }
  PerRunAwsTest ->
    ManagedResource
      { resourceName = "aws-test"
      , resourceClass = PerRun
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws stack test destroy --yes"
      , resourceDestroyCapability = managedDestroyCapability "aws-test"
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiTestDestroy True noPlan)
      }
 where
  noPlan = PlanOptions False Nothing

perRunManagedResources :: [ManagedResource]
perRunManagedResources = map perRunManagedResourceFor perRunStackIdentities

-- | Sprint 4.24: the long-lived managed resources whose @destroy@ is
-- an S3-object operation rather than a @pulumi destroy@. Today this is
-- the retained public-edge production TLS certificate material in the
-- long-lived @pulumi_state_backend@ bucket. These are 'LongLived' and
-- so are never reconciled by @rke2 delete@ / @aws teardown@; @prodbox
-- nuke@ removes the certificate transitively when it destroys the
-- whole long-lived bucket, and this registered @destroy@ is the
-- explicit per-resource path. (The @aws-ses@ long-lived stack keeps
-- its existing 'Prodbox.CLI.Nuke' Pulumi-destroy wiring.)
longLivedManagedResources :: [ManagedResource]
longLivedManagedResources =
  [ ManagedResource
      { resourceName = publicEdgeTlsResourceName
      , resourceClass = LongLived
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox nuke"
      , resourceDestroyCapability = managedDestroyCapability publicEdgeTlsResourceName
      , resourceDestroy = destroyPublicEdgeTlsCertificate
      }
  ]

-- | Sprint 4.84: the closed set of operational resources @prodbox aws
-- teardown@ owns.
--
-- Their entries were authored in "Prodbox.Aws", which meant the module that
-- supplies the /effect/ also authored the identity, the lifecycle class, and
-- the operator-facing command text — so a caller outside the registry could
-- register a name the registry never declared, or classify one of them as
-- anything at all. The registry now owns every field except the effect, and
-- the effect arrives per identity through a total function, so membership
-- determines the identity and its class even though the action still lives
-- with its credentials.
data OperationalResourceIdentity
  = OperationalAwsSesLeaseRole
  | OperationalIamUser
  | OperationalAwsConfig
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalResourceIdentities :: [OperationalResourceIdentity]
operationalResourceIdentities = [minBound .. maxBound]

operationalResourceName :: OperationalResourceIdentity -> String
operationalResourceName identity = case identity of
  OperationalAwsSesLeaseRole -> "operational-aws-ses-lease-role"
  OperationalIamUser -> "operational-iam-user"
  OperationalAwsConfig -> "operational-aws-config"

-- | Build one operational registry entry from its identity and its effect.
--
-- Only 'resourceDestroy' is supplied by the caller. The name, class, and
-- command text are the registry\'s.
operationalManagedResourceFor
  :: OperationalResourceIdentity -> (FilePath -> IO ExitCode) -> ManagedResource
operationalManagedResourceFor identity destroy =
  ManagedResource
    { resourceName = name
    , resourceClass = Operational
    , resourceEnsureCommand = case identity of
        OperationalAwsSesLeaseRole -> Just "prodbox aws setup"
        OperationalIamUser -> Nothing
        OperationalAwsConfig -> Nothing
    , resourceEnsurePresent = Nothing
    , resourceDestroyCommand = "prodbox aws teardown"
    , resourceDestroyCapability = managedDestroyCapability name
    , resourceDestroy = destroy
    }
 where
  name = operationalResourceName identity

-- | Sprint 4.84: every statically named identity the effect-bearing registry
-- mints, paired with the lifecycle class that entry actually carries.
--
-- Read off the constructed entries rather than restated, so this cannot become
-- a fourth independent statement of the same fact. Dynamic families — Pulsar
-- topics and the run-time-named DNS validation zone — are deliberately absent:
-- their concrete names are produced at run time and only their family rows are
-- registrable.
effectRegistryStaticIdentities :: [(String, LifecycleClass)]
effectRegistryStaticIdentities =
  map
    identityOf
    ( perRunManagedResources
        ++ longLivedManagedResources
        ++ [awsSesPulumiResource, legacyHarborHelmResource]
        ++ map
          (\identity -> operationalManagedResourceFor identity unusedDestroy)
          operationalResourceIdentities
    )
 where
  identityOf resource = (resourceName resource, resourceClass resource)
  -- The projection reads name and class only; this effect is never run, and
  -- reading the real constructed entry is what keeps the pair honest.
  unusedDestroy _ = pure (ExitFailure 1)

-- | Sprint 4.84: join the effect-bearing registry to the flat lifecycle
-- inventory.
--
-- @resourceClass@ was a third independent statement of a resource\'s lifecycle
-- class, after the typed teardown registry and @resourceLifecycleClasses@, and
-- nothing joined it to either. It is not decorative: it selects the operator-
-- facing scope label for a destructive reconcile batch, and
-- @resourceLifecycleClasses@ is the table @guardTestDelete@ refuses against and
-- @substrates.md@ publishes. Two tables disagreeing about one resource\'s class
-- is what Sprint 4.84 already corrected between the typed registry and the flat
-- inventory; this closes the same join for the third table.
effectRegistryLifecycleClassViolations :: [String]
effectRegistryLifecycleClassViolations =
  concatMap violationFor effectRegistryStaticIdentities
 where
  violationFor (name, registered) = case lookup name resourceLifecycleClasses of
    Nothing ->
      [ "the effect-bearing managed-resource registry registers `"
          ++ name
          ++ "` but resourceLifecycleClasses has no row for it; add it to "
          ++ "src/Prodbox/Lifecycle/ResourceClass.hs "
          ++ "(lifecycle_reconciliation_doctrine.md \167\&3.1 totality)."
      ]
    Just flatClass
      | flatClass == registered -> []
      | otherwise ->
          [ "`"
              ++ name
              ++ "` is "
              ++ show registered
              ++ " in the effect-bearing managed-resource registry but "
              ++ show flatClass
              ++ " in resourceLifecycleClasses; a resource has exactly one "
              ++ "static lifecycle class (lifecycle_reconciliation_doctrine.md \167\&3.1)."
          ]

-- | Sprint 4.26: the @aws-ses@ long-lived Pulumi stack as a managed
-- resource. Kept separate from 'longLivedManagedResources' (the S3-object
-- destroy class, today just @public-edge-tls@) because @aws-ses@ is a
-- Pulumi-stack destroy with its own admin-credentialed flow. This is the
-- registry SSoT for the @aws-ses@ teardown-gate pairing — the residue
-- refusal that @prodbox aws teardown@ surfaces no longer hand-maintains
-- the @(stack-name, destroy-command)@ pair.
awsSesPulumiResource :: ManagedResource
awsSesPulumiResource =
  ManagedResource
    { resourceName = "aws-ses"
    , resourceClass = LongLived
    , resourceEnsureCommand = Just "prodbox aws stack aws-ses reconcile"
    , resourceEnsurePresent =
        Just
          ( \repoRoot ->
              runPulumiCommand repoRoot (PulumiAwsSesResources (PlanOptions False Nothing))
          )
    , resourceDestroyCommand = "prodbox aws stack aws-ses destroy --yes"
    , resourceDestroyCapability = managedDestroyCapability "aws-ses"
    , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiAwsSesDestroy True (PlanOptions False Nothing))
    }

-- | The registry projection that supports desired-present reconciliation.
-- Long-lived classification controls ordinary cleanup; this independent
-- projection controls capability-derived preparation. Today only the fixed
-- account-scoped @aws-ses@ stack has a registered ensure action.
desiredPresentManagedResources :: [ManagedResource]
desiredPresentManagedResources = [awsSesPulumiResource]

-- | Resources retained only for cleanup compatibility. They can never be
-- ensured present; their registered program is observe → destroy → exact
-- absence read-back.
desiredAbsentManagedResources :: [ManagedResource]
desiredAbsentManagedResources = [legacyHarborHelmResource]

legacyHarborHelmResource :: ManagedResource
legacyHarborHelmResource =
  ManagedResource
    { resourceName = "legacy-harbor-helm-release"
    , resourceClass = PerRun
    , resourceEnsureCommand = Nothing
    , resourceEnsurePresent = Nothing
    , resourceDestroyCommand = "prodbox cluster reconcile"
    , resourceDestroyCapability = managedDestroyCapability "legacy-harbor-helm-release"
    , resourceDestroy = destroyLegacyHarborRelease
    }

destroyLegacyHarborRelease :: FilePath -> IO ExitCode
destroyLegacyHarborRelease repoRoot =
  case HelmRelease.mkHelmReleaseCoordinate "harbor" "harbor" of
    Left coordinateError -> do
      writeDiagnosticLine ("Legacy Harbor release coordinate is invalid: " ++ show coordinateError)
      pure (ExitFailure 1)
    Right coordinate -> do
      result <- HelmRelease.reconcileHelmReleaseAbsent repoRoot coordinate
      case result of
        Left failure -> do
          writeDiagnosticLine
            ("Legacy Harbor release desired-absence reconciliation failed: " ++ show failure)
          pure (ExitFailure 1)
        Right outcome -> do
          writeOutputLine ("Legacy Harbor release absence: " ++ show outcome)
          pure ExitSuccess

-- | Sprint 4.35: adapt a typed Pulsar topic into the managed-resource
-- registry. Topics are dynamic broker resources, so the static
-- 'resourceLifecycleClasses' table registers the per-run / long-lived
-- topic families while this adapter carries the concrete algebra-derived
-- topic name and broker delete action.
pulsarTopicManagedResource :: PulsarTopicBroker -> ManagedTopic -> ManagedResource
pulsarTopicManagedResource broker topic =
  ManagedResource
    { resourceName = managedTopicResourceName topic
    , resourceClass = managedTopicClass topic
    , resourceEnsureCommand = Nothing
    , resourceEnsurePresent = Nothing
    , resourceDestroyCommand =
        case managedTopicClass topic of
          PerRun -> "prodbox cluster delete --cascade"
          LongLived -> "prodbox nuke"
          Operational -> "prodbox nuke"
    , resourceDestroyCapability = managedDestroyCapability (managedTopicResourceName topic)
    , resourceDestroy = \_repoRoot -> do
        result <- deleteTopic broker topic
        case result of
          Right () -> pure ExitSuccess
          Left reason -> do
            writeDiagnosticLine
              ( "Pulsar topic destroy failed: "
                  ++ renderTopicUnobservableReason reason
              )
            pure (ExitFailure 1)
    }

-- | Adapt 'destroyRetainedPublicEdgeTls' (which reports a structured
-- @Either String ()@) to the 'ManagedResource' @destroy@ shape
-- (@FilePath -> IO ExitCode@), emitting operator-visible narration.
destroyPublicEdgeTlsCertificate :: FilePath -> IO ExitCode
destroyPublicEdgeTlsCertificate repoRoot = do
  result <- destroyRetainedPublicEdgeTls repoRoot
  case result of
    Right () -> do
      writeOutputLine
        "Retained public-edge TLS certificate: removed from the long-lived S3 store."
      pure ExitSuccess
    Left err -> do
      writeDiagnosticLine
        ("Retained public-edge TLS certificate destroy failed: " ++ err)
      pure (ExitFailure 1)

-- | Pair each per-run managed resource with its freshly-discovered
-- 'ResidueStatus', in canonical order. The caller resolves all three
-- statuses in one shared MinIO port-forward
-- ('Prodbox.Lifecycle.LiveResidue.queryPerRunResidueStatuses') and
-- hands them here, so 'reconcileAbsent' does not re-discover per
-- resource (preserving the single-port-forward batching). Pure; the
-- argument order is @aws-eks@, @aws-eks-subzone@, @aws-test@.
-- | Sprint 4.84: one residue answer per per-run stack, named by the stack it
-- is an answer about.
--
-- The three fields replace three positional arguments. Swapping two at a call
-- site was previously invisible — every argument had type 'ResidueStatus' —
-- and would have reported the @aws-test@ stack\'s presence under the
-- @aws-eks@ destroy command.
data PerRunResidueAnswers = PerRunResidueAnswers
  { perRunAnswerAwsEks :: !ResidueStatus
  , perRunAnswerAwsEksSubzone :: !ResidueStatus
  , perRunAnswerAwsTest :: !ResidueStatus
  }
  deriving (Eq, Show)

perRunResidueAnswerFor :: PerRunStackIdentity -> PerRunResidueAnswers -> ResidueStatus
perRunResidueAnswerFor identity answers = case identity of
  PerRunAwsEks -> perRunAnswerAwsEks answers
  PerRunAwsEksSubzone -> perRunAnswerAwsEksSubzone answers
  PerRunAwsTest -> perRunAnswerAwsTest answers

-- | Join each per-run registry entry to its own observation.
--
-- Both sides are selected by the same 'PerRunStackIdentity', so the join is
-- correct by construction rather than by two list orders agreeing.
pairPerRunResidue :: PerRunResidueAnswers -> [(ManagedResource, ResidueStatus)]
pairPerRunResidue answers =
  [ (perRunManagedResourceFor identity, perRunResidueAnswerFor identity answers)
  | identity <- perRunStackIdentities
  ]

-- | Sprint 4.26: pair the @aws-ses@ long-lived Pulumi stack resource with
-- its freshly-discovered 'ResidueStatus'. Pure; the singleton list shape
-- composes with 'residueGateRefusalList' the same way 'pairPerRunResidue'
-- does, so the teardown gate's residue list is wholly registry-derived.
pairAwsSesResidue :: ResidueStatus -> [(ManagedResource, ResidueStatus)]
pairAwsSesResidue sesStatus = [(awsSesPulumiResource, sesStatus)]

-- | Pure: the resources a teardown reconcile must destroy — those whose
-- discovered status is 'ResiduePresent'. 'ResidueAbsent' is already
-- gone; 'ResidueUnreachable' has no destroy to run against it, because
-- there is no readable checkpoint to destroy from (the cascade's
-- graceful-degradation exception, per
-- @lifecycle_reconciliation_doctrine.md § 3@ / § 5b).
--
-- Sprint 4.76 states the bound that the pre-4.76 haddock overstated:
-- skipping the destroy is **not** a judgement that "the state died with
-- the cluster", and this predicate does not license narrating it as one.
-- 'resourcesUnobserved' carries that set to the caller, and
-- 'absentReconcileExitCode' keeps it out of a success. Refuse-on-
-- unreachable at the *gates* remains the separate concern of
-- 'Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate'.
resourcesToDestroy :: [(ManagedResource, ResidueStatus)] -> [ManagedResource]
resourcesToDestroy pairs =
  [resource | (resource, status) <- pairs, isResiduePresent status]

-- | Sprint 4.76 (pure): the resources whose absence was **positively
-- observed**. This is the only set about which a caller may narrate
-- "gone".
resourcesObservedAbsent :: [(ManagedResource, ResidueStatus)] -> [ManagedResource]
resourcesObservedAbsent pairs =
  [resource | (resource, status) <- pairs, isResidueAbsent status]

-- | Sprint 4.76 (pure): the resources whose state could not be read at
-- all. 'reconcileAbsent' still skips their destroys — that is the
-- cascade's documented per-run graceful degradation
-- (@lifecycle_reconciliation_doctrine.md § 3.1@ invariant 3) — but the
-- skip is now carried out of the reconciler so the aggregate can
-- withhold success instead of reporting an absence nobody observed.
resourcesUnobserved :: [(ManagedResource, ResidueStatus)] -> [ManagedResource]
resourcesUnobserved pairs =
  [resource | (resource, status) <- pairs, isResidueUnreachable status]

-- | Sprint 4.26 (pure): the registry-derived @(stack-name,
-- destroy-command)@ list the teardown *refuse-gates* consume, replacing
-- the parallel hand-maintained 'Prodbox.Aws.categorizePulumiResidue'
-- classifier. A resource enters the list when its discovered status
-- *blocks the teardown gate* — 'residueBlocksTeardownGate' is "present
-- OR unreachable → block", because "cannot read the Pulumi state
-- backend" is not a confirmation that the AWS resources are gone, so the
-- gate must refuse rather than strand unreadable stacks. (This is the
-- gate semantics, distinct from 'resourcesToDestroy' / 'reconcileAbsent'
-- which skip 'ResidueUnreachable' for the cascade's per-run graceful
-- degradation.) The command string is the registry SSoT
-- 'resourceDestroyCommand', so it cannot drift from the destroy action.
residueGateRefusalList :: [(ManagedResource, ResidueStatus)] -> [(String, String)]
residueGateRefusalList pairs =
  [ (resourceName resource, resourceDestroyCommand resource)
  | (resource, status) <- pairs
  , residueBlocksTeardownGate status
  ]

-- | Sprint 4.76: what a desired-absent reconcile actually observed and
-- did, so the caller can aggregate rather than infer.
--
-- Before this sprint 'reconcileAbsent' returned a bare 'ExitCode' and
-- an empty destroy list printed @"skipped (no live per-run residue)"@ —
-- a claim of absence that an all-'ResidueUnreachable' input satisfies
-- exactly as well as an all-'ResidueAbsent' one. The two inputs are now
-- distinguishable at the type level for every caller.
data AbsentReconcileOutcome = AbsentReconcileOutcome
  { absentReconcileDestroyExit :: !ExitCode
  -- ^ Exit of the destroy fold alone (not of the reconcile as a whole).
  , absentReconcileObservedAbsent :: ![String]
  -- ^ Resources positively observed gone. Nothing was run for these,
  -- and saying so is honest.
  , absentReconcileUnobserved :: ![String]
  -- ^ Resources whose live state could not be read. Their destroys were
  -- skipped, and their presence or absence remains unknown.
  }
  deriving (Eq, Show)

-- | The reconcile's aggregate verdict: a failed destroy fails, and so
-- does an unresolved observation. @lifecycle_reconciliation_doctrine.md
-- § 5b@ phase 1 — an unreachable checkpoint "records an unresolved
-- cleanup failure … the aggregate cannot report success".
absentReconcileExitCode :: AbsentReconcileOutcome -> ExitCode
absentReconcileExitCode outcome = case absentReconcileDestroyExit outcome of
  failure@(ExitFailure _) -> failure
  ExitSuccess
    | null (absentReconcileUnobserved outcome) -> ExitSuccess
    | otherwise -> ExitFailure 1

-- | Sprint 4.76 (pure): the operator-visible class label for a reconcile
-- batch, derived from the registry entries' own 'LifecycleClass' rather
-- than restated at the call site. Before this sprint the narration said
-- "Per-run" unconditionally, including on @prodbox aws teardown@'s
-- 'Operational' batch.
reconcileScopeLabel :: [(ManagedResource, ResidueStatus)] -> String
reconcileScopeLabel pairs = case nub (map (resourceClass . fst) pairs) of
  [PerRun] -> "Per-run"
  [LongLived] -> "Long-lived"
  [Operational] -> "Operational"
  _ -> "Managed"

-- | Reconcile the given (resource, status) pairs toward absent: destroy
-- every 'ResiduePresent' resource in list order, stopping fast on the
-- first non-zero destroy. Skips 'ResidueAbsent' and 'ResidueUnreachable'
-- alike (see 'resourcesToDestroy') but narrates them **separately**, and
-- reports the unobserved set to the caller so the skip can reach the
-- aggregate exit code.
reconcileAbsent
  :: FilePath -> [(ManagedResource, ResidueStatus)] -> IO AbsentReconcileOutcome
reconcileAbsent repoRoot pairs = do
  let scope = reconcileScopeLabel pairs
      present = resourcesToDestroy pairs
      observedAbsent = map resourceName (resourcesObservedAbsent pairs)
      unobserved = map resourceName (resourcesUnobserved pairs)
  unless (null observedAbsent) $
    writeOutputLine
      ( scope
          ++ " residue observed ABSENT (nothing to destroy): "
          ++ intercalate ", " observedAbsent
          ++ "."
      )
  unless (null unobserved) $
    writeDiagnosticLine
      ( scope
          ++ " residue NOT OBSERVED for "
          ++ intercalate ", " unobserved
          ++ ": the state backend could not be read. This is not a confirmation "
          ++ "that the resources are gone. Their destroys are skipped and this "
          ++ "run cannot report success until the state is resolved — destroy "
          ++ "them explicitly once the backend is readable."
      )
  destroyExit <- case present of
    [] -> do
      writeOutputLine
        ( scope
            ++ " Pulumi destroys: none run ("
            ++ narrateNoDestroys observedAbsent unobserved
            ++ ")."
        )
      pure ExitSuccess
    _ -> do
      writeOutputLine
        ( scope
            ++ " Pulumi destroys: running "
            ++ show (length present)
            ++ " destroy(s) against MinIO..."
        )
      foldM (destroyStep repoRoot) ExitSuccess present
  pure
    AbsentReconcileOutcome
      { absentReconcileDestroyExit = destroyExit
      , absentReconcileObservedAbsent = observedAbsent
      , absentReconcileUnobserved = unobserved
      }

-- | Why no destroy ran. Deliberately total over the two skip reasons, so
-- an all-unobserved batch cannot borrow the all-absent sentence.
narrateNoDestroys :: [String] -> [String] -> String
narrateNoDestroys observedAbsent unobserved = case (observedAbsent, unobserved) of
  ([], []) -> "no resources registered for this reconcile"
  (_, []) -> "every registered resource was observed absent"
  ([], _) ->
    "no resource was observed present; "
      ++ show (length unobserved)
      ++ " could not be observed at all"
  (_, _) ->
    show (length observedAbsent)
      ++ " observed absent, "
      ++ show (length unobserved)
      ++ " not observed"

-- | One fold step for 'reconcileAbsent': run the resource's destroy
-- only while the accumulated exit is still success (fail-fast), so the
-- first non-zero destroy short-circuits the rest.
destroyStep :: FilePath -> ExitCode -> ManagedResource -> IO ExitCode
destroyStep repoRoot acc resource = case acc of
  ExitFailure _ -> pure acc
  ExitSuccess -> resourceDestroy resource repoRoot
