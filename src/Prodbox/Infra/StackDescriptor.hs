-- | Sprint 4.27: the single source of truth for the Pulumi-managed AWS
-- substrate stacks. Each stack was previously described by several
-- parallel hand-maintained facts — its registry name, Pulumi stack id,
-- project subdir under @pulumi/@, its CLI verb stem
-- (@eks@\/@test@\/@aws-subzone@\/@aws-ses@), and its lifecycle class —
-- scattered across 'Prodbox.Aws', 'Prodbox.Lifecycle.ResourceClass',
-- 'Prodbox.CLI.Pulumi', and 'Prodbox.CLI.Spec', and prone to drift. This
-- record collapses them into one typed list; the per-run name list, the
-- CLI verbs, the project dirs, and the generated registry-name↔CLI-command
-- doc section are all DERIVED from it.
--
-- This module is deliberately dependency-light (no IO, no AWS\/Pulumi
-- imports) so it can sit below 'Prodbox.Aws' and 'Prodbox.CLI.Pulumi'
-- without an import cycle; it imports only the 'LifecycleClass' ADT from
-- 'Prodbox.Lifecycle.ResourceClass' (the lower-level registry of every
-- creatable resource, of which the Pulumi-managed stacks are the
-- @PerRun@\/@LongLived@-and-stack-backed subset).
--
-- The doctrine SSoT is
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md § 3.1@ and
-- @DEVELOPMENT_PLAN\/substrates.md → Resource Lifecycle Classes@; the
-- @registryName@ of every descriptor here must appear in
-- 'Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses' with the
-- matching class (a unit test pins the parity).
module Prodbox.Infra.StackDescriptor
  ( StackDescriptor (..)
  , stackDescriptors
  , stackResourcesCliVerb
  , stackDestroyCliVerb
  , perRunStackDescriptorNames
  , stackProjectSubdirs
  , stackCliVerbs
  , renderStackCommandSurfaceMarkdown
  )
where

import Data.List (intercalate)
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))

-- | One Pulumi-managed AWS substrate stack, with every hand-maintained
-- fact that used to live in a separate parallel list.
data StackDescriptor = StackDescriptor
  { stackRegistryName :: String
  -- ^ The canonical registry name (e.g. @aws-eks@) — matches the
  -- managed-resource registry key in
  -- 'Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses'.
  , stackPulumiStackId :: String
  -- ^ The Pulumi stack id passed to @pulumi --stack@. Usually equals
  -- 'stackRegistryName', but the EKS validation stack is the registry
  -- name @aws-eks@ provisioned under the Pulumi stack id
  -- @aws-eks-test@.
  , stackProjectSubdir :: String
  -- ^ The project subdir under @pulumi/@ holding @Pulumi.yaml@ +
  -- @Main.yaml@.
  , stackCliVerb :: String
  -- ^ The CLI verb stem: the @<stem>@ in @prodbox pulumi
  -- <stem>-resources@ / @prodbox pulumi <stem>-destroy@.
  , stackLifecycleClass :: LifecycleClass
  -- ^ The lifecycle class. Pulumi-managed stacks are either @PerRun@
  -- (auto-managed per suite run) or @LongLived@ (retained shared
  -- infrastructure).
  }
  deriving (Eq, Show)

-- | The single source of truth: every Pulumi-managed AWS substrate
-- stack, in canonical declaration order. The per-run subset's order must
-- match @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@
-- (@aws-eks@, @aws-eks-subzone@, @aws-test@) so the derived
-- 'perRunStackDescriptorNames' equals the prior literal.
stackDescriptors :: [StackDescriptor]
stackDescriptors =
  [ StackDescriptor
      { stackRegistryName = "aws-eks"
      , stackPulumiStackId = "aws-eks-test"
      , stackProjectSubdir = "aws-eks"
      , stackCliVerb = "eks"
      , stackLifecycleClass = PerRun
      }
  , StackDescriptor
      { stackRegistryName = "aws-eks-subzone"
      , stackPulumiStackId = "aws-eks-subzone"
      , stackProjectSubdir = "aws-eks-subzone"
      , stackCliVerb = "aws-subzone"
      , stackLifecycleClass = PerRun
      }
  , StackDescriptor
      { stackRegistryName = "aws-test"
      , stackPulumiStackId = "aws-test"
      , stackProjectSubdir = "aws-test"
      , stackCliVerb = "test"
      , stackLifecycleClass = PerRun
      }
  , StackDescriptor
      { stackRegistryName = "aws-ses"
      , stackPulumiStackId = "aws-ses"
      , stackProjectSubdir = "aws-ses"
      , stackCliVerb = "aws-ses"
      , stackLifecycleClass = LongLived
      }
  ]

-- | The @prodbox pulumi <verb>-resources@ command for a descriptor.
stackResourcesCliVerb :: StackDescriptor -> String
stackResourcesCliVerb descriptor = stackCliVerb descriptor ++ "-resources"

-- | The @prodbox pulumi <verb>-destroy@ command for a descriptor.
stackDestroyCliVerb :: StackDescriptor -> String
stackDestroyCliVerb descriptor = stackCliVerb descriptor ++ "-destroy"

-- | The registry names of the per-run Pulumi-managed stacks, in
-- declaration order. Derived from 'stackDescriptors'; must equal the
-- prior @["aws-eks", "aws-eks-subzone", "aws-test"]@ literal and the
-- @PerRun@ slice of the managed-resource registry (a unit test pins
-- both).
perRunStackDescriptorNames :: [String]
perRunStackDescriptorNames =
  [ stackRegistryName descriptor
  | descriptor <- stackDescriptors
  , stackLifecycleClass descriptor == PerRun
  ]

-- | The project subdirs under @pulumi/@ of every Pulumi-managed stack,
-- in declaration order. Derived from 'stackDescriptors'.
stackProjectSubdirs :: [String]
stackProjectSubdirs = map stackProjectSubdir stackDescriptors

-- | The CLI verb stems of every Pulumi-managed stack, in declaration
-- order. Derived from 'stackDescriptors'.
stackCliVerbs :: [String]
stackCliVerbs = map stackCliVerb stackDescriptors

-- | Sprint 4.27: render the registry-name↔CLI-command table from
-- 'stackDescriptors', in declaration order. Deterministic (no IO, no
-- sorting, no environment-derived input) so it is safe as a
-- @GeneratedSectionRule@ renderer: @prodbox docs generate@ splices it
-- into the substrates inventory doc and @prodbox docs check@ fails the
-- build if the doc table drifts from this SSoT. This is the typed source
-- Sprint 0.10 consumes for the registry-name↔CLI-verb list and Sprint 5.6
-- consumes for registry-generated golden coverage.
renderStackCommandSurfaceMarkdown :: [StackDescriptor] -> String
renderStackCommandSurfaceMarkdown descriptors =
  intercalate
    "\n"
    ( [ "| Registry name | Pulumi stack id | Project subdir | Resources command | Destroy command | Lifecycle class |"
      , "|---------------|-----------------|----------------|-------------------|-----------------|-----------------|"
      ]
        ++ map renderRow descriptors
    )
 where
  renderRow descriptor =
    "| `"
      ++ stackRegistryName descriptor
      ++ "` | `"
      ++ stackPulumiStackId descriptor
      ++ "` | `pulumi/"
      ++ stackProjectSubdir descriptor
      ++ "/` | `prodbox aws stack "
      ++ stackCliVerb descriptor
      ++ " reconcile` | `prodbox aws stack "
      ++ stackCliVerb descriptor
      ++ " destroy --yes` | "
      ++ renderClass (stackLifecycleClass descriptor)
      ++ " |"
  renderClass klass = case klass of
    PerRun -> "PerRun"
    LongLived -> "LongLived"
    Operational -> "Operational"
