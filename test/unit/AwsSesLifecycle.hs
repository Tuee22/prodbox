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
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.Infra.AwsEksTestStack
  ( awsEksCanonicalClusterName
  )
import Prodbox.Infra.AwsSesStack
  ( AwsSesPresenceInventory (..)
  , AwsSesResource (..)
  , AwsSesStackSnapshot (..)
  , AwsSesTransactionStage (..)
  , awsSesDesiredPresentStages
  , awsSesPresenceInventoryComplete
  , awsSesTargetSelectionForSink
  , defaultAwsSesTargetSelection
  , parseAwsSesStackFromOutputs
  , runAwsSesTransactionStagesWith
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , TargetClusterSecretSink
  , mkLongLivedCheckpointAuthority
  , mkTargetClusterSecretSink
  )
import TestSupport

awsSesLifecycleSuite :: SuiteBuilder ()
awsSesLifecycleSuite =
  describe "Sprint 4.47 production SES transaction" $ do
    it "orders reconcile, semantic readiness, then fenced SMTP materialization" $
      awsSesDesiredPresentStages
        `shouldBe` [ AwsSesStageReconcile
                   , AwsSesStageAwaitReady
                   , AwsSesStageRepairAndMaterializeSmtp
                   ]

    it "runs SMTP materialization only after the production await stage succeeds" $ do
      successfulTrace <- newIORef []
      successful <-
        runAwsSesTransactionStagesWith $ \stage -> do
          modifyIORef' successfulTrace (++ [stage])
          pure (Right () :: Either String ())
      successful `shouldBe` Right ()
      readIORef successfulTrace `shouldReturn` awsSesDesiredPresentStages

      mapM_
        ( \failureDetail -> do
            failedTrace <- newIORef []
            failed <-
              runAwsSesTransactionStagesWith $ \stage -> do
                modifyIORef' failedTrace (++ [stage])
                pure $
                  if stage == AwsSesStageAwaitReady
                    then Left failureDetail
                    else Right ()
            failed `shouldBe` Left failureDetail
            readIORef failedTrace
              `shouldReturn` [AwsSesStageReconcile, AwsSesStageAwaitReady]
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
              , AwsSesSmtpIamUser
              , AwsSesReceiveRuleSet
              ]
          }
        `shouldBe` True
      awsSesPresenceInventoryComplete
        AwsSesPresenceInventory
          { awsSesPresentResources =
              [ AwsSesCaptureBucket
              , AwsSesSmtpIamUser
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

    it "accepts a scoped live endpoint only for the canonical AWS target" $
      awsSesTargetSelectionForSink testAuthority awsTarget
        `shouldSatisfy` isRight

    it "rejects home endpoint substitution and noncanonical identities" $ do
      awsSesTargetSelectionForSink testAuthority substitutedHomeTarget
        `shouldBe` Left
          "selected SES home target must exactly match the retained authority sink"
      awsSesTargetSelectionForSink testAuthority otherTarget
        `shouldBe` Left
          "selected SES target identity is neither the retained home authority nor canonical AWS EKS"

    it "rejects secret-coordinate substitution for the canonical AWS target" $
      awsSesTargetSelectionForSink testAuthority substitutedAwsTarget
        `shouldBe` Left
          "selected SES AWS target must use the canonical SMTP secret coordinate"

testAuthority :: LongLivedCheckpointAuthority
testAuthority =
  case mkLongLivedCheckpointAuthority
    "prodbox-home"
    "http://127.0.0.1:31822"
    "prodbox-state"
    "model-b"
    "prodbox" of
    Left err -> error (show err)
    Right authority -> authority

homeTarget :: TargetClusterSecretSink
homeTarget =
  targetSink "prodbox-home" "http://127.0.0.1:31822" "keycloak/smtp"

awsTarget :: TargetClusterSecretSink
awsTarget =
  targetSink
    (Text.pack awsEksCanonicalClusterName)
    "http://127.0.0.1:43117"
    "keycloak/smtp"

substitutedHomeTarget :: TargetClusterSecretSink
substitutedHomeTarget =
  targetSink "prodbox-home" "http://127.0.0.1:49999" "keycloak/smtp"

otherTarget :: TargetClusterSecretSink
otherTarget =
  targetSink "some-other-cluster" "http://127.0.0.1:43117" "keycloak/smtp"

substitutedAwsTarget :: TargetClusterSecretSink
substitutedAwsTarget =
  targetSink
    (Text.pack awsEksCanonicalClusterName)
    "http://127.0.0.1:43117"
    "somewhere/else"

targetSink :: Text.Text -> Text.Text -> Text.Text -> TargetClusterSecretSink
targetSink identity endpoint path =
  case mkTargetClusterSecretSink identity endpoint "secret" path of
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
    , ("smtp_endpoint", "email-smtp.us-east-1.amazonaws.com")
    , ("smtp_iam_user_name", "prodbox-ses-smtp")
    , ("smtp_iam_user_arn", "arn:aws:iam::123456789012:user/prodbox-ses-smtp")
    ]
