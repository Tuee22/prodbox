{-# LANGUAGE OverloadedStrings #-}

-- | The finite AWS refusal/remedy policy and its published baseline.
module Prodbox.Lifecycle.AwsRemedy
  ( AwsStackTarget (..)
  , awsStackCliName
  , awsStackRegistryName
  , AwsLifecycleCause (..)
  , AwsRemedy (..)
  , remedyForAwsCause
  , awsRemedyRows
  , nukeOnlyCauseCount
  , awsRemedyViolations
  , renderAwsRemedyTable
  , awsRemedySectionStart
  , awsRemedySectionEnd
  , parseAwsRemedyBaseline
  , AwsRemedyBaselineSource (..)
  , resolveAwsRemedyBaseline
  )
where

import Data.List (intercalate, isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Numeric.Natural (Natural)

data AwsStackTarget = AwsEksTarget | AwsTestTarget | AwsSubzoneTarget | AwsSesTarget
  deriving (Bounded, Enum, Eq, Ord, Show)

awsStackCliName :: AwsStackTarget -> String
awsStackCliName target = case target of
  AwsEksTarget -> "eks"
  AwsTestTarget -> "test"
  AwsSubzoneTarget -> "aws-subzone"
  AwsSesTarget -> "aws-ses"

awsStackRegistryName :: AwsStackTarget -> Text.Text
awsStackRegistryName target = case target of
  AwsEksTarget -> "aws-eks"
  AwsTestTarget -> "aws-test"
  AwsSubzoneTarget -> "aws-eks-subzone"
  AwsSesTarget -> "aws-ses"

data AwsLifecycleCause
  = LeakedNetworkDependents
  | BlockedDestroy
  | PreviewChanges
  | UnobservableAudit
  | RetainedVolumeTooSmall
  | AuthorityAdmissionRefused
  deriving (Bounded, Enum, Eq, Ord, Show)

data AwsRemedy
  = SelfHeal !Natural !Natural
  | RepairVerb ![String]
  | NukeOnly !String
  deriving (Eq, Show)

-- | Network purge is EKS-scoped. Test-VPC children use its converging destroy;
-- a network refusal attributed to either non-network stack gets a read-only
-- diff rather than permission to destroy an unrelated network.
remedyForAwsCause :: AwsStackTarget -> AwsLifecycleCause -> AwsRemedy
remedyForAwsCause target cause = case cause of
  LeakedNetworkDependents -> case target of
    AwsEksTarget -> RepairVerb (stackPath "purge-dependents")
    AwsTestTarget -> RepairVerb (stackPath "destroy")
    AwsSubzoneTarget -> RepairVerb (stackPath "diff")
    AwsSesTarget -> RepairVerb (stackPath "diff")
  BlockedDestroy -> RepairVerb (stackPath "destroy")
  PreviewChanges -> RepairVerb (stackPath "diff")
  UnobservableAudit -> case target of
    AwsEksTarget -> RepairVerb ["aws", "audit"]
    AwsTestTarget -> RepairVerb ["aws", "audit"]
    AwsSubzoneTarget -> RepairVerb (stackPath "diff")
    AwsSesTarget -> RepairVerb (stackPath "diff")
  RetainedVolumeTooSmall ->
    NukeOnly
      "Replacement deletes the retained family; in-place growth requires the operator's decision (Sprint 5.53)."
  AuthorityAdmissionRefused -> RepairVerb ["cluster", "reconcile"]
 where
  stackPath verb = ["aws", "stack", awsStackCliName target, verb]

awsRemedyRows :: [(AwsStackTarget, AwsLifecycleCause, AwsRemedy)]
awsRemedyRows =
  [ (target, cause, remedyForAwsCause target cause)
  | target <- [minBound .. maxBound]
  , cause <- [minBound .. maxBound]
  ]

-- A cause remains one debt even when it applies to several stack selections.
nukeOnlyCauseCount :: [(AwsStackTarget, AwsLifecycleCause, AwsRemedy)] -> Natural
nukeOnlyCauseCount rows =
  fromIntegral (Set.size (Set.fromList [cause | (_, cause, NukeOnly _) <- rows]))

awsRemedyViolations
  :: [[String]]
  -> Natural
  -> [(AwsStackTarget, AwsLifecycleCause, AwsRemedy)]
  -> [String]
awsRemedyViolations knownPaths baseline rows =
  concatMap validateRow rows
    ++ [ "AWS NukeOnly cause count grew from Git HEAD's "
           ++ show baseline
           ++ " to "
           ++ show (nukeOnlyCauseCount rows)
       | nukeOnlyCauseCount rows > baseline
       ]
 where
  validateRow (_, cause, remedy) = case remedy of
    SelfHeal attempts seconds ->
      [show cause ++ " has an unbounded or empty self-heal" | attempts == 0 || seconds == 0]
    RepairVerb path ->
      [show cause ++ " names an unresolved repair verb: " ++ unwords path | path `notElem` knownPaths]
    NukeOnly reason ->
      [show cause ++ " has no NukeOnly reason" | null (words reason)]

awsRemedySectionStart :: String
awsRemedySectionStart = "<!-- prodbox:aws-lifecycle-remedies:start -->"

awsRemedySectionEnd :: String
awsRemedySectionEnd = "<!-- prodbox:aws-lifecycle-remedies:end -->"

renderAwsRemedyTable :: String
renderAwsRemedyTable =
  unlines
    ( [ "| Stack | Cause | Remedy | Action or reason |"
      , "|-------|-------|--------|------------------|"
      ]
        ++ [ "| "
               ++ intercalate " | " [awsStackCliName target, show cause, kind remedy, action target remedy]
               ++ " |"
           | (target, cause, remedy) <- awsRemedyRows
           ]
    )
 where
  kind remedy = case remedy of
    SelfHeal _ _ -> "SelfHeal"
    RepairVerb _ -> "RepairVerb"
    NukeOnly _ -> "NukeOnly"
  action target remedy = case remedy of
    SelfHeal attempts seconds -> show attempts ++ " attempts within " ++ show seconds ++ " seconds"
    RepairVerb path -> "`prodbox " ++ unwords (path ++ arguments target path) ++ "`"
    NukeOnly reason -> reason
  arguments AwsEksTarget ["aws", "audit"] = ["--stack", "eks"]
  arguments AwsTestTarget ["aws", "audit"] = ["--stack", "test"]
  arguments _ path = case reverse path of
    "destroy" : _ -> ["--yes"]
    _ -> []

-- | Read the committed generated table, not a caller-authored count. A
-- missing/malformed section cannot silently reset the ceiling to zero.
parseAwsRemedyBaseline :: String -> Either String Natural
parseAwsRemedyBaseline document = do
  let rows = lines document
  if length (filter (== awsRemedySectionStart) rows) == 1
    && length (filter (== awsRemedySectionEnd) rows) == 1
    then Right ()
    else Left "Git HEAD has no unique AWS remedy section"
  body <- case dropWhile (/= awsRemedySectionStart) rows of
    [] -> Left "Git HEAD has no AWS remedy section"
    _ : rest -> case break (== awsRemedySectionEnd) rest of
      (_, []) -> Left "Git HEAD AWS remedy section is unterminated"
      (content, _) -> Right content
  parsed <- traverse parseRow [row | row <- body, "| " `Text.isPrefixOf` Text.pack row]
  let entries = [entry | Just entry <- parsed]
      coordinates = [(target, cause) | (target, cause, _) <- entries]
  if null entries || Set.size (Set.fromList coordinates) /= length coordinates
    then Left "Git HEAD AWS remedy rows are empty or duplicated"
    else
      Right
        ( fromIntegral
            (Set.size (Set.fromList [cause | (_, cause, True) <- entries]))
        )
 where
  parseRow :: String -> Either String (Maybe (AwsStackTarget, AwsLifecycleCause, Bool))
  parseRow row = case map Text.strip (Text.splitOn "|" (Text.pack row)) of
    ["", "Stack", "Cause", "Remedy", "Action or reason", ""] -> Right Nothing
    ["", stack, cause, remedy, _, ""] -> do
      target <-
        lookupValue
          "stack"
          stack
          [(Text.pack (awsStackCliName value), value) | value <- [minBound .. maxBound]]
      causeValue <-
        lookupValue "cause" cause [(Text.pack (show value), value) | value <- [minBound .. maxBound]]
      isNuke <- case remedy of
        "SelfHeal" -> Right False
        "RepairVerb" -> Right False
        "NukeOnly" -> Right True
        _ -> Left "Git HEAD AWS remedy kind is unknown"
      Right (Just (target, causeValue, isNuke))
    _ -> Left "Git HEAD AWS remedy row is malformed"
  lookupValue label value choices =
    maybe (Left ("Git HEAD AWS remedy " ++ label ++ " is unknown")) Right (lookup value choices)

data AwsRemedyBaselineSource
  = RegisteredInitialRemedyBaseline !String
  | PublishedRemedyBaseline !String

resolveAwsRemedyBaseline :: AwsRemedyBaselineSource -> Either String Natural
resolveAwsRemedyBaseline source = case source of
  PublishedRemedyBaseline document -> parseAwsRemedyBaseline document
  RegisteredInitialRemedyBaseline phaseAtHead
    | "- The retained-volume-smaller-than-the-plan refusal is registered as `NukeOnly`,"
        `isInfixOf` phaseAtHead ->
        Right 1
    | otherwise -> Left "Git HEAD does not register the initial retained-volume NukeOnly cause"
