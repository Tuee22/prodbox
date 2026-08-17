{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ControlPlaneCleanupProgramDescriptorRepository
  ( controlPlaneCleanupProgramDescriptorRepositorySuite
  )
where

import Control.Monad (filterM, forM_)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Text qualified as Text
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (CleanupRunEndpointDescriptorBound)
  , cleanupRunEndpointBody
  , cleanupRunEndpointStatus
  , cleanupRunMaximumBytes
  , decodeCleanupRunDescriptorResponse
  , encodeCleanupRunDescriptorResponse
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
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
  )
import Prodbox.Http.Client (HttpBoundedError)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  , descriptorBoundCleanupNodeAction
  , descriptorBoundCleanupNodeExecutionContext
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program (teardownOperationTag)
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

controlPlaneCleanupProgramDescriptorRepositorySuite :: SuiteBuilder ()
controlPlaneCleanupProgramDescriptorRepositorySuite =
  describe "Authority cleanup-program descriptor repository" $ do
    it "captures every closed surface only from its exact initial compiled run" $ do
      let checkSurface (SurfaceCase witness expectedSurface maybeAwsScope) =
            case descriptorFixture witness fixtureRunId fixtureFoundation maybeAwsScope of
              Left detail -> expectationFailure (Text.unpack detail)
              Right (compiled, initialRun, descriptor) -> do
                cleanupProgramDescriptorRunId descriptor `shouldBe` fixtureRunId
                cleanupProgramDescriptorSurface descriptor `shouldBe` expectedSurface
                cleanupProgramDescriptorFoundation descriptor `shouldBe` fixtureFoundation
                cleanupProgramDescriptorAwsScope descriptor `shouldBe` maybeAwsScope
                cleanupProgramDescriptorRegistryRevision descriptor
                  `shouldBe` lifecycleRegistryRevision
                cleanupProgramDescriptorLifecycleOperation descriptor
                  `shouldBe` ReconcileDesiredAbsent
                cleanupProgramDescriptorGraphDigest descriptor
                  `shouldBe` cleanupRunGraphDigest initialRun
                cleanupProgramDescriptorCapabilityCatalogDigest descriptor
                  `shouldBe` compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
                cleanupProgramDescriptorOperationIdentityVersion
                  `shouldBe` "lifecycle-cleanup-operation/v3"
                cleanupProgramDescriptorCompilerVersion
                  `shouldBe` "lifecycle-desired-absence-program-compiler/v3"
                cleanupProgramDescriptorCapabilityCatalogVersion
                  `shouldBe` "lifecycle-recovery-capability-catalog/v1"
                cleanupProgramDescriptorCapabilitySetVersion
                  `shouldBe` "lifecycle-recovery-capability-set/v1"
                ByteString.length (cleanupProgramDescriptorBytes descriptor)
                  `shouldSatisfy` (<= maximumCleanupProgramDescriptorBytes)
      forM_ surfaceCases checkSurface

    it "refuses a transitioned run and any compiled/run identity disagreement" $ do
      case descriptorFixture
        CascadeSurface
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope) of
        Left detail -> expectationFailure (Text.unpack detail)
        Right (compiled, initialRun, _) -> do
          let transitioned =
                recordPrimaryOutcome
                  fixtureOwner
                  (cleanupLeaseFence (cleanupRunLease initialRun))
                  CleanupPrimarySucceeded
                  initialRun
          case transitioned of
            Left err -> expectationFailure (show err)
            Right nonInitial ->
              captureCleanupProgramDescriptor compiled nonInitial
                `shouldSatisfy` isLeft
          case descriptorFixture
            CascadeSurface
            otherRunId
            fixtureFoundation
            (Just fixtureAwsScope) of
            Left detail -> expectationFailure (Text.unpack detail)
            Right (_, otherInitialRun, _) ->
              captureCleanupProgramDescriptor compiled otherInitialRun
                `shouldSatisfy` isLeft

    it "exercises create/replay, crash readback, conflict, and hostile storage through the real adapter" $ do
      regressionResult <- fixedCleanupProgramDescriptorRepositoryRegression
      case regressionResult of
        Left detail -> expectationFailure (Text.unpack detail)
        Right regression -> do
          cleanupProgramDescriptorRegressionAllSurfacesCaptured regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionInitialStateRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionResponseLossRecovered regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionExactReplayPreserved regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionConflictPreserved regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionTamperingRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionUnknownStatesRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionWrongRunRefused regression
            `shouldBe` True
          cleanupProgramDescriptorRegressionRestartReconstructionValidated regression
            `shouldBe` True

    it "carries only a canonical committed descriptor through the v2 readback response arm" $ do
      case descriptorFixture
        CascadeSurface
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope) of
        Left detail -> expectationFailure (Text.unpack detail)
        Right (_, _, descriptor) -> do
          let response =
                CleanupRunDescriptorProgramPresent
                  (cleanupRunIdText fixtureRunId)
                  (cleanupDigestText (cleanupProgramDescriptorDigest descriptor))
                  (cleanupProgramDescriptorBytes descriptor)
              bytes = mustRight (encodeCleanupRunDescriptorResponse response)
          decodeCleanupRunDescriptorResponse bytes `shouldBe` Right response
          encodeCleanupRunDescriptorResponse
            ( CleanupRunDescriptorProgramPresent
                (cleanupRunIdText otherRunId)
                (cleanupDigestText (cleanupProgramDescriptorDigest descriptor))
                (cleanupProgramDescriptorBytes descriptor)
            )
            `shouldSatisfy` isLeft
          encodeCleanupRunDescriptorResponse
            ( CleanupRunDescriptorProgramPresent
                (cleanupRunIdText fixtureRunId)
                (Text.replicate 64 "a")
                (cleanupProgramDescriptorBytes descriptor)
            )
            `shouldSatisfy` isLeft

    it "recovers and dispatches two exact surface programs after restart without a side map" $ do
      local <-
        freshProcessDispatch
          LocalOnlySurface
          LocalOnly
          localDispatchRunId
          Nothing
          "uninstall-local-only-foundation"
      cascade <-
        freshProcessDispatch
          CascadeSurface
          Cascade
          cascadeDispatchRunId
          (Just fixtureAwsScope)
          "audit-cascade-escapes"
      local
        `shouldBe` DispatchObservation
          { dispatchObservedSurface = LocalOnly
          , dispatchObservedOperation = "uninstall-local-only-foundation"
          , dispatchHandleMatchesCompiled = True
          , dispatchHandleMatchesReadBack = True
          , dispatchContextMatchesHandle = True
          , dispatchContextMatchesPlan = True
          }
      cascade
        `shouldBe` DispatchObservation
          { dispatchObservedSurface = Cascade
          , dispatchObservedOperation = "audit-cascade-escapes"
          , dispatchHandleMatchesCompiled = True
          , dispatchHandleMatchesReadBack = True
          , dispatchContextMatchesHandle = True
          , dispatchContextMatchesPlan = True
          }
      dispatchObservedOperation local
        `shouldSatisfy` (/= dispatchObservedOperation cascade)

    it "keeps raw decoding, Model-B construction, and positive remint hidden" $ do
      descriptorFacade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/CleanupProgramDescriptor.hs"
      descriptorFacade `shouldNotContain` "decodeAndValidateCleanupProgramDescriptor"
      descriptorFacade `shouldNotContain` "withRecompiledCleanupProgramDescriptor"
      descriptorFacade `shouldNotContain` "CleanupProgramDescriptor (..)"

      repositoryFacade <-
        readFile
          "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository.hs"
      repositoryFacade `shouldNotContain` "ModelBCasAdapter"
      repositoryFacade `shouldNotContain` "modelBCleanupProgramDescriptorRepository"
      repositoryFacade
        `shouldNotContain` "CleanupProgramDescriptorAuthorityClient (..)"
      repositoryFacade
        `shouldNotContain` "CommittedCleanupProgramDescriptor (..)"
      repositoryFacade
        `shouldNotContain` "confirmCommittedCleanupProgramDescriptorBytes"
      repositoryFacade
        `shouldNotContain` "committedCleanupProgramDescriptorBytes"

      descriptorInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal"
      sort descriptorInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/Lifecycle/Teardown/CleanupProgramDescriptor.hs"
          , "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
          ]

      repositoryInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal"
      sort repositoryInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository.hs"
          , "src/Prodbox/ControlPlane/CleanupRunClient.hs"
          , "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
          , "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint/Internal.hs"
          , "src/Prodbox/ControlPlane/Runtime.hs"
          ]

      confirmerUsers <-
        sourceImporters
          "src"
          "confirmCommittedCleanupProgramDescriptorBytes"
      sort confirmerUsers
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupRunClient.hs"
          , "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint/Internal.hs"
          ]
      descriptorBytesUsers <-
        sourceImporters
          "src"
          "committedCleanupProgramDescriptorBytes"
      sort descriptorBytesUsers
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"
          , "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
          ]

      cleanupClient <- readFile "src/Prodbox/ControlPlane/CleanupRunClient.hs"
      let cleanupClientHeader = unlines (takeWhile (/= "where") (lines cleanupClient))
      cleanupClientHeader `shouldNotContain` "DescriptorBoundCleanupRun (..)"
      cleanupClientHeader
        `shouldNotContain` "CommittedCleanupProgramDescriptor (..)"
      cleanupClientHeader
        `shouldNotContain` "withCommittedCleanupProgramDescriptor"
      cleanupClientHeader
        `shouldNotContain` "deriveOrdinaryTeardownRecoveryRequirementInternal"
      cleanupClientHeader
        `shouldNotContain` "confirmCommittedCleanupProgramDescriptorBytes"
      cleanupClientHeader
        `shouldNotContain` "committedCleanupProgramDescriptorBytes"

      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          descriptorInternal =
            "Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal"
          repositoryInternal =
            "Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal"
      unlines libraryExposed `shouldNotContain` descriptorInternal
      unlines libraryExposed `shouldNotContain` repositoryInternal
      unlines libraryPrivate `shouldContain` descriptorInternal
      unlines libraryPrivate `shouldContain` repositoryInternal

data DispatchObservation = DispatchObservation
  { dispatchObservedSurface :: !CleanupSurface
  , dispatchObservedOperation :: !Text.Text
  , dispatchHandleMatchesCompiled :: !Bool
  , dispatchHandleMatchesReadBack :: !Bool
  , dispatchContextMatchesHandle :: !Bool
  , dispatchContextMatchesPlan :: !Bool
  }
  deriving (Eq, Show)

freshProcessDispatch
  :: CleanupSurfaceWitness surface
  -> CleanupSurface
  -> CleanupRunId
  -> Maybe AwsScope
  -> Text.Text
  -> IO DispatchObservation
freshProcessDispatch witness expectedSurface runId maybeAwsScope expectedOperation = do
  (compiled, initialRun, descriptor) <-
    mustRightIO
      (descriptorFixture witness runId fixtureFoundation maybeAwsScope)
  (plan, running) <-
    mustRightIO
      (runningAtOperation expectedOperation compiled initialRun)
  runningBytes <-
    mustRightIO (firstShow (encodeCleanupRun cleanupRunMaximumBytes running))
  let descriptorDigest = cleanupProgramDescriptorDigest descriptor
      responses =
        [ CleanupRunDescriptorPresent
            (cleanupRunIdText runId)
            (cleanupDigestText descriptorDigest)
            runningBytes
        , CleanupRunDescriptorProgramPresent
            (cleanupRunIdText runId)
            (cleanupDigestText descriptorDigest)
            (cleanupProgramDescriptorBytes descriptor)
        ]
  (client, remainingResponses) <- authenticatedDescriptorClientFor responses
  recovered <-
    mustRightIO =<< observeDescriptorBoundCleanupRun client runId
  remainingResponses >>= (`shouldBe` [])
  executionContext <-
    mustRightIO
      (descriptorBoundCleanupNodeExecutionContext recovered plan)
  observations <- newIORef []
  outcome <-
    descriptorBoundCleanupNodeAction
      (recordDispatch observations recovered descriptorDigest)
      recovered
      executionContext
      plan
  outcome `shouldBe` CleanupNodeSucceeded
  observed <- readIORef observations
  case observed of
    [single] -> pure single
    _ -> do
      expectationFailure
        ( "expected one descriptor-bound semantic dispatch, observed "
            <> show (length observed)
        )
      fail "descriptor-bound semantic dispatch count mismatch"
 where
  recordDispatch
    :: IORef [DispatchObservation]
    -> DescriptorBoundCleanupRun
    -> CleanupDigest
    -> DescriptorBoundCleanupRun
    -> CleanupSurfaceWitness recoveredSurface
    -> CompiledDesiredAbsenceProgram recoveredSurface
    -> CleanupNodeExecutionContext
    -> CleanupNodePlan
    -> IO CleanupNodeOutcome
  recordDispatch observations recovered expectedDigest current recoveredWitness recoveredCompiled context plan = do
    let operation = operationTagForPlan recoveredCompiled plan
        operationText = case operation of
          Left detail -> detail
          Right tag -> tag
        observation =
          DispatchObservation
            { dispatchObservedSurface = cleanupSurfaceFromWitness recoveredWitness
            , dispatchObservedOperation = operationText
            , dispatchHandleMatchesCompiled =
                descriptorBoundCleanupRunId current
                  == compiledDesiredAbsenceRunId recoveredCompiled
                  && descriptorBoundCleanupRunGraphDigest current
                    == cleanupGraphDigest
                      (compiledDesiredAbsenceGraph recoveredCompiled)
            , dispatchHandleMatchesReadBack =
                descriptorBoundCleanupRunId current
                  == descriptorBoundCleanupRunId recovered
                  && descriptorBoundCleanupRunDescriptorDigest current
                    == descriptorBoundCleanupRunDescriptorDigest recovered
                  && descriptorBoundCleanupRunDescriptorDigest current
                    == expectedDigest
            , dispatchContextMatchesHandle =
                cleanupNodeExecutionRunId context
                  == descriptorBoundCleanupRunId current
                  && cleanupNodeExecutionGraphDigest context
                    == descriptorBoundCleanupRunGraphDigest current
            , dispatchContextMatchesPlan =
                cleanupNodeExecutionNodeId context == cleanupNodeId plan
            }
    operation `shouldBe` Right expectedOperation
    cleanupSurfaceFromWitness recoveredWitness `shouldBe` expectedSurface
    modifyIORef' observations (observation :)
    pure CleanupNodeSucceeded

runningAtOperation
  :: Text.Text
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either Text.Text (CleanupNodePlan, CleanupRun)
runningAtOperation expectedOperation compiled initialRun = do
  withPrimary <-
    firstShow
      ( recordPrimaryOutcome
          fixtureOwner
          (cleanupLeaseFence (cleanupRunLease initialRun))
          CleanupPrimarySucceeded
          initialRun
      )
  drive withPrimary (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
 where
  drive _ [] =
    Left ("compiled program lacks operation " <> expectedOperation)
  drive run (plan : remaining) = do
    operation <- operationTagForPlan compiled plan
    attempt <-
      firstShow
        (mkCleanupAttemptId ("restart-dispatch/" <> cleanupNodeIdText (cleanupNodeId plan)))
    running <-
      firstShow
        ( beginCleanupNode
            fixtureOwner
            (cleanupLeaseFence (cleanupRunLease run))
            (cleanupNodeId plan)
            attempt
            run
        )
    if operation == expectedOperation
      then Right (plan, running)
      else do
        completed <-
          firstShow
            ( completeCleanupNode
                fixtureOwner
                (cleanupLeaseFence (cleanupRunLease running))
                (cleanupNodeId plan)
                attempt
                CleanupNodeSucceeded
                running
            )
        drive completed remaining

operationTagForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either Text.Text Text.Text
operationTagForPlan compiled plan =
  case [ teardownOperationTag operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left "compiled program has no semantic operation for cleanup node"
    _ -> Left "compiled program has duplicate semantic operations for cleanup node"

data SurfaceCase where
  SurfaceCase
    :: CleanupSurfaceWitness surface
    -> CleanupSurface
    -> Maybe AwsScope
    -> SurfaceCase

surfaceCases :: [SurfaceCase]
surfaceCases =
  [ SurfaceCase LocalOnlySurface LocalOnly Nothing
  , SurfaceCase CascadeSurface Cascade (Just fixtureAwsScope)
  , SurfaceCase ExplicitPerRunSurface ExplicitPerRun (Just fixtureAwsScope)
  , SurfaceCase
      OperationalTeardownSurface
      OperationalTeardown
      (Just fixtureAwsScope)
  , SurfaceCase
      ExplicitLongLivedSurface
      ExplicitLongLived
      (Just fixtureAwsScope)
  , SurfaceCase
      TotalDecommissionSurface
      TotalDecommission
      (Just fixtureAwsScope)
  ]

descriptorFixture
  :: CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Either
       Text.Text
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
descriptorFixture witness runId foundation maybeAwsScope = do
  compiled <-
    firstShow
      (compileDesiredAbsenceGraph runId foundation maybeAwsScope witness)
  initialRun <-
    firstShow
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          fixtureOwner
          1
          1000
      )
  descriptor <-
    firstShow (captureCleanupProgramDescriptor compiled initialRun)
  Right (compiled, initialRun, descriptor)

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "descriptor-unit-run")

otherRunId :: CleanupRunId
otherRunId = mustRight (mkCleanupRunId "descriptor-unit-other-run")

localDispatchRunId :: CleanupRunId
localDispatchRunId = mustRight (mkCleanupRunId "descriptor-unit-local-restart")

cascadeDispatchRunId :: CleanupRunId
cascadeDispatchRunId = mustRight (mkCleanupRunId "descriptor-unit-cascade-restart")

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "descriptor-unit-authority")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "foundation/home"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

authenticatedDescriptorClientFor
  :: [CleanupRunDescriptorResponse]
  -> IO
       ( DescriptorBoundCleanupRunClient IO
       , IO [CleanupRunDescriptorResponse]
       )
authenticatedDescriptorClientFor responses = do
  queuedResponses <- newIORef responses
  endpoint <-
    mustRightIO
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    mustRightIO
      ( controlPlaneClientWithTransport
          descriptorClientMaximumResponseBytes
          endpoint
          (descriptorClientTransport queuedResponses)
      )
  pure
    ( descriptorBoundCleanupRunClient
        ( mkAuthenticatedClientTransport
            descriptorTransportBounds
            descriptorClientProviders
            rawClient
        )
    , readIORef queuedResponses
    )

descriptorClientTransport
  :: IORef [CleanupRunDescriptorResponse]
  -> Method
  -> [Header]
  -> String
  -> ByteString.ByteString
  -> IO (Either HttpBoundedError (Int, ByteString.ByteString))
descriptorClientTransport queuedResponses method _ url _ = do
  method `shouldBe` "POST"
  url
    `shouldBe` "http://lifecycle-authority:8600/v1/authority/cleanup-run"
  let dequeue queued = case queued of
        [] -> ([], Nothing)
        response : remaining -> (remaining, Just response)
  nextResponse <-
    atomicModifyIORef' queuedResponses dequeue
  case nextResponse of
    Nothing -> do
      expectationFailure "descriptor client issued an unexpected request"
      pure (Right (500, mempty))
    Just response -> do
      let endpointResult = CleanupRunEndpointDescriptorBound response
      pure
        ( Right
            ( replyStatusCode (cleanupRunEndpointStatus endpointResult)
            , cleanupRunEndpointBody endpointResult
            )
        )

descriptorClientMaximumResponseBytes :: Int
descriptorClientMaximumResponseBytes = 4 * 1024 * 1024

descriptorTransportBounds :: AuthenticatedTransportBounds
descriptorTransportBounds =
  mustRight
    ( mkAuthenticatedTransportBounds
        descriptorClientMaximumResponseBytes
        256
        (descriptorClientMaximumResponseBytes - 1024)
    )

descriptorClientProviders :: AuthenticatedClientProviders IO
descriptorClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure
          ( Right
              (localRequestSigningCapability descriptorRequestSigner)
          )
    , provideAuthenticatedClientScope = pure (Right descriptorAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right descriptorDeadline)
    , provideAuthenticatedClientNonce = pure (Right descriptorRequestNonce)
    }

descriptorRequestSigner :: RequestSigner
descriptorRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

descriptorRequestNonce :: RequestNonce
descriptorRequestNonce =
  mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

descriptorAuthorityScope :: AuthorityScope
descriptorAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

descriptorDeadline :: AuthorityTime
descriptorDeadline = authorityTimeFromMicros 2000

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  filterM (fmap (isInfixOf importNeedle) . readFile) paths

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else pure [path | takeExtension path == ".hs"]

firstShow :: (Show error) => Either error value -> Either Text.Text value
firstShow result = case result of
  Left err -> Left (Text.pack (show err))
  Right value -> Right value

mustRight :: (Show error) => Either error value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustRightIO :: (Show error) => Either error value -> IO value
mustRightIO result = case result of
  Left err -> do
    expectationFailure (show err)
    fail "invalid descriptor-bound cleanup fixture"
  Right value -> pure value
