{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The admission proof a mutating reconcile step is not invocable without.
--
-- The repository already minted the right proof and then discarded it.
-- @classifyObservation@ produces an opaque, nominally-roled @AdmissionTicket@
-- binding coordinate digest, generation, and observation instant, failing closed
-- on mismatch, staleness, and stale generation — and one line in
-- "Prodbox.Lifecycle.CapabilityReadinessBarrier" pattern-matched the ready
-- verdict and returned unit.
--
-- Downstream, @runAnchoredStepOrder@ took the mutation as an action accepting no
-- admission and the readiness gate as one returning none, so a step mutating a
-- component could run while that component's graph-declared dependency was last
-- observed ready an entire reconcile phase earlier — minutes, across federated
-- Vault unseal and a settings reload.
--
-- This is the /Staleness/ class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md),
-- and the fix is the @ValidatedSettings@ move applied to ordering: make the
-- proof a required argument. It narrows the observe-to-act window; it does not
-- make the pair atomic. Only a fence does that.
module Prodbox.Lifecycle.DependencyAdmission
  ( DependencyAdmission
  , MutationAdmission
  , AdmissionSet
  , AdmissionRefusal (..)
  , admittedComponent
  , admittedAtMicros
  , mutationAdmittedComponent
  , mutationAdmittedAtMicros
  , mutationAdmittedDependencies
  , dependencyAdmissionFromVerdict
  , recordAdmission
  , admissionFor
  , dependencyAdmissionBoundMicros
  , admitComponentMutation
  , renderAdmissionRefusal
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Config.ComponentGraph
  ( ComponentDag
  , ComponentDependency (..)
  , ComponentId
  , componentCapabilityRequirement
  , componentIdText
  , depends_on
  , lookupComponentNode
  )
import Prodbox.ControlPlane.CapabilityRequirement
  ( LatencyBudget (..)
  , SomeCapabilityRequirement (..)
  , requiredLatencyBudget
  )
import Prodbox.ControlPlane.Observation
  ( ReadinessVerdict (..)
  , admissionObservedAt
  )
import Prodbox.Lifecycle.DependencyAdmission.Internal
  ( AdmissionSet (..)
  , DependencyAdmission (..)
  , MutationAdmission (..)
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)

-- | The sole minter of a 'DependencyAdmission'.
--
-- Total over the verdict, and only the one arm carrying a ticket yields a
-- value. The instant comes from the ticket rather than from a clock read here,
-- so the admission is stamped with when the dependency was observed, not with
-- when somebody asked about it.
dependencyAdmissionFromVerdict
  :: ComponentId -> ReadinessVerdict k -> Maybe DependencyAdmission
dependencyAdmissionFromVerdict component verdict = case verdict of
  VerdictReady ticket ->
    Just
      DependencyAdmission
        { admittedComponent = component
        , admittedAtMicros = authorityTimeMicros (admissionObservedAt ticket)
        }
  VerdictPending _ -> Nothing
  VerdictFailed _ -> Nothing
  VerdictUnobservable _ -> Nothing

-- | Record an admission, replacing any earlier one for the same component: a
-- re-observation supersedes what it re-observed.
recordAdmission :: DependencyAdmission -> AdmissionSet -> AdmissionSet
recordAdmission admission (AdmissionSet admissions) =
  AdmissionSet (Map.insert (admittedComponent admission) admission admissions)

admissionFor :: ComponentId -> AdmissionSet -> Maybe DependencyAdmission
admissionFor component (AdmissionSet admissions) = Map.lookup component admissions

-- | Why a mutation was not admitted.
data AdmissionRefusal
  = -- | The mutated component's graph node is not in the dag at all.
    AdmissionComponentUnknown !ComponentId
  | -- | A graph-declared dependency has no admission: it was never observed
    -- ready in this run.
    AdmissionMissing !ComponentId !ComponentId
  | -- | An admission exists and is older than the bound derived for its edge.
    -- Carries the mutated component, the dependency, the admission's age, and
    -- the bound, so the refusal names the number it failed rather than a
    -- generic \"stale\".
    AdmissionExpired !ComponentId !ComponentId !Natural !Natural
  deriving stock (Eq, Show)

renderAdmissionRefusal :: AdmissionRefusal -> Text
renderAdmissionRefusal refusal = case refusal of
  AdmissionComponentUnknown component ->
    "component `"
      <> Text.pack (componentIdText component)
      <> "` is not a node of the validated component graph"
  AdmissionMissing component dependency ->
    "mutating `"
      <> Text.pack (componentIdText component)
      <> "` requires an admission for its declared dependency `"
      <> Text.pack (componentIdText dependency)
      <> "`, which was never observed ready in this run"
  AdmissionExpired component dependency ageMicros boundMicros ->
    "the admission for `"
      <> Text.pack (componentIdText dependency)
      <> "` is "
      <> Text.pack (show ageMicros)
      <> "us old, past the "
      <> Text.pack (show boundMicros)
      <> "us bound its edge to `"
      <> Text.pack (componentIdText component)
      <> "` derives"

-- | The bound an admission for @dependency@ must satisfy, __derived from the
-- graph__ rather than authored beside the call site.
--
-- The derivation is the dependency's own resolved latency budget: the graph
-- states how long observing that dependency may take, and an admission older
-- than that window is older than the observation summarising it could have been
-- valid for.
--
-- __A limitation worth stating rather than implying.__ Today
-- @componentRequirementSpec@ returns the same @specRequireLatencyMicros@ literal
-- for every component, so this function currently yields one value for every
-- edge in the graph. What has landed is the /mechanism/ — the bound is read
-- from the graph, so the moment per-component budgets differentiate, the bounds
-- differentiate with no change here. Reading this as \"per-edge numbers exist
-- today\" would be reading more than the code says.
dependencyAdmissionBoundMicros :: ComponentDag -> ComponentId -> Maybe Natural
dependencyAdmissionBoundMicros dag dependency =
  case componentCapabilityRequirement dependency dag of
    Nothing -> Nothing
    Just (SomeCapabilityRequirement _ requirement) ->
      case requiredLatencyBudget requirement of
        LatencyBudget micros -> Just micros

-- | The total re-validation at the mutating seam.
--
-- Every graph-declared dependency of the mutated component must carry an
-- admission, and each must be no older than the bound its own edge derives. A
-- missing bound (a dependency with no resolved requirement) refuses rather than
-- defaulting — \"cannot derive a bound\" is never \"any age is fine\".
admitComponentMutation
  :: ComponentDag
  -> Natural
  -- ^ The instant the mutation is about to run at.
  -> ComponentId
  -> AdmissionSet
  -> Either AdmissionRefusal MutationAdmission
admitComponentMutation dag nowMicros component admissions =
  case lookupComponentNode component dag of
    Nothing -> Left (AdmissionComponentUnknown component)
    Just node -> do
      admitted <- traverse (admitDependency . dependency_on) (depends_on node)
      pure
        MutationAdmission
          { mutationAdmittedComponent = component
          , mutationAdmittedAtMicros = nowMicros
          , mutationAdmittedDependencies = admitted
          }
 where
  admitDependency dependency =
    case admissionFor dependency admissions of
      Nothing -> Left (AdmissionMissing component dependency)
      Just admission ->
        let age = admissionAge (admittedAtMicros admission)
         in case dependencyAdmissionBoundMicros dag dependency of
              Nothing -> Left (AdmissionMissing component dependency)
              Just bound
                | age > bound -> Left (AdmissionExpired component dependency age bound)
                | otherwise -> Right admission

  -- The reconcile clock never runs backwards, but an admission stamped after
  -- `nowMicros` must not underflow 'Natural'.
  admissionAge observedAt
    | nowMicros <= observedAt = 0
    | otherwise = nowMicros - observedAt
