{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Sprint 4.56: the admission proof a mutating reconcile step cannot be
-- invoked without.
module DependencyAdmissionSuite (dependencyAdmissionSuite) where

import Data.IORef (newIORef, readIORef, writeIORef)
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
import Prodbox.Lib.AwsSubstratePlatform (runReconcileSlices)
import Prodbox.Lifecycle.AnchoredReconcile
  ( ReconcileStepAnchor (ComponentMutation, ComponentReadiness)
  , runAnchoredStepOrder
  , runFirstAnchoredStepOrder
  )
import Prodbox.Lifecycle.DependencyAdmission

-- Sprint 4.64: `noAdmissions` left the public API so that no production module
-- can begin a phase with an empty set. A test suite must still be able to
-- construct the empty case in order to assert what it refuses, and reaching the
-- package-internal module is the documented way to do that: the `dev check`
-- rule that bars this import is scoped to `src/`.
import Prodbox.Lifecycle.DependencyAdmission.Internal (noAdmissions)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
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

    it "returns the typed refusal instead of lowering it to a bare exit code" $ do
      mutationStarted <- newIORef False
      outcome <-
        runAnchoredStepOrder
          dag
          (pure now)
          (const (ComponentMutation mutatedComponent))
          (\_ _ -> writeIORef mutationStarted True >> pure ExitSuccess)
          (const (pure ExitSuccess))
          (const (pure (Left (ExitFailure 99))))
          noAdmissions
          [()]
      readIORef mutationStarted `shouldReturn` False
      case outcome of
        Left (AdmissionMissing component dependency) -> do
          component `shouldBe` mutatedComponent
          dependency `shouldBe` firstDependency
        Left other -> expectationFailure ("unexpected refusal: " <> show other)
        Right result ->
          expectationFailure
            ("the refusal was lowered to an executable result: " <> show (fst result))

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

    it "Sprint 4.64: only the reconcile executor may begin a run with no admissions" $ do
      -- The empty set left the public API, so a phase call site cannot name it.
      -- Two things have to hold together for that to mean anything, and this
      -- case asserts both.
      --
      -- (1) The executor is on the allowlist, because it is the one module that
      --     legitimately starts empty.
      let internalImport =
            "import Prodbox.Lifecycle.DependencyAdmission.Internal (noAdmissions)\n"
      dependencyAdmissionInternalSourceViolations
        ("src/Prodbox/Lifecycle/AnchoredReconcile.hs", internalImport)
        `shouldBe` []
      -- (2) The two reconcile surfaces are NOT, so reaching around the removed
      --     export fails the build rather than compiling. Without this the
      --     removal would only have moved the reset one import away.
      length
        ( dependencyAdmissionInternalSourceViolations
            ("src/Prodbox/CLI/Rke2.hs", internalImport)
        )
        `shouldBe` 1
      length
        ( dependencyAdmissionInternalSourceViolations
            ("src/Prodbox/Lib/AwsSubstratePlatform.hs", internalImport)
        )
        `shouldBe` 1

    it "Sprint 4.64: beginning a run and continuing one are different functions" $ do
      -- `runFirstAnchoredStepOrder` supplies the empty set itself and returns
      -- the admissions a later phase must be given; the two are distinguished
      -- by type, so a later phase cannot be started fresh by passing a value
      -- that merely happens to be empty.
      --
      -- The observable difference: a first phase whose readiness step succeeds
      -- returns a NON-empty set, which is precisely the value Sprint 4.61's
      -- defect discarded.
      admitted <- newIORef ([] :: [ComponentId])
      let readinessFor component = do
            seen <- readIORef admitted
            writeIORef admitted (seen ++ [component])
            pure (Right (admissionAt now component))
      outcome <-
        runFirstAnchoredStepOrder
          dag
          (pure now)
          (const (ComponentReadiness firstDependency))
          (\_ _ -> pure ExitSuccess)
          (\_ -> pure ExitSuccess)
          readinessFor
          [()]
      case outcome of
        Left refusal -> expectationFailure ("first phase refused: " ++ show refusal)
        Right (exitCode, admissions) -> do
          exitCode `shouldBe` ExitSuccess
          -- Carried out of the first phase, available to the next one.
          admissionFor firstDependency admissions `shouldSatisfy` isJust
      observed <- readIORef admitted
      observed `shouldBe` [firstDependency]

    it "Sprint 4.69: a reconcile run threads its admissions through the fold" $ do
      -- The defect this replaces was a call site, not a value: the final slice
      -- dropped the set it returned with `fst <$>`, correct only because it was
      -- last. Threading is now the fold's job, so a slice that ignores the
      -- carrier is a slice someone wrote that way rather than a slice that was
      -- handed nothing.
      seen <- newIORef ([] :: [Bool])
      let record carried = do
            observed <- readIORef seen
            writeIORef seen (observed ++ [isJust (admissionFor firstDependency carried)])
            pure (Right (recordAdmission (admissionAt now firstDependency) carried))
      exitCode <-
        runReconcileSlices
          (pure (Right noAdmissions))
          [record, record, record]
      exitCode `shouldBe` ExitSuccess
      -- The first slice opens with nothing; every later slice observes what the
      -- one before it recorded. The pre-fix shape produced `False` from the
      -- second slice onward, which is Sprint 4.61's defect with no compile
      -- error and no lint.
      readIORef seen `shouldReturn` [False, True, True]

    it "Sprint 4.69: a failing slice stops the run and no later slice observes" $ do
      ran <- newIORef (0 :: Int)
      let counting carried = do
            observed <- readIORef ran
            writeIORef ran (observed + 1)
            pure (Right carried)
      exitCode <-
        runReconcileSlices
          (pure (Right noAdmissions))
          [ counting
          , \_ -> pure (Left (ExitFailure 3))
          , counting
          ]
      exitCode `shouldBe` ExitFailure 3
      readIORef ran `shouldReturn` 1

    it "Sprint 4.69: a failing opening slice runs nothing at all" $ do
      ran <- newIORef (0 :: Int)
      let counting carried = do
            observed <- readIORef ran
            writeIORef ran (observed + 1)
            pure (Right carried)
      exitCode <-
        runReconcileSlices (pure (Left (ExitFailure 2))) [counting]
      exitCode `shouldBe` ExitFailure 2
      readIORef ran `shouldReturn` 0

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
