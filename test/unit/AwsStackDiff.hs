{-# LANGUAGE OverloadedStrings #-}

module AwsStackDiff (awsStackDiffSuite) where

import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.ProviderProduction (previewPulumiStackVia)
import Prodbox.Infra.AwsStackRepair (runStackDiffVia)
import Prodbox.Lifecycle.AwsRemedy (AwsStackTarget (..))
import Prodbox.Lifecycle.AwsStackDiff
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

awsStackDiffSuite :: SuiteBuilder ()
awsStackDiffSuite = describe "Sprint 4.112 redacted stack preview" $ do
  it "keeps resource and property changes while discarding every value and diagnostic" $ do
    preview <- expectRight (decodePulumiStackPreview (success fixture))
    stackPreviewChanges preview
      `shouldBe` [PreviewChange urn PreviewUpdate ["password", "size"]]
    evidence <- expectRight (encodeStackPreviewEvidence "aws-eks" preview)
    decodeStackPreviewEvidence "aws-eks" evidence `shouldBe` Right preview
    let report = Text.unlines (renderStackPreview "aws-eks" preview)
    mapM_
      (\value -> Text.isInfixOf value evidence `shouldBe` False)
      ["SECRET_CANARY", "PLAIN_VALUE_CANARY", "DIAGNOSTIC_CANARY"]
    Text.isInfixOf "password,size" report `shouldBe` True
    Text.isInfixOf urn report `shouldBe` True
    decodeStackPreviewEvidence "aws-test" evidence `shouldSatisfy` isLeft

  it "reads create/read/delete property names from the real PreviewDigest state shape" $ do
    let step =
          object
            [ "op" .= ("read" :: Text.Text)
            , "urn" .= urn
            , "newState" .= object ["inputs" .= object ["name" .= ("VALUE_CANARY" :: Text.Text)]]
            , "detailedDiff" .= Null
            ]
        document = object ["steps" .= [step], "changeSummary" .= object ["read" .= (1 :: Int)]]
    preview <- expectRight (decodePulumiStackPreview (success document))
    stackPreviewChanges preview `shouldBe` [PreviewChange urn PreviewRead ["name"]]

  it "refuses partial, failed, corrupt, unknown-operation and error-diagnostic previews" $ do
    let noSummary = object ["steps" .= ([] :: [Value])]
        corrupt = object ["changeSummary" .= object [], "maybeCorrupt" .= True]
        errorDiagnostic =
          object
            [ "changeSummary" .= object []
            , "diagnostics"
                .= [object ["severity" .= ("error" :: Text.Text), "message" .= ("SECRET_CANARY" :: Text.Text)]]
            ]
        unknown = object ["changeSummary" .= object ["unknown-operation" .= (1 :: Int)]]
        truncated = object ["changeSummary" .= object ["update" .= (1 :: Int)]]
    mapM_
      ((`shouldSatisfy` isLeft) . decodePulumiStackPreview . success)
      [noSummary, corrupt, errorDiagnostic, unknown, truncated]
    decodePulumiStackPreview (ProcessOutput (ExitFailure 1) "SECRET_CANARY" "SECRET_CANARY")
      `shouldBe` Left "Pulumi preview did not complete successfully"
    decodePulumiStackPreview (ProcessOutput ExitSuccess "SECRET_CANARY" "")
      `shouldBe` Left "Pulumi preview output is not a JSON object"

  it "refuses oversized input and malformed or injected identifiers" $ do
    decodePulumiStackPreview (ProcessOutput ExitSuccess (replicate (2 * 1024 * 1024 + 1) 'x') "")
      `shouldBe` Left "Pulumi preview exceeded its decode bound"
    let bad =
          object
            [ "steps"
                .= [object ["op" .= ("update" :: Text.Text), "urn" .= ("urn:pulumi:line\nbreak" :: Text.Text)]]
            , "changeSummary" .= object ["update" .= (1 :: Int)]
            ]
    decodePulumiStackPreview (success bad) `shouldSatisfy` isLeft

  it "runs only login, existing-stack selection and a redacted JSON preview" $ do
    calls <- newIORef []
    let runner arguments = do
          modifyIORef' calls (++ [arguments])
          pure (if "preview" `elem` arguments then success fixture else ProcessOutput ExitSuccess "" "")
    preview <-
      expectRight
        =<< previewPulumiStackVia runner "file:///scratch" "aws-eks" [("operatorCidr", "127.0.0.1/32")]
    length (stackPreviewChanges preview) `shouldBe` 1
    commands <- readIORef calls
    map (take 1) commands `shouldBe` [["login"], ["stack"], ["preview"]]
    let arguments = concat commands
    mapM_
      (\flag -> elem flag arguments `shouldBe` True)
      ["--json", "--diff", "--suppress-outputs", "--non-interactive"]
    mapM_
      (\flag -> elem flag arguments `shouldBe` False)
      ["up", "destroy", "init", "--show-secrets", "--expect-no-changes"]

  it "refuses failed checkpoint selection without preview or diagnostic leakage" $ do
    calls <- newIORef []
    result <-
      previewPulumiStackVia
        ( \arguments ->
            modifyIORef' calls (++ [arguments])
              >> pure
                ( if take 1 arguments == ["login"]
                    then ProcessOutput ExitSuccess "" ""
                    else ProcessOutput (ExitFailure 1) "SECRET_CANARY" "SECRET_CANARY"
                )
        )
        "file:///scratch"
        "aws-eks"
        []
    result `shouldBe` Left "Pulumi preview requires an observable registered checkpoint"
    (length <$> readIORef calls) `shouldReturn` 2

  it "uses one exact preview request and refuses a substituted stack report" $ do
    calls <- newIORef []
    preview <- expectRight (decodePulumiStackPreview (success fixture))
    evidence <- expectRight (encodeStackPreviewEvidence "aws-eks" preview)
    let config = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")
        dispatch intent = modifyIORef' calls (++ [intent]) >> pure (Right evidence)
    result <- runStackDiffVia dispatch AwsEksTarget config
    result `shouldSatisfy` either (const False) (any (Text.isInfixOf urn))
    readIORef calls
      `shouldReturn` [PreviewRegisteredStack (mustRight (mkProviderStackRef "aws-eks")) config]
    mismatched <- expectRight (encodeStackPreviewEvidence "aws-test" preview)
    runStackDiffVia (const (pure (Right mismatched))) AwsEksTarget config `shouldReturnSatisfy` isLeft

  it "admits SES only through the dedicated read-only preview key" $ do
    let config = mustRight (mkAwsSesPreviewStackConfig "example.test" "receive.example.test" "capture-bucket")
        ref = mustRight (mkProviderStackRef "aws-ses")
        intent = PreviewRegisteredStack ref config
        resources = mkRegisteredProviderResources productionRegisteredProviderResources
    providerIntentResourceKey intent `shouldBe` "stack-diff:aws-ses"
    isProviderResourceRegistered (providerIntentResourceKey intent) resources `shouldBe` True
    isProviderResourceRegistered "stack:aws-ses" resources `shouldBe` False
    validateProviderStackConfig (mustRight (mkProviderStackRef "aws-eks")) config `shouldSatisfy` isLeft
    providerIntentEvidenceMaximumCharacters intent `shouldBe` 32768
 where
  isLeft value = case value of
    Left _ -> True
    Right _ -> False

urn :: Text.Text
urn = "urn:pulumi:example::project::aws:ec2:Vpc::network"

fixture :: Value
fixture =
  object
    [ "config" .= object ["password" .= ("SECRET_CANARY" :: Text.Text)]
    , "diagnostics"
        .= [object ["severity" .= ("warning" :: Text.Text), "message" .= ("DIAGNOSTIC_CANARY" :: Text.Text)]]
    , "changeSummary" .= object ["update" .= (1 :: Int)]
    , "steps"
        .= [ object
               [ "op" .= ("update" :: Text.Text)
               , "urn" .= urn
               , "newState"
                   .= object
                     [ "inputs"
                         .= object
                           ["password" .= ("SECRET_CANARY" :: Text.Text), "other" .= ("PLAIN_VALUE_CANARY" :: Text.Text)]
                     ]
               , "diffReasons" .= (["size"] :: [Text.Text])
               , "detailedDiff"
                   .= object ["password" .= object ["kind" .= ("update" :: Text.Text), "inputDiff" .= True]]
               ]
           ]
    ]

success :: Value -> ProcessOutput
success value =
  ProcessOutput
    ExitSuccess
    (Text.unpack (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode value))))
    ""

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Right value -> pure value
  Left detail -> expectationFailure (show detail) >> fail "expected preview"

shouldReturnSatisfy :: (Show a) => IO a -> (a -> Bool) -> IO ()
shouldReturnSatisfy action predicate = action >>= (`shouldSatisfy` predicate)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left detail -> error ("invalid stack-preview fixture: " ++ show detail)
