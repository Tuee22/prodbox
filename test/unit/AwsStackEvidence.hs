{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsStackEvidence (awsStackEvidenceSuite) where

import AwsAuditEnumeration qualified as Model
import Control.Monad (forM_)
import Data.Aeson
  ( FromJSON (..)
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified
import Prodbox.Aws.CliError (awsCliServiceErrorMatches)
import Prodbox.Infra.AwsEksTestStack qualified as Eks
import Prodbox.Infra.AwsFieldAudit
import Prodbox.Infra.AwsTestStack qualified as Test
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence
  ( AuditBinding (..)
  , decodeAwsAuditEvidence
  , encodeAwsAuditEvidence
  )
import Prodbox.Lifecycle.AwsAuditField (auditStackField)
import Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeEksClusterAbsent
  )
import Prodbox.Lifecycle.ProviderWorker.Evidence (providerEvidenceText)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Subprocess (ProcessOutput (..))
import Prodbox.Test.AwsStackEvidence
import System.Exit (ExitCode (..))
import TestSupport

awsStackEvidenceSuite :: SuiteBuilder ()
awsStackEvidenceSuite = describe "Sprint 5.58 provider create evidence consumers" $ do
  forM_ [minBound .. maxBound] $ \validation -> describe (show validation) $ do
    it "composes the actual field renderer, recorded output decoder and effect-boundary consumer" $ do
      calls <- newIORef ([] :: [(Text, AuditStack)])
      let stack = stackFor validation
          boundary =
            AwsStackValidationBoundary
              { reconcileValidationStack = \target -> do
                  modifyIORef' calls (<> [("reconcile", target)])
                  pure (Right (captured validation (complete validation)))
              , readValidationStackOutputs = \target -> do
                  modifyIORef' calls (<> [("outputs", target)])
                  pure (Right (outputsFor validation))
              }
      runAwsStackEvidenceValidation boundary validation >>= (`shouldBe` Right ())
      readIORef calls >>= (`shouldBe` [("reconcile", stack), ("outputs", stack)])
    it "rejects the real empty-input digest by name while the frozen prefix-only assertion accepts it" $ do
      let output = captured validation (complete validation)
          empty =
            output
              { processStdout = Text.unpack (Text.replace digest emptyDigest (Text.pack (processStdout output)))
              }
      legacyPrefixAccepted validation empty `shouldBe` True
      assertAwsStackCreateEvidence validation (outputsFor validation) empty
        `shouldBe` Left AwsStackReceiptEmptyInput
      renderAwsStackEvidenceError AwsStackReceiptEmptyInput
        `shouldSatisfy` Text.isInfixOf "EMPTY-INPUT-RECEIPT-ACCEPTED-AS-PROVIDER-EVIDENCE-2026-10-15"
    it "refuses a recorded identity absent from the provider and names it" $ do
      let missing = if validation == AwsEksValidation then "subnet-a" else "i-fixture-1"
          audit =
            withRows
              validation
              (filter ((/= missing) . auditRowIdentity) (rowsFor validation))
              AuditControlSeen
              Nothing
      case assertAwsStackCreateEvidence validation (outputsFor validation) (captured validation audit) of
        Left err@(AwsStackRecordedIdentityMissing _ identity) -> do
          identity `shouldBe` missing
          renderAwsStackEvidenceError err `shouldSatisfy` Text.isInfixOf missing
        other -> expectationFailure (show other)
    it "refuses an unanswered unrelated class even while the verdict is Residue" $ do
      let audit = withRows validation (rowsFor validation) AuditControlSeen (Just AuditNetworkInterface)
      auditVerdict (fieldAuditObservation audit) `shouldSatisfy` isResidue
      assertAwsStackCreateEvidence validation (outputsFor validation) (captured validation audit)
        `shouldBe` Left AwsStackReportIncomplete
    it "requires a positive control even while all recorded identities are present" $ do
      let audit = withRows validation (rowsFor validation) AuditControlMissing Nothing
      assertAwsStackCreateEvidence validation (outputsFor validation) (captured validation audit)
        `shouldBe` Left AwsStackReportIncomplete
    it "does not mistake Clean for proof that the newly created stack is present" $ do
      let audit = withRows validation [] AuditControlSeen Nothing
      assertAwsStackCreateEvidence validation (outputsFor validation) (captured validation audit)
        `shouldBe` Left AwsStackReportIncomplete
    it "requires exact ready states and does not accept a state containing ACTIVE or running" $ do
      let class' = if validation == AwsEksValidation then AuditEksCluster else AuditInstance
          notReady row = if auditRowClass row == class' then row {auditRowDetail = "NOT_ACTIVE_running"} else row
          audit = withRows validation (map notReady (rowsFor validation)) AuditControlSeen Nothing
      assertAwsStackCreateEvidence validation (outputsFor validation) (captured validation audit)
        `shouldSatisfy` isNotReady
    it "preserves a failing create command instead of using its apparent success text" $ do
      let output = (captured validation (complete validation)) {processExitCode = ExitFailure 5}
      assertAwsStackCreateEvidence validation (outputsFor validation) output
        `shouldBe` Left (AwsStackCommandFailed (ExitFailure 5))
    it "stops before fetching recorded outputs when the report cannot prove presence" $ do
      outputReads <- newIORef (0 :: Int)
      let boundary =
            AwsStackValidationBoundary
              { reconcileValidationStack =
                  const (pure (Right (captured validation (withRows validation [] AuditControlSeen Nothing))))
              , readValidationStackOutputs = \_ -> modifyIORef' outputReads (+ 1) >> pure (Right (outputsFor validation))
              }
      runAwsStackEvidenceValidation boundary validation >>= (`shouldBe` Left AwsStackReportIncomplete)
      readIORef outputReads >>= (`shouldBe` 0)
  it
    "carries real producer readiness through bounded Provider evidence, its renderer and the consumer"
    $ do
      recording <- loadReadinessRecording
      let world =
            Model.plant
              AuditEksNodeGroup
              awsEksProvisionedNodeGroupName
              []
              True
              ( Model.plant
                  AuditEksCluster
                  awsEksProvisionedClusterName
                  []
                  True
                  ( Model.plant
                      AuditSecurityGroup
                      "sg-fixture"
                      []
                      False
                      ( Model.plant
                          AuditSubnet
                          "subnet-a"
                          []
                          False
                          (Model.plant AuditSubnet "subnet-b" [] False (Model.withVpc Model.emptyWorld))
                      )
                  )
              )
          ref = Model.refFor "aws-eks"
          config = Model.configFor "aws-eks"
          target = must (mkProviderStackRef "aws-eks" >>= \stack -> mkProviderAuditTarget stack Nothing)
          control = must (mkProviderAuditControl "fixture-state" Nothing)
          intent = ObserveAwsAudit target config control
      issued <- newIORef []
      let runner = AwsNativeStackFamilyRunner $ \args -> do
            modifyIORef' issued (<> [args])
            pure (recordedReadinessResponse recording RecordedActive world args)
      taken <- auditStackField runner ref config
      let (_, answers) = must taken
          observation = must (mkAuditObservation AuditAwsEks answers AuditControlSeen)
          encoded = must (encodeAwsAuditEvidence (providerIntentEvidenceBound intent) ref observation)
          (binding, decoded) = must (decodeAwsAuditEvidence AuditAwsEks (providerEvidenceText encoded))
          audit = FieldAudit AuditAwsEks binding decoded
          recorded = Map.insert "vpc_id" Model.vpcId eksOutputs
      assertAwsStackCreateEvidence AwsEksValidation recorded (captured AwsEksValidation audit)
        `shouldBe` Right ()
      commands <- readIORef issued
      map Model.queryOf commands
        `shouldContain` ["{arn:cluster.arn,status:cluster.status}", "{arn:nodegroup.nodegroupArn,status:nodegroup.status}"]
  it "recognizes the installed CLI's exact missing-resource responses as answered empty classes" $ do
    recording <- loadReadinessRecording
    observation <- recordedObservation recording RecordedMissing id
    auditVerdict observation `shouldBe` AuditClean
  it
    "accepts legacy and measured retry headers without accepting ambiguous or malformed service errors"
    $ do
      recording <- loadReadinessRecording
      let original =
            recordedReadinessResponse
              recording
              RecordedMissing
              Model.emptyWorld
              ["--query", "{arn:cluster.arn,status:cluster.status}"]
          rewrite change = original {processStderr = Text.unpack (change (Text.pack (processStderr original)))}
          matches = awsCliServiceErrorMatches "ResourceNotFoundException" "DescribeCluster"
          bare =
            rewrite
              (Text.replace "aws: [ERROR]: " "" . Text.replace " operation (reached max retries: 0):" " operation:")
          anotherRetry = rewrite (Text.replace "max retries: 0" "max retries: 2")
      mapM_ (\output -> matches output `shouldBe` True) [original, bare, anotherRetry]
      mapM_
        (\output -> matches output `shouldBe` False)
        [ original {processExitCode = ExitSuccess}
        , original {processStdout = processStderr original, processStderr = ""}
        , original {processStderr = processStderr original <> processStderr original}
        , rewrite (Text.replace "max retries: 0" "max retries: -1")
        , rewrite (Text.replace "max retries: 0" "max retries: ")
        , rewrite (Text.replace "DescribeCluster operation" "DescribeNodegroup operation")
        , rewrite (Text.replace "ResourceNotFoundException" "AccessDeniedException")
        , rewrite (Text.replace "aws: [ERROR]: " "unknown-wrapper: ")
        , original {processStderr = replicate (16 * 1024 + 1) 'x'}
        ]
  it "uses the same measured missing response at the native cluster-absence boundary" $ do
    recording <- loadReadinessRecording
    let response =
          recordedReadinessResponse
            recording
            RecordedMissing
            Model.emptyWorld
            ["--query", "{arn:cluster.arn,status:cluster.status}"]
    observed <- observeEksClusterAbsent (AwsNativeStackFamilyRunner (const (pure response)))
    observed `shouldBe` Right True
  it "keeps denied, mismatched, malformed and wrong-service readiness reads unobservable" $ do
    recording <- loadReadinessRecording
    let denied output =
          output
            { processStderr =
                Text.unpack
                  (Text.replace "ResourceNotFoundException" "AccessDeniedException" (Text.pack (processStderr output)))
            }
        wrongService output =
          output
            { processStderr =
                Text.unpack (Text.replace "when calling the" "when refusing the" (Text.pack (processStderr output)))
            }
        malformed output = output {processStdout = "{}"}
        wrongAccount output =
          output
            { processStdout =
                Text.unpack (Text.replace ":123456789012:" ":111122223333:" (Text.pack (processStdout output)))
            }
    mapM_
      ( \(mode, transform) ->
          recordedObservation recording mode transform
            >>= (\observation -> auditVerdict observation `shouldSatisfy` isUnobservable)
      )
      [ (RecordedMissing, denied)
      , (RecordedMissing, wrongService)
      , (RecordedActive, malformed)
      , (RecordedActive, wrongAccount)
      ]
  it "refuses a node group with a neighboring name even when its prefix matches" $ do
    let changed row =
          if auditRowClass row == AuditEksNodeGroup
            then
              row
                { auditRowIdentity =
                    "nodegroup/"
                      <> awsEksProvisionedClusterName
                      <> "/"
                      <> awsEksProvisionedNodeGroupName
                      <> "-other/nonce"
                }
            else row
        audit = withRows AwsEksValidation (map changed (rowsFor AwsEksValidation)) AuditControlSeen Nothing
    assertAwsStackCreateEvidence AwsEksValidation eksOutputs (captured AwsEksValidation audit)
      `shouldSatisfy` isMissing
  it "requires the node group to be ACTIVE independently of the cluster" $ do
    let changed row = if auditRowClass row == AuditEksNodeGroup then row {auditRowDetail = "CREATING"} else row
        audit = withRows AwsEksValidation (map changed (rowsFor AwsEksValidation)) AuditControlSeen Nothing
    assertAwsStackCreateEvidence AwsEksValidation eksOutputs (captured AwsEksValidation audit)
      `shouldSatisfy` isNotReady
  it "refuses truncated required rows rather than counting them as observed" $ do
    let full = complete AwsEksValidation
        observation = fieldAuditObservation full
        answers = Map.toList (auditObservationAnswers observation)
        hidden =
          [ (class', if class' == AuditSubnet then auditWithOmitted 2 (auditAnswered []) else answer)
          | (class', answer) <- answers
          ]
        audit = full {fieldAuditObservation = must (mkAuditObservation AuditAwsEks hidden AuditControlSeen)}
    assertAwsStackCreateEvidence AwsEksValidation eksOutputs (captured AwsEksValidation audit)
      `shouldSatisfy` isMissing
  it "refuses a field from another stack, duplicate headers, contradictory counts and unknown rows" $ do
    let original = captured AwsEksValidation (complete AwsEksValidation)
        text = Text.pack (processStdout original)
        header = case renderFieldAuditReport (complete AwsEksValidation) of
          first : _ -> first
          [] -> error "fixture producer has no header"
        changes =
          [ Text.replace "AWS_FIELD aws-eks " "AWS_FIELD aws-test " text
          , text <> header <> "\n"
          , Text.replace "class=subnet count=2" "class=subnet count=3" text
          , text <> "AWS_FIELD aws-eks mystery opaque\n"
          , Text.replace "control=seen" "control=unanswered (denied)" text
          ]
    mapM_
      ( \changed ->
          assertAwsStackCreateEvidence
            AwsEksValidation
            eksOutputs
            original {processStdout = Text.unpack changed}
            `shouldSatisfy` isLeft
      )
      changes
  it "refuses duplicate receipts and preserves the three-node recorded topology requirement" $ do
    let original = captured PulumiValidation (complete PulumiValidation)
        duplicate =
          original
            { processStdout =
                processStdout original <> Text.unpack (receiptFor PulumiValidation <> "sha256:" <> digest <> "\n")
            }
    assertAwsStackCreateEvidence PulumiValidation testOutputs duplicate
      `shouldBe` Left AwsStackReceiptInvalid
    assertAwsStackCreateEvidence PulumiValidation (Map.insert "nodes" "[]" testOutputs) original
      `shouldSatisfy` isLeft

legacyPrefixAccepted :: AwsStackValidation -> ProcessOutput -> Bool
legacyPrefixAccepted validation output =
  processExitCode output == ExitSuccess
    && (receiptFor validation <> "sha256:") `Text.isInfixOf` Text.pack (processStdout output)

captured :: AwsStackValidation -> FieldAudit -> ProcessOutput
captured validation audit =
  ProcessOutput
    { processExitCode = ExitSuccess
    , processStdout =
        Text.unpack
          (Text.unlines ((receiptFor validation <> "sha256:" <> digest) : renderFieldAuditReport audit))
    , processStderr = ""
    }

receiptFor :: AwsStackValidation -> Text
receiptFor validation = Text.pack $ case validation of
  AwsEksValidation -> Eks.awsEksProviderReceiptLabel
  PulumiValidation -> Test.awsTestProviderReceiptLabel
  HaRke2AwsValidation -> Test.awsTestProviderReceiptLabel

stackFor :: AwsStackValidation -> AuditStack
stackFor validation = case validation of
  AwsEksValidation -> AuditAwsEks
  PulumiValidation -> AuditAwsTest
  HaRke2AwsValidation -> AuditAwsTest

complete :: AwsStackValidation -> FieldAudit
complete validation = withRows validation (rowsFor validation) AuditControlSeen Nothing

withRows :: AwsStackValidation -> [AuditRow] -> AuditControl -> Maybe AuditClass -> FieldAudit
withRows validation rows control missing =
  FieldAudit
    stack
    (AuditBinding "123456789012" (Text.pack (fixtureAwsRegion FixtureCaCentral1)))
    observation
 where
  stack = stackFor validation
  observation =
    must
      (mkAuditObservation stack [(class', answer class') | class' <- auditStackClasses stack] control)
  answer class' = case missing of
    Just gap | gap == class' -> auditPartial (inClass class') "AccessDenied"
    _ -> auditAnswered (inClass class')
  inClass class' = [row | row <- rows, auditRowClass row == class']

rowsFor :: AwsStackValidation -> [AuditRow]
rowsFor validation =
  [ mkAuditRow AuditVpc "vpc-fixture" ""
  , mkAuditRow AuditSubnet "subnet-a" "available"
  , mkAuditRow AuditSubnet "subnet-b" "available"
  , mkAuditRow AuditSecurityGroup "sg-fixture" ""
  ]
    <> case validation of
      AwsEksValidation ->
        [ mkAuditRow AuditEksCluster ("cluster/" <> awsEksProvisionedClusterName) "ACTIVE"
        , mkAuditRow
            AuditEksNodeGroup
            ("nodegroup/" <> awsEksProvisionedClusterName <> "/" <> awsEksProvisionedNodeGroupName <> "/12345678")
            "ACTIVE"
        ]
      _ ->
        [ mkAuditRow AuditInstance ("i-fixture-" <> Text.pack (show index)) "running"
        | index <- [1 :: Int .. 3]
        ]

outputsFor :: AwsStackValidation -> Map.Map Text Text
outputsFor validation = case validation of
  AwsEksValidation -> eksOutputs
  _ -> testOutputs

eksOutputs :: Map.Map Text Text
eksOutputs =
  Map.fromList
    [ ("backend_bucket", "fixture-state")
    , ("cluster_name", awsEksProvisionedClusterName)
    , ("cluster_role_name", "cluster-role")
    , ("node_group_name", awsEksProvisionedNodeGroupName)
    , ("node_role_name", "node-role")
    , ("vpc_id", "vpc-fixture")
    , ("subnet_ids", "[\"subnet-a\",\"subnet-b\"]")
    , ("cluster_security_group_id", "sg-fixture")
    , ("cluster_oidc_issuer", "https://oidc.example.test")
    , ("oidc_provider_arn", "arn:aws:iam::123456789012:oidc-provider/example")
    , ("aws_lb_controller_policy_arn", "arn:aws:iam::123456789012:policy/lbc")
    , ("aws_lb_controller_role_arn", "arn:aws:iam::123456789012:role/lbc")
    , ("aws_lb_controller_role_name", "lbc")
    , ("retained_ebs_availability_zone", Text.pack (fixtureAwsRegion FixtureCaCentral1) <> "a")
    ]

testOutputs :: Map.Map Text Text
testOutputs =
  Map.fromList
    [ ("backend_bucket", "fixture-state")
    , ("vpc_id", "vpc-fixture")
    , ("subnet_ids", "[\"subnet-a\",\"subnet-b\"]")
    , ("security_group_id", "sg-fixture")
    , ("nodes", jsonText (toJSONNodes [1 .. 3]))
    ]
 where
  toJSONNodes :: [Int] -> Value
  toJSONNodes indices =
    Array
      ( fromListValues
          [ object
              [ "name" .= ("node-" <> Text.pack (show index))
              , "availability_zone" .= (Text.pack (fixtureAwsRegion FixtureCaCentral1) <> "a")
              , "instance_id" .= ("i-fixture-" <> Text.pack (show index))
              , "private_ip" .= ("10.0.0.1" :: Text)
              , "public_ip" .= ("203.0.113.1" :: Text)
              ]
          | index <- indices
          ]
      )

fromListValues :: [Value] -> Data.Vector.Vector Value
fromListValues = Data.Vector.fromList

jsonText :: Value -> Text
jsonText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

digest :: Text
digest = Text.replicate 64 "a"

emptyDigest :: Text
emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

isResidue :: AuditVerdict -> Bool
isResidue verdict = case verdict of AuditResidue _ -> True; _ -> False

isNotReady :: Either AwsStackEvidenceError () -> Bool
isNotReady result = case result of Left AwsStackRecordedIdentityNotReady {} -> True; _ -> False

isMissing :: Either AwsStackEvidenceError () -> Bool
isMissing result = case result of Left AwsStackRecordedIdentityMissing {} -> True; _ -> False

must :: (Show error) => Either error value -> value
must = either (error . show) id

-- Recording scope: installed AWS CLI over synthetic unsigned loopback HTTP.
-- This verifies CLI projections/error framing, not live AWS service behavior.
newtype ReadinessRecording = ReadinessRecording (Map.Map Text RecordedCommand)

data RecordedCommand = RecordedCommand Int String String

instance FromJSON ReadinessRecording where
  parseJSON = withObject "readiness recording" decodeRecording
   where
    decodeRecording fields = ReadinessRecording <$> fields .: "cases"

instance FromJSON RecordedCommand where
  parseJSON = withObject "recorded CLI result" decodeCommand
   where
    decodeCommand fields = RecordedCommand <$> fields .: "exit_code" <*> fields .: "stdout" <*> fields .: "stderr"

data RecordedMode = RecordedActive | RecordedMissing

loadReadinessRecording :: IO ReadinessRecording
loadReadinessRecording = must . eitherDecodeStrict' <$> ByteString.readFile "test/fixtures/aws-eks-readiness-cli.json"

recordedReadinessResponse
  :: ReadinessRecording -> RecordedMode -> Model.World -> [String] -> ProcessOutput
recordedReadinessResponse (ReadinessRecording recording) mode world args = case Model.queryOf args of
  "{arn:cluster.arn,status:cluster.status}" -> result (select "cluster_active" "cluster_missing")
  "{arn:nodegroup.nodegroupArn,status:nodegroup.status}" -> result (select "nodegroup_active" "nodegroup_missing")
  _ -> Model.respond world args
 where
  select active missing = case mode of RecordedActive -> active; RecordedMissing -> missing
  result key = case Map.lookup key recording of
    Just (RecordedCommand code output diagnostic) -> ProcessOutput (if code == 0 then ExitSuccess else ExitFailure code) output diagnostic
    Nothing -> error "readiness recording has no required CLI case"

recordedObservation
  :: ReadinessRecording -> RecordedMode -> (ProcessOutput -> ProcessOutput) -> IO AuditObservation
recordedObservation recording mode transform = do
  let runner = AwsNativeStackFamilyRunner $ \args -> pure (mapReadiness args)
      mapReadiness args = case Model.queryOf args of
        "{arn:cluster.arn,status:cluster.status}" -> transform (response args)
        "{arn:nodegroup.nodegroupArn,status:nodegroup.status}" -> transform (response args)
        _ -> response args
      response = recordedReadinessResponse recording mode Model.emptyWorld
  taken <- auditStackField runner (Model.refFor "aws-eks") (Model.configFor "aws-eks")
  let (_, answers) = must taken
  pure (must (mkAuditObservation AuditAwsEks answers AuditControlSeen))

isUnobservable :: AuditVerdict -> Bool
isUnobservable verdict = case verdict of AuditUnobservable {} -> True; _ -> False
