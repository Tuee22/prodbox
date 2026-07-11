{-# LANGUAGE OverloadedStrings #-}

module AwsSesSmtpKey
  ( awsSesSmtpKeySuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.AwsSesSmtpKey
  ( AwsSesSmtpCommandFailure (..)
  , classifyAwsSesSmtpCommandResult
  , classifyAwsSesSmtpKeyCreateResult
  , classifyAwsSesSmtpKeyDeleteResult
  , classifyAwsSesSmtpKeyInventoryResult
  , createAwsSesSmtpAccessKeyWith
  , deleteAwsSesSmtpAccessKeyWith
  , observeAwsSesSmtpKeyInventoryWith
  , smtpKeyMaterialDigest
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpAccessKeyId
  , SmtpKeyCleanupResult (..)
  , SmtpKeyInventoryObservation (..)
  , mkSmtpAccessKeyId
  , smtpAccessKeyIdText
  )
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  )
import System.Exit (ExitCode (..))
import TestSupport

awsSesSmtpKeySuite :: SuiteBuilder ()
awsSesSmtpKeySuite =
  describe "Sprint 4.47 exact SES SMTP IAM adapter" $ do
    it "distinguishes not-found, access-denied, network, start, and other command failures" $ do
      classifyAwsSesSmtpCommandResult noSuchEntityResult
        `shouldSatisfy` isNotFound
      classifyAwsSesSmtpCommandResult accessDeniedResult
        `shouldSatisfy` isAccessDenied
      classifyAwsSesSmtpCommandResult networkFailureResult
        `shouldSatisfy` isNetworkFailure
      classifyAwsSesSmtpCommandResult (Failure "aws executable missing")
        `shouldBe` Left (AwsSesSmtpProcessStartFailure "aws executable missing")
      classifyAwsSesSmtpCommandResult
        (failedProcess "unexpected service failure")
        `shouldBe` Left (AwsSesSmtpOtherCommandFailure "unexpected service failure")

    it "classifies exact-user inventory, not-found, malformed JSON, wrong user, and over-bound state" $ do
      classifyAwsSesSmtpKeyInventoryResult
        (successfulProcess exactInventoryJson)
        `shouldBe` SmtpKeyInventoryObserved [keyOne, keyTwo]
      classifyAwsSesSmtpKeyInventoryResult noSuchEntityResult
        `shouldBe` SmtpKeyInventoryPending "SMTP IAM user is not yet visible"
      classifyAwsSesSmtpKeyInventoryResult
        (successfulProcess "{not-json")
        `shouldSatisfy` inventoryReasonContains "invalid IAM access-key inventory JSON"
      classifyAwsSesSmtpKeyInventoryResult
        (successfulProcess wrongUserInventoryJson)
        `shouldSatisfy` inventoryReasonContains "unexpected user somebody-else"
      classifyAwsSesSmtpKeyInventoryResult
        (successfulProcess overBoundInventoryJson)
        `shouldBe` SmtpKeyInventoryOverBound 3 2
      classifyAwsSesSmtpKeyInventoryResult accessDeniedResult
        `shouldSatisfy` inventoryReasonContains "AWS IAM access denied"
      classifyAwsSesSmtpKeyInventoryResult networkFailureResult
        `shouldSatisfy` inventoryReasonContains "AWS IAM network failure"

    it "keeps delete idempotent only for exact success/not-found and propagates other failures" $ do
      classifyAwsSesSmtpKeyDeleteResult keyOne (successfulProcess "")
        `shouldBe` SmtpKeyDeleted keyOne
      classifyAwsSesSmtpKeyDeleteResult keyOne noSuchEntityResult
        `shouldBe` SmtpKeyDeleted keyOne
      classifyAwsSesSmtpKeyDeleteResult keyOne accessDeniedResult
        `shouldSatisfy` cleanupReasonContains "AWS IAM access denied"
      classifyAwsSesSmtpKeyDeleteResult keyOne networkFailureResult
        `shouldSatisfy` cleanupReasonContains "AWS IAM network failure"

    it "accepts only an exact-user create response with valid key id and nonempty material" $ do
      case classifyAwsSesSmtpKeyCreateResult (successfulProcess exactCreateJson) of
        Right (keyId, material) -> do
          keyId `shouldBe` keyOne
          material `shouldBe` "created-secret"
        Left detail -> expectationFailure (Text.unpack detail)
      classifyAwsSesSmtpKeyCreateResult (successfulProcess wrongUserCreateJson)
        `shouldSatisfy` leftReasonContains "unexpected user somebody-else"
      classifyAwsSesSmtpKeyCreateResult (successfulProcess "not-json")
        `shouldSatisfy` leftReasonContains "invalid IAM create-access-key JSON"
      classifyAwsSesSmtpKeyCreateResult (successfulProcess emptySecretCreateJson)
        `shouldBe` Left "IAM create-access-key returned empty secret material"
      classifyAwsSesSmtpKeyCreateResult accessDeniedResult
        `shouldSatisfy` leftReasonContains "AWS IAM access denied"
      classifyAwsSesSmtpKeyCreateResult networkFailureResult
        `shouldSatisfy` leftReasonContains "AWS IAM network failure"

    it "injects the runner and pins list/delete/create to the exact SMTP user" $ do
      seenRef <- newIORef []
      let runner spec = do
            modifyIORef' seenRef (++ [spec])
            pure $ case subprocessArguments spec of
              ["iam", "list-access-keys", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                successfulProcess exactInventoryJson
              ["iam", "delete-access-key", "--user-name", "prodbox-ses-smtp", "--access-key-id", keyId]
                | keyId == Text.unpack (smtpAccessKeyIdText keyOne) -> successfulProcess ""
              ["iam", "create-access-key", "--user-name", "prodbox-ses-smtp", "--output", "json"] ->
                successfulProcess exactCreateJson
              _ -> Failure "unexpected command"
          environment = [("AWS_REGION", "ca-central-1")]
      inventory <- observeAwsSesSmtpKeyInventoryWith runner "/repo" environment
      cleanup <- deleteAwsSesSmtpAccessKeyWith runner "/repo" environment keyOne
      created <- createAwsSesSmtpAccessKeyWith runner "/repo" environment
      inventory `shouldBe` SmtpKeyInventoryObserved [keyOne, keyTwo]
      cleanup `shouldBe` SmtpKeyDeleted keyOne
      fmap fst created `shouldBe` Right keyOne
      seen <- readIORef seenRef
      length seen `shouldBe` 3
      map subprocessPath seen `shouldBe` ["aws", "aws", "aws"]
      map subprocessEnvironment seen `shouldBe` replicate 3 (Just environment)
      map subprocessWorkingDirectory seen `shouldBe` replicate 3 (Just "/repo")

    it "constructs the canonical SHA-256 digest without a partial validation branch" $ do
      targetValueDigestText (smtpKeyMaterialDigest "abc")
        `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      Text.length (targetValueDigestText (smtpKeyMaterialDigest BS8.empty))
        `shouldBe` 64

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

noSuchEntityResult :: Result ProcessOutput
noSuchEntityResult =
  failedProcess "An error occurred (NoSuchEntity) when calling ListAccessKeys"

accessDeniedResult :: Result ProcessOutput
accessDeniedResult =
  failedProcess "An error occurred (AccessDenied) when calling ListAccessKeys"

networkFailureResult :: Result ProcessOutput
networkFailureResult =
  failedProcess "Could not connect to the endpoint URL: https://iam.amazonaws.com"

exactInventoryJson :: String
exactInventoryJson =
  "{\"AccessKeyMetadata\":["
    ++ accessKeyEntry "prodbox-ses-smtp" "AKIAEXACTKEY00001"
    ++ ","
    ++ accessKeyEntry "prodbox-ses-smtp" "AKIAEXACTKEY00002"
    ++ "]}"

wrongUserInventoryJson :: String
wrongUserInventoryJson =
  "{\"AccessKeyMetadata\":["
    ++ accessKeyEntry "somebody-else" "AKIAEXACTKEY00001"
    ++ "]}"

overBoundInventoryJson :: String
overBoundInventoryJson =
  "{\"AccessKeyMetadata\":["
    ++ accessKeyEntry "prodbox-ses-smtp" "AKIAEXACTKEY00001"
    ++ ","
    ++ accessKeyEntry "prodbox-ses-smtp" "AKIAEXACTKEY00002"
    ++ ","
    ++ accessKeyEntry "prodbox-ses-smtp" "AKIAEXACTKEY00003"
    ++ "]}"

accessKeyEntry :: String -> String -> String
accessKeyEntry userName keyId =
  "{\"UserName\":\""
    ++ userName
    ++ "\",\"AccessKeyId\":\""
    ++ keyId
    ++ "\"}"

exactCreateJson :: String
exactCreateJson = createJson "prodbox-ses-smtp" "created-secret"

wrongUserCreateJson :: String
wrongUserCreateJson = createJson "somebody-else" "created-secret"

emptySecretCreateJson :: String
emptySecretCreateJson = createJson "prodbox-ses-smtp" ""

createJson :: String -> String -> String
createJson userName secret =
  "{\"AccessKey\":{\"UserName\":\""
    ++ userName
    ++ "\",\"AccessKeyId\":\"AKIAEXACTKEY00001\",\"SecretAccessKey\":\""
    ++ secret
    ++ "\"}}"

keyOne :: SmtpAccessKeyId
keyOne = expectRight (mkSmtpAccessKeyId "AKIAEXACTKEY00001")

keyTwo :: SmtpAccessKeyId
keyTwo = expectRight (mkSmtpAccessKeyId "AKIAEXACTKEY00002")

isNotFound :: Either AwsSesSmtpCommandFailure String -> Bool
isNotFound result = case result of
  Left (AwsSesSmtpUserNotFound _) -> True
  _ -> False

isAccessDenied :: Either AwsSesSmtpCommandFailure String -> Bool
isAccessDenied result = case result of
  Left (AwsSesSmtpAccessDenied _) -> True
  _ -> False

isNetworkFailure :: Either AwsSesSmtpCommandFailure String -> Bool
isNetworkFailure result = case result of
  Left (AwsSesSmtpNetworkFailure _) -> True
  _ -> False

inventoryReasonContains :: String -> SmtpKeyInventoryObservation -> Bool
inventoryReasonContains expected observation = case observation of
  SmtpKeyInventoryUnobservable detail -> Text.pack expected `Text.isInfixOf` detail
  _ -> False

cleanupReasonContains :: String -> SmtpKeyCleanupResult -> Bool
cleanupReasonContains expected result = case result of
  SmtpKeyDeleteFailed _ detail -> Text.pack expected `Text.isInfixOf` detail
  _ -> False

leftReasonContains
  :: String -> Either Text (SmtpAccessKeyId, ByteString) -> Bool
leftReasonContains expected result = case result of
  Left detail -> Text.pack expected `Text.isInfixOf` detail
  Right _ -> False

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result = case result of
  Left err -> error ("unexpected Left: " ++ show err)
  Right value -> value
