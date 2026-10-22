{-# LANGUAGE OverloadedStrings #-}

-- | Suite-owned consumers of the operator's provider-enumerated create report.
-- A successful child and a receipt are necessary; the complete field and the
-- recorded resource coordinates, rather than either label, establish presence.
module Prodbox.Test.AwsStackEvidence
  ( AwsStackValidation (..)
  , AwsStackValidationBoundary (..)
  , AwsStackEvidenceError (..)
  , runAwsStackEvidenceValidation
  , assertAwsStackCreateEvidence
  , renderAwsStackEvidenceError
  ) where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Char (isControl)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Infra.AwsEksTestStack qualified as Eks
import Prodbox.Infra.AwsFieldAudit (FieldAudit (..), renderFieldAuditReport)
import Prodbox.Infra.AwsTestStack qualified as Test
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding (..))
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (validRegionText)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

data AwsStackValidation = AwsEksValidation | PulumiValidation | HaRke2AwsValidation
  deriving (Eq, Show, Enum, Bounded)

data AwsStackValidationBoundary m = AwsStackValidationBoundary
  { reconcileValidationStack :: AuditStack -> m (Either Text ProcessOutput)
  , readValidationStackOutputs :: AuditStack -> m (Either Text (Map.Map Text Text))
  }

data AwsStackEvidenceError
  = AwsStackCommandUnavailable !Text
  | AwsStackCommandFailed !ExitCode
  | AwsStackReceiptEmptyInput
  | AwsStackReceiptInvalid
  | AwsStackReportInvalid !Text
  | AwsStackReportIncomplete
  | AwsStackRecordedOutputsInvalid !Text
  | AwsStackRecordedIdentityMissing !AuditClass !Text
  | AwsStackRecordedIdentityNotReady !AuditClass !Text !Text
  deriving (Eq, Show)

runAwsStackEvidenceValidation
  :: (Monad m)
  => AwsStackValidationBoundary m
  -> AwsStackValidation
  -> m (Either AwsStackEvidenceError ())
runAwsStackEvidenceValidation boundary validation = do
  captured <- reconcileValidationStack boundary stack
  case first AwsStackCommandUnavailable captured >>= decodeCreateReport validation of
    Left err -> pure (Left err)
    Right audit -> do
      recorded <- readValidationStackOutputs boundary stack
      pure $ do
        outputs <- first AwsStackRecordedOutputsInvalid recorded
        expected <- expectedIdentities validation outputs
        checkIdentities audit expected
 where
  stack = validationStack validation

assertAwsStackCreateEvidence
  :: AwsStackValidation
  -> Map.Map Text Text
  -> ProcessOutput
  -> Either AwsStackEvidenceError ()
assertAwsStackCreateEvidence validation outputs captured = do
  audit <- decodeCreateReport validation captured
  expected <- expectedIdentities validation outputs
  checkIdentities audit expected

validationStack :: AwsStackValidation -> AuditStack
validationStack validation = case validation of
  AwsEksValidation -> AuditAwsEks
  PulumiValidation -> AuditAwsTest
  HaRke2AwsValidation -> AuditAwsTest

receiptLabel :: AwsStackValidation -> Text
receiptLabel validation = Text.pack $ case validation of
  AwsEksValidation -> Eks.awsEksProviderReceiptLabel
  PulumiValidation -> Test.awsTestProviderReceiptLabel
  HaRke2AwsValidation -> Test.awsTestProviderReceiptLabel

decodeCreateReport :: AwsStackValidation -> ProcessOutput -> Either AwsStackEvidenceError FieldAudit
decodeCreateReport validation captured = do
  unless
    (processExitCode captured == ExitSuccess)
    (Left (AwsStackCommandFailed (processExitCode captured)))
  let output = Text.pack (processStdout captured)
      receipts =
        [ suffix | line <- Text.lines output, Just suffix <- [Text.stripPrefix (receiptLabel validation) line]
        ]
  case receipts of
    [receipt]
      | receipt == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ->
          Left AwsStackReceiptEmptyInput
      | Just digest <- Text.stripPrefix "sha256:" receipt
      , Text.length digest == 64
      , Text.all (`elem` ("0123456789abcdef" :: String)) digest ->
          Right ()
    _ -> Left AwsStackReceiptInvalid
  audit <- first AwsStackReportInvalid (parseFieldReport (validationStack validation) output)
  let observation = fieldAuditObservation audit
  unless
    ( auditObservationControl observation == AuditControlSeen
        && all ((== Nothing) . auditAnswerGap) (Map.elems (auditObservationAnswers observation))
    )
    (Left AwsStackReportIncomplete)
  case auditVerdict observation of
    AuditResidue _ -> Right audit
    _ -> Left AwsStackReportIncomplete

data ExpectedIdentity
  = ExactIdentity !AuditClass !Text !(Maybe Text)
  | NodeGroupIdentity !Text !Text

expectedIdentities
  :: AwsStackValidation -> Map.Map Text Text -> Either AwsStackEvidenceError [ExpectedIdentity]
expectedIdentities validation outputs = case validation of
  AwsEksValidation -> do
    snapshot <-
      first (AwsStackRecordedOutputsInvalid . Text.pack) (Eks.parseAwsEksTestStackFromOutputs outputs)
    subnets <- coordinates "subnets" (map Text.pack (Eks.eksSnapshotSubnetIds snapshot))
    vpc <- coordinate (Text.pack (Eks.eksSnapshotVpcId snapshot))
    group <- coordinate (Text.pack (Eks.eksSnapshotClusterSecurityGroupId snapshot))
    cluster <- coordinate (Text.pack (Eks.eksSnapshotClusterName snapshot))
    nodes <- coordinate (Text.pack (Eks.eksSnapshotNodeGroupName snapshot))
    Right
      ( [ExactIdentity AuditVpc vpc Nothing, ExactIdentity AuditSecurityGroup group Nothing]
          <> map (\name -> ExactIdentity AuditSubnet name Nothing) subnets
          <> [ ExactIdentity AuditEksCluster ("cluster/" <> cluster) (Just "ACTIVE")
             , NodeGroupIdentity cluster nodes
             ]
      )
  PulumiValidation -> testIdentities
  HaRke2AwsValidation -> testIdentities
 where
  testIdentities = do
    snapshot <-
      first (AwsStackRecordedOutputsInvalid . Text.pack) (Test.parseAwsTestStackFromOutputs outputs)
    unless
      (length (Test.testSnapshotNodes snapshot) == 3)
      (Left (AwsStackRecordedOutputsInvalid "expected the recorded three-node topology"))
    instances <-
      coordinates
        "instances"
        (map (Text.pack . Test.testNodeInstanceId) (Test.testSnapshotNodes snapshot))
    subnets <- coordinates "subnets" (map Text.pack (Test.testSnapshotSubnetIds snapshot))
    vpc <- coordinate (Text.pack (Test.testSnapshotVpcId snapshot))
    group <- coordinate (Text.pack (Test.testSnapshotSecurityGroupId snapshot))
    Right
      ( [ExactIdentity AuditVpc vpc Nothing, ExactIdentity AuditSecurityGroup group Nothing]
          <> map (\name -> ExactIdentity AuditSubnet name Nothing) subnets
          <> map (\name -> ExactIdentity AuditInstance name (Just "running")) instances
      )
  coordinate value
    | Text.null value || Text.any (\char -> isControl char || char == ' ') value =
        Left (AwsStackRecordedOutputsInvalid "recorded resource coordinate is empty or malformed")
    | otherwise = Right value
  coordinates label values = do
    checked <- traverse coordinate values
    unless
      (not (null checked) && length checked == length (nub checked))
      (Left (AwsStackRecordedOutputsInvalid ("recorded " <> label <> " are empty or duplicated")))
    Right checked

checkIdentities :: FieldAudit -> [ExpectedIdentity] -> Either AwsStackEvidenceError ()
checkIdentities audit = mapM_ check
 where
  rows = auditRows (fieldAuditObservation audit)
  check expected = case expected of
    ExactIdentity class' identity ready -> require class' identity ((== identity) . auditRowIdentity) ready
    NodeGroupIdentity cluster name ->
      require
        AuditEksNodeGroup
        ("nodegroup/" <> cluster <> "/" <> name)
        (nodeGroupMatches cluster name . auditRowIdentity)
        (Just "ACTIVE")
  require class' identity matches ready = case [row | row <- rows, auditRowClass row == class', matches row] of
    [row] -> case ready of
      Nothing -> Right ()
      Just state
        | auditRowDetail row == state -> Right ()
        | otherwise -> Left (AwsStackRecordedIdentityNotReady class' identity state)
    _ -> Left (AwsStackRecordedIdentityMissing class' identity)
  -- The provider supplies the node group's generated ARN suffix. Its exact
  -- cluster/name segments are the recorded coordinate; a prefix match is not.
  nodeGroupMatches cluster name value = case Text.splitOn "/" value of
    ["nodegroup", observedCluster, observedName, suffix] ->
      observedCluster == cluster && observedName == name && not (Text.null suffix)
    _ -> False

data ReportRow
  = HeaderRow !AuditBinding
  | VerdictRow
  | ControlRow !AuditControl
  | CountRow !AuditClass !Natural
  | ResourceRow !AuditRow
  | OmittedRow !AuditClass !Natural
  | GapRow !AuditClass !Text

parseFieldReport :: AuditStack -> Text -> Either Text FieldAudit
parseFieldReport stack output = do
  unless (Text.length output <= 128 * 1024) (Left "create output exceeds the validation report bound")
  let lines' = [line | line <- Text.lines output, "AWS_FIELD " `Text.isPrefixOf` line]
  unless
    (length lines' <= 3 + 23 * length (auditStackClasses stack))
    (Left "too many field report rows")
  rows <- traverse parseLine lines'
  binding <- single "account/region binding" [value | HeaderRow value <- rows]
  control <- single "positive control" [value | ControlRow value <- rows]
  _ <- single "verdict" [() | VerdictRow <- rows]
  unique "class count" [class' | CountRow class' _ <- rows]
  unique "omission" [class' | OmittedRow class' _ <- rows]
  unique "unanswered class" [class' | GapRow class' _ <- rows]
  unique "resource identity" [(auditRowClass row, auditRowIdentity row) | ResourceRow row <- rows]
  let answer class' =
        let found = [row | ResourceRow row <- rows, auditRowClass row == class']
            answered = case lookup class' [(key, gap) | GapRow key gap <- rows] of
              Nothing -> auditAnswered found
              Just gap -> auditPartial found gap
         in auditWithOmitted (maybe 0 id (lookup class' [(key, total) | OmittedRow key total <- rows])) answered
  observation <-
    first
      (const "field report has an invalid class")
      (mkAuditObservation stack [(class', answer class') | class' <- auditStackClasses stack] control)
  let audit = FieldAudit stack binding observation
  unless
    (renderFieldAuditReport audit == lines')
    (Left "field report is incomplete, contradictory or noncanonical")
  Right audit
 where
  parseLine line = do
    body <-
      maybe
        (Left "field report names another stack")
        Right
        (Text.stripPrefix ("AWS_FIELD " <> auditStackLabel stack <> " ") line)
    case Text.words body of
      [account, region]
        | Just accountId <- Text.stripPrefix "account=" account
        , Just regionName <- Text.stripPrefix "region=" region
        , Text.length accountId == 12
        , Text.all (`elem` ("0123456789" :: String)) accountId
        , validRegionText regionName ->
            Right (HeaderRow (AuditBinding accountId regionName))
      ["verdict=Clean"] -> Right VerdictRow
      ["verdict=Residue"] -> Right VerdictRow
      ["verdict=Unobservable"] -> Right VerdictRow
      ["control=seen"] -> Right (ControlRow AuditControlSeen)
      ["control=missing"] -> Right (ControlRow AuditControlMissing)
      [classWord, countWord]
        | Just label <- Text.stripPrefix "class=" classWord
        , Just total <- Text.stripPrefix "count=" countWord ->
            CountRow <$> classOf label <*> natural total
      _ -> parseOther body
  parseOther body
    | Just detail <- Text.stripPrefix "control=unanswered " body =
        ControlRow . AuditControlUnanswered <$> parenthesized detail
    | Just detail <- Text.stripPrefix "unanswered=" body = do
        let (label, reason) = Text.breakOn " " detail
        GapRow <$> classOf label <*> parenthesized (Text.drop 1 reason)
    | otherwise = do
        let (label, remainder) = Text.breakOn " " body
            value = Text.drop 1 remainder
        class' <- classOf label
        case Text.stripPrefix "omitted=" value of
          Just total -> OmittedRow class' <$> natural total
          Nothing ->
            let (identity, detail) = Text.breakOn " " value
             in if Text.null identity
                  then Left "field report resource has no identity"
                  else Right (ResourceRow (mkAuditRow class' identity (Text.drop 1 detail)))
  classOf label = case auditClassFromLabel label of
    Just class' | class' `elem` auditStackClasses stack -> Right class'
    _ -> Left "field report names an unknown class"
  parenthesized value =
    maybe
      (Left "field report reason is malformed")
      Right
      (Text.stripPrefix "(" value >>= Text.stripSuffix ")")
  natural value
    | Text.null value || Text.length value > 20 || not (Text.all (`elem` ("0123456789" :: String)) value) =
        Left "field report count is malformed"
    | otherwise = maybe (Left "field report count is malformed") Right (readMaybe (Text.unpack value))
  single label values = case values of
    [value] -> Right value
    _ -> Left ("field report has no single " <> label)
  unique label values = unless (length values == length (nub values)) (Left ("field report repeats a " <> label))

renderAwsStackEvidenceError :: AwsStackEvidenceError -> Text
renderAwsStackEvidenceError err = case err of
  AwsStackCommandUnavailable detail -> "stack reconcile could not run: " <> detail
  AwsStackCommandFailed code -> "stack reconcile failed: " <> Text.pack (show code)
  AwsStackReceiptEmptyInput -> "EMPTY-INPUT-RECEIPT-ACCEPTED-AS-PROVIDER-EVIDENCE-2026-10-15: receipt hashes empty input"
  AwsStackReceiptInvalid -> "stack reconcile has no single nonempty canonical Provider receipt"
  AwsStackReportInvalid detail -> "provider field report refused: " <> detail
  AwsStackReportIncomplete -> "provider field is incomplete or supplies no positive stack-presence evidence"
  AwsStackRecordedOutputsInvalid detail -> "recorded stack outputs refused: " <> detail
  AwsStackRecordedIdentityMissing class' identity -> "provider did not observe recorded " <> auditClassLabel class' <> " " <> identity
  AwsStackRecordedIdentityNotReady class' identity state -> "recorded " <> auditClassLabel class' <> " " <> identity <> " is not " <> state
