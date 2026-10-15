{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleCleanupClient
  ( lifecycleCleanupClientSuite
  )
where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , SomeException
  , throwIO
  , try
  )
import Control.Monad (foldM, forM_, unless, void, when)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (isPrefixOf, nub)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Prodbox.CLI.Command (TestScope (TestAll))
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedServerProviders (..)
  , AuthenticatedTransportBounds
  , RouteTrustRegistry
  , authenticateControlPlaneFrame
  , authenticatedServerInnerBody
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  , mkRouteTrustRegistry
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( callerMayCallRoute
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerTestHarness)
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunPrimaryOutcome
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (CleanupRunDescriptorBound)
  , CleanupRunDescriptorCommand (..)
  , CleanupRunDescriptorRefusal (..)
  , CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (CleanupRunEndpointDescriptorBound)
  , cleanupRunEndpointBody
  , cleanupRunEndpointStatus
  , cleanupRunMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  , trustedRequestKeyFromSigner
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleCleanupRun, LifecycleLocalRke2HostObservation)
  , allControlPlaneRoutes
  , routesForRole
  )
import Prodbox.Http.Client (HttpBoundedError)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunEntry
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentStore
  , HostTerminalPermitId
  , hostCleanupGraphDigest
  , hostCleanupRun
  , hostCleanupRunId
  , hostCleanupTerminalIdentity
  , hostCleanupTerminalOperationId
  , mkHostCleanupIntentStore
  , mkHostTerminalPermitId
  , observeHostCleanupIntent
  )
import Prodbox.Lifecycle.HostCleanupRunner (prepareHostCleanupRunner)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorDigest
  )
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
  ( SomeTeardownOperation (..)
  , TeardownOperation (..)
  , someTeardownOperationTag
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Substrate (Substrate (..))
import Prodbox.Test.LifecycleCleanupClient
  ( HarnessCleanupBracket (..)
  , LifecycleTestHarnessCleanupError (LifecycleTestHarnessMainRunMissing)
  , PrimaryDecision (..)
  , ZoneDisposition (..)
  , ZoneEvidence (..)
  , ZoneTailPlan (..)
  , harnessMainRunPrefix
  , harnessZoneRunPrefix
  , lifecycleTestHarnessCleanupCaller
  , orchestrateHarnessCleanup
  , partitionByZoneScope
  , planZoneTail
  , primaryDecision
  , runIdBelongsTo
  )
import Prodbox.TestPlan
  ( TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import Prodbox.TestRunner (harnessCleanupSuiteId)
import System.Directory (doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

lifecycleCleanupClientSuite :: SuiteBuilder ()
lifecycleCleanupClientSuite = do
  entryProtocolSuite
  harnessCleanupCompositionSuite

entryProtocolSuite :: SuiteBuilder ()
entryProtocolSuite =
  describe "Sprint 5.36 lifecycle-owned validation cleanup client" $ do
    it "binds an ordinary per-run surface with no host record at all" $ do
      -- Sprint 5.36: the entry protocol was fixed to the cascade, and the
      -- cascade is the surface that uninstalls the retained local foundation.
      -- A per-run cleanup mutates registered targets and never the host, so it
      -- has no local-uninstall operation to bind a host record to — binding one
      -- anyway would have meant inventing a terminal the compiled program does
      -- not contain.
      --
      -- The ordinary binding runs exactly the checks the cascade binding runs,
      -- because both call one `requireCleanupBinding`; what differs is only the
      -- host half.
      lifecycleCleanupDescriptorRunId ordinaryDescriptor `shouldBe` fixtureRunId
      lifecycleCleanupDescriptorInitialRun ordinaryDescriptor
        `shouldBe` ordinaryInitialRun
      lifecycleCleanupDescriptorHostRecord ordinaryDescriptor
        `shouldBe` NoHostIntent
      -- The shared binding refuses a foreign initial run on this surface for
      -- the same reason it refuses one on the cascade, rather than by a weaker
      -- prefix of those checks.
      mkOrdinaryCleanupDescriptor fixtureRunId ordinaryCompiled fixtureInitialRun
        `shouldSatisfy` isLeft
      -- The cascade's host record is reachable only at the surface that has
      -- one: `lifecycleCleanupDescriptorHostIntent` does not typecheck against
      -- an ordinary descriptor, which is why there is no negative case for it.
      lifecycleCleanupDescriptorHostRecord fixtureDescriptor
        `shouldBe` CascadeHostIntent
          (lifecycleCleanupDescriptorHostIntent fixtureDescriptor)

    it "binds one caller run id to the compiled graph, CleanupRun, scope, and terminal operation" $ do
      lifecycleCleanupDescriptorRunId fixtureDescriptor `shouldBe` fixtureRunId
      lifecycleCleanupDescriptorProgram fixtureDescriptor
        `shouldSatisfy` sameCompiledBinding fixtureCompiled
      lifecycleCleanupDescriptorInitialRun fixtureDescriptor `shouldBe` fixtureInitialRun
      cleanupProgramDescriptorDigest
        (lifecycleCleanupDescriptorProgramDescriptor fixtureDescriptor)
        `shouldBe` cleanupProgramDescriptorDigest fixtureProgramDescriptor
      let hostIntent = lifecycleCleanupDescriptorHostIntent fixtureDescriptor
      hostCleanupRunId hostIntent `shouldBe` fixtureRunId
      hostCleanupGraphDigest hostIntent `shouldBe` cleanupRunGraphDigest fixtureInitialRun
      hostCleanupRun hostIntent `shouldBe` fixtureInitialRun
      hostCleanupTerminalOperationId (hostCleanupTerminalIdentity hostIntent)
        `shouldBe` fixtureTerminalOperationId
      mkLifecycleCleanupDescriptor
        otherRunId
        fixtureCompiled
        fixtureInitialRun
        fixtureTerminalPermit
        `shouldSatisfy` isCompiledRunIdMismatch
      mkLifecycleCleanupDescriptor
        fixtureRunId
        fixtureCompiled
        otherFoundationRun
        fixtureTerminalPermit
        `shouldSatisfy` isInitialGraphMismatch

    it "never invokes a supplied mutation before the exact host descriptor is re-observable" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-gate" $ \retainedRoot -> do
        let store = fixtureStore retainedRoot
        observedInside <- newIORef (Right Nothing)
        result <-
          prepareLifecycleCleanupBeforeMutation (PrepareHostUninstallRecord store) fixtureDescriptor $ do
            observed <- observeHostCleanupIntent store
            writeIORef observedInside observed
            pure ("mutation-ran" :: Text)
        result `shouldBe` Right "mutation-ran"
        readIORef observedInside
          `shouldReturn` Right (Just (lifecycleCleanupDescriptorHostIntent fixtureDescriptor))

        let conflicting = descriptorFor otherRunId
        _ <-
          expectIoRight
            ( prepareHostCleanupRunner
                store
                (lifecycleCleanupDescriptorHostIntent fixtureDescriptor)
            )
        mutationRan <- newIORef False
        refused <-
          prepareLifecycleCleanupBeforeMutation
            (PrepareHostUninstallRecord store)
            conflicting
            (writeIORef mutationRan True)
        refused `shouldSatisfy` isLeft
        readIORef mutationRan `shouldReturn` False
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            False
            (const CleanupNodeSucceeded)
        refusedRegistration <-
          registerLifecycleCleanupRun
            (PrepareHostUninstallRecord store)
            (fakeCleanupRunClient fake)
            conflicting
        refusedRegistration `shouldSatisfy` isLeft
        readIORef (fakeCommandTrace fake)
          `shouldReturn` [CleanupRunDescriptorObserve fixtureRawRunId]

    it "creates a fresh run after the production descriptor-missing observation" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-descriptor-missing" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            False
            (const CleanupNodeSucceeded)
        _ <-
          expectIoRight
            ( registerLifecycleCleanupRun
                (PrepareHostUninstallRecord (fixtureStore retainedRoot))
                (fakeCleanupRunClient fake)
                fixtureDescriptor
            )
        trace <- readIORef (fakeCommandTrace fake)
        case take 2 trace of
          [CleanupRunDescriptorObserve _, CleanupRunDescriptorCreate _ _] -> pure ()
          observed ->
            expectationFailure
              ("expected descriptor-missing observe before create, observed " ++ show observed)
        readIORef (fakeCreateApplications fake) `shouldReturn` 1

    it "recovers create, primary, and report response loss without duplicating a lifecycle effect" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-response-loss" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            [LoseCreateResponse, LosePrimaryResponse, LoseCompactResponse]
            True
            (const CleanupNodeSucceeded)
        let store = fixtureStore retainedRoot
            client = fakeCleanupRunClient fake
        registered <-
          expectIoRight
            (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
        replayed <-
          expectIoRight
            (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
        descriptorBoundCleanupRunId (registeredLifecycleCleanupBoundRun replayed)
          `shouldBe` descriptorBoundCleanupRunId (registeredLifecycleCleanupBoundRun registered)
        readIORef (fakeCreateApplications fake) `shouldReturn` 1
        readIORef (fakeNodeEffects fake) `shouldReturn` []

        recorded <-
          expectIoRight
            ( attachLifecycleCleanupPrimaryOutcome
                client
                CleanupPrimarySucceeded
                replayed
            )
        result <- observeLifecycleCleanupResult client 1000 0 recorded
        case result of
          LifecycleCleanupIncompleteResult incomplete ->
            expectationFailure ("unexpected incomplete result: " ++ show incomplete)
          LifecycleCleanupReportObserved report -> do
            cleanupReportRunId report `shouldBe` fixtureRunId
            cleanupReportPrimaryOutcome report `shouldBe` CleanupPrimarySucceeded
        effects <- readIORef (fakeNodeEffects fake)
        effects
          `shouldBe` (cleanupNodeId <$> cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled))
        length (nub effects) `shouldBe` length effects
        readIORef (fakeCreateApplications fake) `shouldReturn` 1
        assertOneRunId fake
        compactCount <- countCommands isCompactCommand <$> readIORef (fakeCommandTrace fake)
        compactCount `shouldBe` 1

    it "returns the exact terminal report without compacting inside its retention window" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-retention" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            True
            (const CleanupNodeSucceeded)
        let client = fakeCleanupRunClient fake
        registered <-
          expectIoRight
            ( registerLifecycleCleanupRun
                (PrepareHostUninstallRecord (fixtureStore retainedRoot))
                client
                fixtureDescriptor
            )
        recorded <-
          expectIoRight
            ( attachLifecycleCleanupPrimaryOutcome
                client
                CleanupPrimarySucceeded
                registered
            )
        result <- observeLifecycleCleanupResult client 100 1 recorded
        case result of
          LifecycleCleanupIncompleteResult incomplete ->
            expectationFailure ("retained terminal report became incomplete: " ++ show incomplete)
          LifecycleCleanupReportObserved report -> do
            cleanupReportRunId report `shouldBe` fixtureRunId
            cleanupReportPrimaryOutcome report `shouldBe` CleanupPrimarySucceeded
        stored <- readIORef (fakeStoredRun fake)
        stored `shouldSatisfy` isLiveStoredRun
        compactCount <- countCommands isCompactCommand <$> readIORef (fakeCommandTrace fake)
        compactCount `shouldBe` 0

    it "archives an immutable terminal failure before admitting a distinct host intent" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-failed-retirement" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            True
            (const (CleanupNodeFailed "fixed terminal failure"))
        let store = fixtureStore retainedRoot
            client = fakeCleanupRunClient fake
        registered <-
          expectIoRight
            ( registerLifecycleCleanupRun
                (PrepareHostUninstallRecord store)
                client
                fixtureDescriptor
            )
        _ <-
          expectIoRight
            ( attachLifecycleCleanupPrimaryOutcome
                client
                CleanupPrimarySucceeded
                registered
            )
        let replacement = descriptorFor otherRunId
        replacementResult <-
          registerLifecycleCleanupRun
            (PrepareHostUninstallRecord store)
            client
            replacement
        replacementResult `shouldSatisfy` isLeft
        observeHostCleanupIntent store
          `shouldReturn` Right
            (Just (lifecycleCleanupDescriptorHostIntent replacement))
        archived <-
          listDirectory
            (retainedRoot </> "host-cleanup-intent")
        length (filter ("failed-" `isPrefixOf`) archived) `shouldBe` 1

    it "preserves both the transition failure and its failed independent re-observation" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-unconfirmed" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            [LoseCreateResponse, RefuseNextLiveObserve]
            False
            (const CleanupNodeSucceeded)
        result <-
          registerLifecycleCleanupRun
            (PrepareHostUninstallRecord (fixtureStore retainedRoot))
            (fakeCleanupRunClient fake)
            fixtureDescriptor
        result `shouldSatisfy` isBoundedUnconfirmed
        readIORef (fakeCreateApplications fake) `shouldReturn` 1
        readIORef (fakeNodeEffects fake) `shouldReturn` []

    it "leaves cancellation durably recoverable and preserves the typed cancelled primary" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-cancel" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            True
            (const CleanupNodeSucceeded)
        let store = fixtureStore retainedRoot
            client = fakeCleanupRunClient fake
        interrupted <-
          try
            ( prepareLifecycleCleanupBeforeMutation
                (PrepareHostUninstallRecord store)
                fixtureDescriptor
                (throwIO ThreadKilled)
            )
            :: IO
                 ( Either
                     SomeException
                     (Either LifecycleCleanupClientError ())
                 )
        interrupted `shouldSatisfy` isThreadKilled
        observeHostCleanupIntent store
          `shouldReturn` Right (Just (lifecycleCleanupDescriptorHostIntent fixtureDescriptor))
        readIORef (fakeCommandTrace fake) `shouldReturn` []

        registered <-
          expectIoRight
            (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
        recorded <-
          expectIoRight
            ( attachLifecycleCleanupPrimaryOutcome
                client
                CleanupPrimaryCancelled
                registered
            )
        result <- observeLifecycleCleanupResult client 1000 0 recorded
        case result of
          LifecycleCleanupReportObserved report ->
            cleanupReportPrimaryOutcome report
              `shouldBe` CleanupPrimaryCancelled
          LifecycleCleanupIncompleteResult incomplete ->
            expectationFailure ("cancelled run became incomplete: " ++ show incomplete)

    it "takes over one expired run after owner restart without allocating a replacement identity" $
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-owner-restart" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            True
            (const CleanupNodeSucceeded)
        let store = fixtureStore retainedRoot
            client = fakeCleanupRunClient fake
        registered <-
          expectIoRight
            (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
        claimed <-
          expectIoRight
            ( claimLifecycleCleanupRun
                client
                restartedOwner
                101
                200
                registered
            )
        descriptorBoundCleanupRunPrimaryOutcome
          (registeredLifecycleCleanupBoundRun claimed)
          `shouldBe` Just CleanupPrimaryRunnerLost
        finishFakeAuthority
          fake
          fixtureCompiled
          (const CleanupNodeSucceeded)
        replayed <-
          expectIoRight
            (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
        descriptorBoundCleanupRunId (registeredLifecycleCleanupBoundRun replayed)
          `shouldBe` fixtureRunId
        result <- observeLifecycleCleanupResult client 1000 0 replayed
        case result of
          LifecycleCleanupReportObserved report ->
            cleanupReportPrimaryOutcome report
              `shouldBe` CleanupPrimaryRunnerLost
          LifecycleCleanupIncompleteResult incomplete ->
            expectationFailure ("restart did not close the run: " ++ show incomplete)
        readIORef (fakeCreateApplications fake) `shouldReturn` 1
        effects <- readIORef (fakeNodeEffects fake)
        length (nub effects) `shouldBe` length effects
        assertOneRunId fake

    it "preserves typed validation failure, terminal cleanup failures, and explicit incompleteness" $ do
      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-incomplete" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            False
            (const CleanupNodeSucceeded)
        registered <-
          expectIoRight
            ( registerLifecycleCleanupRun
                (PrepareHostUninstallRecord (fixtureStore retainedRoot))
                (fakeCleanupRunClient fake)
                fixtureDescriptor
            )
        recorded <-
          expectIoRight
            ( attachLifecycleCleanupPrimaryOutcome
                (fakeCleanupRunClient fake)
                fixturePrimaryFailure
                registered
            )
        observed <-
          observeLifecycleCleanupResult
            (fakeCleanupRunClient fake)
            1000
            0
            recorded
        case observed of
          LifecycleCleanupReportObserved report ->
            expectationFailure ("nonterminal run forged a report: " ++ show report)
          LifecycleCleanupIncompleteResult incomplete -> do
            lifecycleCleanupIncompleteRunId incomplete `shouldBe` fixtureRunId
            lifecycleCleanupIncompletePrimaryOutcome incomplete
              `shouldBe` Just fixturePrimaryFailure
            NonEmpty.toList (lifecycleCleanupIncompleteFailures incomplete)
              `shouldSatisfy` any isNonterminalFailure

      withSystemTempDirectory "prodbox-lifecycle-cleanup-client-failure-report" $ \retainedRoot -> do
        fake <-
          newFakeAuthority
            fixtureCompiled
            []
            True
            ( \operation ->
                if operation == SomeTeardownOperation UninstallCascadeLocalFoundation
                  then CleanupNodeFailed "local-uninstall-refused"
                  else CleanupNodeSucceeded
            )
        registered <-
          expectIoRight
            ( registerLifecycleCleanupRun
                (PrepareHostUninstallRecord (fixtureStore retainedRoot))
                (fakeCleanupRunClient fake)
                fixtureDescriptor
            )
        recorded <-
          expectIoRight
            ( attachLifecycleCleanupPrimaryOutcome
                (fakeCleanupRunClient fake)
                fixturePrimaryFailure
                registered
            )
        observed <-
          observeLifecycleCleanupResult
            (fakeCleanupRunClient fake)
            1000
            0
            recorded
        case observed of
          LifecycleCleanupIncompleteResult incomplete ->
            expectationFailure ("terminal failure report was discarded: " ++ show incomplete)
          LifecycleCleanupReportObserved report -> do
            cleanupReportPrimaryOutcome report `shouldBe` fixturePrimaryFailure
            Map.lookup fixtureTerminalNodeId (cleanupReportNodeStates report)
              `shouldSatisfy` isRecordedUninstallFailure

    it "resumes the same descriptor across interruption before every mutation prefix" $ do
      forM_ [0 .. length mutationPrefixes - 1] $ \interruptionIndex ->
        withSystemTempDirectory
          ("prodbox-lifecycle-cleanup-prefix-" ++ show interruptionIndex)
          $ \retainedRoot -> do
            fake <-
              newFakeAuthority
                fixtureCompiled
                []
                False
                (const CleanupNodeSucceeded)
            let store = fixtureStore retainedRoot
                client = fakeCleanupRunClient fake
                beforeInterruption = take interruptionIndex mutationPrefixes
                afterRestart = drop interruptionIndex mutationPrefixes
            mutations <- newIORef ([] :: [MutationPrefix])
            mapM_ (runPrefix store client fake mutations) beforeInterruption
            when (AuthorityReachablePrefix `elem` beforeInterruption) $ do
              _ <-
                expectIoRight
                  (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
              pure ()
            interrupted <-
              try
                ( prepareLifecycleCleanupBeforeMutation
                    (PrepareHostUninstallRecord store)
                    fixtureDescriptor
                    (throwIO ThreadKilled)
                )
                :: IO
                     ( Either
                         SomeException
                         (Either LifecycleCleanupClientError ())
                     )
            interrupted `shouldSatisfy` isThreadKilled
            observeHostCleanupIntent store
              `shouldReturn` Right (Just (lifecycleCleanupDescriptorHostIntent fixtureDescriptor))
            mapM_ (runPrefix store client fake mutations) afterRestart
            _ <-
              expectIoRight
                (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
            readIORef mutations `shouldReturn` mutationPrefixes
            readIORef (fakeCreateApplications fake) `shouldReturn` 1
            assertOneRunId fake
            let replayedOperationIds =
                  cleanupNodeOperationId
                    <$> cleanupGraphNodes
                      ( compiledDesiredAbsenceGraph
                          (lifecycleCleanupDescriptorProgram fixtureDescriptor)
                      )
            replayedOperationIds `shouldBe` fixtureOperationIds

    it "contains no validation-owned graph, id allocator, callback cleanup plan, or success fold" $ do
      source <- readFile "src/Prodbox/Lifecycle/CleanupRunEntry.hs"
      source `shouldNotContain` "Prodbox.Test.ManagedCleanupPlan"
      source `shouldNotContain` "compileManagedCleanupPlan"
      source `shouldNotContain` "mkCleanupGraph"
      source `shouldNotContain` "mkCleanupRunId"
      source `shouldNotContain` "mkCleanupOperationId"
      source `shouldNotContain` "runWithDurableCleanup"
      source `shouldContain` "CompiledDesiredAbsenceProgram"
      source `shouldContain` "DescriptorBoundCleanupRunClient"
      source `shouldNotContain` "CleanupRunCommand"
      source `shouldNotContain` "executeCleanupRunCommand"
      source
        `shouldNotContain` ("CleanupProgramDescriptor." <> "Internal")
      source `shouldContain` "prepareHostCleanupRunner"
      validationClient <-
        readFile "src/Prodbox/Test/LifecycleCleanupClient.hs"
      validationClient `shouldNotContain` "mkCleanupGraph"
      validationClient `shouldNotContain` "mkCleanupOperationId"
      validationClient `shouldNotContain` "CapabilityBoundCleanupAction"
      validationClient `shouldNotContain` "CleanupNodeCompleted"
      validationClient `shouldContain` "compileDesiredAbsenceGraphForRegisteredKeys"
      validationClient `shouldContain` "descriptorBoundOrdinaryLifecycleNodeActionInternal"
      validationClient `shouldContain` "adoptExplicitPerRunLifecycleCleanup"
      testRunner <- readFile "src/Prodbox/TestRunner.hs"
      testRunner `shouldNotContain` "Prodbox.Test.ManagedCleanupPlan"
      testRunner `shouldNotContain` "Prodbox.Test.DurableCleanupComposition"
      testRunner `shouldNotContain` "mkCleanupGraph"
      testRunner `shouldNotContain` "CleanupNodeState"
      testRunner `shouldNotContain` "cleanupNodeFailed"
      testRunner `shouldContain` "runLifecycleTestHarnessCleanup"
      testRunner `shouldNotContain` "awsPostflightDestroyCommandArgs"
      cloudRuntime <-
        readFile "src/Prodbox/Lifecycle/Teardown/CloudRuntimeProduction.hs"
      cloudRuntime `shouldContain` "selectRegisteredStackGenerationForCleanup"
      cloudRuntime `shouldNotContain` "queryPerRunResidueStatuses"
      oldManagedPlan <- doesFileExist "src/Prodbox/Test/ManagedCleanupPlan.hs"
      oldComposition <- doesFileExist "src/Prodbox/Test/DurableCleanupComposition.hs"
      oldRoute53Owner <- doesFileExist "src/Prodbox/Infra/Route53ValidationZone.hs"
      (oldManagedPlan, oldComposition, oldRoute53Owner)
        `shouldBe` (False, False, False)
      testSource <- readFile "test/unit/LifecycleCleanupClient.hs"
      testSource
        `shouldNotContain` ("CleanupProgramDescriptor." <> "Internal")

-- | Sprint 5.50: the composition around the validation body.
harnessCleanupCompositionSuite :: SuiteBuilder ()
harnessCleanupCompositionSuite =
  describe "Sprint 5.50 harness cleanup composition" $ do
    it "authenticates as the operator, which is trusted wherever the harness identity is" $ do
      -- The first node of every ordinary program posts the host observation,
      -- a route only the operator may call. The switch widens nothing: every
      -- route that trusts the harness also trusts the operator.
      lifecycleTestHarnessCleanupCaller `shouldBe` LifecycleAuthorityOperator
      forM_ allControlPlaneRoutes $ \route ->
        when (callerMayCallRoute CallerTestHarness route) $
          callerMayCallRoute CallerOperatorCli route `shouldBe` True
      callerMayCallRoute CallerOperatorCli LifecycleLocalRke2HostObservation `shouldBe` True
      callerMayCallRoute CallerTestHarness LifecycleLocalRke2HostObservation `shouldBe` False

    it "never names the harness identity as the cleanup caller" $ do
      client <- readFile "src/Prodbox/Test/LifecycleCleanupClient.hs"
      client `shouldContain` "LifecycleAuthorityOperator"
      client `shouldNotContain` "LifecycleAuthorityTestHarness"

    it "keeps no session open while the body runs, and drives afterwards with the primary outcome" $ do
      trace <- newIORef ([] :: [String])
      sessionOpen <- newIORef False
      let record event = modifyIORef' trace (++ [event])
          withSession name action = do
            writeIORef sessionOpen True
            record ("open:" ++ name)
            result <- action
            record ("close:" ++ name)
            writeIORef sessionOpen False
            pure result
          bracket =
            HarnessCleanupBracket
              { bracketRegister = withSession "register" (pure (Right True))
              , bracketDrive = \primary ->
                  withSession "drive" $ do
                    record ("primary:" ++ primaryTag primary)
                    pure (Left LifecycleTestHarnessMainRunMissing)
              }
          body = do
            open <- readIORef sessionOpen
            record ("body:sessionOpen=" ++ show open)
            pure (ExitFailure 3)
      result <- orchestrateHarnessCleanup bracket body
      leftOf result `shouldBe` Just LifecycleTestHarnessMainRunMissing
      readIORef trace
        `shouldReturn` [ "open:register"
                       , "close:register"
                       , "body:sessionOpen=False"
                       , "open:drive"
                       , "primary:exit3"
                       , "close:drive"
                       ]

    it "can detect a session left open across the body (negative control)" $ do
      sessionOpen <- newIORef False
      observed <- newIORef Nothing
      let leaking =
            HarnessCleanupBracket
              { bracketRegister = writeIORef sessionOpen True >> pure (Right True)
              , bracketDrive = \_ -> pure (Left LifecycleTestHarnessMainRunMissing)
              }
      _ <-
        orchestrateHarnessCleanup leaking $ do
          readIORef sessionOpen >>= writeIORef observed . Just
          pure ExitSuccess
      readIORef observed `shouldReturn` Just True

    it "adopts a leftover run without running the body again" $ do
      bodyRuns <- newIORef (0 :: Int)
      primaries <- newIORef ([] :: [String])
      let bracket =
            HarnessCleanupBracket
              { bracketRegister = pure (Right False)
              , bracketDrive = \primary -> do
                  modifyIORef' primaries (++ [primaryTag primary])
                  pure (Left LifecycleTestHarnessMainRunMissing)
              }
      _ <- orchestrateHarnessCleanup bracket (modifyIORef' bodyRuns (+ 1) >> pure ExitSuccess)
      readIORef bodyRuns `shouldReturn` 0
      readIORef primaries `shouldReturn` ["none"]

    it "drives cleanup after a body that throws, recording the failure as the primary outcome" $ do
      primaries <- newIORef ([] :: [String])
      let bracket =
            HarnessCleanupBracket
              { bracketRegister = pure (Right True)
              , bracketDrive = \primary -> do
                  modifyIORef' primaries (++ [primaryTag primary])
                  pure (Left LifecycleTestHarnessMainRunMissing)
              }
      result <- orchestrateHarnessCleanup bracket (throwIO (ErrorCall "validation exploded"))
      leftOf result `shouldBe` Just LifecycleTestHarnessMainRunMissing
      readIORef primaries `shouldReturn` ["thrown"]

    it "runs cleanup masked after an asynchronous cancellation and then rethrows it" $ do
      primaries <- newIORef ([] :: [String])
      let bracket =
            HarnessCleanupBracket
              { bracketRegister = pure (Right True)
              , bracketDrive = \primary -> do
                  modifyIORef' primaries (++ [primaryTag primary])
                  pure (Left LifecycleTestHarnessMainRunMissing)
              }
      outcome <-
        try (void (orchestrateHarnessCleanup bracket (throwIO ThreadKilled)))
          :: IO (Either SomeException ())
      outcome `shouldSatisfy` isThreadKilled
      readIORef primaries `shouldReturn` ["cancelled"]

    it "does not run the body or the drive when registration fails" $ do
      events <- newIORef ([] :: [String])
      let bracket =
            HarnessCleanupBracket
              { bracketRegister = pure (Left LifecycleTestHarnessMainRunMissing)
              , bracketDrive = \_ -> modifyIORef' events (++ ["drive"]) >> pure (Left LifecycleTestHarnessMainRunMissing)
              }
      result <-
        orchestrateHarnessCleanup bracket (modifyIORef' events (++ ["body"]) >> pure ExitSuccess)
      leftOf result `shouldBe` Just LifecycleTestHarnessMainRunMissing
      readIORef events `shouldReturn` []

    it "matches a run id only when it is the prefix followed by digits" $ do
      let suite = "integration-aws"
          mainPrefix = harnessMainRunPrefix suite
          zonePrefix = harnessZoneRunPrefix suite
          runId = mustRight . mkCleanupRunId
      runIdBelongsTo mainPrefix (runId "test-harness-integration-aws-1700000000000000") `shouldBe` True
      -- The suite whose id extends this one has runs of its own.
      runIdBelongsTo mainPrefix (runId "test-harness-integration-aws-eks-1700000000000000")
        `shouldBe` False
      runIdBelongsTo mainPrefix (runId "test-harness-integration-aws-12x") `shouldBe` False
      runIdBelongsTo mainPrefix (runId "test-harness-integration-aws-") `shouldBe` False
      -- The two prefixes cannot select each other's runs.
      runIdBelongsTo mainPrefix (runId "test-harness-zonetail.integration-aws-1700000000000000")
        `shouldBe` False
      runIdBelongsTo zonePrefix (runId "test-harness-integration-aws-1700000000000000")
        `shouldBe` False
      runIdBelongsTo zonePrefix (runId "test-harness-zonetail.integration-aws-1700000000000000")
        `shouldBe` True

    it "Sprint 5.53 gives the two substrates different cleanup suite ids for one suite" $ do
      let cleanupSuiteIdFor substrate =
            case testPlanExecutionMode (testExecutionPlan substrate TestAll) of
              NativeSuite plan -> harnessCleanupSuiteId plan
              DelegatedSuite _ -> error "test all is a native suite"
          homeSuite = cleanupSuiteIdFor SubstrateHomeLocal
          awsSuite = cleanupSuiteIdFor SubstrateAws
          runId = mustRight . mkCleanupRunId
      -- The home substrate keeps the id the runs already on record carry.
      homeSuite `shouldBe` "all"
      awsSuite `shouldNotBe` homeSuite
      -- A live run one substrate left is not a run the other adopts, in either direction.
      runIdBelongsTo (harnessMainRunPrefix homeSuite) (runId "test-harness-all-1700000000000000")
        `shouldBe` True
      runIdBelongsTo (harnessMainRunPrefix awsSuite) (runId "test-harness-all-1700000000000000")
        `shouldBe` False
      runIdBelongsTo
        (harnessMainRunPrefix awsSuite)
        (runId "test-harness-aws-substrate-all-1700000000000000")
        `shouldBe` True
      runIdBelongsTo
        (harnessMainRunPrefix homeSuite)
        (runId "test-harness-aws-substrate-all-1700000000000000")
        `shouldBe` False
      -- The prefix is not one an ordinary suite id begins with, so no home suite can claim
      -- an AWS run by extending its own id.
      awsSuite `shouldSatisfy` Text.isPrefixOf "aws-substrate-"

    it "decides the zone-scoped families from evidence alone" $ do
      let zone = mustZoneId "Z00231272QFGWVE1AJI2G"
          zoneScoped = [AwsEksSubzoneKey, AwsDns01ChallengeRecordKey]
      planZoneTail [] ZoneEvidenceAbsent `shouldBe` ZoneTailNone ZoneNotSelected
      planZoneTail [] (ZoneEvidenceIncomplete "ignored") `shouldBe` ZoneTailNone ZoneNotSelected
      planZoneTail zoneScoped ZoneEvidenceAbsent `shouldBe` ZoneTailNone ZoneNotApplicable
      planZoneTail zoneScoped (ZoneEvidenceResolved zone)
        `shouldBe` ZoneTailRegister zone zoneScoped
      -- An unobservable stack is never read as an absent one.
      planZoneTail zoneScoped (ZoneEvidenceIncomplete "unreachable")
        `shouldBe` ZoneTailNone (ZoneIncomplete "unreachable")

    it "partitions the selected targets so no zoneless program holds a zone-scoped key" $ do
      let (zoneFree, zoneScoped) = partitionByZoneScope [minBound .. maxBound]
      zoneScoped `shouldBe` [AwsEksSubzoneKey, AwsDns01ChallengeRecordKey]
      forM_ zoneFree $ \key ->
        registeredResourceKeyRequiresDnsZone key `shouldBe` False
      (length zoneFree + length zoneScoped)
        `shouldBe` length [minBound .. maxBound :: RegisteredResourceKey]

    it "decides a run's primary outcome so that no run is left without one and a recorded one stands" $ do
      primaryDecision Nothing (Just (Right ExitSuccess))
        `shouldBe` PrimaryRecord (Just ExitSuccess) CleanupPrimarySucceeded
      primaryDecision Nothing (Just (Right (ExitFailure 3)))
        `shouldBe` PrimaryRecord (Just (ExitFailure 3)) (CleanupPrimaryExitFailure 3)
      -- An adopted run's body was not run now: the outcome is unknown, and a
      -- run with none could never become terminal.
      primaryDecision Nothing Nothing `shouldBe` PrimaryRecord Nothing CleanupPrimaryCancelled
      -- A recorded outcome stands over whatever this invocation observed; the
      -- kernel would refuse a different one on every attempt.
      primaryDecision (Just (CleanupPrimaryExitFailure 1)) (Just (Right ExitSuccess))
        `shouldBe` PrimaryKeepRecorded (CleanupPrimaryExitFailure 1)
      primaryDecision (Just CleanupPrimarySucceeded) Nothing
        `shouldBe` PrimaryKeepRecorded CleanupPrimarySucceeded

    it "ties the zone predicate to the two adapters that refuse a zoneless scope" $ do
      -- Neither refusal is at program compile time: both are at request
      -- construction, so the program compiles with or without a zone and a
      -- compile cannot witness the predicate. The adapters are the witness.
      dns01 <- readFile "src/Prodbox/Lifecycle/Teardown/Dns01ChallengeRecordAdapter.hs"
      family <- readFile "src/Prodbox/Lifecycle/Teardown/AwsNativeStackFamilyAdapter.hs"
      dns01 `shouldContain` "Dns01ChallengeHostedZoneMissing"
      family `shouldContain` "AwsNativeStackFamilyZoneMissing"
      registeredResourceKeyRequiresDnsZone AwsDns01ChallengeRecordKey `shouldBe` True
      registeredResourceKeyRequiresDnsZone AwsEksSubzoneKey `shouldBe` True
      -- No other family reads the scope's zone to refuse.
      forM_ [minBound .. maxBound] $ \key ->
        unless (key `elem` [AwsDns01ChallengeRecordKey, AwsEksSubzoneKey]) $
          registeredResourceKeyRequiresDnsZone key `shouldBe` False

    it "keeps the legacy host IAM setup and teardown out of the runner and says what is retained" $ do
      runner <- readFile "src/Prodbox/TestRunner.hs"
      runner `shouldNotContain` "runManagedAwsHarnessSetup"
      runner `shouldNotContain` "runManagedAwsHarnessTeardown"
      runner `shouldNotContain` "runAwsIamHarnessSetup"
      runner `shouldNotContain` "runAwsIamHarnessTeardown"
      runner `shouldNotContain` "proved the typed credential-revocation node"
      runner `shouldContain` "OPERATIONAL_CREDENTIAL_DISPOSITION=retained"
      -- The harness path is entered from the tier alone and has no second
      -- selector or standalone config sync behind it.
      runner `shouldNotContain` "harnessNeedsVaultBeforeSetup"
      runner `shouldNotContain` "harnessRequiresStandaloneInForceConfigSync"
      runner `shouldNotContain` "runReconcileInForceConfig"
      runner `shouldContain` "runNativeHarnessBootstrapFloor repoRoot"
      runner `shouldContain` "reconcileHarnessLifecycleProviderCredential"

leftOf :: Either left right -> Maybe left
leftOf result = case result of
  Left err -> Just err
  Right _ -> Nothing

primaryTag :: Maybe (Either SomeException ExitCode) -> String
primaryTag primary = case primary of
  Nothing -> "none"
  Just (Right ExitSuccess) -> "success"
  Just (Right (ExitFailure code)) -> "exit" ++ show code
  Just (Left exception)
    | show exception == show ThreadKilled -> "cancelled"
    | otherwise -> "thrown"

mustZoneId :: Text -> HostedZoneId
mustZoneId raw = mustRight (mkHostedZoneId raw)

data MutationPrefix
  = ConfigRegenerationPrefix
  | AuthorityReachablePrefix
  | InForceSynchronizationPrefix
  | IamSetupPrefix
  | BodyEntryPrefix
  deriving stock (Bounded, Enum, Eq, Show)

mutationPrefixes :: [MutationPrefix]
mutationPrefixes = [minBound .. maxBound]

runPrefix
  :: HostCleanupIntentStore
  -> DescriptorBoundCleanupRunClient IO
  -> FakeAuthority
  -> IORef [MutationPrefix]
  -> MutationPrefix
  -> IO ()
runPrefix store client fake mutations prefix = do
  result <-
    prepareLifecycleCleanupBeforeMutation (PrepareHostUninstallRecord store) fixtureDescriptor $ do
      observed <- observeHostCleanupIntent store
      unless
        (observed == Right (Just (lifecycleCleanupDescriptorHostIntent fixtureDescriptor)))
        (error "mutation reached before exact host descriptor read-back")
      modifyIORef' mutations (++ [prefix])
  result `shouldBe` Right ()
  when (prefix == AuthorityReachablePrefix) $ do
    _ <-
      expectIoRight
        (registerLifecycleCleanupRun (PrepareHostUninstallRecord store) client fixtureDescriptor)
    readIORef (fakeCreateApplications fake) `shouldReturn` 1

data FakeFault
  = LoseCreateResponse
  | LosePrimaryResponse
  | LoseCompactResponse
  | RefuseNextLiveObserve
  deriving stock (Eq, Ord, Show)

data FakeAuthority = FakeAuthority
  { fakeCleanupRunClient :: !(DescriptorBoundCleanupRunClient IO)
  , fakeStoredRun :: !(IORef FakeStoredRun)
  , fakeCommandTrace :: !(IORef [CleanupRunDescriptorCommand])
  , fakeCreateApplications :: !(IORef Int)
  , fakeNodeEffects :: !(IORef [CleanupNodeId])
  }

data FakeStoredRun
  = FakeRunMissing
  | FakeRunLive !CleanupRun
  | FakeRunTombstoned !CleanupDigest

newFakeAuthority
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> [FakeFault]
  -> Bool
  -> (SomeTeardownOperation 'Cascade -> CleanupNodeOutcome)
  -> IO FakeAuthority
newFakeAuthority compiled injectedFaults finishAutomatically outcomeFor = do
  storedRun <- newIORef FakeRunMissing
  commands <- newIORef []
  createApplications <- newIORef 0
  nodeEffects <- newIORef []
  faults <- newIORef (Set.fromList injectedFaults)
  endpoint <-
    expectRight
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    expectRight
      ( controlPlaneClientWithTransport
          fakeMaximumResponseBytes
          endpoint
          ( fakeAuthorityTransport
              compiled
              finishAutomatically
              outcomeFor
              storedRun
              commands
              createApplications
              nodeEffects
              faults
          )
      )
  let client =
        descriptorBoundCleanupRunClient
          ( mkAuthenticatedClientTransport
              fakeTransportBounds
              fakeClientProviders
              rawClient
          )
  pure
    FakeAuthority
      { fakeCleanupRunClient = client
      , fakeStoredRun = storedRun
      , fakeCommandTrace = commands
      , fakeCreateApplications = createApplications
      , fakeNodeEffects = nodeEffects
      }

fakeAuthorityTransport
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Bool
  -> (SomeTeardownOperation 'Cascade -> CleanupNodeOutcome)
  -> IORef FakeStoredRun
  -> IORef [CleanupRunDescriptorCommand]
  -> IORef Int
  -> IORef [CleanupNodeId]
  -> IORef (Set FakeFault)
  -> Method
  -> [Header]
  -> String
  -> ByteString.ByteString
  -> IO (Either HttpBoundedError (Int, ByteString.ByteString))
fakeAuthorityTransport compiled finishAutomatically outcomeFor storedRun commands createApplications nodeEffects faults method _ url body = do
  method `shouldBe` "POST"
  url `shouldBe` "http://lifecycle-authority:8600/v1/authority/cleanup-run"
  authenticated <-
    authenticateControlPlaneFrame
      fakeTransportBounds
      fakeMaximumLifetime
      fakeServerProviders
      LifecycleAuthorityRuntime
      LifecycleCleanupRun
      (LazyByteString.fromStrict body)
  case authenticated of
    Left err -> do
      expectationFailure ("fake Authority authentication failed: " ++ show err)
      pure (Right (401, "authentication-refused"))
    Right request ->
      case decodeControlPlaneRequest
        cleanupRunMaximumBytes
        (LazyByteString.fromStrict (authenticatedServerInnerBody request)) of
        Left err -> do
          expectationFailure ("fake Authority request decode failed: " ++ show err)
          pure (Right (400, "request-invalid"))
        Right (CleanupRunDescriptorBound command) -> do
          modifyIORef' commands (++ [command])
          (response, responseLost) <-
            executeFakeDescriptorCommand
              compiled
              finishAutomatically
              outcomeFor
              storedRun
              createApplications
              nodeEffects
              faults
              command
          let endpointResult = CleanupRunEndpointDescriptorBound response
              status
                | responseLost = 599
                | otherwise =
                    replyStatusCode (cleanupRunEndpointStatus endpointResult)
          pure (Right (status, cleanupRunEndpointBody endpointResult))
        Right _ -> do
          expectationFailure "validation client issued a raw cleanup-run command"
          pure (Right (400, "raw-command-refused"))

executeFakeDescriptorCommand
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Bool
  -> (SomeTeardownOperation 'Cascade -> CleanupNodeOutcome)
  -> IORef FakeStoredRun
  -> IORef Int
  -> IORef [CleanupNodeId]
  -> IORef (Set FakeFault)
  -> CleanupRunDescriptorCommand
  -> IO (CleanupRunDescriptorResponse, Bool)
executeFakeDescriptorCommand compiled finishAutomatically outcomeFor storedRun createApplications nodeEffects faults command =
  case command of
    CleanupRunDescriptorCreate rawRunId descriptorBytes
      | rawRunId /= fixtureRawRunId -> pure (bindingRefusal "create run id mismatch", False)
      | descriptorBytes /= cleanupProgramDescriptorBytes fixtureProgramDescriptor ->
          pure (bindingRefusal "create descriptor bytes mismatch", False)
      | otherwise -> do
          existing <- readIORef storedRun
          case existing of
            FakeRunMissing -> do
              writeIORef storedRun (FakeRunLive fixtureInitialRun)
              modifyIORef' createApplications (+ 1)
              lose <- consumeFault faults LoseCreateResponse
              pure (presentRun fixtureInitialRun, lose)
            FakeRunLive observed -> do
              lose <- consumeFault faults LoseCreateResponse
              pure (presentRun observed, lose)
            FakeRunTombstoned reportDigest ->
              pure
                ( CleanupRunDescriptorTombstoned
                    fixtureRawDescriptorDigest
                    (cleanupDigestText reportDigest)
                , False
                )
    CleanupRunDescriptorObserve rawRunId
      | rawRunId /= fixtureRawRunId -> pure (bindingRefusal "observe run id mismatch", False)
      | otherwise -> do
          stored <- readIORef storedRun
          case stored of
            FakeRunMissing ->
              pure
                ( CleanupRunDescriptorRefused CleanupRunDescriptorMissing
                , False
                )
            FakeRunLive run -> do
              refuse <- consumeFault faults RefuseNextLiveObserve
              pure
                ( if refuse
                    then
                      CleanupRunDescriptorRefused
                        ( CleanupRunDescriptorUnavailable
                            "independent read-back unavailable"
                        )
                    else presentRun run
                , False
                )
            FakeRunTombstoned reportDigest ->
              pure
                ( CleanupRunDescriptorTombstoned
                    fixtureRawDescriptorDigest
                    (cleanupDigestText reportDigest)
                , False
                )
    CleanupRunDescriptorReadBackProgram rawRunId
      | rawRunId /= fixtureRawRunId -> pure (bindingRefusal "descriptor run id mismatch", False)
      | otherwise ->
          pure
            ( CleanupRunDescriptorProgramPresent
                fixtureRawRunId
                fixtureRawDescriptorDigest
                (cleanupProgramDescriptorBytes fixtureProgramDescriptor)
            , False
            )
    CleanupRunDescriptorClaim rawRunId rawDescriptorDigest rawOwner now expires ->
      withDescriptorIdentity rawRunId rawDescriptorDigest $ case mkCleanupOwnerId rawOwner of
        Left detail -> pure (bindingRefusal detail, False)
        Right owner -> do
          transitioned <-
            applyFakeTransition
              compiled
              False
              outcomeFor
              storedRun
              nodeEffects
              (claimCleanupRun owner now expires)
          pure (either transitionRefusal presentRun transitioned, False)
    CleanupRunDescriptorRecordPrimary rawRunId rawDescriptorDigest rawOwner fence outcome ->
      withDescriptorIdentity rawRunId rawDescriptorDigest $ case mkCleanupOwnerId rawOwner of
        Left detail -> pure (bindingRefusal detail, False)
        Right owner -> do
          transitioned <-
            applyFakeTransition
              compiled
              finishAutomatically
              outcomeFor
              storedRun
              nodeEffects
              (recordPrimaryOutcome owner fence outcome)
          lose <- consumeFault faults LosePrimaryResponse
          pure (either transitionRefusal presentRun transitioned, lose && isRight transitioned)
    CleanupRunDescriptorCompact rawRunId rawDescriptorDigest _ _ ->
      withDescriptorIdentity rawRunId rawDescriptorDigest $ do
        stored <- readIORef storedRun
        case stored of
          FakeRunMissing -> pure (CleanupRunDescriptorNotFound, False)
          FakeRunTombstoned reportDigest ->
            pure
              ( CleanupRunDescriptorTombstoned
                  fixtureRawDescriptorDigest
                  (cleanupDigestText reportDigest)
              , False
              )
          FakeRunLive run -> case compactCleanupRun run of
            Left err -> pure (transitionRefusal err, False)
            Right report -> case encodeCleanupRunReport cleanupRunMaximumBytes report of
              Left err -> pure (bindingRefusal (Text.pack (show err)), False)
              Right reportBytes -> do
                let reportDigest = cleanupDigestOfBytes reportBytes
                writeIORef storedRun (FakeRunTombstoned reportDigest)
                lose <- consumeFault faults LoseCompactResponse
                pure
                  ( CleanupRunDescriptorCompacted
                      fixtureRawDescriptorDigest
                      reportBytes
                  , lose
                  )
    CleanupRunDescriptorBeginNode {} ->
      pure (bindingRefusal "validation client attempted local node execution", False)
    CleanupRunDescriptorCompleteNode {} ->
      pure (bindingRefusal "validation client attempted local node completion", False)
    CleanupRunDescriptorScan ->
      pure (bindingRefusal "unexpected descriptor-bound scan", False)
 where
  withDescriptorIdentity rawRunId rawDescriptorDigest action
    | rawRunId /= fixtureRawRunId =
        pure (bindingRefusal "transition run id mismatch", False)
    | rawDescriptorDigest /= fixtureRawDescriptorDigest =
        pure (bindingRefusal "transition descriptor digest mismatch", False)
    | otherwise = action

presentRun :: CleanupRun -> CleanupRunDescriptorResponse
presentRun run = case encodeCleanupRun cleanupRunMaximumBytes run of
  Left err -> bindingRefusal (Text.pack (show err))
  Right bytes ->
    CleanupRunDescriptorPresent
      fixtureRawRunId
      fixtureRawDescriptorDigest
      bytes

bindingRefusal :: Text -> CleanupRunDescriptorResponse
bindingRefusal =
  CleanupRunDescriptorRefused . CleanupRunDescriptorBindingMismatch

transitionRefusal :: CleanupRunError -> CleanupRunDescriptorResponse
transitionRefusal =
  CleanupRunDescriptorRefused . CleanupRunDescriptorTransitionRefused

applyFakeTransition
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Bool
  -> (SomeTeardownOperation 'Cascade -> CleanupNodeOutcome)
  -> IORef FakeStoredRun
  -> IORef [CleanupNodeId]
  -> (CleanupRun -> Either CleanupRunError CleanupRun)
  -> IO (Either CleanupRunError CleanupRun)
applyFakeTransition compiled finishAutomatically outcomeFor storedRun nodeEffects transition = do
  stored <- readIORef storedRun
  case stored of
    FakeRunMissing -> pure (Left CleanupRunNotTerminal)
    FakeRunTombstoned {} -> pure (Left CleanupRunNotTerminal)
    FakeRunLive run -> case transition run of
      Left err -> pure (Left err)
      Right transitioned -> do
        finished <-
          if finishAutomatically && cleanupRunPrimaryOutcome transitioned /= Nothing
            then case finishFakeCleanup compiled outcomeFor transitioned of
              Left _ -> pure (Left CleanupRunNotTerminal)
              Right (terminal, effects) -> do
                modifyIORef' nodeEffects (++ effects)
                pure (Right terminal)
            else pure (Right transitioned)
        case finished of
          Left err -> pure (Left err)
          Right next -> do
            writeIORef storedRun (FakeRunLive next)
            pure (Right next)

finishFakeAuthority
  :: FakeAuthority
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> (SomeTeardownOperation 'Cascade -> CleanupNodeOutcome)
  -> IO ()
finishFakeAuthority fake compiled outcomeFor = do
  stored <- readIORef (fakeStoredRun fake)
  case stored of
    FakeRunLive run -> case finishFakeCleanup compiled outcomeFor run of
      Left detail -> expectationFailure (Text.unpack detail)
      Right (terminal, effects) -> do
        writeIORef (fakeStoredRun fake) (FakeRunLive terminal)
        modifyIORef' (fakeNodeEffects fake) (++ effects)
    FakeRunMissing -> expectationFailure "fake Authority cleanup run is missing"
    FakeRunTombstoned {} ->
      expectationFailure "fake Authority cleanup run is already tombstoned"

finishFakeCleanup
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> (SomeTeardownOperation 'Cascade -> CleanupNodeOutcome)
  -> CleanupRun
  -> Either Text (CleanupRun, [CleanupNodeId])
finishFakeCleanup compiled outcomeFor initial =
  foldM
    runNode
    (initial, [])
    (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
 where
  runNode (run, effects) node =
    case Map.lookup (cleanupNodeId node) (cleanupRunNodeStates run) of
      Nothing -> Left "compiled node missing from fake run"
      Just CleanupNodePending -> do
        operation <-
          maybe
            (Left "compiled operation missing from fake run")
            Right
            (compiledOperationForNode (cleanupNodeId node) compiled)
        attempt <-
          firstText
            ( mkCleanupAttemptId
                ("fake-authority/" <> cleanupNodeIdText (cleanupNodeId node))
            )
        running <-
          firstShow
            ( beginCleanupNode
                (cleanupLeaseOwner (cleanupRunLease run))
                (cleanupLeaseFence (cleanupRunLease run))
                (cleanupNodeId node)
                attempt
                run
            )
        completed <-
          firstShow
            ( completeCleanupNode
                (cleanupLeaseOwner (cleanupRunLease running))
                (cleanupLeaseFence (cleanupRunLease running))
                (cleanupNodeId node)
                attempt
                (outcomeFor operation)
                running
            )
        Right (completed, effects ++ [cleanupNodeId node])
      Just CleanupNodeBlocked {} -> Right (run, effects)
      Just CleanupNodeCompleted {} -> Right (run, effects)
      Just CleanupNodeRunning {} ->
        Left "fake Authority observed an unowned running node"

consumeFault :: IORef (Set FakeFault) -> FakeFault -> IO Bool
consumeFault faults fault =
  atomicModifyIORef' faults $ \remaining ->
    if Set.member fault remaining
      then (Set.delete fault remaining, True)
      else (remaining, False)

fakeMaximumResponseBytes :: Int
fakeMaximumResponseBytes = 4 * 1024 * 1024

fakeTransportBounds :: AuthenticatedTransportBounds
fakeTransportBounds =
  mustRight
    ( mkAuthenticatedTransportBounds
        fakeMaximumResponseBytes
        256
        (fakeMaximumResponseBytes - 1024)
    )

fakeMaximumLifetime :: AuthorityDuration
fakeMaximumLifetime = mustRight (authorityDurationFromMicros 5000)

fakeNow, fakeDeadline :: AuthorityTime
fakeNow = authorityTimeFromMicros 1000
fakeDeadline = authorityTimeFromMicros 2000

fakeAuthorityScope :: AuthorityScope
fakeAuthorityScope = mustRight (mkAuthorityScope "lifecycle-cleanup-client")

fakeRequestSigner :: RequestSigner
fakeRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString8.pack "0123456789abcdef0123456789abcdef")
    )

fakeRequestNonce :: RequestNonce
fakeRequestNonce =
  mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

fakeClientProviders :: AuthenticatedClientProviders IO
fakeClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability fakeRequestSigner))
    , provideAuthenticatedClientScope = pure (Right fakeAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right fakeDeadline)
    , provideAuthenticatedClientNonce = pure (Right fakeRequestNonce)
    }

fakeServerProviders :: AuthenticatedServerProviders IO
fakeServerProviders =
  AuthenticatedServerProviders
    { provideAuthenticatedServerScope = pure (Right fakeAuthorityScope)
    , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedServerTime = pure (Right fakeNow)
    , provideAuthenticatedServerTrustRegistry =
        pure (Right fakeTrustRegistry)
    }

fakeTrustRegistry :: RouteTrustRegistry
fakeTrustRegistry =
  mustRight
    ( mkRouteTrustRegistry
        LifecycleAuthorityRuntime
        1
        [ (route, trustedRequestKeyFromSigner fakeRequestSigner)
        | route <- routesForRole LifecycleAuthorityRuntime
        ]
    )

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "teardown-client-run-0001")
otherRunId = mustRight (mkCleanupRunId "teardown-client-run-0002")

fixtureOwner, restartedOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "validation-owner-a")
restartedOwner = mustRight (mkCleanupOwnerId "validation-owner-b")

fixtureFoundation, otherFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "qualification-home-rke2"
otherFoundation = LinuxRke2FoundationId "qualification-other-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "123456789012")
    (AwsRegion (fixtureAwsRegion FixtureUsEast1))

fixtureCompiled :: CompiledDesiredAbsenceProgram 'Cascade
fixtureCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope)
        Nothing
        CascadeSurface
    )

fixtureInitialRun :: CleanupRun
fixtureInitialRun =
  mustRight
    ( newCleanupRun
        fixtureRunId
        (compiledDesiredAbsenceGraph fixtureCompiled)
        fixtureOwner
        0
        100
    )

fixtureProgramDescriptor :: CleanupProgramDescriptor
fixtureProgramDescriptor =
  lifecycleCleanupDescriptorProgramDescriptor fixtureDescriptor

fixtureRawRunId :: Text
fixtureRawRunId = cleanupRunIdText fixtureRunId

fixtureRawDescriptorDigest :: Text
fixtureRawDescriptorDigest =
  cleanupDigestText (cleanupProgramDescriptorDigest fixtureProgramDescriptor)

otherFoundationRun :: CleanupRun
otherFoundationRun =
  let compiled =
        mustRight
          ( compileDesiredAbsenceGraph
              fixtureRunId
              otherFoundation
              (Just fixtureAwsScope)
              Nothing
              CascadeSurface
          )
   in mustRight
        ( newCleanupRun
            fixtureRunId
            (compiledDesiredAbsenceGraph compiled)
            fixtureOwner
            0
            100
        )

fixtureTerminalPermit :: HostTerminalPermitId
fixtureTerminalPermit =
  mustRight
    (mkHostTerminalPermitId "teardown-client-run-0001/local-uninstall")

fixtureDescriptor :: LifecycleCleanupDescriptor 'Cascade
fixtureDescriptor =
  mustRight
    ( mkLifecycleCleanupDescriptor
        fixtureRunId
        fixtureCompiled
        fixtureInitialRun
        fixtureTerminalPermit
    )

descriptorFor :: CleanupRunId -> LifecycleCleanupDescriptor 'Cascade
descriptorFor runId =
  let compiled =
        mustRight
          ( compileDesiredAbsenceGraph
              runId
              fixtureFoundation
              (Just fixtureAwsScope)
              Nothing
              CascadeSurface
          )
      run =
        mustRight
          ( newCleanupRun
              runId
              (compiledDesiredAbsenceGraph compiled)
              fixtureOwner
              0
              100
          )
   in mustRight
        ( mkLifecycleCleanupDescriptor
            runId
            compiled
            run
            fixtureTerminalPermit
        )

fixtureStore :: FilePath -> HostCleanupIntentStore
fixtureStore = mustRight . mkHostCleanupIntentStore

fixtureTerminalNodeId :: CleanupNodeId
fixtureTerminalNodeId = operationNodeId "uninstall-cascade-local-foundation"

fixtureTerminalOperationId :: CleanupOperationId
fixtureTerminalOperationId =
  case [ cleanupNodeOperationId node
       | node <- cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)
       , cleanupNodeId node == fixtureTerminalNodeId
       ] of
    [operationId] -> operationId
    operations -> error ("unexpected terminal operation count: " ++ show (length operations))

fixtureOperationIds :: [CleanupOperationId]
fixtureOperationIds =
  cleanupNodeOperationId
    <$> cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)

operationNodeId :: Text -> CleanupNodeId
operationNodeId tag =
  case [ nodeId
       | (nodeId, operation) <- compiledDesiredAbsenceOperations fixtureCompiled
       , someTeardownOperationTag operation == tag
       ] of
    [nodeId] -> nodeId
    nodes -> error ("unexpected operation node count: " ++ show (length nodes))

fixturePrimaryFailure :: CleanupPrimaryOutcome
fixturePrimaryFailure = CleanupPrimaryFailed "validation-refused"

sameCompiledBinding
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> Bool
sameCompiledBinding expected actual =
  compiledDesiredAbsenceRunId actual == compiledDesiredAbsenceRunId expected
    && compiledDesiredAbsenceGraph actual == compiledDesiredAbsenceGraph expected
    && compiledDesiredAbsenceObservationScope actual
      == compiledDesiredAbsenceObservationScope expected
    && compiledDesiredAbsenceOperations actual
      == compiledDesiredAbsenceOperations expected

assertOneRunId :: FakeAuthority -> IO ()
assertOneRunId fake = do
  commands <- readIORef (fakeCommandTrace fake)
  let runIds = [runId | Just runId <- commandRunId <$> commands]
  runIds `shouldSatisfy` (not . null)
  nub runIds `shouldBe` [cleanupRunIdText fixtureRunId]

commandRunId :: CleanupRunDescriptorCommand -> Maybe Text
commandRunId command = case command of
  CleanupRunDescriptorCreate runId _ -> Just runId
  CleanupRunDescriptorObserve runId -> Just runId
  CleanupRunDescriptorClaim runId _ _ _ _ -> Just runId
  CleanupRunDescriptorRecordPrimary runId _ _ _ _ -> Just runId
  CleanupRunDescriptorBeginNode runId _ _ _ _ _ -> Just runId
  CleanupRunDescriptorCompleteNode runId _ _ _ _ _ _ -> Just runId
  CleanupRunDescriptorScan -> Nothing
  CleanupRunDescriptorCompact runId _ _ _ -> Just runId
  CleanupRunDescriptorReadBackProgram runId -> Just runId

countCommands
  :: (CleanupRunDescriptorCommand -> Bool)
  -> [CleanupRunDescriptorCommand]
  -> Int
countCommands predicate = length . filter predicate

isCompactCommand :: CleanupRunDescriptorCommand -> Bool
isCompactCommand command = case command of
  CleanupRunDescriptorCompact {} -> True
  _ -> False

isLiveStoredRun :: FakeStoredRun -> Bool
isLiveStoredRun stored = case stored of
  FakeRunLive {} -> True
  FakeRunMissing -> False
  FakeRunTombstoned {} -> False

isRecordedUninstallFailure :: Maybe CleanupNodeState -> Bool
isRecordedUninstallFailure state = case state of
  Just (CleanupNodeCompleted _ (CleanupNodeFailed "local-uninstall-refused")) -> True
  _ -> False

isNonterminalFailure :: LifecycleCleanupClientError -> Bool
isNonterminalFailure failure = case failure of
  LifecycleCleanupRunNotTerminal _ -> True
  _ -> False

isBoundedUnconfirmed
  :: Either LifecycleCleanupClientError (RegisteredLifecycleCleanup 'Cascade)
  -> Bool
isBoundedUnconfirmed result = case result of
  Left
    ( LifecycleCleanupAuthorityResponseUnconfirmed
        _
        (LifecycleCleanupReobserveClientFailed _)
      ) -> True
  _ -> False

isCompiledRunIdMismatch
  :: Either LifecycleCleanupDescriptorError (LifecycleCleanupDescriptor 'Cascade)
  -> Bool
isCompiledRunIdMismatch result = case result of
  Left (LifecycleCleanupCompiledRunIdMismatch supplied compiled) ->
    supplied == otherRunId && compiled == fixtureRunId
  _ -> False

isInitialGraphMismatch
  :: Either LifecycleCleanupDescriptorError (LifecycleCleanupDescriptor 'Cascade)
  -> Bool
isInitialGraphMismatch result = case result of
  Left LifecycleCleanupInitialGraphMismatch -> True
  _ -> False

isThreadKilled :: Either SomeException value -> Bool
isThreadKilled result = case result of
  Left exception -> show exception == show ThreadKilled
  Right _ -> False

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Left _ -> False
  Right _ -> True

expectIoRight :: (Show err) => IO (Either err value) -> IO value
expectIoRight action = do
  result <- action
  case result of
    Left err -> do
      expectationFailure (show err)
      error "unreachable"
    Right value -> pure value

expectRight :: (Show err) => Either err value -> IO value
expectRight result = expectIoRight (pure result)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

firstText :: Either Text value -> Either Text value
firstText = id

firstShow :: (Show err) => Either err value -> Either Text value
firstShow result = case result of
  Left err -> Left (Text.pack (show err))
  Right value -> Right value

-- | Sprint 5.36: the ordinary per-run surface the harness cleanup binds.
ordinaryCompiled :: CompiledDesiredAbsenceProgram 'ExplicitPerRun
ordinaryCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope)
        Nothing
        ExplicitPerRunSurface
    )

ordinaryInitialRun :: CleanupRun
ordinaryInitialRun =
  mustRight
    ( newCleanupRun
        fixtureRunId
        (compiledDesiredAbsenceGraph ordinaryCompiled)
        fixtureOwner
        0
        100
    )

ordinaryDescriptor :: LifecycleCleanupDescriptor 'ExplicitPerRun
ordinaryDescriptor =
  mustRight
    (mkOrdinaryCleanupDescriptor fixtureRunId ordinaryCompiled ordinaryInitialRun)
