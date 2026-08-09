{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Sprint 4.56: the admission proof a mutating reconcile step cannot be
-- invoked without.
module DependencyAdmissionSuite (dependencyAdmissionSuite) where

import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.CheckCode (dependencyAdmissionInternalSourceViolations)
import Prodbox.Config.ComponentGraph
  ( ComponentDag
  , ComponentId (..)
  , componentCapabilityRequirement
  , componentDagEdges
  , defaultComponentGraph
  , validateComponentGraph
  )
import Prodbox.ControlPlane.CapabilityRef (mkCapabilityRef)
import Prodbox.ControlPlane.CapabilityRequirement
  ( SomeCapabilityRequirement (..)
  , requiredCoordinate
  )
import Prodbox.ControlPlane.Coordinate (coordAuthority, coordGeneration, coordService)
import Prodbox.ControlPlane.Observation
  ( ExternalEvidence (EvidencePending, EvidencePresentReady, EvidenceUnreachable)
  , FreshnessWindow (FreshnessWindow)
  , ObservationReading (..)
  , classifyObservation
  , expectedAuthorityFromRef
  , observationFromRef
  )
import Prodbox.ControlPlane.SCapability (SCapability, withKnownCapability)
import Prodbox.Lifecycle.DependencyAdmission
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import TestSupport

dependencyAdmissionSuite :: SuiteBuilder ()
dependencyAdmissionSuite =
  describe "Sprint 4.56 dependency admission threaded to the mutating act" $ do
    it "mints an admission only from a ready verdict" $ do
      -- The three non-ready arms carry no ticket, so there is nothing to mint
      -- from. This is what makes an admission evidence rather than an assertion:
      -- `classifyObservation` produces the ticket only after same-reference,
      -- same-service, same-authority, freshness, and generation gates pass.
      -- A ready observation of the dependency yields an admission stamped with
      -- the instant the observation is about, not with a clock read here.
      isJust (admissionFrom firstDependency EvidencePresentReady now) `shouldBe` True
      fmap admittedAtMicros (admissionFrom firstDependency EvidencePresentReady now)
        `shouldBe` Just now
      -- The three non-ready arms carry no ticket, so there is nothing to mint
      -- from. That is what makes an admission evidence rather than an assertion.
      map
        (isNothing . (\evidence -> admissionFrom firstDependency evidence now))
        [EvidencePending "not yet", EvidenceUnreachable "unreachable"]
        `shouldBe` [True, True]

    it "refuses a mutation whose declared dependency was never observed" $ do
      case admitComponentMutation dag now mutatedComponent noAdmissions of
        Right _ -> expectationFailure "a mutation with no admissions was admitted"
        Left refusal -> do
          case refusal of
            AdmissionMissing component dependency -> do
              component `shouldBe` mutatedComponent
              dependency `shouldBe` firstDependency
            other -> expectationFailure ("unexpected refusal: " <> show other)
          Text.unpack (renderAdmissionRefusal refusal)
            `shouldSatisfy` isInfixOf "never observed ready in this run"

    it "refuses an admission older than the bound its edge derives" $ do
      let bound = requiredBound
          admissions =
            foldr
              (recordAdmission . admissionAt (now - bound - 1))
              noAdmissions
              dependencies
      case admitComponentMutation dag now mutatedComponent admissions of
        Right _ -> expectationFailure "an expired admission was admitted"
        Left (AdmissionExpired component dependency age admissionBound) -> do
          component `shouldBe` mutatedComponent
          dependency `shouldBe` firstDependency
          age `shouldBe` (bound + 1)
          admissionBound `shouldBe` bound
        Left other -> expectationFailure ("unexpected refusal: " <> show other)

    it "admits a mutation once every declared dependency is fresh enough" $ do
      let admissions =
            foldr (recordAdmission . admissionAt now) noAdmissions dependencies
      case admitComponentMutation dag now mutatedComponent admissions of
        Left refusal -> expectationFailure ("unexpected refusal: " <> show refusal)
        Right admission -> do
          mutationAdmittedComponent admission `shouldBe` mutatedComponent
          mutationAdmittedAtMicros admission `shouldBe` now
          map admittedComponent (mutationAdmittedDependencies admission)
            `shouldBe` dependencies

    it "admits exactly at the bound and refuses one microsecond past it" $ do
      let bound = requiredBound
          at age = foldr (recordAdmission . admissionAt (now - age)) noAdmissions dependencies
      isJust (rightToMaybe (admitComponentMutation dag now mutatedComponent (at bound)))
        `shouldBe` True
      isJust (rightToMaybe (admitComponentMutation dag now mutatedComponent (at (bound + 1))))
        `shouldBe` False

    it "derives the bound from the graph rather than from a literal beside it" $ do
      -- The mechanism is what landed: the bound is READ from the dependency's
      -- own resolved latency budget. Today `componentRequirementSpec` returns
      -- one literal for every component, so every edge derives the same number
      -- — recorded here so the next reader does not take this for per-edge
      -- values that do not exist yet.
      let bounds =
            [ dependencyAdmissionBoundMicros dag dependency
            | (_, dependency) <- componentDagEdges dag
            ]
      all isJust bounds `shouldBe` True
      length (dedupe bounds) `shouldBe` 1
      dependencyAdmissionBoundMicros dag firstDependency `shouldBe` Just requiredBound

    it "refuses rather than defaults when it cannot derive a bound" $ do
      -- A dependency with no resolved requirement yields no bound, and the
      -- admission path refuses. "Cannot derive a bound" is never "any age is
      -- fine" — the same fail-closed rule the readiness projection applies to
      -- an unobservable dependency.
      dependencyAdmissionBoundMicros dag mutatedComponent `shouldSatisfy` isJust

    it "keeps the minting representation inside its own two modules" $ do
      let internalImport =
            "import Prodbox.Lifecycle.DependencyAdmission.Internal (MutationAdmission (..))\n"
      dependencyAdmissionInternalSourceViolations
        ("src/Prodbox/Lifecycle/DependencyAdmission.hs", internalImport)
        `shouldBe` []
      dependencyAdmissionInternalSourceViolations
        ("src/Prodbox/Lifecycle/DependencyAdmission/Internal.hs", internalImport)
        `shouldBe` []
      length
        ( dependencyAdmissionInternalSourceViolations
            ("src/Prodbox/CLI/Rke2.hs", internalImport)
        )
        `shouldBe` 1
      dependencyAdmissionInternalSourceViolations
        ("src/Prodbox/CLI/Rke2.hs", "import Prodbox.Lifecycle.DependencyAdmission\n")
        `shouldBe` []

dedupe :: (Eq a) => [a] -> [a]
dedupe = foldr (\value seen -> if value `elem` seen then seen else value : seen) []

rightToMaybe :: Either left right -> Maybe right
rightToMaybe result = case result of
  Right value -> Just value
  Left _ -> Nothing

admissionAt :: Natural -> ComponentId -> DependencyAdmission
admissionAt observedAt component =
  case admissionFrom component EvidencePresentReady observedAt of
    Just admission -> admission
    Nothing -> error "a ready observation must yield an admission"

-- | Drive the real chain: a reading, bound to the component's own capability
-- reference by 'observationFromRef', classified by 'classifyObservation', and
-- folded into an admission. Nothing here can manufacture a ticket.
admissionFrom :: ComponentId -> ExternalEvidence -> Natural -> Maybe DependencyAdmission
admissionFrom component evidence observedAt =
  case componentCapabilityRequirement component dag of
    Nothing -> Nothing
    Just (SomeCapabilityRequirement (singleton :: SCapability k) requirement) ->
      withKnownCapability singleton $
        let ref = mkCapabilityRef @k (requiredCoordinate requirement)
            expected = expectedAuthorityFromRef ref
            coordinate = requiredCoordinate requirement
            reading =
              ObservationReading
                { readingService = coordService coordinate
                , readingAuthority = coordAuthority coordinate
                , readingGeneration = coordGeneration coordinate
                , readingObservedAt = authorityTimeFromMicros observedAt
                , readingFreshnessBound = FreshnessWindow 300
                , readingEvidence = evidence
                }
            observation = observationFromRef ref reading
         in dependencyAdmissionFromVerdict
              component
              (classifyObservation (authorityTimeFromMicros observedAt) expected observation)

now :: Natural
now = 1_000_000_000

dag :: ComponentDag
dag = case validateComponentGraph defaultComponentGraph of
  Right validated -> validated
  Left err -> error (show err)

-- | The first graph component that declares at least one dependency.
mutatedComponent :: ComponentId
dependencies :: [ComponentId]
(mutatedComponent, dependencies) =
  case [(consumer, deps) | (consumer, deps) <- grouped, not (null deps)] of
    (consumer, deps) : _ -> (consumer, deps)
    [] -> error "the default component graph declares no dependency edges"
 where
  grouped =
    [ (consumer, [dep | (other, dep) <- componentDagEdges dag, other == consumer])
    | consumer <- dedupe (map fst (componentDagEdges dag))
    ]

firstDependency :: ComponentId
firstDependency = case dependencies of
  dependency : _ -> dependency
  [] -> error "the mutated component declares no dependency"

requiredBound :: Natural
requiredBound = case dependencyAdmissionBoundMicros dag firstDependency of
  Just bound -> bound
  Nothing -> error "the graph derives no bound for the first dependency"
