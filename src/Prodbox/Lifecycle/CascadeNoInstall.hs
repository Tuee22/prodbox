{-# LANGUAGE OverloadedStrings #-}

-- | The decision behind a @cluster delete --cascade@ that finds no local RKE2
-- install.
--
-- Everything here is pure: no file, network or credential access happens in
-- this module. The effects that gather the evidence live in
-- "Prodbox.CLI.Rke2", and this module decides what that evidence licenses.
--
-- __Why the decision is separate from the effects.__ A cascade that reached no
-- phase observed nothing by itself. The only way it can exit zero honestly is
-- by asking AWS read-only on the same invocation, and then every fact that
-- licenses the zero has to be present at once: the deployment authored an AWS
-- coordinate (so there is an account for residue to be in), the tag sweep ran
-- and came back clean, the sweep asked every region the authored coordinates
-- name, the credential it ran with is tied to the deployment's own account
-- wherever a coordinate can say so, and every retained root in the worktree was
-- looked at. 'confirmCascadeNoInstall' is the only producer of
-- 'ConfirmedNoInstallCascade', its constructor is unexported, and it returns the
-- reasons it refused rather than a bare 'Nothing', so each missing fact is a
-- named, testable refusal.
--
-- __A sweep that was never owed is not a confirmation.__ 'CascadeSweepNotOwed'
-- issues no query, so a confirmation built from it would be minted from
-- silence. It therefore never confirms here, under any scope. The full cascade
-- (which has already run its destroy phases against exact checkpoints) keeps
-- admitting it; that divergence is deliberate and pinned by a unit test.
module Prodbox.Lifecycle.CascadeNoInstall
  ( -- * Authored AWS coordinates
    AuthoredAwsCoordinate (..)
  , authoredCoordinateField
  , authoredCoordinateFieldNames
  , authoredAwsCoordinates
  , pinningZoneId

    -- * Scope and sweep
  , CascadeAwsScope (..)
  , classifyCascadeAwsScope
  , cascadeAwsScopeFromConfig
  , cascadeAwsScopeFromValidated
  , cascadeAwsScopeOwesSweep
  , CascadePostflightSweep (..)

    -- * Sweep fan-out and region coverage
  , cascadeSweepInputs
  , cascadeSweepQueriedRegions
  , requiredSweepRegions
  , missingSweepRegions

    -- * Account evidence
  , HostedZoneVisibility (..)
  , AccountEvidence (..)
  , accountCoverageGaps
  , classifyHostedZoneProbe

    -- * Retained roots
  , RetainedRootKind (..)
  , RetainedRootObservation (..)
  , RetainedRootFinding (..)
  , retainedRootCandidates
  , retainedRootSignatures
  , rootRefusals

    -- * The decision
  , NoInstallObservation (..)
  , NoInstallRefusal (..)
  , NoInstallPlan (..)
  , planNoInstallCascade
  , ConfirmedNoInstallCascade
  , confirmedRetainedByDesign
  , confirmedQueriedRegions
  , confirmedCoordinates
  , confirmedAccount
  , confirmedRootFindings
  , confirmCascadeNoInstall
  , confirmedNoInstallCascadeExit
  , NoInstallObservationClass (..)
  , noInstallObservationClass

    -- * Narration
  , carveOutDescription
  , renderConfirmedNoInstallCascade
  , renderNoInstallRefusals
  , retainedStateObservedNotConfirmedLine
  )
where

import Data.Char (isSpace)
import Data.List (dropWhileEnd, intercalate, isInfixOf, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Lib.Storage
  ( defaultChartDataRootRelative
  , testDataRootRelative
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Settings
  ( AwsSubstrateProfile
  , AwsSubstrateSection (..)
  , ConfigFile (..)
  , ValidatedCoordinates (..)
  , ValidatedSettings (..)
  , requireAwsSubstrateProfile
  , validatedCoordinatesFor
  )
import Prodbox.Settings.Coordinate
  ( AwsRegion
  , Route53ZoneId
  , awsRegionText
  )
import System.Exit (ExitCode (..))
import System.FilePath (dropTrailingPathSeparator, normalise, (</>))

-- Authored coordinates -------------------------------------------------------

-- | One Tier-0 field that names an AWS object. A payload is carried only where
-- a downstream decision needs the value (a zone id for the account check, a
-- region for sweep coverage); every other coordinate is a bare marker, and
-- narration prints field names, never values.
data AuthoredAwsCoordinate
  = AuthoredHomeZone !Route53ZoneId
  | AuthoredSubstrateZone !Route53ZoneId
  | AuthoredSubstrateSubzone
  | AuthoredSubstrateProfile
  | AuthoredOperationalRegion !AwsRegion
  | AuthoredBackendRegion !AwsRegion
  | AuthoredBackendBucket
  | AuthoredSesSenderDomain
  | AuthoredSesReceiveSubdomain
  | AuthoredSesCaptureBucket
  deriving (Eq, Show)

-- | The dotted Tier-0 field name, exactly as an operator writes it.
authoredCoordinateField :: AuthoredAwsCoordinate -> String
authoredCoordinateField coordinate = case coordinate of
  AuthoredHomeZone _ -> "route53.zone_id"
  AuthoredSubstrateZone _ -> "aws_substrate.hosted_zone_id"
  AuthoredSubstrateSubzone -> "aws_substrate.subzone_name"
  AuthoredSubstrateProfile -> "aws_substrate.profile"
  AuthoredOperationalRegion _ -> "aws.region"
  AuthoredBackendRegion _ -> "pulumi_state_backend.region"
  AuthoredBackendBucket -> "pulumi_state_backend.bucket_name"
  AuthoredSesSenderDomain -> "ses.sender_domain"
  AuthoredSesReceiveSubdomain -> "ses.receive_subdomain"
  AuthoredSesCaptureBucket -> "ses.capture_bucket"

-- | The closed list of field names, in the order 'authoredAwsCoordinates'
-- emits them. A unit test pins this list against the constructor set, so a new
-- coordinate without a row fails.
authoredCoordinateFieldNames :: [String]
authoredCoordinateFieldNames =
  [ "route53.zone_id"
  , "aws_substrate.hosted_zone_id"
  , "aws_substrate.subzone_name"
  , "aws_substrate.profile"
  , "aws.region"
  , "pulumi_state_backend.region"
  , "pulumi_state_backend.bucket_name"
  , "ses.sender_domain"
  , "ses.receive_subdomain"
  , "ses.capture_bucket"
  ]

-- | The single definition of \"authored\".
--
-- A coordinate is authored when its validated projection is present. A blank
-- field projects to 'Nothing' and is not authored. The key prefix is excluded
-- on purpose: its shipped default is non-empty, so it would always read as
-- authored. Secret references, ACME, domain, storage and deployment fields name
-- no AWS object and are excluded too.
authoredAwsCoordinates
  :: ValidatedCoordinates -> Maybe AwsSubstrateProfile -> [AuthoredAwsCoordinate]
authoredAwsCoordinates coordinates substrateProfile =
  catMaybes
    [ AuthoredHomeZone <$> coordinateHomeZoneId coordinates
    , AuthoredSubstrateZone <$> coordinateAwsSubstrateZoneId coordinates
    , AuthoredSubstrateSubzone <$ coordinateAwsSubstrateSubzone coordinates
    , AuthoredSubstrateProfile <$ substrateProfile
    , AuthoredOperationalRegion <$> coordinateOperationalAwsRegion coordinates
    , AuthoredBackendRegion <$> coordinatePulumiBackendRegion coordinates
    , AuthoredBackendBucket <$ coordinatePulumiBackendBucket coordinates
    , AuthoredSesSenderDomain <$ coordinateSesSenderDomain coordinates
    , AuthoredSesReceiveSubdomain <$ coordinateSesReceiveSubdomain coordinates
    , AuthoredSesCaptureBucket <$ coordinateSesCaptureBucket coordinates
    ]

-- Scope and sweep ------------------------------------------------------------

-- | Whether this cluster lifecycle ever had AWS in scope.
--
-- Decided from authored configuration, which is a fact this repository wrote,
-- and never from per-stack checkpoints reading absent. A checkpoint is Pulumi
-- state: its absence says the state is gone, which is exactly the condition in
-- which an AWS resource is most likely to be stranded and least likely to be
-- nameable.
data CascadeAwsScope
  = -- | The configuration was read and no AWS coordinate is authored, so there
    -- is no account for residue to be in.
    CascadeAwsUndeclared
  | -- | At least one AWS coordinate is authored. The sweep is owed whether or
    -- not this particular run created anything, because a run that created
    -- nothing cannot prove that an earlier one did not. The evidence is carried
    -- so \"declared with nothing authored\" is unrepresentable.
    CascadeAwsDeclared !(NonEmpty AuthoredAwsCoordinate)
  | -- | The declaration itself could not be read. Fail-closed: an unreadable
    -- configuration is not a configuration that declares nothing.
    CascadeAwsScopeUnreadable !String
  deriving (Eq, Show)

-- | The only place 'CascadeAwsDeclared' is built.
classifyCascadeAwsScope :: [AuthoredAwsCoordinate] -> CascadeAwsScope
classifyCascadeAwsScope coordinates = case NonEmpty.nonEmpty coordinates of
  Nothing -> CascadeAwsUndeclared
  Just authored -> CascadeAwsDeclared authored

-- | Scope from a decoded Tier-0 configuration.
--
-- It takes the decoded config rather than a path so it cannot reach the
-- Lifecycle Authority: with no install there is no Authority, and a reader that
-- asked it would always answer unreadable. A shape failure in any validated
-- field is unreadable, never undeclared.
cascadeAwsScopeFromConfig :: Either String ConfigFile -> CascadeAwsScope
cascadeAwsScopeFromConfig loaded = case loaded of
  Left detail -> CascadeAwsScopeUnreadable detail
  Right config -> case validatedCoordinatesFor config of
    Left detail -> CascadeAwsScopeUnreadable detail
    Right coordinates ->
      classifyCascadeAwsScope
        (authoredAwsCoordinates coordinates (profile (aws_substrate config)))

-- | Scope from validated in-force settings, for the full cascade where the
-- Authority is still serving. It derives the same list through the same pure
-- function.
cascadeAwsScopeFromValidated :: ValidatedSettings -> CascadeAwsScope
cascadeAwsScopeFromValidated settings =
  classifyCascadeAwsScope
    ( authoredAwsCoordinates
        (validatedCoordinates settings)
        (either (const Nothing) Just (requireAwsSubstrateProfile settings))
    )

-- | Pure: the sweep is owed unless the deployment provably authors no AWS
-- coordinate.
cascadeAwsScopeOwesSweep :: CascadeAwsScope -> Bool
cascadeAwsScopeOwesSweep scope = case scope of
  CascadeAwsUndeclared -> False
  CascadeAwsDeclared _ -> True
  CascadeAwsScopeUnreadable _ -> True

-- | What the postflight sweep produced, as three distinct facts.
--
-- \"Not owed\", \"owed and not run\", and \"owed and answered\" are three
-- different things to know before destroying the only surface that could act on
-- an answer, and only the third can admit the uninstall.
data CascadePostflightSweep
  = CascadeSweepNotOwed
  | CascadeSweepNotRun !String
  | CascadeSweepRan !TagSweep.TagSweepVerdict
  deriving (Eq, Show)

-- Fan-out and region coverage ------------------------------------------------

-- | One sweep input per distinct region: the run region first, then every
-- authored region. Only the run-region field differs between them.
cascadeSweepInputs
  :: TagSweep.TagSweepInput -> [AuthoredAwsCoordinate] -> [TagSweep.TagSweepInput]
cascadeSweepInputs base coordinates =
  [ base {TagSweep.tagSweepRunRegion = regionValue}
  | regionValue <- nub (TagSweep.tagSweepRunRegion base : authoredRegions coordinates)
  ]

-- | Every region the given inputs actually ask, without repeats. Computed from
-- the same list the runner issues, so coverage is a fact about what was queried
-- and not about what was intended.
cascadeSweepQueriedRegions :: [TagSweep.TagSweepInput] -> [Text]
cascadeSweepQueriedRegions = nub . concatMap TagSweep.tagSweepRegions

authoredRegions :: [AuthoredAwsCoordinate] -> [Text]
authoredRegions coordinates = nub (concatMap regionOf coordinates)
 where
  regionOf coordinate = case coordinate of
    AuthoredOperationalRegion region -> [awsRegionText region]
    AuthoredBackendRegion region -> [awsRegionText region]
    AuthoredHomeZone _ -> []
    AuthoredSubstrateZone _ -> []
    AuthoredSubstrateSubzone -> []
    AuthoredSubstrateProfile -> []
    AuthoredBackendBucket -> []
    AuthoredSesSenderDomain -> []
    AuthoredSesReceiveSubdomain -> []
    AuthoredSesCaptureBucket -> []

-- | The regions a sweep must have asked for the authored coordinates to be
-- covered: every authored region, plus the global-service region whenever a
-- coordinate names a global service (Route 53).
requiredSweepRegions :: NonEmpty AuthoredAwsCoordinate -> [Text]
requiredSweepRegions coordinates =
  nub
    ( authoredRegions authored
        ++ [awsGlobalServiceRegion | any namesGlobalService authored]
    )
 where
  authored = NonEmpty.toList coordinates
  namesGlobalService coordinate = case coordinate of
    AuthoredHomeZone _ -> True
    AuthoredSubstrateZone _ -> True
    AuthoredSubstrateSubzone -> True
    AuthoredSubstrateProfile -> False
    AuthoredOperationalRegion _ -> False
    AuthoredBackendRegion _ -> False
    AuthoredBackendBucket -> False
    AuthoredSesSenderDomain -> False
    AuthoredSesReceiveSubdomain -> False
    AuthoredSesCaptureBucket -> False

-- | Required minus queried. Empty means covered.
missingSweepRegions :: NonEmpty AuthoredAwsCoordinate -> [Text] -> [Text]
missingSweepRegions coordinates queried =
  filter (`notElem` queried) (requiredSweepRegions coordinates)

-- Account evidence -----------------------------------------------------------

-- | Whether the credential's account can see a hosted zone the deployment
-- authored.
data HostedZoneVisibility
  = HostedZoneVisible
  | -- | AWS answered that no such zone exists in the credential's account.
    HostedZoneNotVisible !String
  | -- | The probe produced no usable answer (access denied, timeout, an
    -- unrecognized failure). Treated as a gap, never as visible.
    HostedZoneUnanswered !String
  deriving (Eq, Show)

-- | What the run learned about whether its credential belongs to this
-- deployment's account.
data AccountEvidence
  = AccountNotProbed
  | AccountProbed ![(AuthoredAwsCoordinate, HostedZoneVisibility)]
  deriving (Eq, Show)

-- | The zone id a pinning coordinate names, if it is one.
pinningZoneId :: AuthoredAwsCoordinate -> Maybe Route53ZoneId
pinningZoneId coordinate = case coordinate of
  AuthoredHomeZone zoneId -> Just zoneId
  AuthoredSubstrateZone zoneId -> Just zoneId
  AuthoredSubstrateSubzone -> Nothing
  AuthoredSubstrateProfile -> Nothing
  AuthoredOperationalRegion _ -> Nothing
  AuthoredBackendRegion _ -> Nothing
  AuthoredBackendBucket -> Nothing
  AuthoredSesSenderDomain -> Nothing
  AuthoredSesReceiveSubdomain -> Nothing
  AuthoredSesCaptureBucket -> Nothing

-- | The coordinates that can pin an account: a zone id is only visible from the
-- account that owns (or can read) the zone. Buckets, SES identities and regions
-- are not pins: a bucket name is global and a region names no account.
pinningCoordinates :: [AuthoredAwsCoordinate] -> [AuthoredAwsCoordinate]
pinningCoordinates = filter isPin
 where
  isPin coordinate = case coordinate of
    AuthoredHomeZone _ -> True
    AuthoredSubstrateZone _ -> True
    AuthoredSubstrateSubzone -> False
    AuthoredSubstrateProfile -> False
    AuthoredOperationalRegion _ -> False
    AuthoredBackendRegion _ -> False
    AuthoredBackendBucket -> False
    AuthoredSesSenderDomain -> False
    AuthoredSesReceiveSubdomain -> False
    AuthoredSesCaptureBucket -> False

-- | Pinning coordinates whose zone was not seen. With no pinning coordinate
-- authored there is nothing to compare and the result is empty: the narration
-- says the account was not verified, and refusing forever would lock out a
-- deployment that authored only buckets or SES identities.
accountCoverageGaps
  :: NonEmpty AuthoredAwsCoordinate
  -> AccountEvidence
  -> [(AuthoredAwsCoordinate, HostedZoneVisibility)]
accountCoverageGaps coordinates evidence =
  [ (pin, result)
  | pin <- pinningCoordinates (NonEmpty.toList coordinates)
  , let result = probeFor pin
  , result /= HostedZoneVisible
  ]
 where
  probeFor pin = case evidence of
    AccountNotProbed -> HostedZoneUnanswered "the zone was not probed"
    AccountProbed probes ->
      fromMaybe (HostedZoneUnanswered "the zone was not probed") (lookup pin probes)

-- | Classify the result of a hosted-zone read. Visible only on exit zero.
classifyHostedZoneProbe :: ExitCode -> String -> HostedZoneVisibility
classifyHostedZoneProbe exitCode stderrText = case exitCode of
  ExitSuccess -> HostedZoneVisible
  ExitFailure code
    | "NoSuchHostedZone" `isInfixOf` stderrText ->
        HostedZoneNotVisible "AWS reports no such hosted zone"
    | null (trimString stderrText) ->
        HostedZoneUnanswered ("the probe exited " ++ show code ++ " without a message")
    | otherwise ->
        HostedZoneUnanswered
          ("the probe exited " ++ show code ++ ": " ++ firstLine stderrText)
 where
  firstLine = takeWhile (/= '\n') . trimString

trimString :: String -> String
trimString = dropWhileEnd isSpace . dropWhile isSpace

-- Retained roots -------------------------------------------------------------

data RetainedRootKind
  = RootConfigured
  | RootDefaultProduction
  | RootTest
  | RootDiscovered
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What a read-only look at one root found. Absent and present both count as
-- examined: the root was looked for and named. Only an unexaminable root blocks.
data RetainedRootObservation
  = RootAbsent
  | RootPresent !Int
  | RootUnexaminable !String
  deriving (Eq, Show)

data RetainedRootFinding = RetainedRootFinding
  { rootFindingKind :: !RetainedRootKind
  , rootFindingPath :: !FilePath
  , rootFindingObservation :: !RetainedRootObservation
  }
  deriving (Eq, Show)

-- | The roots a cascade must account for, derived from the repository root and
-- the configured root so a caller cannot pass a shorter list and obtain a
-- confirmation. Deduplicated by normalised path; the first occurrence wins.
retainedRootCandidates :: FilePath -> FilePath -> [(RetainedRootKind, FilePath)]
retainedRootCandidates repoRoot configuredRoot =
  dedupe
    [ (RootConfigured, normalisedPath configuredRoot)
    , (RootDefaultProduction, normalisedPath (repoRoot </> defaultChartDataRootRelative))
    , (RootTest, normalisedPath (repoRoot </> testDataRootRelative))
    ]
 where
  dedupe = foldl keepFirst []
  keepFirst kept candidate@(_, path)
    | path `elem` map snd kept = kept
    | otherwise = kept ++ [candidate]

normalisedPath :: FilePath -> FilePath
normalisedPath = dropTrailingPathSeparator . normalise

-- | Relative paths whose presence under an immediate child of the repository
-- root marks that child as a retained root. They are the Vault durable volume
-- and the object-store volume that the retained-state inventory names.
retainedRootSignatures :: [FilePath]
retainedRootSignatures = ["vault" </> "vault" </> "0", "prodbox" </> "minio" </> "0"]

-- | Reasons a root set is not fully examined. Every candidate needs a finding;
-- an unexaminable finding (candidate or discovered) blocks.
rootRefusals :: FilePath -> FilePath -> [RetainedRootFinding] -> [NoInstallRefusal]
rootRefusals repoRoot configuredRoot findings = missing ++ unexaminable
 where
  candidatePaths = map snd (retainedRootCandidates repoRoot configuredRoot)
  missing =
    [ RefusedRootNotExamined path
    | path <- candidatePaths
    , path `notElem` map (normalisedPath . rootFindingPath) findings
    ]
  unexaminable =
    [ RefusedRootUnexaminable (rootFindingPath finding) detail
    | finding <- findings
    , RootUnexaminable detail <- [rootFindingObservation finding]
    ]

-- The decision ---------------------------------------------------------------

-- | Everything the sole producer decides over.
data NoInstallObservation = NoInstallObservation
  { observedScope :: !CascadeAwsScope
  , observedSweep :: !CascadePostflightSweep
  , observedQueriedRegions :: ![Text]
  , observedAccount :: !AccountEvidence
  , observedRepoRoot :: !FilePath
  , observedConfiguredRoot :: !FilePath
  , observedRoots :: ![RetainedRootFinding]
  }
  deriving (Eq, Show)

-- | One constructor per way the evidence can fall short. The producer reports
-- every applicable reason, in a fixed order, so a refusal is never a
-- first-error.
data NoInstallRefusal
  = RefusedNothingAuthored
  | RefusedScopeUnreadable !String
  | RefusedRootNotExamined !FilePath
  | RefusedRootUnexaminable !FilePath !String
  | RefusedSweepInconsistent
  | RefusedSweepNotRun !String
  | RefusedResidueEscaped !(NonEmpty TagSweep.TaggedResource)
  | RefusedSweepUnconfirmed !String
  | RefusedRegionsNotCovered !(NonEmpty Text)
  | RefusedAccountNotCovered !(NonEmpty (AuthoredAwsCoordinate, HostedZoneVisibility))
  deriving (Eq, Show)

-- | Whether the run asked AWS before it refused. It selects the retained-state
-- sentence, because \"nothing was observed\" is only true of the first class.
data NoInstallObservationClass
  = NoInstallUnobserved
  | NoInstallObservedNotConfirmed
  deriving (Bounded, Enum, Eq, Show)

noInstallObservationClass :: NonEmpty NoInstallRefusal -> NoInstallObservationClass
noInstallObservationClass reasons
  | any queriedAws reasons = NoInstallObservedNotConfirmed
  | otherwise = NoInstallUnobserved
 where
  queriedAws reason = case reason of
    RefusedResidueEscaped _ -> True
    RefusedSweepUnconfirmed _ -> True
    RefusedRegionsNotCovered _ -> True
    RefusedAccountNotCovered _ -> True
    RefusedNothingAuthored -> False
    RefusedScopeUnreadable _ -> False
    RefusedRootNotExamined _ -> False
    RefusedRootUnexaminable _ _ -> False
    RefusedSweepInconsistent -> False
    RefusedSweepNotRun _ -> False

scopeRefusals :: CascadeAwsScope -> [NoInstallRefusal]
scopeRefusals scope = case scope of
  CascadeAwsUndeclared -> [RefusedNothingAuthored]
  CascadeAwsScopeUnreadable detail -> [RefusedScopeUnreadable detail]
  CascadeAwsDeclared _ -> []

sweepRefusals :: CascadeAwsScope -> CascadePostflightSweep -> [NoInstallRefusal]
sweepRefusals scope sweep = case sweep of
  CascadeSweepNotOwed -> case scope of
    CascadeAwsDeclared _ -> [RefusedSweepInconsistent]
    CascadeAwsUndeclared -> []
    CascadeAwsScopeUnreadable _ -> []
  CascadeSweepNotRun detail -> [RefusedSweepNotRun detail]
  CascadeSweepRan verdict -> case verdict of
    TagSweep.TagSweepConfirmedClean _ -> []
    TagSweep.TagSweepEscaped _ escaped -> case NonEmpty.nonEmpty escaped of
      Just rows -> [RefusedResidueEscaped rows]
      Nothing -> [RefusedSweepUnconfirmed "the escaped verdict carried no resources"]
    TagSweep.TagSweepUnconfirmed detail -> [RefusedSweepUnconfirmed detail]

coverageRefusals
  :: CascadeAwsScope
  -> CascadePostflightSweep
  -> [Text]
  -> AccountEvidence
  -> [NoInstallRefusal]
coverageRefusals scope sweep queried account = case scope of
  CascadeAwsDeclared coordinates -> case sweep of
    CascadeSweepRan verdict ->
      regionRefusal coordinates ++ accountRefusal coordinates verdict
    CascadeSweepNotOwed -> []
    CascadeSweepNotRun _ -> []
  CascadeAwsUndeclared -> []
  CascadeAwsScopeUnreadable _ -> []
 where
  regionRefusal coordinates =
    [ RefusedRegionsNotCovered missing
    | Just missing <- [NonEmpty.nonEmpty (missingSweepRegions coordinates queried)]
    ]
  accountRefusal coordinates verdict = case verdict of
    TagSweep.TagSweepConfirmedClean _ ->
      [ RefusedAccountNotCovered gaps
      | Just gaps <- [NonEmpty.nonEmpty (accountCoverageGaps coordinates account)]
      ]
    TagSweep.TagSweepEscaped _ _ -> []
    TagSweep.TagSweepUnconfirmed _ -> []

-- | What the pure planner decides before any credential is requested.
data NoInstallPlan
  = -- | Refuse without a prompt and without a network call.
    NoInstallRefuseOffline !(NonEmpty NoInstallRefusal)
  | -- | Everything decidable offline passed; the run may ask AWS.
    NoInstallQueryAws !(NonEmpty AuthoredAwsCoordinate)
  deriving (Eq, Show)

-- | Decide, from offline evidence alone, whether the run may ask AWS. Every
-- refusal that does not need a network answer comes before the first credential
-- prompt, so an unreadable configuration or an unexaminable root never makes an
-- operator type a credential for a run that cannot succeed.
planNoInstallCascade
  :: CascadeAwsScope -> FilePath -> FilePath -> [RetainedRootFinding] -> NoInstallPlan
planNoInstallCascade scope repoRoot configuredRoot findings =
  case NonEmpty.nonEmpty (scopeRefusals scope ++ rootRefusals repoRoot configuredRoot findings) of
    Just reasons -> NoInstallRefuseOffline reasons
    Nothing -> case scope of
      CascadeAwsDeclared coordinates -> NoInstallQueryAws coordinates
      CascadeAwsUndeclared -> NoInstallRefuseOffline (RefusedNothingAuthored :| [])
      CascadeAwsScopeUnreadable detail ->
        NoInstallRefuseOffline (RefusedScopeUnreadable detail :| [])

-- | A no-install cascade whose read-only AWS query confirmed it left nothing
-- behind.
--
-- The constructor is unexported and 'confirmCascadeNoInstall' is its only
-- producer, so \"never mint success from silence\" is a fact about what can be
-- built. The fields are the evidence the narration prints.
data ConfirmedNoInstallCascade = ConfirmedNoInstallCascade
  { confirmedRetainedByDesign :: ![TagSweep.TaggedResource]
  , confirmedQueriedRegions :: ![Text]
  , confirmedCoordinates :: !(NonEmpty AuthoredAwsCoordinate)
  , confirmedAccount :: !AccountEvidence
  , confirmedRootFindings :: ![RetainedRootFinding]
  }
  deriving (Eq, Show)

-- | The sole producer.
--
-- 'Right' only for one evidence shape: the scope is declared, the sweep ran and
-- came back confirmed clean, every authored region was queried, no pinning zone
-- is missing from the credential's account, and every required root was looked
-- at. 'CascadeSweepNotOwed' is 'Left' under every scope. The reasons are
-- computed by total functions over the scope and the sweep with no wildcard
-- arms, so a new constructor fails to compile where the reasons are decided.
confirmCascadeNoInstall
  :: NoInstallObservation
  -> Either (NonEmpty NoInstallRefusal) ConfirmedNoInstallCascade
confirmCascadeNoInstall observation =
  case (observedScope observation, observedSweep observation, NonEmpty.nonEmpty refusals) of
    ( CascadeAwsDeclared coordinates
      , CascadeSweepRan (TagSweep.TagSweepConfirmedClean retained)
      , Nothing
      ) ->
        Right
          ConfirmedNoInstallCascade
            { confirmedRetainedByDesign = retained
            , confirmedQueriedRegions = observedQueriedRegions observation
            , confirmedCoordinates = coordinates
            , confirmedAccount = observedAccount observation
            , confirmedRootFindings = observedRoots observation
            }
    (_, _, Just reasons) -> Left reasons
    (_, _, Nothing) -> Left (RefusedSweepInconsistent :| [])
 where
  scope = observedScope observation
  sweep = observedSweep observation
  refusals =
    scopeRefusals scope
      ++ rootRefusals
        (observedRepoRoot observation)
        (observedConfiguredRoot observation)
        (observedRoots observation)
      ++ sweepRefusals scope sweep
      ++ coverageRefusals
        scope
        sweep
        (observedQueriedRegions observation)
        (observedAccount observation)

-- | The exit a confirmed no-install cascade may carry. Holding the value is the
-- whole authorization: there is no arm, flag, or table row that reaches this.
confirmedNoInstallCascadeExit :: ConfirmedNoInstallCascade -> ExitCode
confirmedNoInstallCascadeExit _ = ExitSuccess

-- Narration ------------------------------------------------------------------

-- | A human description of each long-lived retention marker. Total over the
-- markers the sweep carves out; the renderer prints an explicit unlabelled line
-- for any it cannot describe, never dropping one.
carveOutDescription :: (String, String) -> Maybe String
carveOutDescription marker
  | marker == ("prodbox.io/role", "long-lived-pulumi-state") =
      Just "the pulumi_state_backend bucket"
  | marker == ("prodbox.io/substrate", "shared") =
      Just "the aws-ses cross-substrate stack"
  | marker == (TagSweep.ebsLifecycleTagKey, TagSweep.ebsRetainedLifecycleValue) =
      Just "retained-production EBS volumes"
  | otherwise = Nothing

-- | The narration of a confirmed no-install cascade. It never says the account
-- is empty and never says a completion receipt exists.
renderConfirmedNoInstallCascade :: ConfirmedNoInstallCascade -> [String]
renderConfirmedNoInstallCascade confirmed =
  [ "No local RKE2 install was present, so this cascade reached no phase and destroyed nothing. It queried AWS read-only on this invocation."
  , "Authored AWS coordinates checked (field names only): "
      ++ intercalate ", " (map authoredCoordinateField (NonEmpty.toList (confirmedCoordinates confirmed)))
      ++ "."
  , "Regions queried: " ++ intercalate ", " (map Text.unpack (confirmedQueriedRegions confirmed)) ++ "."
  ]
    ++ accountLines (confirmedAccount confirmed) (confirmedCoordinates confirmed)
    ++ [ "Result: no per-run residue carrying a prodbox managed-by tag or a kubernetes.io/cluster tag was found in those regions. This is NOT an empty account."
       ]
    ++ retainedLines (confirmedRetainedByDesign confirmed)
    ++ [ "Not visible to this check: untagged IAM principals, access keys and DNS records are invisible to the Tagging API, so their absence is not shown here."
       ]
    ++ rootLines (confirmedRootFindings confirmed)
    ++ [ "This exit is not a completion receipt, and nothing was recorded. No exit status from this route authorizes deleting the retained root."
       ]
 where
  accountLines evidence coordinates = case NonEmpty.nonEmpty (pinningCoordinates (NonEmpty.toList coordinates)) of
    Nothing ->
      [ "Account: the account is the one the admin credential belongs to. No authored coordinate names an account, so account coverage was not verified beyond the credential itself."
      ]
    Just pins ->
      [ "Account: the account is the one the admin credential belongs to. Hosted zones checked for visibility from it: "
          ++ intercalate ", " (map (zoneLine evidence) (NonEmpty.toList pins))
          ++ "."
      ]
  zoneLine evidence pin =
    authoredCoordinateField pin
      ++ " "
      ++ case evidence of
        AccountNotProbed -> "(not probed)"
        AccountProbed probes -> maybe "(not probed)" renderVisibility (lookup pin probes)
  renderVisibility visibility = case visibility of
    HostedZoneVisible -> "(visible)"
    HostedZoneNotVisible detail -> "(not visible: " ++ detail ++ ")"
    HostedZoneUnanswered detail -> "(unanswered: " ++ detail ++ ")"
  retainedLines retained =
    let arns = nub (map TagSweep.taggedResourceArn retained)
        returned
          | null arns =
              "Still present by design: none were returned by the tag query; absence from a tag query is not evidence they are gone."
          | otherwise =
              "Still present by design (returned by the tag query): " ++ intercalate ", " arns ++ "."
        carveOuts =
          "Retained by design and left in place, whether or not the query returned them: "
            ++ intercalate "; " (map describeMarker TagSweep.longLivedRetentionMarkers)
            ++ "."
     in [returned, carveOuts]
  describeMarker marker =
    fromMaybe
      ("unlabelled retention marker " ++ fst marker ++ "=" ++ snd marker)
      (carveOutDescription marker)
  rootLines findings =
    "Retained roots surveyed, not read:"
      : [ "  - " ++ rootFindingPath finding ++ " " ++ renderRootObservation (rootFindingObservation finding)
        | finding <- findings
        ]
  renderRootObservation observation = case observation of
    RootAbsent -> "(not found)"
    RootPresent entries -> "(found, " ++ show entries ++ " top-level entries)"
    RootUnexaminable detail -> "(could not be examined: " ++ detail ++ ")"

-- | One block per refusal reason, each saying what to do. The caller prints the
-- preamble that names the durable cleanup namespace and the recovery-plane
-- disposition.
renderNoInstallRefusals :: NonEmpty NoInstallRefusal -> [String]
renderNoInstallRefusals = concatMap renderRefusal . NonEmpty.toList
 where
  renderRefusal reason = case reason of
    RefusedNothingAuthored ->
      [ "No AWS coordinate is authored in this deployment's Tier-0 configuration, so there is no AWS account whose residue this cascade could check, and nothing was observed. To remove only the local substrate, run `prodbox cluster delete --yes`."
      ]
    RefusedScopeUnreadable detail ->
      [ "The Tier-0 configuration could not be read ("
          ++ detail
          ++ "), so which AWS coordinates are authored is unknown. Unknown is not absence. No credential was requested and nothing was queried."
      ]
    RefusedRootNotExamined path ->
      ["Retained root `" ++ path ++ "` was not examined, so this cascade cannot say what it holds."]
    RefusedRootUnexaminable path detail ->
      ["Retained root `" ++ path ++ "` could not be examined: " ++ detail ++ "."]
    RefusedSweepInconsistent ->
      [ "The sweep reported that it was not owed although AWS coordinates are authored. That is inconsistent evidence and is refused."
      ]
    RefusedSweepNotRun detail ->
      [ "The postflight tag sweep is owed and was not run ("
          ++ detail
          ++ "): no ephemeral admin AWS credential was available, so no Tagging API query was attempted. This is not a confirmation that no AWS residue exists. Re-run with an admin AWS credential available."
      ]
    RefusedResidueEscaped rows ->
      ( "The postflight tag sweep found "
          ++ show (length (NonEmpty.toList rows))
          ++ " resource(s) this cascade did not destroy; operator action required:"
      )
        : [ "  - "
              ++ TagSweep.taggedResourceArn row
              ++ " (matched tag: "
              ++ TagSweep.taggedResourceMatchedTagKey row
              ++ ")"
          | row <- NonEmpty.toList rows
          ]
    RefusedSweepUnconfirmed detail ->
      [ "The postflight tag sweep could not be confirmed: "
          ++ detail
          ++ ". An unanswered query is never read as absence."
      ]
    RefusedRegionsNotCovered regions ->
      [ "Authored region(s) "
          ++ intercalate ", " (map Text.unpack (NonEmpty.toList regions))
          ++ " were not among the regions the sweep queried, so residue there was not checked."
      ]
    RefusedAccountNotCovered gaps ->
      ( "The admin credential could not be tied to this deployment's account. Either it belongs to a different account than this checkout was deployed into, or the authored zone no longer exists. Use the matching credential or clear the stale coordinate. Zones not visible from it:"
      )
        : [ "  - " ++ authoredCoordinateField coordinate ++ " " ++ renderGap visibility
          | (coordinate, visibility) <- NonEmpty.toList gaps
          ]
  renderGap visibility = case visibility of
    HostedZoneVisible -> "(visible)"
    HostedZoneNotVisible detail -> "(not visible: " ++ detail ++ ")"
    HostedZoneUnanswered detail -> "(unanswered: " ++ detail ++ ")"

-- | The retained-state sentence for a run that asked AWS and did not confirm.
-- It must not borrow the sentence for a run that observed nothing.
retainedStateObservedNotConfirmedLine :: String
retainedStateObservedNotConfirmedLine =
  "This cascade reached no phase and attempted no per-run AWS destroy. It queried AWS read-only and did NOT confirm absence. It carries NO completion receipt, so it does not establish that the retained root above may be retired: no exit status from this route authorizes deleting it. Resolve what is reported above and retry, or destroy a named stack directly with `prodbox aws stack <name> destroy --yes`."
