{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleCleanupClient
  ( lifecycleCleanupClientSuite
  )
where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , SomeException
  , throwIO
  , try
  )
import Control.Monad (foldM, forM_, unless, when)
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
import Data.List (nub)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
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
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
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
  ( ControlPlaneRoute (LifecycleCleanupRun)
  , routesForRole
  )
import Prodbox.Http.Client (HttpBoundedError)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
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
  ( TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Test.LifecycleCleanupClient
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

lifecycleCleanupClientSuite :: SuiteBuilder ()
lifecycleCleanupClientSuite =
  describe "Sprint 5.36 lifecycle-owned validation cleanup client" $ do
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
          prepareLifecycleCleanupBeforeMutation store fixtureDescriptor $ do
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
            store
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
            store
            (fakeCleanupRunClient fake)
            conflicting
        refusedRegistration `shouldSatisfy` isLeft
        readIORef (fakeCommandTrace fake) `shouldReturn` []

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
            (registerLifecycleCleanupRun store client fixtureDescriptor)
        replayed <-
          expectIoRight
            (registerLifecycleCleanupRun store client fixtureDescriptor)
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
            (fixtureStore retainedRoot)
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
                store
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
            (registerLifecycleCleanupRun store client fixtureDescriptor)
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
            (registerLifecycleCleanupRun store client fixtureDescriptor)
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
            (registerLifecycleCleanupRun store client fixtureDescriptor)
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
                (fixtureStore retainedRoot)
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
                if operation == UninstallCascadeLocalFoundation
                  then CleanupNodeFailed "local-uninstall-refused"
                  else CleanupNodeSucceeded
            )
        registered <-
          expectIoRight
            ( registerLifecycleCleanupRun
                (fixtureStore retainedRoot)
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
                  (registerLifecycleCleanupRun store client fixtureDescriptor)
              pure ()
            interrupted <-
              try
                ( prepareLifecycleCleanupBeforeMutation
                    store
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
                (registerLifecycleCleanupRun store client fixtureDescriptor)
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
      source <- readFile "src/Prodbox/Test/LifecycleCleanupClient.hs"
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
      testSource <- readFile "test/unit/LifecycleCleanupClient.hs"
      testSource
        `shouldNotContain` ("CleanupProgramDescriptor." <> "Internal")

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
    prepareLifecycleCleanupBeforeMutation store fixtureDescriptor $ do
      observed <- observeHostCleanupIntent store
      unless
        (observed == Right (Just (lifecycleCleanupDescriptorHostIntent fixtureDescriptor)))
        (error "mutation reached before exact host descriptor read-back")
      modifyIORef' mutations (++ [prefix])
  result `shouldBe` Right ()
  when (prefix == AuthorityReachablePrefix) $ do
    _ <-
      expectIoRight
        (registerLifecycleCleanupRun store client fixtureDescriptor)
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
  -> (TeardownOperation 'Cascade -> CleanupNodeOutcome)
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
  -> (TeardownOperation 'Cascade -> CleanupNodeOutcome)
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
  -> (TeardownOperation 'Cascade -> CleanupNodeOutcome)
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
            FakeRunMissing -> pure (CleanupRunDescriptorNotFound, False)
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
  -> (TeardownOperation 'Cascade -> CleanupNodeOutcome)
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
  -> (TeardownOperation 'Cascade -> CleanupNodeOutcome)
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
  -> (TeardownOperation 'Cascade -> CleanupNodeOutcome)
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
    (AwsRegion "us-east-1")

fixtureCompiled :: CompiledDesiredAbsenceProgram 'Cascade
fixtureCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope)
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

fixtureDescriptor :: LifecycleCleanupDescriptor
fixtureDescriptor =
  mustRight
    ( mkLifecycleCleanupDescriptor
        fixtureRunId
        fixtureCompiled
        fixtureInitialRun
        fixtureTerminalPermit
    )

descriptorFor :: CleanupRunId -> LifecycleCleanupDescriptor
descriptorFor runId =
  let compiled =
        mustRight
          ( compileDesiredAbsenceGraph
              runId
              fixtureFoundation
              (Just fixtureAwsScope)
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
       , teardownOperationTag operation == tag
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

isRecordedUninstallFailure :: Maybe CleanupNodeState -> Bool
isRecordedUninstallFailure state = case state of
  Just (CleanupNodeCompleted _ (CleanupNodeFailed "local-uninstall-refused")) -> True
  _ -> False

isNonterminalFailure :: LifecycleCleanupClientError -> Bool
isNonterminalFailure failure = case failure of
  LifecycleCleanupRunNotTerminal _ -> True
  _ -> False

isBoundedUnconfirmed
  :: Either LifecycleCleanupClientError RegisteredLifecycleCleanup
  -> Bool
isBoundedUnconfirmed result = case result of
  Left
    ( LifecycleCleanupAuthorityResponseUnconfirmed
        _
        (LifecycleCleanupReobserveClientFailed _)
      ) -> True
  _ -> False

isCompiledRunIdMismatch
  :: Either LifecycleCleanupDescriptorError LifecycleCleanupDescriptor
  -> Bool
isCompiledRunIdMismatch result = case result of
  Left (LifecycleCleanupCompiledRunIdMismatch supplied compiled) ->
    supplied == otherRunId && compiled == fixtureRunId
  _ -> False

isInitialGraphMismatch
  :: Either LifecycleCleanupDescriptorError LifecycleCleanupDescriptor
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
