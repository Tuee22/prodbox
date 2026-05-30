-- | Sprint 4.20: the pure single-source-of-truth facts for the
-- managed-resource registry — every AWS\/cluster resource @prodbox@ can
-- create, paired with its lifecycle class. This module is deliberately
-- dependency-light (no IO, no AWS\/Pulumi imports) so it can sit below
-- 'Prodbox.Aws' and 'Prodbox.Lifecycle.LiveResidue' without an import
-- cycle: the IO-bearing registry
-- ('Prodbox.Lifecycle.ResourceRegistry', scheduled Sprint 4.21)
-- decorates these facts with @discover@ \/ @destroy@ actions, while
-- 'Prodbox.Aws.perRunStackNames' \/ 'longLivedStackNames' derive their
-- name lists from here.
--
-- The doctrine SSoT is
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md § 3.1@;
-- this list must match
-- @DEVELOPMENT_PLAN\/substrates.md → Resource Lifecycle Classes@
-- verbatim (Sprint 4.22 makes that parity machine-enforced).
module Prodbox.Lifecycle.ResourceClass
  ( LifecycleClass (..)
  , resourceLifecycleClasses
  , resourceNamesOfClass
  , renderRegisteredResourcesMarkdown
  )
where

import Data.List (intercalate)

-- | The lifecycle class of a managed resource. Determines which
-- teardown command reconciles it to absent and which Pulumi-state
-- backend (if any) holds its state.
data LifecycleClass
  = -- | Per-run AWS-substrate Pulumi stacks. State lives in the
    -- in-cluster MinIO backend and dies with the cluster; destroyed by
    -- @prodbox rke2 delete@ and the test-harness postflight.
    PerRun
  | -- | Long-lived cross-substrate shared infrastructure (e.g.
    -- @aws-ses@). State lives in the operator-account S3 backend;
    -- destroyed only by @prodbox pulumi aws-ses-destroy@ / @prodbox
    -- nuke@.
    LongLived
  | -- | Ephemeral operational credentials created by @prodbox aws
    -- setup@ and cleared by @prodbox aws teardown@ (the operational
    -- @prodbox@ IAM user and the operational @aws.*@ config block).
    -- Not Pulumi-backed.
    Operational
  deriving (Eq, Show)

-- | The single source of truth: every managed resource @prodbox@ can
-- create, by canonical name, paired with its lifecycle class. Keep in
-- lockstep with @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle
-- Classes@.
resourceLifecycleClasses :: [(String, LifecycleClass)]
resourceLifecycleClasses =
  [ ("aws-eks", PerRun)
  , ("aws-eks-subzone", PerRun)
  , ("aws-test", PerRun)
  , ("aws-ses", LongLived)
  , ("operational-iam-user", Operational)
  , ("operational-aws-config", Operational)
  ]

-- | The canonical names of every resource in the given lifecycle
-- class, in declaration order.
resourceNamesOfClass :: LifecycleClass -> [String]
resourceNamesOfClass wanted =
  [name | (name, klass) <- resourceLifecycleClasses, klass == wanted]

-- | Sprint 4.22: render 'resourceLifecycleClasses' as a Markdown table,
-- in declaration order. Deterministic (no IO, no sorting, no
-- environment-derived input) so it is safe as a @GeneratedSectionRule@
-- renderer: @prodbox docs generate@ splices this into
-- @DEVELOPMENT_PLAN/substrates.md@ and @prodbox docs check@ fails the
-- build if the doc table drifts from this registry — the machine-
-- enforced registry ↔ doc parity that makes "a creatable-but-
-- undocumented resource" unrepresentable.
renderRegisteredResourcesMarkdown :: [(String, LifecycleClass)] -> String
renderRegisteredResourcesMarkdown entries =
  intercalate
    "\n"
    ( [ "| Resource | Lifecycle class |"
      , "|----------|-----------------|"
      ]
        ++ map renderRow entries
    )
 where
  renderRow (resourceName, klass) =
    "| `" ++ resourceName ++ "` | " ++ renderClass klass ++ " |"
  renderClass klass = case klass of
    PerRun -> "PerRun"
    LongLived -> "LongLived"
    Operational -> "Operational"
