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
  , perRunManagedResources
  , longLivedManagedResources
  , pairPerRunResidue
  , resourcesToDestroy
  , reconcileAbsent
  )
where

import Control.Monad (foldM)
import Prodbox.CLI.Command
  ( PlanOptions (..)
  , PulumiCommand (..)
  )
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.Lifecycle.LiveResidue
  ( destroyRetainedPublicEdgeTls
  , publicEdgeTlsResourceName
  )
import Prodbox.Lifecycle.ResidueStatus (ResidueStatus, isResiduePresent)
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import System.Exit (ExitCode (..))

-- | One managed resource: its canonical name, lifecycle class (from the
-- 'Prodbox.Lifecycle.ResourceClass' SSoT facts), and the action that
-- destroys it idempotently (the underlying @pulumi destroy@ / delete is
-- a no-op when the resource is already gone).
data ManagedResource = ManagedResource
  { resourceName :: String
  , resourceClass :: LifecycleClass
  , resourceDestroy :: FilePath -> IO ExitCode
  }

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
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiEksDestroy True noPlan)
      }
  , ManagedResource
      { resourceName = "aws-eks-subzone"
      , resourceClass = PerRun
      , resourceDestroy = \repoRoot -> runPulumiCommand repoRoot (PulumiAwsSubzoneDestroy True noPlan)
      }
  , ManagedResource
      { resourceName = "aws-test"
      , resourceClass = PerRun
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
      , resourceDestroy = destroyPublicEdgeTlsCertificate
      }
  ]

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
