{-# LANGUAGE OverloadedStrings #-}

module AwsSesLifecycle
  ( awsSesLifecycleSuite
  )
where

import Data.Either (isRight)
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (isInfixOf, isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.Infra.AwsEksTestStack
  ( awsEksCanonicalClusterName
  )
import Prodbox.Infra.AwsSesStack
  ( AwsSesPresenceInventory (..)
  , AwsSesResource (..)
  , AwsSesStackSnapshot (..)
  , awsSesPresenceInventoryComplete
  , awsSesTargetSelectionForSink
  , defaultAwsSesTargetSelection
  , destroySummaryFromStackRemove
  , parseAwsSesStackFromOutputs
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , TargetClusterSecretSink
  , mkLongLivedCheckpointAuthority
  , mkTargetClusterSecretSink
  )
import TestSupport

awsSesLifecycleSuite :: SuiteBuilder ()
awsSesLifecycleSuite = do
  describe "Sprint 4.79 the SES destroy reports what it observed" $ do
    it "says destroyed only when the stack entry was actually removed" $
      destroySummaryFromStackRemove (Right ()) `shouldBe` "destroyed"

    it "names the surviving stack entry when removal failed" $ do
      -- Before this sprint `pulumi stack rm`'s result was discarded with `_ <-`
      -- and followed by an unconditional `Right "destroyed"`, so a failed
      -- removal was reported as a completed destroy on the terminal node of the
      -- `nuke` decommission DAG.
      let summary =
            destroySummaryFromStackRemove
              (Left "pulumi stack rm exited with code 255")
      summary `shouldSatisfy` isInfixOf "NOT removed"
      summary `shouldSatisfy` isInfixOf "pulumi stack rm exited with code 255"
      summary `shouldNotBe` "destroyed"

    it "still reports the AWS resources destroyed, because they were" $
      -- The decision recorded rather than glossed: the destroy had already
      -- succeeded when the removal ran, so refusing here would fail a teardown
      -- that did remove every resource. What was wrong was the silence, not the
      -- success.
      destroySummaryFromStackRemove (Left "boom")
        `shouldSatisfy` isPrefixOf "destroyed"

  describe "Sprint 4.47 frozen pre-cutover SES counterexample" $ do
    it "records the superseded non-credential ordering without a production capability" $
      frozenAwsSesDesiredPresentStages
        `shouldBe` [ FrozenAwsSesStageReconcile
                   , FrozenAwsSesStageAwaitReady
                   ]

    it "preserves the historical fail-fast trace as test-only evidence" $ do
      successfulTrace <- newIORef []
      successful <-
        runFrozenAwsSesTransactionStagesWith $ \stage -> do
          modifyIORef' successfulTrace (++ [stage])
          pure (Right () :: Either String ())
      successful `shouldBe` Right ()
      readIORef successfulTrace `shouldReturn` frozenAwsSesDesiredPresentStages

      mapM_
        ( \failureDetail -> do
            failedTrace <- newIORef []
            failed <-
              runFrozenAwsSesTransactionStagesWith $ \stage -> do
                modifyIORef' failedTrace (++ [stage])
                pure $
                  if stage == FrozenAwsSesStageAwaitReady
                    then Left failureDetail
                    else Right ()
            failed `shouldBe` Left failureDetail
            readIORef failedTrace
              `shouldReturn` [FrozenAwsSesStageReconcile, FrozenAwsSesStageAwaitReady]
        )
        ( [ "semantic readiness timed out"
          , "semantic readiness Failed"
          , "semantic readiness Unobservable"
          ]
            :: [String]
        )

    it "requires every finite SES resource before readiness converges" $ do
      awsSesPresenceInventoryComplete
        AwsSesPresenceInventory
          { awsSesPresentResources =
              [ AwsSesReceiveRule
              , AwsSesCaptureBucket
              , AwsSesCaptureReadinessObject
              , AwsSesReceiveRuleSet
              ]
          }
        `shouldBe` True
      awsSesPresenceInventoryComplete
        AwsSesPresenceInventory
          { awsSesPresentResources =
              [ AwsSesCaptureBucket
              , AwsSesReceiveRuleSet
              ]
          }
        `shouldBe` False

    it "requires canonical region, MX, and capture-canary Pulumi outputs" $ do
      case parseAwsSesStackFromOutputs canonicalSesOutputs of
        Left err -> expectationFailure err
        Right snapshot -> do
          sesSnapshotAwsRegion snapshot `shouldBe` "us-east-1"
          sesSnapshotReceiveSubdomainMxPriority snapshot `shouldBe` 10
          sesSnapshotReceiveSubdomainMxTarget snapshot
            `shouldBe` "inbound-smtp.us-east-1.amazonaws.com"
          sesSnapshotCaptureReadinessKey snapshot
            `shouldBe` "inbound/.prodbox-readiness-capability-probe"
      parseAwsSesStackFromOutputs (Map.delete "capture_readiness_key" canonicalSesOutputs)
        `shouldBe` Left "aws-ses Pulumi outputs missing required field 'capture_readiness_key'"
      parseAwsSesStackFromOutputs
        (Map.insert "receive_subdomain_mx_target" "inbound-smtp.us-west-2.amazonaws.com" canonicalSesOutputs)
        `shouldBe` Left
          "aws-ses Pulumi output 'receive_subdomain_mx_target' is \"inbound-smtp.us-west-2.amazonaws.com\", expected \"inbound-smtp.us-east-1.amazonaws.com\""

    it "derives the exact home target registry from the retained authority" $
      awsSesTargetSelectionForSink testAuthority homeTarget
        `shouldBe` defaultAwsSesTargetSelection testAuthority

    it "accepts the canonical AWS target coordinate" $
      awsSesTargetSelectionForSink testAuthority awsTarget
        `shouldSatisfy` isRight

    it "rejects noncanonical target identities" $ do
      awsSesTargetSelectionForSink testAuthority otherTarget
        `shouldBe` Left
          "selected SES target identity is neither the retained home authority nor canonical AWS EKS"

    it "rejects secret-coordinate substitution for the canonical AWS target" $
      awsSesTargetSelectionForSink testAuthority substitutedAwsTarget
        `shouldBe` Left
          "selected SES AWS target must use the canonical SMTP secret coordinate"

-- Frozen evidence of the retired host-direct transaction shape. Keeping this
-- private to the test suite prevents it from becoming a production capability
-- while retaining the historical failure-order counterexample.
data FrozenAwsSesTransactionStage
  = FrozenAwsSesStageReconcile
  | FrozenAwsSesStageAwaitReady
  deriving (Eq, Show)

frozenAwsSesDesiredPresentStages :: [FrozenAwsSesTransactionStage]
frozenAwsSesDesiredPresentStages =
  [ FrozenAwsSesStageReconcile
  , FrozenAwsSesStageAwaitReady
  ]

runFrozenAwsSesTransactionStagesWith
  :: (Monad action)
  => (FrozenAwsSesTransactionStage -> action (Either failure ()))
  -> action (Either failure ())
runFrozenAwsSesTransactionStagesWith runStage =
  go frozenAwsSesDesiredPresentStages
 where
  go [] = pure (Right ())
  go (stage : remaining) = do
    result <- runStage stage
    case result of
      Left failure -> pure (Left failure)
      Right () -> go remaining

testAuthority :: LongLivedCheckpointAuthority
testAuthority =
  case mkLongLivedCheckpointAuthority
    "prodbox-home"
    "prodbox-state"
    "model-b"
    "prodbox" of
    Left err -> error (show err)
    Right authority -> authority

homeTarget :: TargetClusterSecretSink
homeTarget =
  targetSink "prodbox-home" "keycloak/smtp"

awsTarget :: TargetClusterSecretSink
awsTarget =
  targetSink
    (Text.pack awsEksCanonicalClusterName)
    "keycloak/smtp"

otherTarget :: TargetClusterSecretSink
otherTarget =
  targetSink "some-other-cluster" "keycloak/smtp"

substitutedAwsTarget :: TargetClusterSecretSink
substitutedAwsTarget =
  targetSink
    (Text.pack awsEksCanonicalClusterName)
    "somewhere/else"

targetSink :: Text.Text -> Text.Text -> TargetClusterSecretSink
targetSink identity path =
  case mkTargetClusterSecretSink identity "secret" path of
    Left err -> error (show err)
    Right target -> target

canonicalSesOutputs :: Map.Map Text.Text Text.Text
canonicalSesOutputs =
  Map.fromList
    [ ("backend_bucket", "prodbox-state")
    , ("aws_region", "us-east-1")
    , ("sending_domain", "test.resolvefintech.com")
    , ("receive_subdomain", "inbox.test.resolvefintech.com")
    , ("receive_subdomain_mx_fqdn", "inbox.test.resolvefintech.com.")
    , ("receive_subdomain_mx_priority", "10")
    , ("receive_subdomain_mx_target", "inbound-smtp.us-east-1.amazonaws.com")
    , ("receive_rule_set_name", "prodbox-receive-rule-set")
    , ("receive_rule_name", "prodbox-capture-all-mail")
    , ("capture_bucket_name", "prodbox-test-ses-capture")
    , ("capture_bucket_arn", "arn:aws:s3:::prodbox-test-ses-capture")
    , ("capture_bucket_key_prefix", "inbound/")
    , ("capture_readiness_key", "inbound/.prodbox-readiness-capability-probe")
    ]
