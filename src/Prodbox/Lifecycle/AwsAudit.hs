{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The provider-enumerated verdict on one stack's declared field.
--
-- Completion on AWS used to be a statement about bookkeeping: a Pulumi child
-- exited zero and the stack no longer selected, and neither step looked at the
-- provider. A resource the checkpoint never held, such as a network interface a
-- controller attached after the plan was confirmed, was outside the verdict. An
-- audit is the missing instrument. It takes an inventory over a field declared
-- before the query runs (the classes a stack's resources fall into), requires a
-- positive control to appear, and licenses absence for that field and for no
-- other. It never selects what to destroy.
--
-- The verdict is one of three, and an unanswered query is never an empty class:
--
-- * 'AuditClean' -- every class was answered, the control appeared, and no class
--   holds a row.
-- * 'AuditResidue' -- some class holds a row. This is a refutation and stands
--   even if other queries went unanswered.
-- * 'AuditUnobservable' -- no row was found, but a query was not answered or the
--   control did not appear, so the catalog may be blind. A blind catalog and an
--   empty one return the same rows, which is why the control exists.
--
-- Raw identifiers are for the operator's standard output. What a run leaves
-- behind ('AuditRecord') holds counts and class labels only, and the type has
-- no field a raw identifier could be put in.
module Prodbox.Lifecycle.AwsAudit
  ( AuditStack (..)
  , auditStackOfRef
  , auditStackLabel
  , auditStackClasses
  , AuditClass (..)
  , auditClassLabel
  , auditClassFromLabel
  , AuditRow (..)
  , mkAuditRow
  , AuditAnswer
  , auditAnswerRows
  , auditAnswerOmitted
  , auditAnswerGap
  , auditAnswered
  , auditUnanswered
  , auditPartial
  , auditWithOmitted
  , mergeAuditAnswers
  , AuditControl (..)
  , AuditObservation
  , auditObservationStack
  , auditObservationAnswers
  , auditObservationControl
  , AuditObservationError (..)
  , mkAuditObservation
  , AuditVerdict (..)
  , auditVerdict
  , auditVerdictLabel
  , auditExitCode
  , auditRows
  , renderAuditReport
  , AuditRecord
  , auditRecord
  , encodeAuditRecord
  , AuditDiff (..)
  , diffAuditObservations
  , renderAuditDiff
  , sanitizeAuditText
  )
where

import Data.Char (GeneralCategory (Control, Format), generalCategory)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import System.Exit (ExitCode (..))

-- | The stacks whose field an audit can take.
data AuditStack
  = AuditAwsTest
  | AuditAwsEks
  | AuditAwsEksSubzone
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The audit stack a registered stack name selects.
auditStackOfRef :: Text -> Maybe AuditStack
auditStackOfRef name = case name of
  "aws-test" -> Just AuditAwsTest
  "aws-eks" -> Just AuditAwsEks
  "aws-eks-subzone" -> Just AuditAwsEksSubzone
  _ -> Nothing

auditStackLabel :: AuditStack -> Text
auditStackLabel stack = case stack of
  AuditAwsTest -> "aws-test"
  AuditAwsEks -> "aws-eks"
  AuditAwsEksSubzone -> "aws-eks-subzone"

-- | What an audit can find, one class per kind of resource the field names.
data AuditClass
  = AuditVpc
  | AuditSubnet
  | AuditRouteTable
  | AuditInternetGateway
  | AuditSecurityGroup
  | AuditNetworkInterface
  | AuditNatGateway
  | AuditVpcEndpoint
  | AuditInstance
  | AuditLoadBalancer
  | AuditEksCluster
  | AuditEksNodeGroup
  | AuditEksAddon
  | AuditOidcProvider
  | AuditIamRole
  | AuditIamPolicy
  | AuditEbsVolume
  | AuditHostedZone
  | AuditDelegationRecord
  deriving stock (Eq, Ord, Show, Enum, Bounded)

auditClassLabel :: AuditClass -> Text
auditClassLabel class' = case class' of
  AuditVpc -> "vpc"
  AuditSubnet -> "subnet"
  AuditRouteTable -> "route-table"
  AuditInternetGateway -> "internet-gateway"
  AuditSecurityGroup -> "security-group"
  AuditNetworkInterface -> "network-interface"
  AuditNatGateway -> "nat-gateway"
  AuditVpcEndpoint -> "vpc-endpoint"
  AuditInstance -> "instance"
  AuditLoadBalancer -> "load-balancer"
  AuditEksCluster -> "eks-cluster"
  AuditEksNodeGroup -> "eks-node-group"
  AuditEksAddon -> "eks-add-on"
  AuditOidcProvider -> "oidc-provider"
  AuditIamRole -> "iam-role"
  AuditIamPolicy -> "iam-policy"
  AuditEbsVolume -> "ebs-volume"
  AuditHostedZone -> "hosted-zone"
  AuditDelegationRecord -> "delegation-record"

-- | The class a label names, if any.
auditClassFromLabel :: Text -> Maybe AuditClass
auditClassFromLabel label =
  case [class' | class' <- [minBound .. maxBound], auditClassLabel class' == label] of
    class' : _ -> Just class'
    [] -> Nothing

-- | The classes a stack's declared field holds. Declared here, before any
-- query runs, so a class nobody queried is a gap and not an empty class.
auditStackClasses :: AuditStack -> [AuditClass]
auditStackClasses stack = case stack of
  AuditAwsTest -> networkClasses
  AuditAwsEks ->
    networkClasses
      <> [ AuditEksCluster
         , AuditEksNodeGroup
         , AuditEksAddon
         , AuditOidcProvider
         , AuditIamRole
         , AuditIamPolicy
         , AuditEbsVolume
         ]
  AuditAwsEksSubzone -> [AuditHostedZone, AuditDelegationRecord]
 where
  networkClasses =
    [ AuditVpc
    , AuditSubnet
    , AuditRouteTable
    , AuditInternetGateway
    , AuditSecurityGroup
    , AuditNetworkInterface
    , AuditNatGateway
    , AuditVpcEndpoint
    , AuditInstance
    , AuditLoadBalancer
    ]

-- | One resource the field held. The identity and the detail are the provider's
-- own words, so they are for the operator's screen and nothing durable.
data AuditRow = AuditRow
  { auditRowClass :: !AuditClass
  , auditRowIdentity :: !Text
  , auditRowDetail :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | A row whose free text cannot break a line or a field.
--
-- An ARN is kept by its resource part. The account and the region are the same
-- in every row of one inventory and travel once, in the binding, so the part
-- that tells two load balancers or two OIDC providers apart is the part kept;
-- cut to a fixed length from the front, every ARN of an account reads the same.
mkAuditRow :: AuditClass -> Text -> Text -> AuditRow
mkAuditRow class' identity detail =
  AuditRow
    { auditRowClass = class'
    , auditRowIdentity = sanitizeAuditText (resourcePart identity)
    , auditRowDetail = sanitizeAuditText detail
    }

-- | The resource part of an ARN, or the text itself when it is not one.
resourcePart :: Text -> Text
resourcePart identity = case Text.splitOn ":" identity of
  "arn" : _partition : _service : _region : _account : resource@(_ : _) ->
    Text.intercalate ":" resource
  _ -> identity

-- | The provider's text with control characters and field separators replaced
-- and its length bounded, so one description cannot become another row.
sanitizeAuditText :: Text -> Text
sanitizeAuditText =
  Text.take 160 . Text.map replace . Text.strip
 where
  -- A provider's text reaches the operator's terminal. Control characters (the
  -- C0 and C1 ranges and DEL) and format characters (bidirectional marks and
  -- the like) are replaced, so a name cannot steer the screen.
  replace character
    | generalCategory character `elem` [Control, Format] || character == '|' = ' '
    | otherwise = character

-- | What a class's queries returned: the rows they found, how many further rows
-- they found that are not carried (an answer that crossed a wire with room for
-- only so many), and, when a query did not answer, why. A class with rows and a
-- gap was partly answered: the rows stand as a refutation, and the gap stops the
-- class licensing absence.
data AuditAnswer = AuditAnswer
  { auditAnswerRows :: ![AuditRow]
  , auditAnswerOmitted :: !Natural
  , auditAnswerGap :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | A class every query of which answered.
auditAnswered :: [AuditRow] -> AuditAnswer
auditAnswered rows = AuditAnswer rows 0 Nothing

-- | A class no query of which answered.
auditUnanswered :: Text -> AuditAnswer
auditUnanswered = AuditAnswer [] 0 . Just . sanitizeAuditText

-- | A class some query of which answered.
auditPartial :: [AuditRow] -> Text -> AuditAnswer
auditPartial rows = AuditAnswer rows 0 . Just . sanitizeAuditText

-- | The same answer, with rows it found but does not carry.
auditWithOmitted :: Natural -> AuditAnswer -> AuditAnswer
auditWithOmitted omitted answer = answer {auditAnswerOmitted = omitted}

-- | The answer of a class that several queries cover: every row any of them
-- found, once, and a gap if any of them left one.
mergeAuditAnswers :: [AuditAnswer] -> AuditAnswer
mergeAuditAnswers answers =
  AuditAnswer
    { auditAnswerRows =
        Map.elems
          ( Map.fromListWith
              richer
              [((auditRowClass row, auditRowIdentity row), row) | row <- concatMap auditAnswerRows answers]
          )
    , auditAnswerOmitted = sum (map auditAnswerOmitted answers)
    , auditAnswerGap = case [gap | AuditAnswer _ _ (Just gap) <- answers] of
        [] -> Nothing
        gaps -> Just (Text.intercalate "; " gaps)
    }
 where
  -- The same resource seen by two queries is one row; keep the one that says more.
  richer new old
    | Text.null (auditRowDetail new) = old
    | otherwise = new

-- | Whether the positive control appeared in the catalog.
data AuditControl
  = AuditControlSeen
  | AuditControlMissing
  | AuditControlUnanswered !Text
  deriving stock (Eq, Show)

-- | One inventory: every class the stack declares has an answer, and the
-- control has an outcome. Built only by 'mkAuditObservation', which fills a
-- class nobody answered with an unanswered one.
data AuditObservation = AuditObservation
  { auditObservationStack :: !AuditStack
  , auditObservationAnswers :: !(Map AuditClass AuditAnswer)
  , auditObservationControl :: !AuditControl
  }
  deriving stock (Eq, Show)

data AuditObservationError
  = -- | An answer for a class the stack does not declare.
    AuditClassOutsideField !AuditStack !AuditClass
  | -- | A row filed under a class other than the one that was answered.
    AuditRowInWrongClass !AuditClass !AuditClass
  | -- | Two answers for one class.
    AuditClassAnsweredTwice !AuditClass
  deriving stock (Eq, Show)

mkAuditObservation
  :: AuditStack
  -> [(AuditClass, AuditAnswer)]
  -> AuditControl
  -> Either AuditObservationError AuditObservation
mkAuditObservation stack answers control = do
  mapM_ checkClass answers
  case duplicated (map fst answers) of
    class' : _ -> Left (AuditClassAnsweredTwice class')
    [] -> Right ()
  let answered = Map.fromList answers
      complete =
        Map.fromList
          [ ( class'
            , Map.findWithDefault (auditUnanswered "the class was not queried") class' answered
            )
          | class' <- auditStackClasses stack
          ]
  Right
    AuditObservation
      { auditObservationStack = stack
      , auditObservationAnswers = complete
      , auditObservationControl = control
      }
 where
  declared = auditStackClasses stack
  checkClass (class', answer)
    | class' `notElem` declared = Left (AuditClassOutsideField stack class')
    | otherwise = mapM_ (checkRow class') (auditAnswerRows answer)
  checkRow class' row
    | auditRowClass row == class' = Right ()
    | otherwise = Left (AuditRowInWrongClass class' (auditRowClass row))
  duplicated classes =
    [ class'
    | (class', count) <- Map.toList (Map.fromListWith (+) [(c, 1 :: Int) | c <- classes])
    , count > 1
    ]

-- | The three outcomes an audit can license.
data AuditVerdict
  = AuditClean
  | -- | The classes that held rows, with how many each.
    AuditResidue !(Map AuditClass Natural)
  | -- | The classes that did not answer, and why; and whether the control failed.
    AuditUnobservable ![(AuditClass, Text)] !(Maybe Text)
  deriving stock (Eq, Show)

-- | Decide the verdict. A row is a refutation and stands whatever else went
-- unanswered. Absence is licensed only when every class answered and the
-- control appeared.
auditVerdict :: AuditObservation -> AuditVerdict
auditVerdict observation
  | not (Map.null counts) = AuditResidue counts
  | null unanswered && controlProblem == Nothing = AuditClean
  | otherwise = AuditUnobservable unanswered controlProblem
 where
  answers = auditObservationAnswers observation
  counts =
    Map.fromList
      [ (class', total)
      | (class', answer) <- Map.toList answers
      , let total = answerTotal answer
      , total > 0
      ]
  unanswered = [(class', gap) | (class', AuditAnswer _ _ (Just gap)) <- Map.toList answers]
  controlProblem = case auditObservationControl observation of
    AuditControlSeen -> Nothing
    AuditControlMissing -> Just "the positive control did not appear in the catalog, so the catalog may be blind"
    AuditControlUnanswered reason -> Just ("the positive control could not be queried: " <> reason)

-- | Every row the class held: those carried and those not.
answerTotal :: AuditAnswer -> Natural
answerTotal answer = fromIntegral (length (auditAnswerRows answer)) + auditAnswerOmitted answer

auditVerdictLabel :: AuditVerdict -> Text
auditVerdictLabel verdict = case verdict of
  AuditClean -> "Clean"
  AuditResidue _ -> "Residue"
  AuditUnobservable _ _ -> "Unobservable"

-- | 0 clean, 4 residue, 5 unobservable. An unanswered query and a missing
-- control both exit 5, and the report names which.
auditExitCode :: AuditVerdict -> ExitCode
auditExitCode verdict = case verdict of
  AuditClean -> ExitSuccess
  AuditResidue _ -> ExitFailure 4
  AuditUnobservable _ _ -> ExitFailure 5

-- | Every row the field held, in class then identity order.
auditRows :: AuditObservation -> [AuditRow]
auditRows observation =
  sortOn
    (\row -> (auditRowClass row, auditRowIdentity row))
    [row | answer <- Map.elems (auditObservationAnswers observation), row <- auditAnswerRows answer]

-- | The operator's report: stable tokens, one line per fact, and the rows with
-- their identities (bounded per class). This is the only place a raw identifier
-- is rendered.
renderAuditReport :: AuditObservation -> AuditVerdict -> [Text]
renderAuditReport observation verdict =
  [prefix <> " verdict=" <> auditVerdictLabel verdict]
    <> [ prefix <> " class=" <> auditClassLabel class' <> " count=" <> showNatural count
       | (class', count) <- Map.toList (verdictCounts verdict)
       ]
    <> concatMap classRows (Map.toList (auditObservationAnswers observation))
    <> [ prefix <> " unanswered=" <> auditClassLabel class' <> " (" <> reason <> ")"
       | (class', AuditAnswer _ _ (Just reason)) <- Map.toList (auditObservationAnswers observation)
       ]
    <> [prefix <> " control=" <> controlLabel (auditObservationControl observation)]
 where
  prefix = "AWS_FIELD " <> auditStackLabel (auditObservationStack observation)
  classRows (class', answer) =
    let rows = sortOn auditRowIdentity (auditAnswerRows answer)
        shown = take rowsPerClass rows
        left = auditAnswerOmitted answer + fromIntegral (length rows - length shown)
     in [ prefix <> " " <> auditClassLabel class' <> " " <> auditRowIdentity row <> detail row
        | row <- shown
        ]
          <> [ prefix <> " " <> auditClassLabel class' <> " omitted=" <> showNatural left
             | left > 0
             ]
  detail row
    | Text.null (auditRowDetail row) = ""
    | otherwise = " " <> auditRowDetail row
  verdictCounts v = case v of
    AuditResidue counts -> counts
    _ -> Map.empty
  controlLabel control = case control of
    AuditControlSeen -> "seen"
    AuditControlMissing -> "missing"
    AuditControlUnanswered reason -> "unanswered (" <> reason <> ")"

-- | The most rows of one class a report lists; the count says the rest.
rowsPerClass :: Int
rowsPerClass = 20

showNatural :: Natural -> Text
showNatural = Text.pack . show

-- | What a run leaves behind: the verdict, how many rows each class held, and
-- which classes did not answer. It has no field a raw identifier or a
-- provider's description could be put in.
data AuditRecord = AuditRecord
  { recordStack :: !AuditStack
  , recordVerdict :: !Text
  , recordCounts :: ![(AuditClass, Natural)]
  , recordUnanswered :: ![AuditClass]
  , recordControl :: !Text
  }
  deriving stock (Eq, Show)

auditRecord :: AuditObservation -> AuditRecord
auditRecord observation =
  AuditRecord
    { recordStack = auditObservationStack observation
    , recordVerdict = auditVerdictLabel (auditVerdict observation)
    , recordCounts =
        [ (class', total)
        | (class', answer) <- Map.toList (auditObservationAnswers observation)
        , let total = answerTotal answer
        , total > 0
        ]
    , recordUnanswered =
        [class' | (class', AuditAnswer _ _ (Just _)) <- Map.toList (auditObservationAnswers observation)]
    , recordControl = case auditObservationControl observation of
        AuditControlSeen -> "seen"
        AuditControlMissing -> "missing"
        AuditControlUnanswered _ -> "unanswered"
    }

-- | The canonical text of a record: labels and numbers only.
encodeAuditRecord :: AuditRecord -> Text
encodeAuditRecord record =
  Text.unwords $
    [ "aws-audit/v1"
    , "stack=" <> auditStackLabel (recordStack record)
    , "verdict=" <> recordVerdict record
    , "control=" <> recordControl record
    ]
      <> [auditClassLabel class' <> "=" <> showNatural count | (class', count) <- recordCounts record]
      <> ["unanswered=" <> auditClassLabel class' | class' <- recordUnanswered record]

-- | How a field changed between two inventories of the same stack.
data AuditDiff = AuditDiff
  { auditDiffRemoved :: ![AuditRow]
  , auditDiffRemaining :: ![AuditRow]
  , auditDiffAppeared :: ![AuditRow]
  }
  deriving stock (Eq, Show)

-- | What went away, what is still there and what is new, by class and
-- identity. The baseline is the inventory taken when the command began.
diffAuditObservations :: AuditObservation -> AuditObservation -> AuditDiff
diffAuditObservations baseline final =
  AuditDiff
    { auditDiffRemoved = [row | row <- before, key row `Set.notMember` afterKeys]
    , auditDiffRemaining = [row | row <- after, key row `Set.member` beforeKeys]
    , auditDiffAppeared = [row | row <- after, key row `Set.notMember` beforeKeys]
    }
 where
  before = auditRows baseline
  after = auditRows final
  key row = (auditRowClass row, auditRowIdentity row)
  beforeKeys = Set.fromList (map key before)
  afterKeys = Set.fromList (map key after)

-- | The destroy verbs' completion line, and the rows that did not leave.
renderAuditDiff :: AuditObservation -> AuditVerdict -> AuditDiff -> [Text]
renderAuditDiff final verdict diff =
  [ "AWS_FIELD_DIFF "
      <> auditStackLabel (auditObservationStack final)
      <> " verdict="
      <> auditVerdictLabel verdict
      <> " removed="
      <> count (auditDiffRemoved diff)
      <> " remaining="
      <> count (auditDiffRemaining diff)
      <> " appeared="
      <> count (auditDiffAppeared diff)
  ]
    <> [ "AWS_FIELD_DIFF remaining " <> auditClassLabel (auditRowClass row) <> " " <> auditRowIdentity row
       | row <- take 20 (auditDiffRemaining diff)
       ]
    <> [ "AWS_FIELD_DIFF appeared " <> auditClassLabel (auditRowClass row) <> " " <> auditRowIdentity row
       | row <- take 20 (auditDiffAppeared diff)
       ]
 where
  count = showNatural . fromIntegral . length
