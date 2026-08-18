{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.85: which production executor, if any, runs the registered-target
-- operations a compiled desired-absence program emits for one registry key.
--
-- @compileDesiredAbsenceProgram@ emits three nodes per registered managed
-- descriptor — observe, reconcile-absent, and a __mandatory__ absence
-- read-back — and a surface that reports completion is asserting every
-- mandatory read-back succeeded.  Registering a descriptor is therefore not a
-- neutral act: it adds an obligation the production interpreter has to be able
-- to discharge.
--
-- 'Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter' dispatched its
-- three entry points on ad-hoc @(kind, key)@ guards with a fall-through arm
-- that refused.  The refusal is right; the silence is not.  Nothing joined the
-- set of keys the guards cover to the set of keys the registry contains, so a
-- descriptor could be registered with no executor behind it and the only
-- symptom was a node that always failed — which, in a teardown report, reads
-- exactly like infrastructure that refused to go away.
--
-- This module is that join.  'registeredTargetExecutorFor' is total over the
-- closed key enumeration, so adding a 'RegisteredResourceKey' is an
-- exhaustiveness failure until someone states which executor runs it, and the
-- interpreter dispatches on the result rather than restating the guards.
-- 'Prodbox.CheckCode' then fails the build when a registered descriptor with
-- no executor projects onto a surface that can mint completion evidence.
module Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
  ( RegisteredTargetExecutor (..)
  , registeredTargetExecutorTag
  , RegisteredTargetAdapterGap (..)
  , UnexecutableRegisteredTarget (..)
  , unexecutableRegisteredTargetDetail
  , registeredTargetExecutorFor
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Teardown.Model
  ( RegisteredResourceKey (..)
  , registeredResourceKeyText
  )

-- | The production registered-target executors that exist today.
--
-- One constructor per distinct execution path in
-- 'Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter'.  It is
-- deliberately not indexed by 'Prodbox.Lifecycle.Teardown.Model.ResourceKind':
-- two @Stack@ keys take different paths (EKS carries a drain protocol), and
-- two @VolumeFamily@ keys do not both have one.  Dispatching on kind is what
-- let a registered key reach a fall-through refusal without anyone noticing.
data RegisteredTargetExecutor
  = -- | The EKS stack: verified observation, then the separately composed
    -- present-destroy boundary that consumes the durable drain read-back.
    EksStackExecutor
  | -- | Any other registered Pulumi stack, through the generic stack adapter.
    GenericStackExecutor
  | -- | The per-run test EBS family, through the EC2 discover/destroy adapter.
    PerRunTestEbsFamilyExecutor
  deriving (Bounded, Enum, Eq, Ord, Show)

registeredTargetExecutorTag :: RegisteredTargetExecutor -> Text
registeredTargetExecutorTag executor = case executor of
  EksStackExecutor -> "eks-stack"
  GenericStackExecutor -> "generic-stack"
  PerRunTestEbsFamilyExecutor -> "per-run-test-ebs-family"

-- | Why a registered AWS key has no production executor, and what is missing.
--
-- Named rather than collapsed into one "unsupported" value: a gap is a
-- specific unbuilt adapter, and the sprint that owns building it is a fact
-- about that adapter rather than about the resource kind.
data RegisteredTargetAdapterGap
  = -- | The retained EBS family.  The interpreter's @VolumeFamily@ arm is
    -- guarded on the __per-run__ key, so the retained family falls through
    -- with no exact observe, destroy, or absence read-back.
    RetainedEbsFamilyAdapterUnbuilt
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The two ways a registry key can fail to reach an executor.  They are
-- different facts: one is a target this interpreter should never see, the
-- other is a target it should see and cannot yet serve.
data UnexecutableRegisteredTarget
  = -- | Not an AWS registered target at all.  The local Linux RKE2 foundation
    -- is projected as a separately typed local target and never enters the
    -- generic registered-target interpreter.
    NotAnAwsRegisteredTarget
  | -- | A registered AWS target whose adapter does not exist yet.
    NoProductionExecutor !RegisteredTargetAdapterGap
  deriving (Eq, Show)

unexecutableRegisteredTargetDetail
  :: RegisteredResourceKey -> UnexecutableRegisteredTarget -> Text
unexecutableRegisteredTargetDetail key unexecutable = case unexecutable of
  NotAnAwsRegisteredTarget ->
    "registered key "
      <> registeredResourceKeyText key
      <> " is not an AWS registered target; the local foundation is projected \
         \as a separately typed local target"
  NoProductionExecutor RetainedEbsFamilyAdapterUnbuilt ->
    "registered key "
      <> registeredResourceKeyText key
      <> " has no production registered-target executor: the interpreter's \
         \VolumeFamily arm is guarded on the per-run EBS key, so the retained \
         \family has no exact observe, destroy, or absence read-back \
         \(Sprint 7.36 owns the retained EBS desired-absence adapter)"

-- | Total over the closed key enumeration.
registeredTargetExecutorFor
  :: RegisteredResourceKey
  -> Either UnexecutableRegisteredTarget RegisteredTargetExecutor
registeredTargetExecutorFor key = case key of
  LocalLinuxRke2Key -> Left NotAnAwsRegisteredTarget
  AwsEksKey -> Right EksStackExecutor
  AwsEksSubzoneKey -> Right GenericStackExecutor
  AwsTestKey -> Right GenericStackExecutor
  AwsEbsPerRunTestKey -> Right PerRunTestEbsFamilyExecutor
  AwsEbsProductionRetainedKey ->
    Left (NoProductionExecutor RetainedEbsFamilyAdapterUnbuilt)
