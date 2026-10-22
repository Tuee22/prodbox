{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module PerRunTerminalAudit (perRunTerminalAuditSuite) where

import CleanupScopeFixtures
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT, ask, runReaderT)
import Data.Either (isLeft)
import Data.IORef
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import LifecycleTeardownProviderAwsScopeAdapter (fixtureProviderAwsScopeEvidence)
import Prodbox.ControlPlane.AuthorityProviderEndpoint (providerExecutionOutcome)
import Prodbox.ControlPlane.ProviderWorkerExecution (ProviderIntentExecutionResult (..))
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunEntry
import Prodbox.Lifecycle.OwnedResourceTagEvidence
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.PerRunTerminalAudit (observePerRunTerminalAudit)
import Prodbox.Lifecycle.Teardown.PerRunTerminalAuditPlan
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Lifecycle.Teardown.RetainedInventory
import Prodbox.Test.LifecycleCleanupClient
import Prodbox.TestValidation (boundKeycloakInviteRecipient)
import System.Exit (ExitCode (..))
import TestSupport

perRunTerminalAuditSuite :: SuiteBuilder ()
perRunTerminalAuditSuite = describe "Sprint 5.53 durable ordinary terminal audit" $ do
  it "runs every regional and global filter under a distinct key owned by the graph audit operation" $ do
    fixture <- newFixture CompleteEmpty
    outcome <- runAudit fixture
    outcome `shouldBe` CleanupNodeSucceeded
    calls <- readIORef (fixtureCalls fixture)
    length calls `shouldBe` maximumPerRunTerminalAuditQueries
    length (nub (map (providerDispatchSubmissionKey . fst) calls)) `shouldBe` length calls
    map (providerDispatchKeyOperationId . fst) calls
      `shouldSatisfy` all (== cleanupNodeOperationId auditNode)
    length [() | (_, ObserveGlobalOwnedResourceTags _) <- calls]
      `shouldBe` ((maximumPerRunTerminalAuditQueries - 1) `div` 2)
    disposition <-
      finishHarnessCredentialCleanup (recordRevoke fixture) [reportWith outcome] ZoneNotSelected
    disposition `shouldBe` HarnessCredentialRevoked
    readIORef (fixtureRevokeCalls fixture) >>= (`shouldBe` 1)
  it "preserves credentials when one global filter cannot be observed" $ do
    fixture <- newFixture GlobalUnavailable
    outcome <- runAudit fixture
    outcome `shouldSatisfy` isFailed
    finishHarnessCredentialCleanup (recordRevoke fixture) [reportWith outcome] ZoneNotSelected
      >>= (`shouldBe` HarnessCredentialPreservedForRecovery)
    readIORef (fixtureRevokeCalls fixture) >>= (`shouldBe` 0)
    readIORef (fixtureCalls fixture)
      >>= (`shouldSatisfy` ((== maximumPerRunTerminalAuditQueries) . length))
  it "refuses a different Provider account before issuing any field query" $ do
    fixture <- newFixture WrongProviderAccount
    outcome <- runAudit fixture
    outcome `shouldSatisfy` isFailed
    readIORef (fixtureCalls fixture) >>= (`shouldSatisfy` ((== 1) . length))
    finishHarnessCredentialCleanup (recordRevoke fixture) [reportWith outcome] ZoneNotSelected
      >>= (`shouldBe` HarnessCredentialPreservedForRecovery)
  it "reports tagged escapees and preserves credentials" $ do
    fixture <- newFixture TaggedEscape
    outcome <- runAudit fixture
    outcome `shouldSatisfy` isFailed
    finishHarnessCredentialCleanup (recordRevoke fixture) [reportWith outcome] ZoneNotSelected
      >>= (`shouldBe` HarnessCredentialPreservedForRecovery)
    readIORef (fixtureRevokeCalls fixture) >>= (`shouldBe` 0)
  it "refuses a clean observation carrying another query plan digest" $ do
    fixture <- newFixture WrongPlanDigest
    outcome <- runAudit fixture
    outcome `shouldSatisfy` isFailed
    finishHarnessCredentialCleanup (recordRevoke fixture) [reportWith outcome] ZoneNotSelected
      >>= (`shouldBe` HarnessCredentialPreservedForRecovery)
  it "does not give a successful historical resource-only report an audit it never took" $ do
    let legacy =
          must
            ( compileDesiredAbsenceGraphForRegisteredKeys
                runId
                foundation
                (Just awsScope)
                Nothing
                ExplicitPerRunSurface
                []
            )
        report = reportFor legacy CleanupPrimarySucceeded (const CleanupNodeSucceeded)
    calls <- newIORef (0 :: Int)
    finishHarnessCredentialCleanup
      (modifyIORef' calls (+ 1) >> pure ExitSuccess)
      [report]
      ZoneNotSelected
      >>= (`shouldBe` HarnessCredentialPreservedForRecovery)
    readIORef calls >>= (`shouldBe` 0)
  it "places the audit after exact resource read-backs and before the durable surface report" $ do
    let home = Just fixtureHomeDns01Scope
        mail = Just fixtureInviteMailScope
        bindings = mkResourceScopeBindingsWithAudit home mail retainedNames
        full =
          must
            ( compileAuditedExplicitPerRunGraph
                runId
                foundation
                awsScope
                Nothing
                bindings
                [HomeDns01ChallengeRecordKey, SesInviteMailObjectsKey]
            )
        operation tag =
          [ node
          | node <- desiredAbsenceProgramNodes (compiledDesiredAbsenceProgram full)
          , someTeardownOperationTag (programNodeOperation node) == tag
          ]
    case operation "audit-per-run-escapes" of
      [node] -> do
        programNodeDependencies node `shouldSatisfy` ((== 3) . length)
        map programDependencyNode (programNodeDependencies node)
          `shouldSatisfy` notElem (ProgramNodeName "surface/commit-report")
      _ -> expectationFailure "registered graph has no unique terminal audit"
    case operation "commit-ordinary-surface-report" of
      [node] ->
        map programDependencyNode (programNodeDependencies node) `shouldBe` [perRunTerminalAuditNodeName]
      _ -> expectationFailure "registered graph has no unique surface report"
  it "requires durable audit names and supports a deliberately unconfigured SES projection" $ do
    compileAuditedExplicitPerRunGraph runId foundation awsScope Nothing emptyResourceScopeBindings []
      `shouldSatisfy` isLeft
    let names = must (mkOptionalRetainedNameBinding (Just "fixture-state") Nothing Nothing "fixture-cluster")
        bindings = mkResourceScopeBindingsWithAudit Nothing Nothing names
        optionalProgram = must (compileAuditedExplicitPerRunGraph runId foundation awsScope Nothing bindings [])
        plan = must (mkPerRunTerminalAuditPlan (compiledDesiredAbsenceObservationScope optionalProgram))
        families = map retainedMatcherFamily (retainedCatalogMatchers (perRunAuditPlanCatalog plan))
    families `shouldSatisfy` elem RetainedLongLivedPulumiStateBucket
    families `shouldSatisfy` notElem RetainedSesCaptureBucket
    families `shouldSatisfy` notElem RetainedSesDomainIdentity
  it "pins the invitation consumer to the registered recipient and bucket" $ do
    boundKeycloakInviteRecipient "fixture-capture-mail" "example.test" "receive" fixtureInviteMailScope
      `shouldBe` Right "test-abc123@receive.example.test"
    boundKeycloakInviteRecipient "another-capture-mail" "example.test" "receive" fixtureInviteMailScope
      `shouldSatisfy` isLeft
    boundKeycloakInviteRecipient
      "fixture-capture-mail"
      "other.example.test"
      "receive"
      fixtureInviteMailScope
      `shouldSatisfy` isLeft

-- A cache keyed like Authority admission rejects different intents at one key.
-- Thus the production producer's distinct keys are measured, not assumed.
data AuditMode
  = CompleteEmpty
  | GlobalUnavailable
  | TaggedEscape
  | WrongPlanDigest
  | WrongProviderAccount
  deriving (Eq)

data AuditFixture = AuditFixture
  { fixtureMode :: AuditMode
  , fixtureCalls :: IORef [(ProviderDispatchKey, ProviderIntent)]
  , fixtureAdmitted :: IORef (Map.Map Text ProviderIntent)
  , fixtureRevokeCalls :: IORef Int
  }

newFixture :: AuditMode -> IO AuditFixture
newFixture mode = AuditFixture mode <$> newIORef [] <*> newIORef Map.empty <*> newIORef 0

newtype AuditEffects value = AuditEffects (ReaderT AuditFixture IO value)
  deriving newtype (Functor, Applicative, Monad)

instance LifecycleTeardownEffects AuditEffects where
  executeLifecycleTeardownOperation context operation = AuditEffects $ do
    fixture <- ask
    case operation of
      AuditPerRunEscapes -> do
        observed <- liftIO (observePerRunTerminalAudit (boundary fixture) context)
        pure $ case observed of
          Left detail -> TeardownNodeRefused detail
          Right value
            | fixtureMode fixture == WrongPlanDigest ->
                let original = terminalAuditScope value
                    changed =
                      must
                        ( mkTerminalAuditScope
                            ExplicitPerRunSurface
                            (terminalAuditEvidenceScope original)
                            (TerminalAuditQueryDigest (Text.replicate 64 "a"))
                            (terminalAuditRetainedSetDigest original)
                        )
                 in TeardownTerminalAuditObservation value {terminalAuditScope = changed}
            | otherwise -> TeardownTerminalAuditObservation value
      _ -> pure (TeardownNodeRefused "unexpected test operation")

boundary :: AuditFixture -> TeardownProviderBoundary IO
boundary fixture = TeardownProviderBoundary $ \key intent -> do
  modifyIORef' (fixtureCalls fixture) (<> [(key, intent)])
  cache <- readIORef (fixtureAdmitted fixture)
  let submission = Text.pack (show (providerDispatchSubmissionKey key))
  case Map.lookup submission cache of
    Just previous | previous /= intent -> pure (TeardownProviderRefused "divergent replay")
    _ -> do
      modifyIORef' (fixtureAdmitted fixture) (Map.insert submission intent)
      case intent of
        ObserveGlobalOwnedResourceTags _
          | fixtureMode fixture == GlobalUnavailable ->
              pure (TeardownProviderUnavailable "global endpoint unavailable")
        ObserveProviderAwsScope ->
          let account = if fixtureMode fixture == WrongProviderAccount then "111122223333" else "123456789012"
              evidence = fixtureProviderAwsScopeEvidence account (fixtureAwsRegion FixtureCaCentral1)
           in pure
                ( TeardownProviderCompleted
                    ( providerExecutionOutcome
                        (ProviderIntentExecutionObserved (providerIntentCoordinate intent) evidence)
                    )
                )
        ObserveOwnedResourceTags query -> answer intent query
        ObserveGlobalOwnedResourceTags query -> answer intent query
        _ -> pure (TeardownProviderRefused "audit attempted a mutation")
 where
  answer intent query = do
    let entries = case (fixtureMode fixture, intent) of
          (TaggedEscape, ObserveOwnedResourceTags _) ->
            [ OwnedResourceTagEntry
                ( ("arn:aws:ec2:" <> fixtureAwsRegion FixtureCaCentral1 <> ":123456789012:volume/vol-0123456789abcdef0")
                )
                [("prodbox.io/managed-by", "prodbox")]
            ]
          _ -> []
        echo = case query of
          ProviderOwnedTagKeyQuery key -> OwnedResourceTagKeyEcho key
          ProviderOwnedTagPairQuery key value -> OwnedResourceTagPairEcho key value
        evidence = must (renderOwnedResourceTagObservation (OwnedResourceTagObservation echo entries 1))
    pure
      ( TeardownProviderCompleted
          ( providerExecutionOutcome
              (ProviderIntentExecutionObserved (providerIntentCoordinate intent) evidence)
          )
      )

runAudit :: AuditFixture -> IO CleanupNodeOutcome
runAudit fixture = case runCompiledTeardownNode compiled auditNode of
  AuditEffects action -> runReaderT action fixture

recordRevoke :: AuditFixture -> IO ExitCode
recordRevoke fixture = modifyIORef' (fixtureRevokeCalls fixture) (+ 1) >> pure ExitSuccess

reportWith :: CleanupNodeOutcome -> LifecycleCleanupResult
reportWith outcome =
  reportFor
    compiled
    CleanupPrimarySucceeded
    (\node -> if cleanupNodeId node == cleanupNodeId auditNode then outcome else CleanupNodeSucceeded)

reportFor
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupPrimaryOutcome
  -> (CleanupNodePlan -> CleanupNodeOutcome)
  -> LifecycleCleanupResult
reportFor program primary outcome =
  LifecycleCleanupReportObserved
    ( CleanupRunReport
        (compiledDesiredAbsenceRunId program)
        (cleanupGraphDigest (compiledDesiredAbsenceGraph program))
        primary
        ( Map.fromList
            [ (cleanupNodeId node, CleanupNodeCompleted attempt (outcome node))
            | node <- cleanupGraphNodes (compiledDesiredAbsenceGraph program)
            ]
        )
    )

compiled :: CompiledDesiredAbsenceProgram 'ExplicitPerRun
compiled =
  must
    ( compileAuditedExplicitPerRunGraph
        runId
        foundation
        awsScope
        Nothing
        (mkResourceScopeBindingsWithAudit Nothing Nothing retainedNames)
        []
    )

auditNode :: CleanupNodePlan
auditNode = case [ node
                 | node <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
                 , Right (cleanupNodeId node) == perRunTerminalAuditNodeId
                 ] of
  [node] -> node
  _ -> error "fixture has no unique registered terminal audit"

retainedNames :: RetainedNameBinding
retainedNames =
  must (mkRetainedNameBinding "fixture-state" "fixture-capture-mail" "example.test" "fixture-cluster")

runId :: CleanupRunId
runId = must (mkCleanupRunId "fixture-terminal-audit")

foundation :: LinuxRke2FoundationId
foundation = LinuxRke2FoundationId "fixture-home"

awsScope :: AwsScope
awsScope = AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

attempt :: CleanupAttemptId
attempt = must (mkCleanupAttemptId "fixture-audit-attempt")

isFailed :: CleanupNodeOutcome -> Bool
isFailed outcome = case outcome of
  CleanupNodeFailed _ -> True
  _ -> False

must :: (Show error) => Either error value -> value
must = either (error . show) id
