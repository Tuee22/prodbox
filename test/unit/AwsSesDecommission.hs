{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsSesDecommission
  ( awsSesDecommissionSuite
  )
where

import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (nub)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.AwsSesDecommission
  ( AwsSesDecommissionPrimitive
  , AwsSesDecommissionScope (AwsSesProviderOnly, AwsSesWholePulumiStack)
  , AwsSesOwnedFamily (AwsSesProviderFamily)
  , awsSesProviderStackCapability
  , awsSesProviderStackDestroyPrimitiveWith
  , awsSesPulumiStackDestroyPrimitive
  , awsSesPulumiStackOwnedFamilies
  , awsSesSmtpIamCapability
  , awsSesSmtpIamDestroyPrimitiveWith
  , awsSesSmtpIamEnvironmentForCredentials
  )
import Prodbox.Infra.AwsSesStack
  ( awsSesProviderPulumiResourceUrns
  , awsSesSmtpPulumiResourceUrns
  , parseAwsSesPulumiResourceUrns
  )
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , FrameNodeId
  , mkFrameAttemptId
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (SesProviderStack, SesSmtpIam)
  , decommissionNodeFrameId
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeObservation (NodeObservedAbsent)
  , NodeOperation
  , observeNodeOperation
  , runNodeOperation
  , runSesProviderStackCapability
  , runSesSmtpIamCapability
  )
import Prodbox.Lifecycle.ResidueStatus (ResidueStatus (ResidueAbsent))
import Prodbox.Result (Result (Success))
import Prodbox.Settings
  ( Credentials
      ( Credentials
      , access_key_id
      , region
      , secret_access_key
      , session_token
      )
  )
import Prodbox.Subprocess
  ( ProcessOutput
      ( ProcessOutput
      , processExitCode
      , processStderr
      , processStdout
      )
  , Subprocess
    ( subprocessArguments
    , subprocessEnvironment
    , subprocessPath
    , subprocessWorkingDirectory
    )
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import TestSupport

awsSesDecommissionSuite :: SuiteBuilder ()
awsSesDecommissionSuite =
  describe "Sprint 4.50 exact SES decommission ownership" $ do
    it
      "keeps legacy two-family checkpoints typed for Admin teardown while the program is non-credential"
      $ do
        awsSesPulumiStackOwnedFamilies
          `shouldBe` [AwsSesProviderFamily]
        wholeStackScopeWitness
          (awsSesPulumiStackDestroyPrimitive "/repo" True)
          `shouldBe` ()
        pulumiProgram <- readFile "pulumi/aws-ses/Main.yaml"
        pulumiProgram `shouldNotContain` "  smtpUser:\n"
        pulumiProgram `shouldNotContain` "  smtpUserPolicy:\n"
        pulumiProgram `shouldNotContain` "type: aws:iam:User"
        pulumiProgram `shouldNotContain` "type: aws:iam:UserPolicy"

    it "keeps the exact provider target set disjoint from legacy SMTP IAM compatibility URNs" $ do
      length awsSesProviderPulumiResourceUrns `shouldBe` 13
      length awsSesSmtpPulumiResourceUrns `shouldBe` 2
      filter (`elem` awsSesSmtpPulumiResourceUrns) awsSesProviderPulumiResourceUrns
        `shouldBe` []
      Text.unpack (Text.unlines awsSesProviderPulumiResourceUrns) `shouldNotContain` "smtpUser"
      Text.unpack (Text.unlines awsSesSmtpPulumiResourceUrns) `shouldContain` "::smtpUser"
      providerScopeWitness
        (awsSesProviderStackDestroyPrimitiveWith (pure (Right ())) (pure ResidueAbsent))
        `shouldBe` ()

    it "decodes exact URNs from a Pulumi export and refuses malformed state" $ do
      case (awsSesProviderPulumiResourceUrns, awsSesSmtpPulumiResourceUrns) of
        (providerUrn : _, smtpUrn : _) -> do
          let exported =
                "{\"deployment\":{\"resources\":[{\"urn\":\""
                  ++ Text.unpack providerUrn
                  ++ "\"},{\"urn\":\""
                  ++ Text.unpack smtpUrn
                  ++ "\"}]}}"
          parseAwsSesPulumiResourceUrns exported `shouldBe` Right [providerUrn, smtpUrn]
          parseAwsSesPulumiResourceUrns "{\"deployment\":{}}"
            `shouldSatisfy` either (const True) (const False)
        _ -> expectationFailure "compiled SES resource inventories are unexpectedly empty"

    it "keeps provider response-loss observation read-only and convergent" $ do
      destroyCount <- newIORef (0 :: Int)
      absent <- newIORef False
      let destroy = do
            modifyIORef' destroyCount (+ 1)
            modifyIORef' absent (const True)
            pure (Left "provider response lost")
          observe = do
            isAbsent <- readIORef absent
            pure (if isAbsent then ResidueAbsent else error "fixture expected absence")
          operation =
            runSesProviderStackCapability
              ( awsSesProviderStackCapability
                  (awsSesProviderStackDestroyPrimitiveWith destroy observe)
              )
          providerNodeId = decommissionNodeFrameId SesProviderStack
      destroyResult <- runNodeOperation operation providerNodeId attemptId
      destroyResult `shouldBe` Left "provider response lost"
      readIORef destroyCount `shouldReturn` 1
      observeNodeOperation operation providerNodeId attemptId
        `shouldReturn` NodeObservedAbsent
      readIORef destroyCount `shouldReturn` 1

    it "derives AWS CLI auth only from the explicitly supplied ephemeral credential" $ do
      let environment =
            awsSesSmtpIamEnvironmentForCredentials
              [ ("PATH", "/tools")
              , ("AWS_ACCESS_KEY_ID", "ambient-access")
              , ("AWS_SECRET_ACCESS_KEY", "ambient-secret")
              , ("AWS_SESSION_TOKEN", "ambient-token")
              , ("AWS_PROFILE", "ambient-profile")
              , ("AWS_WEB_IDENTITY_TOKEN_FILE", "/ambient/token")
              , ("AWS_CA_BUNDLE", "/ambient/ca.pem")
              ]
              explicitCredentials
      lookup "AWS_ACCESS_KEY_ID" environment `shouldBe` Just "explicit-access"
      lookup "AWS_SECRET_ACCESS_KEY" environment `shouldBe` Just "explicit-secret"
      lookup "AWS_SESSION_TOKEN" environment `shouldBe` Just "explicit-token"
      lookup "AWS_REGION" environment `shouldBe` Just "us-east-1"
      lookup "AWS_DEFAULT_REGION" environment `shouldBe` Just "us-east-1"
      lookup "AWS_EC2_METADATA_DISABLED" environment `shouldBe` Just "true"
      lookup "AWS_PAGER" environment `shouldBe` Just ""
      lookup "AWS_CLI_AUTO_PROMPT" environment `shouldBe` Just "off"
      lookup "PATH" environment `shouldBe` Just "/tools"
      lookup "AWS_PROFILE" environment `shouldBe` Nothing
      lookup "AWS_WEB_IDENTITY_TOKEN_FILE" environment `shouldBe` Nothing
      lookup "AWS_CA_BUNDLE" environment `shouldBe` Nothing
      fmap fst environment `shouldBe` nub (fmap fst environment)

    it "deletes exact access keys, inline policy, and user before confirming absence" $ do
      seenRef <- newIORef []
      let runner spec = do
            modifyIORef' seenRef (++ [spec])
            pure $ case subprocessArguments spec of
              ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                successfulProcess twoKeyInventory
              ["iam", "delete-access-key", "--user-name", "prodbox-ses-smtp", "--access-key-id", _] ->
                successfulProcess ""
              [ "iam"
                , "delete-user-policy"
                , "--user-name"
                , "prodbox-ses-smtp"
                , "--policy-name"
                , "prodbox-ses-smtp-policy"
                ] ->
                  successfulProcess ""
              ["iam", "delete-user", "--user-name", "prodbox-ses-smtp"] ->
                successfulProcess ""
              ["iam", "get-user", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                noSuchEntityProcess
              _ -> failedProcess "unexpected command"
          environment = [("AWS_REGION", "us-east-1")]
          operation =
            runSesSmtpIamCapability
              ( awsSesSmtpIamCapability
                  (awsSesSmtpIamDestroyPrimitiveWith runner "/repo" environment)
              )
      runNodeOperation operation nodeId attemptId `shouldReturn` Right ()
      seen <- readIORef seenRef
      map subprocessArguments seen
        `shouldBe` [ ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                   ,
                     [ "iam"
                     , "delete-access-key"
                     , "--user-name"
                     , "prodbox-ses-smtp"
                     , "--access-key-id"
                     , "AKIAEXACTKEY00001"
                     ]
                   ,
                     [ "iam"
                     , "delete-access-key"
                     , "--user-name"
                     , "prodbox-ses-smtp"
                     , "--access-key-id"
                     , "AKIAEXACTKEY00002"
                     ]
                   ,
                     [ "iam"
                     , "delete-user-policy"
                     , "--user-name"
                     , "prodbox-ses-smtp"
                     , "--policy-name"
                     , "prodbox-ses-smtp-policy"
                     ]
                   , ["iam", "delete-user", "--user-name", "prodbox-ses-smtp"]
                   , ["iam", "get-user", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                   ]
      map subprocessPath seen `shouldBe` replicate 6 "aws"
      map subprocessEnvironment seen `shouldBe` replicate 6 (Just environment)
      map subprocessWorkingDirectory seen `shouldBe` replicate 6 (Just "/repo")

    it "is idempotent when the exact SMTP IAM user is already absent" $ do
      seenRef <- newIORef []
      let runner spec = do
            modifyIORef' seenRef (++ [subprocessArguments spec])
            pure noSuchEntityProcess
          operation = exactOperation runner
      runNodeOperation operation nodeId attemptId `shouldReturn` Right ()
      readIORef seenRef
        `shouldReturn` [ ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                       , ["iam", "get-user", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                       ]

    it "accepts an already-absent inline policy but still removes and reads back the user" $ do
      seenRef <- newIORef []
      let runner spec = do
            modifyIORef' seenRef (++ [subprocessArguments spec])
            pure $ case subprocessArguments spec of
              ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                successfulProcess emptyInventory
              [ "iam"
                , "delete-user-policy"
                , "--user-name"
                , "prodbox-ses-smtp"
                , "--policy-name"
                , "prodbox-ses-smtp-policy"
                ] ->
                  noSuchEntityProcess
              ["iam", "delete-user", "--user-name", "prodbox-ses-smtp"] ->
                successfulProcess ""
              ["iam", "get-user", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                noSuchEntityProcess
              _ -> failedProcess "unexpected command"
      runNodeOperation (exactOperation runner) nodeId attemptId `shouldReturn` Right ()
      readIORef seenRef
        `shouldReturn` [ ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                       ,
                         [ "iam"
                         , "delete-user-policy"
                         , "--user-name"
                         , "prodbox-ses-smtp"
                         , "--policy-name"
                         , "prodbox-ses-smtp-policy"
                         ]
                       , ["iam", "delete-user", "--user-name", "prodbox-ses-smtp"]
                       , ["iam", "get-user", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                       ]

    it "stops at an access-key failure and does not misreport an unobserved absence" $ do
      seenRef <- newIORef []
      let runner spec = do
            modifyIORef' seenRef (++ [subprocessArguments spec])
            pure $ case subprocessArguments spec of
              ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                successfulProcess oneKeyInventory
              ["iam", "delete-access-key", "--user-name", "prodbox-ses-smtp", "--access-key-id", _] ->
                accessDeniedProcess
              _ -> failedProcess "unexpected command"
      result <- runNodeOperation (exactOperation runner) nodeId attemptId
      result `shouldSatisfy` leftContains "AWS IAM access denied"
      readIORef seenRef
        `shouldReturn` [ ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"]
                       ,
                         [ "iam"
                         , "delete-access-key"
                         , "--user-name"
                         , "prodbox-ses-smtp"
                         , "--access-key-id"
                         , "AKIAEXACTKEY00001"
                         ]
                       ]

    it "refuses success when authoritative read-back still observes the user" $ do
      let runner spec = pure $ case subprocessArguments spec of
            ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
              successfulProcess emptyInventory
            [ "iam"
              , "delete-user-policy"
              , "--user-name"
              , "prodbox-ses-smtp"
              , "--policy-name"
              , "prodbox-ses-smtp-policy"
              ] ->
                successfulProcess ""
            ["iam", "delete-user", "--user-name", "prodbox-ses-smtp"] ->
              successfulProcess ""
            ["iam", "get-user", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
              successfulProcess exactUser
            _ -> failedProcess "unexpected command"
      result <- runNodeOperation (exactOperation runner) nodeId attemptId
      result `shouldSatisfy` leftContains "read-back did not confirm absence"

wholeStackScopeWitness
  :: AwsSesDecommissionPrimitive 'AwsSesWholePulumiStack IO -> ()
wholeStackScopeWitness _ = ()

providerScopeWitness
  :: AwsSesDecommissionPrimitive 'AwsSesProviderOnly IO -> ()
providerScopeWitness _ = ()

exactOperation
  :: (Subprocess -> IO (Result ProcessOutput))
  -> NodeOperation IO
exactOperation runner =
  runSesSmtpIamCapability
    ( awsSesSmtpIamCapability
        (awsSesSmtpIamDestroyPrimitiveWith runner "/repo" [])
    )

successfulProcess :: String -> Result ProcessOutput
successfulProcess stdout =
  Success
    ProcessOutput
      { processExitCode = ExitSuccess
      , processStdout = stdout
      , processStderr = ""
      }

failedProcess :: String -> Result ProcessOutput
failedProcess stderr =
  Success
    ProcessOutput
      { processExitCode = ExitFailure 1
      , processStdout = ""
      , processStderr = stderr
      }

noSuchEntityProcess :: Result ProcessOutput
noSuchEntityProcess =
  failedProcess "An error occurred (NoSuchEntity) when calling the IAM operation"

accessDeniedProcess :: Result ProcessOutput
accessDeniedProcess =
  failedProcess "An error occurred (AccessDenied) when calling DeleteAccessKey"

emptyInventory :: String
emptyInventory = "{\"AccessKeyMetadata\":[]}"

oneKeyInventory :: String
oneKeyInventory =
  "{\"AccessKeyMetadata\":["
    ++ accessKeyEntry "AKIAEXACTKEY00001"
    ++ "]}"

twoKeyInventory :: String
twoKeyInventory =
  "{\"AccessKeyMetadata\":["
    ++ accessKeyEntry "AKIAEXACTKEY00001"
    ++ ","
    ++ accessKeyEntry "AKIAEXACTKEY00002"
    ++ "]}"

accessKeyEntry :: String -> String
accessKeyEntry keyId =
  "{\"UserName\":\"prodbox-ses-smtp\",\"AccessKeyId\":\""
    ++ keyId
    ++ "\"}"

exactUser :: String
exactUser = "{\"User\":{\"UserName\":\"prodbox-ses-smtp\"}}"

nodeId :: FrameNodeId
nodeId = decommissionNodeFrameId SesSmtpIam

attemptId :: FrameAttemptId
attemptId = fromJust (mkFrameAttemptId "attempt-ses-smtp-iam")

leftContains :: Text -> Either Text value -> Bool
leftContains expected result = case result of
  Left detail -> expected `Text.isInfixOf` detail
  Right _ -> False

explicitCredentials :: Credentials
explicitCredentials =
  Credentials
    { access_key_id = "explicit-access"
    , secret_access_key = "explicit-secret"
    , session_token = Just "explicit-token"
    , region = "us-east-1"
    }
