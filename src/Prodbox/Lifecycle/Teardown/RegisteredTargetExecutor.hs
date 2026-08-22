{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

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
  , RegisteredTargetAdapterGap
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
  | -- | The @dns-aws@ validation hosted-zone family, through the Route 53
    -- list/delete adapter.
    ValidationHostedZoneFamilyExecutor
  | -- | Sprint 7.36: the retained production EBS family, through its own
    -- EC2 discover\/destroy adapter.  It is a separate constructor from
    -- 'PerRunTestEbsFamilyExecutor' rather than a parameter on it because the
    -- two families have opposite default dispositions, and a shared executor
    -- taking a scope argument would put deleting production storage one wrong
    -- value away from a path that runs on every cascade.
    RetainedEbsFamilyExecutor
  | -- | Sprint 7.36: the DNS01 challenge record family.
    --
    -- The only executor here whose reconcile step is not a Provider mutation.
    -- Its observation and its mandatory absence read-back are Route 53 reads
    -- through the Provider, but the removal is a Kubernetes owner delete —
    -- cert-manager's solver owns the record, and a Provider delete would race
    -- it into rewriting one. This is what the interpreter's Kubernetes-scoped
    -- execution arm exists for, and it is a separate constructor rather than a
    -- flag on another executor because the two arms reach different systems
    -- under different credentials.
    Dns01ChallengeRecordFamilyExecutor
  deriving (Bounded, Enum, Eq, Ord, Show)

registeredTargetExecutorTag :: RegisteredTargetExecutor -> Text
registeredTargetExecutorTag executor = case executor of
  EksStackExecutor -> "eks-stack"
  GenericStackExecutor -> "generic-stack"
  PerRunTestEbsFamilyExecutor -> "per-run-test-ebs-family"
  ValidationHostedZoneFamilyExecutor -> "validation-hosted-zone-family"
  RetainedEbsFamilyExecutor -> "retained-ebs-family"
  Dns01ChallengeRecordFamilyExecutor -> "dns01-challenge-record-family"

-- | Why a registered AWS key has no production executor, and what is missing.
--
-- Named rather than collapsed into one "unsupported" value: a gap is a
-- specific unbuilt adapter, and the sprint that owns building it is a fact
-- about that adapter rather than about the resource kind.
--
-- Sprint 7.36 emptied it.  Its one member, @RetainedEbsFamilyAdapterUnbuilt@,
-- was deleted when
-- 'Prodbox.Lifecycle.Teardown.AwsRetainedEbsAdapter' landed and
-- 'RetainedEbsFamilyExecutor' took the retained key.  The type survives with
-- no constructors on purpose: 'registeredTargetExecutorFor' stays a total
-- function into @Either@, so a future key with no adapter is still recorded as
-- a typed value with a named owner rather than as a fall-through refusal, and
-- @Prodbox.CheckCode.registeredTargetExecutorViolations@ keeps failing the
-- build the moment one projects onto a completion-minting surface.  Today
-- there is no such key, which is what lets @ExplicitLongLived@ mint at all.
data RegisteredTargetAdapterGap

deriving instance Eq RegisteredTargetAdapterGap

deriving instance Show RegisteredTargetAdapterGap

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
  AwsEbsProductionRetainedKey -> Right RetainedEbsFamilyExecutor
  AwsDnsValidationZoneKey -> Right ValidationHostedZoneFamilyExecutor
  AwsDns01ChallengeRecordKey -> Right Dns01ChallengeRecordFamilyExecutor
