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
  , capacityScaledManagedResources
  , perRunManagedResources
  , longLivedManagedResources
  , desiredPresentManagedResources
  , desiredAbsentManagedResources
  , legacyHarborHelmResource
  , awsSesPulumiResource
  , pulsarTopicManagedResource
  , pairPerRunResidue
  , pairAwsSesResidue
  , resourcesToDestroy
  , residueGateRefusalList
  , reconcileAbsent
  , managedDestroyCapability
  )
where

import Control.Monad (foldM)
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
  , isResiduePresent
  , residueBlocksTeardownGate
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
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
perRunManagedResources :: [ManagedResource]
perRunManagedResources =
  [ ManagedResource
      { resourceName = "aws-eks"
      , resourceClass = PerRun
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws stack eks destroy --yes"
      , resourceDestroyCapability = managedDestroyCapability "aws-eks"
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiEksDestroy True noPlan)
      }
  , ManagedResource
      { resourceName = "aws-eks-subzone"
      , resourceClass = PerRun
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws stack aws-subzone destroy --yes"
      , resourceDestroyCapability = managedDestroyCapability "aws-eks-subzone"
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiAwsSubzoneDestroy True noPlan)
      }
  , ManagedResource
      { resourceName = "aws-test"
      , resourceClass = PerRun
      , resourceEnsureCommand = Nothing
      , resourceEnsurePresent = Nothing
      , resourceDestroyCommand = "prodbox aws stack test destroy --yes"
      , resourceDestroyCapability = managedDestroyCapability "aws-test"
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiTestDestroy True noPlan)
      }
  ]
 where
  noPlan = PlanOptions False Nothing

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
pairPerRunResidue
  :: ResidueStatus -> ResidueStatus -> ResidueStatus -> [(ManagedResource, ResidueStatus)]
pairPerRunResidue eksStatus subzoneStatus testStatus =
  zip perRunManagedResources [eksStatus, subzoneStatus, testStatus]

-- | Sprint 4.26: pair the @aws-ses@ long-lived Pulumi stack resource with
-- its freshly-discovered 'ResidueStatus'. Pure; the singleton list shape
-- composes with 'residueGateRefusalList' the same way 'pairPerRunResidue'
-- does, so the teardown gate's residue list is wholly registry-derived.
pairAwsSesResidue :: ResidueStatus -> [(ManagedResource, ResidueStatus)]
pairAwsSesResidue sesStatus = [(awsSesPulumiResource, sesStatus)]

-- | Pure: the resources a teardown reconcile must destroy — those whose
-- discovered status is 'ResiduePresent'. 'ResidueAbsent' is already
-- gone; 'ResidueUnreachable' is skipped for per-run resources because
-- the per-run lifecycle class treats an unreachable backend as
-- "the state died with the cluster" (the cascade's graceful-degradation
-- exception, per @lifecycle_reconciliation_doctrine.md § 3@ / § 5b).
-- Refuse-on-unreachable is the separate concern of the teardown *gates*
-- ('Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate'), not of
-- this active-destroy reconciler.
resourcesToDestroy :: [(ManagedResource, ResidueStatus)] -> [ManagedResource]
resourcesToDestroy pairs =
  [resource | (resource, status) <- pairs, isResiduePresent status]

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

-- | Reconcile the given (resource, status) pairs toward absent: destroy
-- every 'ResiduePresent' resource in list order, stopping fast on the
-- first non-zero destroy. Skips 'ResidueAbsent' / 'ResidueUnreachable'
-- (see 'resourcesToDestroy'). Emits the per-run destroy narration the
-- cascade used to emit inline.
reconcileAbsent :: FilePath -> [(ManagedResource, ResidueStatus)] -> IO ExitCode
reconcileAbsent repoRoot pairs =
  case resourcesToDestroy pairs of
    [] -> do
      writeOutputLine "Per-run Pulumi destroys: skipped (no live per-run residue)."
      pure ExitSuccess
    present -> do
      writeOutputLine
        ( "Per-run Pulumi destroys: running "
            ++ show (length present)
            ++ " destroy(s) against MinIO..."
        )
      foldM (destroyStep repoRoot) ExitSuccess present

-- | One fold step for 'reconcileAbsent': run the resource's destroy
-- only while the accumulated exit is still success (fail-fast), so the
-- first non-zero destroy short-circuits the rest.
destroyStep :: FilePath -> ExitCode -> ManagedResource -> IO ExitCode
destroyStep repoRoot acc resource = case acc of
  ExitFailure _ -> pure acc
  ExitSuccess -> resourceDestroy resource repoRoot
