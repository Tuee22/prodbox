{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Closed lifecycle boundary for the disposable filesystem half of a test
-- run.  The exact two intents are committed and independently read back
-- before the caller's first filesystem mutation.  Deletion remains
-- unauthorized until the matching cascade run has supplied exact terminal
-- local-cluster absence.
module Prodbox.Lifecycle.TestArtifactCleanup
  ( TestArtifactKind (..)
  , TestArtifactIntent
  , testArtifactIntentKind
  , testArtifactIntentPath
  , testArtifactIntentRunId
  , TestArtifactCleanupPlan
  , testArtifactCleanupPlanRunId
  , testArtifactCleanupPlanGraphDigest
  , testArtifactCleanupPlanRepoRoot
  , testArtifactCleanupPlanIntents
  , TestArtifactCleanupPlanError (..)
  , mkTestArtifactCleanupPlan
  , TestArtifactIntentJournal (..)
  , RegisteredTestArtifactCleanup
  , registeredTestArtifactCleanupPlan
  , TestArtifactRegistrationError (..)
  , registerTestArtifactCleanup
  , LocalClusterAbsent
  , localClusterAbsentFromCascadeComplete
  , localClusterAbsentRunId
  , localClusterAbsentGraphDigest
  , TestArtifactDeleteAttempt (..)
  , TestArtifactAbsenceObservation (..)
  , TestArtifactCleanupEffects (..)
  , TestArtifactPrimaryOutcome (..)
  , TestArtifactCleanupOutcome (..)
  , TestArtifactCleanupFailure (..)
  , TestArtifactCleanupResult (..)
  , testArtifactPrimaryOutcome
  , testArtifactCleanupOutcomes
  , testArtifactCleanupFailures
  , runWithTestArtifactCleanup
  , TestArtifactCleanupRegression
  , fixedTestArtifactCleanupRegression
  , testArtifactCleanupRegressionResponseLossResolved
  , testArtifactCleanupRegressionRegistrationRefused
  , testArtifactCleanupRegressionPositiveComplete
  , testArtifactCleanupRegressionAcceptedDeleteRefused
  , testArtifactCleanupRegressionMissingProofRefused
  , testArtifactCleanupRegressionWrongRunRefused
  , testArtifactCleanupRegressionWrongGraphRefused
  , testArtifactCleanupRegressionPrimaryFailurePreserved
  )
where

import Control.Exception
  ( SomeAsyncException
  , SomeException
  , displayException
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (forM)
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeCompleteEvidence
  , cascadeCompleteGraphDigest
  , cascadeCompleteRunId
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( withCascadeEvidenceFixtureForRunInternal
  , withFixedCascadeEvidenceFixtureInternal
  )
import System.FilePath
  ( isAbsolute
  , normalise
  , splitDirectories
  , takeFileName
  , (</>)
  )

data TestArtifactKind
  = TestArtifactGeneratedRunConfig
  | TestArtifactThisRunData
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Run-bound path.  Its constructor is private: raw paths must first pass
-- the exact generated-config or this-run data-root refinement.
data TestArtifactIntent = TestArtifactIntent
  { internalTestArtifactIntentKind :: !TestArtifactKind
  , internalTestArtifactIntentPath :: !FilePath
  , internalTestArtifactIntentRunId :: !CleanupRunId
  }
  deriving stock (Eq, Show)

testArtifactIntentKind :: TestArtifactIntent -> TestArtifactKind
testArtifactIntentKind = internalTestArtifactIntentKind

testArtifactIntentPath :: TestArtifactIntent -> FilePath
testArtifactIntentPath = internalTestArtifactIntentPath

testArtifactIntentRunId :: TestArtifactIntent -> CleanupRunId
testArtifactIntentRunId = internalTestArtifactIntentRunId

-- | Exactly the disposable generated config and the exact per-variant data
-- root for one lifecycle run.  There is no constructor for authored topology,
-- production data, or a long-lived resource.
data TestArtifactCleanupPlan = TestArtifactCleanupPlan
  { internalTestArtifactCleanupRunId :: !CleanupRunId
  , internalTestArtifactCleanupGraphDigest :: !CleanupDigest
  , internalTestArtifactCleanupRepoRoot :: !FilePath
  , internalTestArtifactCleanupIntents :: !(NonEmpty TestArtifactIntent)
  }
  deriving stock (Eq, Show)

testArtifactCleanupPlanRunId :: TestArtifactCleanupPlan -> CleanupRunId
testArtifactCleanupPlanRunId = internalTestArtifactCleanupRunId

testArtifactCleanupPlanGraphDigest :: TestArtifactCleanupPlan -> CleanupDigest
testArtifactCleanupPlanGraphDigest = internalTestArtifactCleanupGraphDigest

testArtifactCleanupPlanRepoRoot :: TestArtifactCleanupPlan -> FilePath
testArtifactCleanupPlanRepoRoot = internalTestArtifactCleanupRepoRoot

testArtifactCleanupPlanIntents
  :: TestArtifactCleanupPlan -> NonEmpty TestArtifactIntent
testArtifactCleanupPlanIntents = internalTestArtifactCleanupIntents

data TestArtifactCleanupPlanError
  = TestArtifactRepoRootNotAbsolute !FilePath
  | TestArtifactPathNotAbsolute !TestArtifactKind !FilePath
  | TestArtifactPathContainsParentTraversal !TestArtifactKind !FilePath
  | TestArtifactGeneratedConfigOutsideBuildRoot !FilePath
  | TestArtifactGeneratedConfigNameInvalid !FilePath
  | TestArtifactDataOutsideThisRunRoot !FilePath
  | TestArtifactPathsOverlap !FilePath
  deriving stock (Eq, Show)

mkTestArtifactCleanupPlan
  :: FilePath
  -> CleanupRunId
  -> CleanupDigest
  -> FilePath
  -> FilePath
  -> Either TestArtifactCleanupPlanError TestArtifactCleanupPlan
mkTestArtifactCleanupPlan repoRoot runId graphDigest generatedConfigPath testDataPath = do
  requireAbsoluteRoot repoRoot
  generated <-
    refineIntent
      TestArtifactGeneratedRunConfig
      generatedConfigPath
  testData <- refineIntent TestArtifactThisRunData testDataPath
  let normalizedRoot = normalise repoRoot
      normalizedBuildRoot = normalise (normalizedRoot </> ".build")
      normalizedTestDataRoot = normalise (normalizedRoot </> ".test-data")
      generatedPath = testArtifactIntentPath generated
      dataPath = testArtifactIntentPath testData
  if pathWithin normalizedBuildRoot generatedPath
    then Right ()
    else Left (TestArtifactGeneratedConfigOutsideBuildRoot generatedConfigPath)
  if takeFileName generatedPath == "prodbox.dhall"
    then Right ()
    else Left (TestArtifactGeneratedConfigNameInvalid generatedConfigPath)
  if strictDescendant normalizedTestDataRoot dataPath
    then Right ()
    else Left (TestArtifactDataOutsideThisRunRoot testDataPath)
  if generatedPath /= dataPath
    then Right ()
    else Left (TestArtifactPathsOverlap generatedPath)
  Right
    TestArtifactCleanupPlan
      { internalTestArtifactCleanupRunId = runId
      , internalTestArtifactCleanupGraphDigest = graphDigest
      , internalTestArtifactCleanupRepoRoot = normalizedRoot
      , internalTestArtifactCleanupIntents = generated :| [testData]
      }
 where
  requireAbsoluteRoot path
    | isAbsolute path && not (containsParentTraversal path) = Right ()
    | otherwise = Left (TestArtifactRepoRootNotAbsolute path)
  refineIntent kind path
    | not (isAbsolute path) = Left (TestArtifactPathNotAbsolute kind path)
    | containsParentTraversal path =
        Left (TestArtifactPathContainsParentTraversal kind path)
    | otherwise =
        Right
          TestArtifactIntent
            { internalTestArtifactIntentKind = kind
            , internalTestArtifactIntentPath = normalise path
            , internalTestArtifactIntentRunId = runId
            }

containsParentTraversal :: FilePath -> Bool
containsParentTraversal = elem ".." . splitDirectories

pathWithin :: FilePath -> FilePath -> Bool
pathWithin root path =
  splitDirectories (normalise root)
    `isPrefixOf` splitDirectories (normalise path)

strictDescendant :: FilePath -> FilePath -> Bool
strictDescendant root path = normalise root /= normalise path && pathWithin root path

-- | Durable intent boundary supplied by the owner.  A commit response is not
-- registration evidence: exact read-back of the same plan is mandatory.
data TestArtifactIntentJournal m = TestArtifactIntentJournal
  { commitTestArtifactIntents
      :: TestArtifactCleanupPlan -> m (Either Text ())
  , observeTestArtifactIntents
      :: CleanupRunId -> m (Either Text (Maybe TestArtifactCleanupPlan))
  }

data RegisteredTestArtifactCleanup = RegisteredTestArtifactCleanup
  { internalRegisteredTestArtifactCleanupPlan :: !TestArtifactCleanupPlan
  }

registeredTestArtifactCleanupPlan
  :: RegisteredTestArtifactCleanup -> TestArtifactCleanupPlan
registeredTestArtifactCleanupPlan = internalRegisteredTestArtifactCleanupPlan

data TestArtifactRegistrationError
  = TestArtifactIntentReadBackMissing !CleanupRunId !(Maybe Text)
  | TestArtifactIntentReadBackFailed !(Maybe Text) !Text
  | TestArtifactIntentReadBackMismatch
      !TestArtifactCleanupPlan
      !TestArtifactCleanupPlan
  deriving stock (Eq, Show)

-- | Commit and independently read back the exact intent set.  Synchronous
-- response loss is resolved by read-back.  Cancellation is rethrown only
-- after the ambiguous commit has been observed.
registerTestArtifactCleanup
  :: TestArtifactIntentJournal IO
  -> TestArtifactCleanupPlan
  -> IO (Either TestArtifactRegistrationError RegisteredTestArtifactCleanup)
registerTestArtifactCleanup journal plan =
  mask $ \restore -> do
    committed <- tryAny (restore (commitTestArtifactIntents journal plan))
    observed <-
      tryAny
        ( restore
            ( observeTestArtifactIntents
                journal
                (testArtifactCleanupPlanRunId plan)
            )
        )
    let resolved = resolveRegistration plan committed observed
    case firstAsyncException [exceptionFrom committed, exceptionFrom observed] of
      Just cancellation -> throwIO cancellation
      Nothing -> pure resolved

resolveRegistration
  :: TestArtifactCleanupPlan
  -> Either SomeException (Either Text ())
  -> Either
       SomeException
       (Either Text (Maybe TestArtifactCleanupPlan))
  -> Either TestArtifactRegistrationError RegisteredTestArtifactCleanup
resolveRegistration expected committed observed =
  case observed of
    Right (Right (Just actual))
      | actual == expected ->
          Right
            RegisteredTestArtifactCleanup
              { internalRegisteredTestArtifactCleanupPlan = actual
              }
      | otherwise ->
          Left (TestArtifactIntentReadBackMismatch expected actual)
    Right (Right Nothing) ->
      Left
        ( TestArtifactIntentReadBackMissing
            (testArtifactCleanupPlanRunId expected)
            (attemptFailure committed)
        )
    Right (Left detail) ->
      Left
        (TestArtifactIntentReadBackFailed (attemptFailure committed) detail)
    Left exception ->
      Left
        ( TestArtifactIntentReadBackFailed
            (attemptFailure committed)
            (exceptionText exception)
        )

attemptFailure
  :: Either SomeException (Either Text value) -> Maybe Text
attemptFailure attempted = case attempted of
  Left exception -> Just (exceptionText exception)
  Right (Left detail) -> Just detail
  Right (Right _) -> Nothing

-- | Opaque exact local-absence proof.  It can be projected only from the
-- lifecycle cascade completion evidence that already binds post-uninstall
-- absence to the same run and graph.
data LocalClusterAbsent = LocalClusterAbsent
  { internalLocalClusterAbsentEvidence :: !CascadeCompleteEvidence
  }
  deriving stock (Eq, Show)

localClusterAbsentFromCascadeComplete
  :: CascadeCompleteEvidence -> LocalClusterAbsent
localClusterAbsentFromCascadeComplete evidence =
  LocalClusterAbsent
    { internalLocalClusterAbsentEvidence = evidence
    }

localClusterAbsentRunId :: LocalClusterAbsent -> CleanupRunId
localClusterAbsentRunId =
  cascadeCompleteRunId . internalLocalClusterAbsentEvidence

localClusterAbsentGraphDigest :: LocalClusterAbsent -> CleanupDigest
localClusterAbsentGraphDigest =
  cascadeCompleteGraphDigest . internalLocalClusterAbsentEvidence

data TestArtifactDeleteAttempt
  = TestArtifactDeleteAccepted
  | TestArtifactDeleteRejected !Text
  | TestArtifactDeleteUnobservable !Text
  | TestArtifactDeleteThrew !Text
  deriving stock (Eq, Show)

data TestArtifactAbsenceObservation
  = TestArtifactObservedAbsent
  | TestArtifactObservedPresent
  | TestArtifactAbsenceUnobservable !Text
  | TestArtifactAbsenceObservationThrew !Text
  deriving stock (Eq, Show)

-- | Mutation and read-back are separate.  An accepted delete is never
-- interpreted as absence, and both receive the unforgeable local proof.
data TestArtifactCleanupEffects m = TestArtifactCleanupEffects
  { observeLocalClusterAbsent
      :: RegisteredTestArtifactCleanup
      -> m (Either Text (Maybe LocalClusterAbsent))
  , attemptTestArtifactDelete
      :: LocalClusterAbsent
      -> TestArtifactIntent
      -> m TestArtifactDeleteAttempt
  , readBackTestArtifactAbsence
      :: LocalClusterAbsent
      -> TestArtifactIntent
      -> m TestArtifactAbsenceObservation
  }

data TestArtifactPrimaryOutcome failure value
  = TestArtifactPrimarySucceeded !value
  | TestArtifactPrimaryFailed !failure
  | TestArtifactPrimaryThrew !Text
  deriving stock (Eq, Show)

data TestArtifactCleanupOutcome = TestArtifactCleanupOutcome
  { testArtifactCleanupIntent :: !TestArtifactIntent
  , testArtifactCleanupDeleteAttempt :: !(Maybe TestArtifactDeleteAttempt)
  , testArtifactCleanupAbsenceObservation
      :: !(Maybe TestArtifactAbsenceObservation)
  }
  deriving stock (Eq, Show)

data TestArtifactCleanupFailure
  = TestArtifactLocalAbsenceReadBackFailed !Text
  | TestArtifactLocalAbsenceMissing
  | TestArtifactLocalAbsenceRunMismatch !CleanupRunId !CleanupRunId
  | TestArtifactLocalAbsenceGraphMismatch !CleanupDigest !CleanupDigest
  | TestArtifactAbsenceNotConfirmed !TestArtifactCleanupOutcome
  deriving stock (Eq, Show)

data TestArtifactCleanupResult failure value
  = TestArtifactCleanupComplete
      !(TestArtifactPrimaryOutcome failure value)
      !(NonEmpty TestArtifactCleanupOutcome)
  | TestArtifactCleanupIncomplete
      !(TestArtifactPrimaryOutcome failure value)
      !(NonEmpty TestArtifactCleanupOutcome)
      !(NonEmpty TestArtifactCleanupFailure)
  deriving stock (Eq, Show)

testArtifactPrimaryOutcome
  :: TestArtifactCleanupResult failure value
  -> TestArtifactPrimaryOutcome failure value
testArtifactPrimaryOutcome result = case result of
  TestArtifactCleanupComplete primary _ -> primary
  TestArtifactCleanupIncomplete primary _ _ -> primary

testArtifactCleanupOutcomes
  :: TestArtifactCleanupResult failure value
  -> NonEmpty TestArtifactCleanupOutcome
testArtifactCleanupOutcomes result = case result of
  TestArtifactCleanupComplete _ outcomes -> outcomes
  TestArtifactCleanupIncomplete _ outcomes _ -> outcomes

testArtifactCleanupFailures
  :: TestArtifactCleanupResult failure value
  -> [TestArtifactCleanupFailure]
testArtifactCleanupFailures result = case result of
  TestArtifactCleanupComplete {} -> []
  TestArtifactCleanupIncomplete _ _ failures -> NonEmpty.toList failures

-- | Register before admitting the primary action, then require exact terminal
-- local absence before either artifact delete.  Every artifact is attempted
-- and read back independently.  Synchronous exceptions become typed outcome
-- data; asynchronous exceptions are delayed until all authorized cleanup
-- attempts and read-backs have run, then rethrown unchanged.
runWithTestArtifactCleanup
  :: TestArtifactIntentJournal IO
  -> TestArtifactCleanupEffects IO
  -> TestArtifactCleanupPlan
  -> IO (Either failure value)
  -> IO
       ( Either
           TestArtifactRegistrationError
           (TestArtifactCleanupResult failure value)
       )
runWithTestArtifactCleanup journal effects plan primary =
  mask $ \restore -> do
    registered <- registerTestArtifactCleanup journal plan
    case registered of
      Left err -> pure (Left err)
      Right exact -> do
        primaryResult <- tryAny (restore primary)
        absenceResult <-
          tryAny (restore (observeLocalClusterAbsent effects exact))
        (outcomes, cleanupFailures, cleanupExceptions) <-
          case resolveLocalAbsence plan absenceResult of
            Left proofFailure ->
              pure
                ( blockedOutcomes plan
                , [proofFailure]
                , maybeToListException absenceResult
                )
            Right proof -> do
              attempted <-
                forM
                  (NonEmpty.toList (testArtifactCleanupPlanIntents plan))
                  (runOneArtifact restore effects proof)
              let rawOutcomes = artifactAttemptOutcome <$> attempted
              pure
                ( NonEmpty.fromList rawOutcomes
                , mapMaybe outcomeFailure rawOutcomes
                , concatMap artifactAttemptExceptions attempted
                )
        let primaryOutcome = classifyPrimary primaryResult
            cancellations =
              exceptionFrom primaryResult
                : exceptionFrom absenceResult
                : cleanupExceptions
        case firstAsyncException cancellations of
          Just cancellation -> throwIO cancellation
          Nothing ->
            pure (Right (classifyCleanupResult primaryOutcome outcomes cleanupFailures))

-- | Fixed package-owned regression result.  It preserves positive and hostile
-- coverage for the cleanup boundary without exporting a cascade proof, a
-- proof callback, or a caller-configurable evidence minter to unit clients.
data TestArtifactCleanupRegression = TestArtifactCleanupRegression
  { testArtifactCleanupRegressionResponseLossResolved :: !Bool
  , testArtifactCleanupRegressionRegistrationRefused :: !Bool
  , testArtifactCleanupRegressionPositiveComplete :: !Bool
  , testArtifactCleanupRegressionAcceptedDeleteRefused :: !Bool
  , testArtifactCleanupRegressionMissingProofRefused :: !Bool
  , testArtifactCleanupRegressionWrongRunRefused :: !Bool
  , testArtifactCleanupRegressionWrongGraphRefused :: !Bool
  , testArtifactCleanupRegressionPrimaryFailurePreserved :: !Bool
  }

fixedTestArtifactCleanupRegression
  :: IO (Either Text TestArtifactCleanupRegression)
fixedTestArtifactCleanupRegression =
  case withFixedCascadeEvidenceFixtureInternal
    ( \_ _ _ _ completion ->
        withCascadeEvidenceFixtureForRunInternal
          "cleanup-run/test-artifact-other"
          ( \_ _ _ _ otherCompletion ->
              runFixedTestArtifactCleanupRegression completion otherCompletion
          )
    ) of
    Left err -> pure (Left err)
    Right (Left err) -> pure (Left err)
    Right (Right action) -> action

runFixedTestArtifactCleanupRegression
  :: CascadeCompleteEvidence
  -> CascadeCompleteEvidence
  -> IO (Either Text TestArtifactCleanupRegression)
runFixedTestArtifactCleanupRegression completion otherCompletion =
  case fixedPlans of
    Left err -> pure (Left err)
    Right (plan, wrongGraphPlan) -> do
      positive <- runPositive plan completion
      registrationRefused <- runRegistrationRefusal plan
      acceptedDeleteRefused <- runAcceptedDeleteRefusal plan completion
      missingProofRefused <- runMissingProofRefusal plan
      wrongRunRefused <- runWrongProofRefusal plan otherCompletion isRunMismatch
      wrongGraphRefused <-
        runWrongProofRefusal wrongGraphPlan completion isGraphMismatch
      primaryFailurePreserved <- runPrimaryFailure plan completion
      pure
        ( Right
            TestArtifactCleanupRegression
              { testArtifactCleanupRegressionResponseLossResolved =
                  fixedPositiveResponseLoss positive
              , testArtifactCleanupRegressionRegistrationRefused =
                  registrationRefused
              , testArtifactCleanupRegressionPositiveComplete =
                  fixedPositiveComplete positive
              , testArtifactCleanupRegressionAcceptedDeleteRefused =
                  acceptedDeleteRefused
              , testArtifactCleanupRegressionMissingProofRefused =
                  missingProofRefused
              , testArtifactCleanupRegressionWrongRunRefused =
                  wrongRunRefused
              , testArtifactCleanupRegressionWrongGraphRefused =
                  wrongGraphRefused
              , testArtifactCleanupRegressionPrimaryFailurePreserved =
                  primaryFailurePreserved
              }
        )
 where
  fixedPlans = do
    plan <- fixedPlanFor "/tmp/prodbox-test-artifact-fixed" completion
    wrongGraphPlan <-
      mapCleanupLeft
        (Text.pack . show)
        ( mkTestArtifactCleanupPlan
            "/tmp/prodbox-test-artifact-fixed-wrong-graph"
            (cascadeCompleteRunId completion)
            (cascadeCompleteGraphDigest otherCompletion)
            "/tmp/prodbox-test-artifact-fixed-wrong-graph/.build/prodbox.dhall"
            "/tmp/prodbox-test-artifact-fixed-wrong-graph/.test-data/suite/case"
        )
    Right (plan, wrongGraphPlan)

data FixedPositiveCleanup = FixedPositiveCleanup
  { fixedPositiveResponseLoss :: !Bool
  , fixedPositiveComplete :: !Bool
  }

runPositive
  :: TestArtifactCleanupPlan
  -> CascadeCompleteEvidence
  -> IO FixedPositiveCleanup
runPositive plan completion = do
  stored <- newIORef Nothing
  committed <- newIORef False
  observed <- newIORef False
  deletes <- newIORef (0 :: Int)
  readBacks <- newIORef (0 :: Int)
  result <-
    runWithTestArtifactCleanup
      TestArtifactIntentJournal
        { commitTestArtifactIntents = \candidate -> do
            writeIORef committed True
            writeIORef stored (Just candidate)
            pure (Left "commit response lost")
        , observeTestArtifactIntents = \_ -> do
            writeIORef observed True
            Right <$> readIORef stored
        }
      TestArtifactCleanupEffects
        { observeLocalClusterAbsent = \_ ->
            pure (Right (Just (localClusterAbsentFromCascadeComplete completion)))
        , attemptTestArtifactDelete = \_ _ -> do
            modifyIORef' deletes (+ 1)
            pure TestArtifactDeleteAccepted
        , readBackTestArtifactAbsence = \_ _ -> do
            modifyIORef' readBacks (+ 1)
            pure TestArtifactObservedAbsent
        }
      plan
      (pure (Right (17 :: Int) :: Either Text Int))
  committedValue <- readIORef committed
  observedValue <- readIORef observed
  deleteCount <- readIORef deletes
  readBackCount <- readIORef readBacks
  pure
    FixedPositiveCleanup
      { fixedPositiveResponseLoss = committedValue && observedValue
      , fixedPositiveComplete = case result of
          Right cleanup ->
            null (testArtifactCleanupFailures cleanup)
              && testArtifactPrimaryOutcome cleanup
                == TestArtifactPrimarySucceeded 17
              && deleteCount == 2
              && readBackCount == 2
          Left _ -> False
      }

runRegistrationRefusal :: TestArtifactCleanupPlan -> IO Bool
runRegistrationRefusal plan = do
  bodyRan <- newIORef False
  result <-
    runWithTestArtifactCleanup
      TestArtifactIntentJournal
        { commitTestArtifactIntents = const (pure (Right ()))
        , observeTestArtifactIntents = const (pure (Right Nothing))
        }
      fixedUnusedEffects
      plan
      (writeIORef bodyRan True >> pure (Right () :: Either Text ()))
  ran <- readIORef bodyRan
  pure $ case result of
    Left TestArtifactIntentReadBackMissing {} -> not ran
    _ -> False

runAcceptedDeleteRefusal
  :: TestArtifactCleanupPlan
  -> CascadeCompleteEvidence
  -> IO Bool
runAcceptedDeleteRefusal plan completion = do
  result <-
    runWithTestArtifactCleanup
      (fixedExactJournal plan)
      ( fixedEffects
          (Right (Just (localClusterAbsentFromCascadeComplete completion)))
          (const (pure TestArtifactDeleteAccepted))
          (const (pure TestArtifactObservedPresent))
      )
      plan
      (pure (Right () :: Either Text ()))
  pure $ case result of
    Right cleanup -> length (testArtifactCleanupFailures cleanup) == 2
    Left _ -> False

runMissingProofRefusal :: TestArtifactCleanupPlan -> IO Bool
runMissingProofRefusal plan = do
  effectsRan <- newIORef False
  result <-
    runWithTestArtifactCleanup
      (fixedExactJournal plan)
      TestArtifactCleanupEffects
        { observeLocalClusterAbsent = const (pure (Right Nothing))
        , attemptTestArtifactDelete = \_ _ ->
            writeIORef effectsRan True >> pure TestArtifactDeleteAccepted
        , readBackTestArtifactAbsence = \_ _ ->
            writeIORef effectsRan True >> pure TestArtifactObservedAbsent
        }
      plan
      (pure (Right () :: Either Text ()))
  ran <- readIORef effectsRan
  pure $ case result of
    Right cleanup ->
      not ran
        && any isMissingFailure (testArtifactCleanupFailures cleanup)
    Left _ -> False

runWrongProofRefusal
  :: TestArtifactCleanupPlan
  -> CascadeCompleteEvidence
  -> (TestArtifactCleanupFailure -> Bool)
  -> IO Bool
runWrongProofRefusal plan completion expected = do
  effectsRan <- newIORef False
  result <-
    runWithTestArtifactCleanup
      (fixedExactJournal plan)
      TestArtifactCleanupEffects
        { observeLocalClusterAbsent =
            const . pure . Right . Just $
              localClusterAbsentFromCascadeComplete completion
        , attemptTestArtifactDelete = \_ _ ->
            writeIORef effectsRan True >> pure TestArtifactDeleteAccepted
        , readBackTestArtifactAbsence = \_ _ ->
            writeIORef effectsRan True >> pure TestArtifactObservedAbsent
        }
      plan
      (pure (Right () :: Either Text ()))
  ran <- readIORef effectsRan
  pure $ case result of
    Right cleanup ->
      not ran && any expected (testArtifactCleanupFailures cleanup)
    Left _ -> False

runPrimaryFailure
  :: TestArtifactCleanupPlan
  -> CascadeCompleteEvidence
  -> IO Bool
runPrimaryFailure plan completion = do
  result <-
    runWithTestArtifactCleanup
      (fixedExactJournal plan)
      ( fixedEffects
          (Right (Just (localClusterAbsentFromCascadeComplete completion)))
          (const (pure TestArtifactDeleteAccepted))
          (const (pure TestArtifactObservedAbsent))
      )
      plan
      (pure (Left "primary-refused" :: Either Text Int))
  pure $ case result of
    Right cleanup ->
      null (testArtifactCleanupFailures cleanup)
        && testArtifactPrimaryOutcome cleanup
          == TestArtifactPrimaryFailed "primary-refused"
    Left _ -> False

fixedPlanFor
  :: FilePath
  -> CascadeCompleteEvidence
  -> Either Text TestArtifactCleanupPlan
fixedPlanFor root completion =
  mapCleanupLeft (Text.pack . show) $ do
    mkTestArtifactCleanupPlan
      root
      (cascadeCompleteRunId completion)
      (cascadeCompleteGraphDigest completion)
      (root </> ".build" </> "prodbox.dhall")
      (root </> ".test-data" </> "suite" </> "case")

mapCleanupLeft :: (left -> other) -> Either left value -> Either other value
mapCleanupLeft transform result = case result of
  Left err -> Left (transform err)
  Right value -> Right value

fixedExactJournal
  :: TestArtifactCleanupPlan -> TestArtifactIntentJournal IO
fixedExactJournal plan =
  TestArtifactIntentJournal
    { commitTestArtifactIntents = const (pure (Right ()))
    , observeTestArtifactIntents = const (pure (Right (Just plan)))
    }

fixedUnusedEffects :: TestArtifactCleanupEffects IO
fixedUnusedEffects =
  fixedEffects
    (Left "unused local-absence observer")
    (const (pure (TestArtifactDeleteRejected "unexpected delete")))
    (const (pure (TestArtifactAbsenceUnobservable "unexpected read-back")))

fixedEffects
  :: Either Text (Maybe LocalClusterAbsent)
  -> (TestArtifactIntent -> IO TestArtifactDeleteAttempt)
  -> (TestArtifactIntent -> IO TestArtifactAbsenceObservation)
  -> TestArtifactCleanupEffects IO
fixedEffects absence attempt observe =
  TestArtifactCleanupEffects
    { observeLocalClusterAbsent = const (pure absence)
    , attemptTestArtifactDelete = \_ -> attempt
    , readBackTestArtifactAbsence = \_ -> observe
    }

isMissingFailure :: TestArtifactCleanupFailure -> Bool
isMissingFailure failure = case failure of
  TestArtifactLocalAbsenceMissing -> True
  _ -> False

isRunMismatch :: TestArtifactCleanupFailure -> Bool
isRunMismatch failure = case failure of
  TestArtifactLocalAbsenceRunMismatch {} -> True
  _ -> False

isGraphMismatch :: TestArtifactCleanupFailure -> Bool
isGraphMismatch failure = case failure of
  TestArtifactLocalAbsenceGraphMismatch {} -> True
  _ -> False

classifyCleanupResult
  :: TestArtifactPrimaryOutcome failure value
  -> NonEmpty TestArtifactCleanupOutcome
  -> [TestArtifactCleanupFailure]
  -> TestArtifactCleanupResult failure value
classifyCleanupResult primary outcomes failures = case failures of
  [] -> TestArtifactCleanupComplete primary outcomes
  firstFailure : remainingFailures ->
    TestArtifactCleanupIncomplete
      primary
      outcomes
      (firstFailure :| remainingFailures)

resolveLocalAbsence
  :: TestArtifactCleanupPlan
  -> Either SomeException (Either Text (Maybe LocalClusterAbsent))
  -> Either TestArtifactCleanupFailure LocalClusterAbsent
resolveLocalAbsence plan result = case result of
  Left exception ->
    Left (TestArtifactLocalAbsenceReadBackFailed (exceptionText exception))
  Right (Left detail) -> Left (TestArtifactLocalAbsenceReadBackFailed detail)
  Right (Right Nothing) -> Left TestArtifactLocalAbsenceMissing
  Right (Right (Just proof))
    | localClusterAbsentRunId proof /= expectedRunId ->
        Left
          ( TestArtifactLocalAbsenceRunMismatch
              expectedRunId
              (localClusterAbsentRunId proof)
          )
    | localClusterAbsentGraphDigest proof /= expectedGraphDigest ->
        Left
          ( TestArtifactLocalAbsenceGraphMismatch
              expectedGraphDigest
              (localClusterAbsentGraphDigest proof)
          )
    | otherwise -> Right proof
 where
  expectedRunId = testArtifactCleanupPlanRunId plan
  expectedGraphDigest = testArtifactCleanupPlanGraphDigest plan

data ArtifactAttempt = ArtifactAttempt
  { artifactAttemptOutcome :: !TestArtifactCleanupOutcome
  , artifactAttemptExceptions :: ![Maybe SomeException]
  }

runOneArtifact
  :: (forall result. IO result -> IO result)
  -> TestArtifactCleanupEffects IO
  -> LocalClusterAbsent
  -> TestArtifactIntent
  -> IO ArtifactAttempt
runOneArtifact restore effects proof intent = do
  attempted <-
    tryAny (restore (attemptTestArtifactDelete effects proof intent))
  observed <-
    tryAny (restore (readBackTestArtifactAbsence effects proof intent))
  pure
    ArtifactAttempt
      { artifactAttemptOutcome =
          TestArtifactCleanupOutcome
            { testArtifactCleanupIntent = intent
            , testArtifactCleanupDeleteAttempt =
                Just (either (TestArtifactDeleteThrew . exceptionText) id attempted)
            , testArtifactCleanupAbsenceObservation =
                Just
                  ( either
                      (TestArtifactAbsenceObservationThrew . exceptionText)
                      id
                      observed
                  )
            }
      , artifactAttemptExceptions =
          [exceptionFrom attempted, exceptionFrom observed]
      }

blockedOutcomes
  :: TestArtifactCleanupPlan -> NonEmpty TestArtifactCleanupOutcome
blockedOutcomes plan =
  fmap
    ( \intent ->
        TestArtifactCleanupOutcome
          { testArtifactCleanupIntent = intent
          , testArtifactCleanupDeleteAttempt = Nothing
          , testArtifactCleanupAbsenceObservation = Nothing
          }
    )
    (testArtifactCleanupPlanIntents plan)

outcomeFailure
  :: TestArtifactCleanupOutcome -> Maybe TestArtifactCleanupFailure
outcomeFailure outcome =
  case testArtifactCleanupAbsenceObservation outcome of
    Just TestArtifactObservedAbsent -> Nothing
    _ -> Just (TestArtifactAbsenceNotConfirmed outcome)

classifyPrimary
  :: Either SomeException (Either failure value)
  -> TestArtifactPrimaryOutcome failure value
classifyPrimary result = case result of
  Left exception -> TestArtifactPrimaryThrew (exceptionText exception)
  Right (Left failure) -> TestArtifactPrimaryFailed failure
  Right (Right value) -> TestArtifactPrimarySucceeded value

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

exceptionText :: SomeException -> Text
exceptionText = Text.pack . displayException

exceptionFrom :: Either SomeException value -> Maybe SomeException
exceptionFrom result = case result of
  Left exception -> Just exception
  Right _ -> Nothing

maybeToListException
  :: Either SomeException value -> [Maybe SomeException]
maybeToListException result = [exceptionFrom result]

firstAsyncException :: [Maybe SomeException] -> Maybe SomeException
firstAsyncException = listToMaybe . mapMaybe onlyAsync
 where
  onlyAsync candidate = case candidate of
    Just exception -> case fromException exception :: Maybe SomeAsyncException of
      Just _ -> Just exception
      Nothing -> Nothing
    Nothing -> Nothing
