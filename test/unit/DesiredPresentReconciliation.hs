module DesiredPresentReconciliation
  ( desiredPresentReconciliationSuite
  )
where

import Control.Monad (forM_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Prodbox.Config.Basics (SealMode (..), UnencryptedBasics (..))
import Prodbox.Infra.AwsSesStack
  ( AwsSesPresenceProbe (..)
  , classifyAwsSesPresenceOutput
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( longLivedCheckpointAuthorityFromBasics
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( checkpointAuthorityClusterId
  , checkpointAuthorityGatewayEndpoint
  , checkpointAuthorityObjectBucket
  )
import Prodbox.Lifecycle.DesiredPresence
import Prodbox.Lifecycle.ResidueStatus
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (LongLived))
import Prodbox.Lifecycle.ResourceRegistry
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

desiredPresentReconciliationSuite :: SuiteBuilder ()
desiredPresentReconciliationSuite = do
  describe "Sprint 4.47 exhaustive desired-present planning" $ do
    it "covers every observable presence x checkpoint combination with explicit action data" $
      forM_ observableDecisionTable $ \(presence, checkpoint, expected) ->
        planDesiredPresence presence checkpoint `shouldBe` expected

    it "refuses every unobservable combination without discarding a second failure" $
      forM_ refusalDecisionTable $ \(presence, checkpoint, expected) ->
        planDesiredPresence presence checkpoint `shouldBe` expected

    it "only positive presence plus a valid checkpoint is converged" $ do
      desiredPresenceConverged (PresencePresent "inventory") (CheckpointValid "snapshot")
        `shouldBe` True
      forM_
        [ desiredPresenceConverged PresenceAbsent (CheckpointValid "snapshot")
        , desiredPresenceConverged (PresencePresent "inventory") CheckpointMissing
        , desiredPresenceConverged (PresencePresent "inventory") (CheckpointCorrupt corruptFixture)
        , desiredPresenceConverged
            (PresenceUnobservable presenceFailureFixture)
            (CheckpointValid "snapshot")
        , desiredPresenceConverged
            (PresencePresent "inventory")
            (CheckpointUnobservable checkpointObservationFailureFixture)
        ]
        (`shouldBe` False)

  describe "Sprint 4.47 desired-present effectful interpreter" $ do
    it "runs observe -> plan -> enact -> mandatory re-observe and returns external evidence" $ do
      events <- newIORef []
      presences <- newIORef [PresenceAbsent, PresencePresent "live"]
      checkpoints <- newIORef [CheckpointMissing, CheckpointValid "stored"]
      result <-
        reconcileDesiredPresence
          (fakeHooks events presences checkpoints (Right ()))
      result
        `shouldBe` Right
          DesiredPresenceRun
            { desiredPresenceInitialPresence = PresenceAbsent
            , desiredPresenceInitialCheckpoint = CheckpointMissing
            , desiredPresenceEnactedAction = CreateFromAbsentMissingCheckpoint
            , desiredPresenceFinalPresence = PresencePresent "live"
            , desiredPresenceFinalCheckpoint = CheckpointValid "stored"
            }
      readIORef events
        `shouldReturn` ["observe-presence", "observe-checkpoint", "enact", "observe-presence", "observe-checkpoint"]

    it "still re-observes both authorities after enactment reports failure" $ do
      events <- newIORef []
      presences <- newIORef [PresenceAbsent, PresencePresent "partial-live"]
      checkpoints <- newIORef [CheckpointMissing, CheckpointMissing]
      result <-
        reconcileDesiredPresence
          (fakeHooks events presences checkpoints (Left "provider failed"))
      result
        `shouldBe` Left
          ( DesiredPresenceEnactFailed
              CreateFromAbsentMissingCheckpoint
              "provider failed"
              (PresencePresent "partial-live")
              CheckpointMissing
          )
      readIORef events
        `shouldReturn` ["observe-presence", "observe-checkpoint", "enact", "observe-presence", "observe-checkpoint"]

    it "fails when successful enactment is not confirmed by re-observation" $ do
      events <- newIORef []
      presences <- newIORef [PresenceAbsent, PresenceAbsent]
      checkpoints <- newIORef [CheckpointMissing, CheckpointValid "stored"]
      result <-
        reconcileDesiredPresence
          (fakeHooks events presences checkpoints (Right ()))
      result
        `shouldBe` Left
          ( DesiredPresencePostconditionFailed
              CreateFromAbsentMissingCheckpoint
              PresenceAbsent
              (CheckpointValid "stored")
          )

    it "refuses before enactment when either initial authority is unobservable" $ do
      events <- newIORef []
      presences <- newIORef [PresenceUnobservable presenceFailureFixture]
      checkpoints <- newIORef [CheckpointMissing]
      result <-
        reconcileDesiredPresence
          (fakeHooks events presences checkpoints (Right ()))
      result
        `shouldBe` Left
          (DesiredPresencePlanFailed (PresenceObservationRefused presenceFailureFixture))
      readIORef events `shouldReturn` ["observe-presence", "observe-checkpoint"]

  describe "Sprint 4.47 aws-ses typed AWS presence classification" $ do
    it "classifies successful probes as positively present" $
      classifyAwsSesPresenceOutput
        AwsSesSmtpIamUserProbe
        (processOutput ExitSuccess "{\"User\":{\"UserName\":\"prodbox-ses-smtp\"}}" "")
        `shouldBe` PresencePresent ()

    it "keeps a successful but malformed or mismatched AWS response unobservable" $ do
      classifyAwsSesPresenceOutput
        AwsSesSmtpIamUserProbe
        (processOutput ExitSuccess "not-json" "")
        `shouldSatisfy` isPresenceUnobservable
      classifyAwsSesPresenceOutput
        AwsSesSmtpIamUserProbe
        (processOutput ExitSuccess "{\"User\":{\"UserName\":\"someone-else\"}}" "")
        `shouldSatisfy` isPresenceUnobservable

    it "classifies only each service's exact not-found error as absent" $ do
      forM_
        [
          ( AwsSesCaptureBucketProbe "capture"
          , "An error occurred (404) when calling the HeadBucket operation: Not Found"
          )
        , (AwsSesSmtpIamUserProbe, "An error occurred (NoSuchEntity) when calling the GetUser operation")
        ,
          ( AwsSesReceiveRuleSetProbe
          , "An error occurred (RuleSetDoesNotExist) when calling DescribeReceiptRuleSet"
          )
        , (AwsSesReceiveRuleProbe, "An error occurred (RuleDoesNotExist) when calling DescribeReceiptRule")
        ]
        $ \(probe, detail) ->
          classifyAwsSesPresenceOutput probe (processOutput (ExitFailure 255) "" detail)
            `shouldBe` PresenceAbsent

    it "keeps access denial, throttling, credential, and network failures unobservable" $ do
      forM_
        [ "An error occurred (AccessDenied) when calling the GetUser operation"
        , "An error occurred (ThrottlingException) when calling the GetUser operation"
        , "Unable to locate credentials"
        , "Could not connect to the endpoint URL"
        ]
        $ \detail ->
          classifyAwsSesPresenceOutput
            AwsSesSmtpIamUserProbe
            (processOutput (ExitFailure 255) "" detail)
            `shouldSatisfy` isPresenceUnobservable

  describe "Sprint 4.47 managed-resource desired-present registration" $ do
    it "registers exactly the canonical aws-ses ensure beside LongLived destroy ownership" $ do
      map resourceName desiredPresentManagedResources `shouldBe` ["aws-ses"]
      map resourceClass desiredPresentManagedResources `shouldBe` [LongLived]
      map resourceEnsureCommand desiredPresentManagedResources
        `shouldBe` [Just "prodbox aws stack aws-ses reconcile"]
      case resourceEnsurePresent awsSesPulumiResource of
        Nothing -> expectationFailure "aws-ses must register an ensure action"
        Just _ -> pure ()
      resourceDestroyCommand awsSesPulumiResource
        `shouldBe` "prodbox aws stack aws-ses destroy --yes"

    it "derives the retained checkpoint authority from Tier-0, not the selected substrate" $ do
      let basics =
            UnencryptedBasics
              { basicsClusterId = Text.pack "control-plane-a"
              , basicsVaultAddress = Text.pack "http://127.0.0.1:31820"
              , basicsSealMode = SealModeShamir
              , basicsParentRef = Nothing
              , basicsFormatVersion = 1
              }
      case longLivedCheckpointAuthorityFromBasics basics of
        Left err -> expectationFailure ("authority decode failed: " ++ show err)
        Right authority -> do
          checkpointAuthorityClusterId authority `shouldBe` Text.pack "control-plane-a"
          checkpointAuthorityGatewayEndpoint authority `shouldBe` Text.pack "http://127.0.0.1:30443"
          checkpointAuthorityObjectBucket authority `shouldBe` Text.pack "prodbox-state"

observableDecisionTable
  :: [(PresenceObservation String, CheckpointObservation String, DesiredPresencePlan String String)]
observableDecisionTable =
  [ (PresenceAbsent, CheckpointMissing, DesiredPresenceActionPlanned CreateFromAbsentMissingCheckpoint)
  ,
    ( PresenceAbsent
    , CheckpointValid "snapshot"
    , DesiredPresenceActionPlanned (CreateFromAbsentValidCheckpoint "snapshot")
    )
  ,
    ( PresenceAbsent
    , CheckpointCorrupt corruptFixture
    , DesiredPresenceActionPlanned (CreateFromAbsentCorruptCheckpoint corruptFixture)
    )
  ,
    ( PresencePresent "inventory"
    , CheckpointMissing
    , DesiredPresenceActionPlanned (ImportPresentMissingCheckpoint "inventory")
    )
  ,
    ( PresencePresent "inventory"
    , CheckpointValid "snapshot"
    , DesiredPresenceActionPlanned (ReconcilePresentValidCheckpoint "inventory" "snapshot")
    )
  ,
    ( PresencePresent "inventory"
    , CheckpointCorrupt corruptFixture
    , DesiredPresenceActionPlanned (RepairPresentCorruptCheckpoint "inventory" corruptFixture)
    )
  ]

refusalDecisionTable
  :: [(PresenceObservation String, CheckpointObservation String, DesiredPresencePlan String String)]
refusalDecisionTable =
  [
    ( PresenceUnobservable presenceFailureFixture
    , CheckpointMissing
    , DesiredPresencePlanningRefused (PresenceObservationRefused presenceFailureFixture)
    )
  ,
    ( PresenceUnobservable presenceFailureFixture
    , CheckpointValid "snapshot"
    , DesiredPresencePlanningRefused (PresenceObservationRefused presenceFailureFixture)
    )
  ,
    ( PresenceUnobservable presenceFailureFixture
    , CheckpointCorrupt corruptFixture
    , DesiredPresencePlanningRefused (PresenceObservationRefused presenceFailureFixture)
    )
  ,
    ( PresenceAbsent
    , CheckpointUnobservable checkpointObservationFailureFixture
    , DesiredPresencePlanningRefused
        (CheckpointObservationRefused checkpointObservationFailureFixture)
    )
  ,
    ( PresencePresent "inventory"
    , CheckpointUnobservable checkpointObservationFailureFixture
    , DesiredPresencePlanningRefused
        (CheckpointObservationRefused checkpointObservationFailureFixture)
    )
  ,
    ( PresenceUnobservable presenceFailureFixture
    , CheckpointUnobservable checkpointObservationFailureFixture
    , DesiredPresencePlanningRefused
        ( PresenceAndCheckpointObservationsRefused
            presenceFailureFixture
            checkpointObservationFailureFixture
        )
    )
  ]

fakeHooks
  :: IORef [String]
  -> IORef [PresenceObservation String]
  -> IORef [CheckpointObservation String]
  -> Either String ()
  -> DesiredPresenceHooks String String
fakeHooks events presences checkpoints enactResult =
  DesiredPresenceHooks
    { observeDesiredResourcePresence = do
        modifyIORef' events (++ ["observe-presence"])
        popObservation presences
    , observeDesiredResourceCheckpoint = do
        modifyIORef' events (++ ["observe-checkpoint"])
        popObservation checkpoints
    , enactDesiredPresenceAction = \_ -> do
        modifyIORef' events (++ ["enact"])
        pure enactResult
    }

popObservation :: IORef [a] -> IO a
popObservation ref = do
  values <- readIORef ref
  case values of
    [] -> error "desired-present fake observation exhausted"
    value : remaining -> do
      writeIORef ref remaining
      pure value

presenceFailureFixture :: ObservationFailure
presenceFailureFixture =
  ObservationFailure
    { observationFailureOperation = "aws inventory"
    , observationFailureDetail = "access denied"
    }

checkpointObservationFailureFixture :: ObservationFailure
checkpointObservationFailureFixture =
  ObservationFailure
    { observationFailureOperation = "checkpoint load"
    , observationFailureDetail = "network unavailable"
    }

corruptFixture :: CheckpointFailure
corruptFixture = CheckpointFailure {checkpointFailureDetail = "invalid JSON"}

processOutput :: ExitCode -> String -> String -> ProcessOutput
processOutput exitCode stdout stderr =
  ProcessOutput
    { processExitCode = exitCode
    , processStdout = stdout
    , processStderr = stderr
    }

isPresenceUnobservable :: PresenceObservation a -> Bool
isPresenceUnobservable observation = case observation of
  PresenceUnobservable _ -> True
  _ -> False
