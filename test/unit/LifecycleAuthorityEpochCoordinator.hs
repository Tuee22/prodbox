module LifecycleAuthorityEpochCoordinator (lifecycleAuthorityEpochCoordinatorSuite) where

import Control.Monad (unless)
import Data.IORef
import Data.Set qualified as Set
import EpochPromotionFixture
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochPromotionCoordinator
import Prodbox.Lifecycle.Authority.EpochPromotionObservation
import Prodbox.Lifecycle.Authority.EpochPromotionSchedule qualified as Schedule
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import TestSupport

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

context :: PromotionContext
context = PromotionContext 1 2 epochTopologyFixture (authorityTimeFromMicros 1000000)

preparedAggregate :: AuthorityAdmissionAggregate
preparedAggregate =
  applyEpochAggregateCommand
    importedFrozenEpochAggregate
    ( ApplyAuthorityMigration
        (PrepareReplacementEpoch (epochFixtureEpoch 1) (epochFixtureEpoch 2) epochTopologyFixture)
    )

data Fake = Fake
  { fakeAggregate :: IORef AuthorityAdmissionAggregate
  , fakePhysical :: IORef [PhysicalTransition]
  , fakeLostCommit :: IORef Bool
  , fakeTime :: IORef Word
  , fakeDrift :: IORef Bool
  , fakeObservations :: IORef Int
  , fakeSubmissions :: IORef Int
  }

newFake :: IO Fake
newFake =
  Fake
    <$> newIORef preparedAggregate
    <*> newIORef []
    <*> newIORef False
    <*> newIORef 100
    <*> newIORef False
    <*> newIORef 0
    <*> newIORef 0

boundary :: Fake -> PromotionBoundary IO String
boundary fake =
  PromotionBoundary
    { boundaryTime = Right . authorityTimeFromMicros . fromIntegral <$> readIORef (fakeTime fake)
    , boundaryObserve = do
        modifyIORef' (fakeObservations fake) (+ 1)
        aggregate <- readIORef (fakeAggregate fake)
        drift <- readIORef (fakeDrift fake)
        let promotion = case authorityAggregateMigration aggregate of
              AuthorityCleanInstall -> Nothing
              AuthorityMigrationControlled migration -> migrationEpochPromotion migration
            observed =
              observeEpochPromotion
                (authorityAggregateAuthenticationEpoch aggregate)
                (either (const Nothing) Just (activeAuthorityEpoch aggregate))
                promotion
        pure $ case observed of
          Left failure -> Left (show failure)
          Right snapshot -> Right (if drift then snapshot {observedRetainedEpoch = 99} else snapshot)
    , boundaryPhysical = \_ transition _ -> modifyIORef' (fakePhysical fake) (<> [transition]) >> pure (Right ())
    , boundarySubmit = \_ request -> do
        modifyIORef' (fakeSubmissions fake) (+ 1)
        aggregate <- readIORef (fakeAggregate fake)
        let (decision, next) = stepAuthorityAdmission aggregate (ApplyAuthorityMigration (ApplyPreparedEpochPromotion request))
        case decision of
          AuthorityMigrationDecided (MigrationAccepted _) -> do
            writeIORef (fakeAggregate fake) next
            lost <- readIORef (fakeLostCommit fake)
            if lost && promotionRequestAction request == CommitFrozenEpoch
              then writeIORef (fakeLostCommit fake) False >> pure (Left "lost commit reply")
              else pure (Right ())
          AuthorityMigrationDecided MigrationAlreadyApplied -> pure (Right ())
          other -> pure (Left (show other))
    }

lifecycleAuthorityEpochCoordinatorSuite :: SuiteBuilder ()
lifecycleAuthorityEpochCoordinatorSuite = describe "Sprint 6.5 staged epoch coordinator" $ do
  it "runs, resumes and retires with the recorded schedule and fences" coordinatorControls

coordinatorControls :: IO ()
coordinatorControls = do
  normal <- newFake
  result <- runPromotion (boundary normal) context CompletePromotion
  assert "complete promotion failed" (result == Right PromotionAdmissionObserved)
  effects <- readIORef (fakePhysical normal)
  let count = Set.size (epochTopologyBindings epochTopologyFixture)
      oldCount = Set.size (epochTopologyOldWriterBindings epochTopologyFixture)
  assert
    "physical stages do not cover exact topology"
    ( length (filter (== PreparePhysical) effects) == count
        && length (filter (== PromotePhysical) effects) == count
    )
  observations <- readIORef (fakeObservations normal)
  submissions <- readIORef (fakeSubmissions normal)
  let schedule =
        either
          (error . show)
          id
          (Schedule.promotionSchedule epochTopologyFixture CompletePromotion EpochPrepared)
  assert
    "prepared schedule differs from execution"
    ( Schedule.scheduleAuthorityObservations schedule == fromIntegral observations
        && Schedule.scheduleAuthoritySubmissions schedule == fromIntegral submissions
        && Schedule.schedulePhysicalActions schedule == fromIntegral (length effects)
    )
  assert
    "observation schedule omitted an expected boundary"
    (observations == 4 * count + 2 * oldCount + 5)
  assert
    "submission schedule omitted an expected request"
    (submissions == 2 * count + 2 * oldCount + 2)

  interrupted <- newFake
  writeIORef (fakeLostCommit interrupted) True
  lost <- runPromotion (boundary interrupted) context CompletePromotion
  assert
    "lost commit reply reported success"
    (lost == Left (PromotionBoundaryRefused "lost commit reply"))
  beforeResume <- readIORef (fakePhysical interrupted)
  observationsBeforeResume <- readIORef (fakeObservations interrupted)
  submissionsBeforeResume <- readIORef (fakeSubmissions interrupted)
  resumed <- runPromotion (boundary interrupted) context CompletePromotion
  assert "frozen promotion did not resume" (resumed == Right PromotionAdmissionObserved)
  afterResume <- readIORef (fakePhysical interrupted)
  observationsAfterResume <- readIORef (fakeObservations interrupted)
  submissionsAfterResume <- readIORef (fakeSubmissions interrupted)
  let frozenSchedule =
        either
          (error . show)
          id
          (Schedule.promotionSchedule epochTopologyFixture CompletePromotion EpochFrozen)
  assert
    "frozen resume schedule differs from execution"
    ( Schedule.scheduleAuthorityObservations frozenSchedule
        == fromIntegral (observationsAfterResume - observationsBeforeResume)
        && Schedule.scheduleAuthoritySubmissions frozenSchedule
          == fromIntegral (submissionsAfterResume - submissionsBeforeResume)
        && Schedule.schedulePhysicalActions frozenSchedule
          == fromIntegral (length afterResume - length beforeResume)
    )
  assert
    "resume repeated preparation"
    ( length (filter (== PreparePhysical) afterResume)
        == length (filter (== PreparePhysical) beforeResume)
    )

  rollback <- newFake
  retired <- runPromotion (boundary rollback) context RetirePreparation
  assert "precommit retirement failed" (retired == Right PreparationRetiredNeedsWriterRecovery)
  retiredEffects <- readIORef (fakePhysical rollback)
  retiredObservations <- readIORef (fakeObservations rollback)
  retiredSubmissions <- readIORef (fakeSubmissions rollback)
  let retireSchedule =
        either
          (error . show)
          id
          (Schedule.promotionSchedule epochTopologyFixture RetirePreparation EpochPrepared)
  assert
    "retirement schedule differs from execution"
    ( Schedule.scheduleAuthorityObservations retireSchedule == fromIntegral retiredObservations
        && Schedule.scheduleAuthoritySubmissions retireSchedule == fromIntegral retiredSubmissions
        && Schedule.schedulePhysicalActions retireSchedule == fromIntegral (length retiredEffects)
    )
  assert
    "retirement did not cover exact topology"
    (length retiredEffects == count && all (== RetirePhysical) retiredEffects)
  afterCommit <- runPromotion (boundary normal) context RetirePreparation
  assert "postcommit rollback was accepted" (afterCommit == Left PromotionForwardRecoveryRequired)

  drift <- newFake
  writeIORef (fakeDrift drift) True
  drifted <- runPromotion (boundary drift) context CompletePromotion
  assert "epoch drift was accepted" (drifted == Left PromotionContextMismatch)
  readIORef (fakePhysical drift) >>= assert "epoch drift reached physical effects" . null

  expired <- newFake
  writeIORef (fakeTime expired) 1000000
  elapsed <- runPromotion (boundary expired) context CompletePromotion
  assert "expired request proceeded" (elapsed == Left PromotionExpired)
  readIORef (fakePhysical expired) >>= assert "expired request reached physical effects" . null

  racing <- newFake
  let raceBoundary =
        (boundary racing)
          { boundaryPhysical = \_ _ _ -> do
              aggregate <- readIORef (fakeAggregate racing)
              let action = EpochPromotionRequest 2 epochTopologyFixtureDigest BeginPreparedEpochRollback
                  (_, changed) = stepAuthorityAdmission aggregate (ApplyAuthorityMigration (ApplyPreparedEpochPromotion action))
              writeIORef (fakeAggregate racing) changed
              pure (Right ())
          }
  raced <- runPromotion raceBoundary context CompletePromotion
  assert
    "phase change after physical effect was ignored"
    (raced == Left (PromotionPhaseChanged EpochPreparedRollback))

  delayed <- newFake
  let delayedBoundary =
        (boundary delayed)
          { boundaryPhysical = \_ _ _ -> writeIORef (fakeTime delayed) 1000000 >> pure (Right ())
          }
  late <- runPromotion delayedBoundary context CompletePromotion
  assert "deadline after physical effect was ignored" (late == Left PromotionExpired)
  aggregate <- readIORef (fakeAggregate delayed)
  assert "late effect changed Authority aggregate" (aggregate == preparedAggregate)
