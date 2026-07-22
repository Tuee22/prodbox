-- | Sprint 4.20: the pure single-source-of-truth facts for the
-- managed-resource registry — every AWS\/cluster resource @prodbox@ can
-- create, paired with its lifecycle class. This module is deliberately
-- dependency-light (no IO, no AWS\/Pulumi imports) so it can sit below
-- 'Prodbox.Aws' and 'Prodbox.Lifecycle.LiveResidue' without an import
-- cycle: the IO-bearing registry
-- ('Prodbox.Lifecycle.ResourceRegistry', scheduled Sprint 4.21)
-- decorates these facts with @discover@ \/ @destroy@ actions, while
-- 'Prodbox.Aws.longLivedResourceNames' derives its name list from here
-- (and 'Prodbox.Aws.perRunStackNames' from the 'StackDescriptor' SSoT,
-- whose per-run registry names must match the @PerRun@ slice here).
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
    -- @prodbox cluster delete@ and the test-harness postflight.
    PerRun
  | -- | Long-lived cross-substrate shared infrastructure (e.g.
    -- @aws-ses@). State lives in the operator-account S3 backend;
    -- destroyed only by @prodbox aws stack aws-ses destroy@ / @prodbox
    -- nuke@.
    LongLived
  | -- | Ephemeral operational credentials created by @prodbox aws
    -- setup@ and cleared by @prodbox aws teardown@ (the operational
    -- SES lease role, the @prodbox@ IAM user, and the operational
    -- @aws.*@ config block).
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
  , -- Sprint 4.35: dynamic Pulsar topics whose backlog dies with a
    -- single validation/workflow run. Individual topic names are
    -- produced by the typed topic algebra; this family row keeps their
    -- lifecycle class registered without pretending every topic is a
    -- Pulumi stack.
    ("pulsar-topics-per-run", PerRun)
  , ("aws-ses", LongLived)
  , -- Sprint 4.39: pre-created EBS volumes that back EKS static
    -- @Retain@ PersistentVolumes. Production-retained volumes carry
    -- @prodbox.io/lifecycle=retained-ebs@ and survive cluster teardown;
    -- test-scoped volumes carry @prodbox.io/lifecycle=per-run-test@
    -- plus the EKS @kubernetes.io/cluster/<name>=owned@ tag and are
    -- destroyed by the typed EC2 discover/destroy path instead of a
    -- Pulumi stack destroy.
    ("aws-ebs-volumes", LongLived)
  , -- Sprint 4.24: the retained public-edge TLS certificate
    -- material, written to a substrate-scoped key
    -- (@public-edge-tls/\<substrate\>/\<canonical-scope-key\>@) in the long-lived
    -- @pulumi_state_backend@ S3 bucket. Classified 'LongLived' (the same
    -- class as @aws-ses@) because re-ordering the certificate on every
    -- rebuild would consume the ZeroSSL ACME issuance quota; the cert is
    -- retained and restored instead, making it a rate-limited external
    -- resource, not disposable @PerRun@ chart state. Unlike the
    -- other long-lived entry it is an S3 *object* class rather than a
    -- Pulumi stack; @prodbox nuke@ removes it transitively when it
    -- destroys the long-lived bucket.
    ("public-edge-tls", LongLived)
  , -- Sprint 4.35: dynamic retained Pulsar topics whose offloaded
    -- backlog draws from the finite durable-store budget and survives
    -- a single run. Destroyed only through explicit long-lived
    -- teardown.
    ("pulsar-topics-long-lived", LongLived)
  , ("operational-aws-ses-lease-role", Operational)
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
