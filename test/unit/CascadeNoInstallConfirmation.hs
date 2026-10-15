{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 6.6: a @cluster delete --cascade@ with no local install can still
-- ask AWS.
--
-- The decision is pure ("Prodbox.Lifecycle.CascadeNoInstall"), so every case
-- here constructs evidence and asks what it licenses. The retained-root survey
-- is the one effect, and it is exercised against temporary directories only: a
-- test must never look at, let alone touch, the repository's real roots.
module CascadeNoInstallConfirmation
  ( cascadeNoInstallConfirmationSuite
  )
where

import Control.Exception (IOException, finally, try)
import Control.Monad (forM_, unless)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.CLI.Rke2
  ( CascadeUninstallGate (..)
  , cascadeSweepCredentialAbsentExit
  , decideCascadeUninstallGate
  , settleUnreadableScope
  )
import Prodbox.Lifecycle.CascadeNoInstall
import Prodbox.Lifecycle.RetainedRootSurvey
  ( surveyRetainedRoots
  )
import Prodbox.Lifecycle.TagSweep
  ( TagSweepInput (..)
  , TagSweepScope (..)
  , TagSweepVerdict (..)
  , TaggedResource (..)
  , decideTagSweep
  , discoverClusterTaggedAwsResourcesForAll
  , discoverClusterTaggedAwsResourcesWith
  , longLivedRetentionMarkers
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( AwsCredentialsRef (..)
  , AwsSubstrateSection (..)
  , ConfigFile (..)
  , PulumiStateBackendSection (..)
  , Route53Section (..)
  , SesSection (..)
  , defaultConfigFile
  )
import Prodbox.Settings.AwsSubstrateProfile
  ( AwsSubstrateProfileInput (..)
  , mkAwsSubstrateProfile
  )
import Prodbox.Settings.Coordinate
  ( AwsRegion
  , Route53ZoneId
  , mkAwsRegion
  , mkRoute53ZoneId
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Directory
  ( createDirectoryIfMissing
  , createDirectoryLink
  , doesDirectoryExist
  , emptyPermissions
  , listDirectory
  , setOwnerReadable
  , setOwnerSearchable
  , setOwnerWritable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

cascadeNoInstallConfirmationSuite :: SuiteBuilder ()
cascadeNoInstallConfirmationSuite =
  describe "Sprint 6.6 a cascade with no cluster can still ask AWS" $ do
    authoredCoordinateCases
    scopeCases
    fanOutCases
    accountCases
    rootPureCases
    rootSurveyCases
    producerCases
    plannerCases
    narrationCases
    boundedRunnerCases

-- Fixtures -------------------------------------------------------------------

mustRight :: (Show left) => Either left right -> right
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result

regionOf :: FixtureAwsRegion -> AwsRegion
regionOf region = mustRight (mkAwsRegion (fixtureAwsRegion region))

regionText :: FixtureAwsRegion -> Text
regionText = fixtureAwsRegion

zoneA :: Route53ZoneId
zoneA = mustRight (mkRoute53ZoneId "Z0FIXTUREZONEA")

zoneB :: Route53ZoneId
zoneB = mustRight (mkRoute53ZoneId "Z0FIXTUREZONEB")

globalRegion :: Text
globalRegion = awsGlobalServiceRegion

retainedRow :: TaggedResource
retainedRow =
  TaggedResource
    { taggedResourceArn = "arn:aws:s3:::fixture-retained-state"
    , taggedResourceMatchedTagKey = "prodbox.io/role"
    , taggedResourceMatchedTagValue = "long-lived-pulumi-state"
    }

escapedRow :: TaggedResource
escapedRow =
  TaggedResource
    { taggedResourceArn =
        "arn:aws:ec2:" ++ fixtureAwsRegion FixtureEuWest2 ++ ":000000000000:vpc/vpc-escaped"
    , taggedResourceMatchedTagKey = "prodbox.io/run-scope"
    , taggedResourceMatchedTagValue = "escaped-fixture"
    }

validProfileInput :: AwsSubstrateProfileInput
validProfileInput =
  AwsSubstrateProfileInput
    { operator_cidr = "203.0.113.44/32"
    , eks_node_instance_type = "m7i.large"
    , eks_node_disk_size_gib = 61
    , eks_node_min_size = 2
    , eks_node_max_size = 5
    , aws_test_instance_types = ["m7i.large", "m7i.xlarge", "c7i.large"]
    , aws_test_root_volume_types = ["gp3", "io2", "gp2"]
    , aws_test_root_volume_sizes_gib = [31, 32, 33]
    , static_ebs_volume_type = "io2"
    , eks_vpc_cidr = "10.71.0.0/16"
    , eks_subnet_cidrs = ["10.71.10.0/24", "10.71.20.0/24"]
    , aws_test_vpc_cidr = "10.72.0.0/16"
    , aws_test_subnet_cidrs = ["10.72.10.0/24", "10.72.20.0/24", "10.72.30.0/24"]
    }

-- | Each row sets exactly one authored AWS field on the shipped default.
singleFieldConfigs :: [(String, ConfigFile)]
singleFieldConfigs =
  [ ("route53.zone_id", base {route53 = Route53Section {zone_id = "Z0FIXTUREZONEA"}})
  ,
    ( "aws_substrate.hosted_zone_id"
    , base {aws_substrate = (aws_substrate base) {hosted_zone_id = "Z0FIXTUREZONEB"}}
    )
  ,
    ( "aws_substrate.subzone_name"
    , base {aws_substrate = (aws_substrate base) {subzone_name = "aws.fixture.example.com"}}
    )
  ,
    ( "aws_substrate.profile"
    , base
        { aws_substrate =
            (aws_substrate base) {profile = Just (mustRight (mkAwsSubstrateProfile validProfileInput))}
        }
    )
  ,
    ( "aws.region"
    , base {aws = (aws base) {awsCredentialRegion = regionText FixtureEuWest2}}
    )
  ,
    ( "pulumi_state_backend.region"
    , base {pulumi_state_backend = (pulumi_state_backend base) {psbRegion = regionText FixtureCaCentral1}}
    )
  ,
    ( "pulumi_state_backend.bucket_name"
    , base {pulumi_state_backend = (pulumi_state_backend base) {psbBucketName = "fixture-state-bucket"}}
    )
  ,
    ( "ses.sender_domain"
    , base {ses = (ses base) {sender_domain = "mail.fixture.example.com"}}
    )
  ,
    ( "ses.receive_subdomain"
    , base {ses = (ses base) {receive_subdomain = "inbox"}}
    )
  ,
    ( "ses.capture_bucket"
    , base {ses = (ses base) {capture_bucket = "fixture-capture-bucket"}}
    )
  ]
 where
  base = defaultConfigFile

-- | A base case every refusal test varies exactly one input away from.
positive :: NoInstallObservation
positive =
  NoInstallObservation
    { observedScope =
        CascadeAwsDeclared
          (AuthoredHomeZone zoneA :| [AuthoredBackendRegion (regionOf FixtureCaCentral1)])
    , observedSweep = CascadeSweepRan (TagSweepConfirmedClean [retainedRow])
    , observedQueriedRegions = [regionText FixtureEuWest2, regionText FixtureCaCentral1, globalRegion]
    , observedAccount = AccountProbed [(AuthoredHomeZone zoneA, HostedZoneVisible)]
    , observedRepoRoot = "/work/repo"
    , observedConfiguredRoot = "/work/repo/.data"
    , observedRoots = examinedRoots
    }

examinedRoots :: [RetainedRootFinding]
examinedRoots =
  [ RetainedRootFinding RootDefaultProduction "/work/repo/.data" RootAbsent
  , RetainedRootFinding RootTest "/work/repo/.test-data" (RootPresent 1)
  ]

sweepInputIn :: FixtureAwsRegion -> TagSweepInput
sweepInputIn region =
  TagSweepInput
    { tagSweepEnvironment = []
    , tagSweepClusterName = Nothing
    , tagSweepWorkingDirectory = Nothing
    , tagSweepRunRegion = regionText region
    }

isRight' :: Either left right -> Bool
isRight' value = case value of
  Right _ -> True
  Left _ -> False

reasonsOf :: NoInstallObservation -> [NoInstallRefusal]
reasonsOf observation = case confirmCascadeNoInstall observation of
  Left reasons -> NonEmpty.toList reasons
  Right _ -> []

-- Authored coordinates -------------------------------------------------------

authoredCoordinateCases :: SuiteBuilder ()
authoredCoordinateCases = do
  it "authors nothing in the shipped default, including the always-present key prefix" $ do
    cascadeAwsScopeFromConfig (Right defaultConfigFile) `shouldBe` CascadeAwsUndeclared
    cascadeAwsScopeOwesSweep (cascadeAwsScopeFromConfig (Right defaultConfigFile))
      `shouldBe` False
    -- The prefix is non-empty in the default, so counting it would make every
    -- deployment look as if it authored an AWS coordinate.
    psbKeyPrefix (pulumi_state_backend defaultConfigFile) `shouldNotBe` ""

  it "reads each of the ten fields alone as exactly that one coordinate" $ do
    let scopes = [(name, cascadeAwsScopeFromConfig (Right config)) | (name, config) <- singleFieldConfigs]
    forM_ scopes (uncurry expectSingleCoordinate)
    map fst singleFieldConfigs `shouldBe` authoredCoordinateFieldNames

  it
    "does not read a blank or whitespace-only field as authored, and treats a malformed one as unreadable"
    $ do
      let blank = defaultConfigFile {route53 = Route53Section {zone_id = "   "}}
          malformed = defaultConfigFile {route53 = Route53Section {zone_id = "not-a-zone"}}
      cascadeAwsScopeFromConfig (Right blank) `shouldNotSatisfy'` isDeclared
      cascadeAwsScopeFromConfig (Right malformed) `shouldSatisfy` isUnreadable
      cascadeAwsScopeFromConfig (Left "no prodbox.dhall")
        `shouldBe` CascadeAwsScopeUnreadable "no prodbox.dhall"

  it "pins the field-name table to the constructor set" $ do
    let representatives =
          [ AuthoredHomeZone zoneA
          , AuthoredSubstrateZone zoneB
          , AuthoredSubstrateSubzone
          , AuthoredSubstrateProfile
          , AuthoredOperationalRegion (regionOf FixtureEuWest2)
          , AuthoredBackendRegion (regionOf FixtureCaCentral1)
          , AuthoredBackendBucket
          , AuthoredSesSenderDomain
          , AuthoredSesReceiveSubdomain
          , AuthoredSesCaptureBucket
          ]
    map authoredCoordinateField representatives `shouldBe` authoredCoordinateFieldNames
    length (nub authoredCoordinateFieldNames) `shouldBe` length authoredCoordinateFieldNames
 where
  expectSingleCoordinate :: String -> CascadeAwsScope -> Expectation
  expectSingleCoordinate name scope = case scope of
    CascadeAwsDeclared (coordinate :| rest) -> do
      authoredCoordinateField coordinate `shouldBe` name
      rest `shouldBe` []
    other -> expectationFailure (name ++ " alone should be declared, got " ++ show other)
  isDeclared scope = case scope of
    CascadeAwsDeclared _ -> True
    CascadeAwsUndeclared -> False
    CascadeAwsScopeUnreadable _ -> False
  isUnreadable scope = case scope of
    CascadeAwsScopeUnreadable _ -> True
    CascadeAwsUndeclared -> False
    CascadeAwsDeclared _ -> False
  shouldNotSatisfy' value predicate = value `shouldSatisfy` (not . predicate)

-- Scope and the full cascade -------------------------------------------------

scopeCases :: SuiteBuilder ()
scopeCases = do
  it "owes the sweep for any authored coordinate, which a Route 53 zone id alone now does" $ do
    let zoneOnly =
          cascadeAwsScopeFromConfig
            (Right defaultConfigFile {route53 = Route53Section {zone_id = "Z0FIXTUREZONEA"}})
    cascadeAwsScopeOwesSweep zoneOnly `shouldBe` True
    -- It used to be undeclared (only a substrate profile counted), so a
    -- deployment with a home zone and no profile exited zero with no query.
    cascadeSweepCredentialAbsentExit zoneOnly `shouldBe` ExitFailure 1
    cascadeSweepCredentialAbsentExit CascadeAwsUndeclared `shouldBe` ExitSuccess
    cascadeSweepCredentialAbsentExit (CascadeAwsScopeUnreadable "x") `shouldBe` ExitFailure 1

  it "keeps the admitting sets of the full cascade and the no-install cascade deliberately different" $ do
    -- The full cascade has already run its destroy phases against exact
    -- checkpoints, so a sweep that was never owed may admit its uninstall. The
    -- no-install cascade observed nothing by itself, so a sweep that was never
    -- owed would confirm from silence. They must not be "repaired" into one.
    decideCascadeUninstallGate CascadeSweepNotOwed `shouldBe` CascadeUninstallAdmitted
    forM_ allScopes $ \scope ->
      isRight'
        (confirmCascadeNoInstall positive {observedScope = scope, observedSweep = CascadeSweepNotOwed})
        `shouldBe` False

  it "never lets an unreadable declaration stand behind a clean full-cascade sweep" $ do
    let clean = CascadeSweepRan (TagSweepConfirmedClean [])
        escaped = CascadeSweepRan (TagSweepEscaped [] [escapedRow])
        unreadable = CascadeAwsScopeUnreadable "no config"
    -- A clean answer from the run region cannot cover regions nobody could read.
    settleUnreadableScope unreadable clean `shouldSatisfy` isUnconfirmedSweep
    -- Everything else passes through untouched.
    settleUnreadableScope unreadable escaped `shouldBe` escaped
    settleUnreadableScope unreadable (CascadeSweepNotRun "x") `shouldBe` CascadeSweepNotRun "x"
    settleUnreadableScope (observedScope positive) clean `shouldBe` clean
    settleUnreadableScope CascadeAwsUndeclared CascadeSweepNotOwed `shouldBe` CascadeSweepNotOwed
 where
  isUnconfirmedSweep sweep = case sweep of
    CascadeSweepRan (TagSweepUnconfirmed _) -> True
    CascadeSweepRan (TagSweepConfirmedClean _) -> False
    CascadeSweepRan (TagSweepEscaped _ _) -> False
    CascadeSweepNotOwed -> False
    CascadeSweepNotRun _ -> False

-- Fan-out and region coverage ------------------------------------------------

fanOutCases :: SuiteBuilder ()
fanOutCases = do
  it "queries one input per distinct region and reports the regions it actually asked" $ do
    let base = sweepInput FixtureEuWest2
        authoredB = [AuthoredBackendRegion (regionOf FixtureCaCentral1)]
        inputs = cascadeSweepInputs base authoredB
    map tagSweepRunRegion inputs
      `shouldBe` [regionText FixtureEuWest2, regionText FixtureCaCentral1]
    sort (cascadeSweepQueriedRegions inputs)
      `shouldBe` sort (nub [regionText FixtureEuWest2, regionText FixtureCaCentral1, globalRegion])
    -- The authored region equal to the run region collapses to one input, and
    -- no authored region asks only for the run region.
    length (cascadeSweepInputs base [AuthoredBackendRegion (regionOf FixtureEuWest2)]) `shouldBe` 1
    length (cascadeSweepInputs base []) `shouldBe` 1

  it "covers an authored region that differs from the admin credential's region" $ do
    let coordinates = AuthoredBackendRegion (regionOf FixtureCaCentral1) :| []
        queried =
          cascadeSweepQueriedRegions
            (cascadeSweepInputs (sweepInput FixtureEuWest2) (NonEmpty.toList coordinates))
    missingSweepRegions coordinates queried `shouldBe` []

  it "refuses an authored region the sweep did not ask, and a zone with no global-service query" $ do
    reasonsOf positive {observedQueriedRegions = [regionText FixtureEuWest2, globalRegion]}
      `shouldBe` [RefusedRegionsNotCovered (regionText FixtureCaCentral1 :| [])]
    reasonsOf
      positive {observedQueriedRegions = [regionText FixtureEuWest2, regionText FixtureCaCentral1]}
      `shouldBe` [RefusedRegionsNotCovered (globalRegion :| [])]
 where
  sweepInput = sweepInputIn

-- Account evidence -----------------------------------------------------------

accountCases :: SuiteBuilder ()
accountCases = do
  it "classifies a hosted-zone probe as visible only on exit zero" $ do
    classifyHostedZoneProbe ExitSuccess "" `shouldBe` HostedZoneVisible
    classifyHostedZoneProbe (ExitFailure 254) "An error occurred (NoSuchHostedZone) when calling"
      `shouldSatisfy` isNotVisible
    classifyHostedZoneProbe (ExitFailure 254) "An error occurred (AccessDenied)"
      `shouldSatisfy` isUnanswered
    classifyHostedZoneProbe (ExitFailure 1) "" `shouldSatisfy` isUnanswered

  it "finds a gap for every pinning zone that was not seen, and none when nothing pins an account" $ do
    let pinned = AuthoredHomeZone zoneA :| []
        twoZones = AuthoredHomeZone zoneA :| [AuthoredSubstrateZone zoneB]
    accountCoverageGaps pinned (AccountProbed [(AuthoredHomeZone zoneA, HostedZoneVisible)])
      `shouldBe` []
    length
      (accountCoverageGaps pinned (AccountProbed [(AuthoredHomeZone zoneA, HostedZoneNotVisible "gone")]))
      `shouldBe` 1
    length
      (accountCoverageGaps pinned (AccountProbed [(AuthoredHomeZone zoneA, HostedZoneUnanswered "slow")]))
      `shouldBe` 1
    length (accountCoverageGaps pinned AccountNotProbed) `shouldBe` 1
    length
      ( accountCoverageGaps
          twoZones
          ( AccountProbed
              [ (AuthoredHomeZone zoneA, HostedZoneVisible)
              , (AuthoredSubstrateZone zoneB, HostedZoneNotVisible "gone")
              ]
          )
      )
      `shouldBe` 1
    -- Buckets, SES identities and regions name no account, so authoring only
    -- those must not lock the arm out forever.
    accountCoverageGaps (AuthoredBackendBucket :| [AuthoredSesSenderDomain]) AccountNotProbed
      `shouldBe` []

  it "refuses a clean sweep whose credential cannot see the authored zone" $ do
    reasonsOf
      positive
        { observedAccount = AccountProbed [(AuthoredHomeZone zoneA, HostedZoneNotVisible "no such zone")]
        }
      `shouldSatisfy` any isAccountRefusal
    reasonsOf positive {observedAccount = AccountNotProbed} `shouldSatisfy` any isAccountRefusal
 where
  isNotVisible visibility = case visibility of
    HostedZoneNotVisible _ -> True
    HostedZoneVisible -> False
    HostedZoneUnanswered _ -> False
  isUnanswered visibility = case visibility of
    HostedZoneUnanswered _ -> True
    HostedZoneVisible -> False
    HostedZoneNotVisible _ -> False
  isAccountRefusal reason = case reason of
    RefusedAccountNotCovered _ -> True
    _ -> False

-- Retained roots (pure) ------------------------------------------------------

rootPureCases :: SuiteBuilder ()
rootPureCases = do
  it "derives the roots a cascade must account for from the repository and configured root" $ do
    map snd (retainedRootCandidates "/work/repo" "/work/repo/.data")
      `shouldBe` ["/work/repo/.data", "/work/repo/.test-data"]
    map snd (retainedRootCandidates "/work/repo" "/srv/elsewhere")
      `shouldBe` ["/srv/elsewhere", "/work/repo/.data", "/work/repo/.test-data"]
    map snd (retainedRootCandidates "/work/repo" "/work/repo/.test-data/")
      `shouldBe` ["/work/repo/.test-data", "/work/repo/.data"]
    map fst (retainedRootCandidates "/work/repo" "/srv/elsewhere")
      `shouldBe` [RootConfigured, RootDefaultProduction, RootTest]

  it "refuses a candidate root that has no finding, and any root that could not be examined" $ do
    -- The second retained root is present in the worktree and was not looked at.
    rootRefusals
      "/work/repo"
      "/work/repo/.data"
      [RetainedRootFinding RootDefaultProduction "/work/repo/.data" RootAbsent]
      `shouldBe` [RefusedRootNotExamined "/work/repo/.test-data"]
    rootRefusals "/work/repo" "/work/repo/.data" examinedRoots `shouldBe` []
    rootRefusals
      "/work/repo"
      "/work/repo/.data"
      ( examinedRoots
          ++ [RetainedRootFinding RootDiscovered "/work/repo/old" (RootUnexaminable "permission denied")]
      )
      `shouldBe` [RefusedRootUnexaminable "/work/repo/old" "permission denied"]
    -- A finding for some other path does not satisfy a candidate.
    rootRefusals "/work/repo" "/work/repo/.data" [RetainedRootFinding RootTest "/elsewhere" RootAbsent]
      `shouldSatisfy` (\reasons -> length reasons == 2)

-- Retained roots (effects, temp directories only) -----------------------------

rootSurveyCases :: SuiteBuilder ()
rootSurveyCases = do
  it "names an absent default root and a present test root, and writes nothing" $ do
    withSystemTempDirectory "prodbox-survey-basic" $ \tmp -> do
      createDirectoryIfMissing True (tmp </> ".test-data" </> "case")
      before <- listTree tmp
      findings <- surveyRetainedRoots tmp (tmp </> "custom")
      map rootFindingObservation findings `shouldBe` [RootAbsent, RootAbsent, RootPresent 1]
      map rootFindingKind findings `shouldBe` [RootConfigured, RootDefaultProduction, RootTest]
      after <- listTree tmp
      after `shouldBe` before

  it
    "discovers a root left behind by an earlier configuration, and not a directory without the signature"
    $ do
      withSystemTempDirectory "prodbox-survey-discover" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "old-root" </> "vault" </> "vault" </> "0")
        createDirectoryIfMissing True (tmp </> "unrelated" </> "vault")
        createDirectoryIfMissing True (tmp </> ".git")
        findings <- surveyRetainedRoots tmp (tmp </> ".data")
        [rootFindingPath f | f <- findings, rootFindingKind f == RootDiscovered]
          `shouldBe` [tmp </> "old-root"]

  it "cannot examine a regular file or a link that leaves the worktree, and follows one that stays" $ do
    withSystemTempDirectory "prodbox-survey-links" $ \tmp -> do
      withSystemTempDirectory "prodbox-survey-outside" $ \outside -> do
        -- A regular file where a root should be.
        writeFileAt (tmp </> ".data") "not a directory"
        -- A link to a directory outside the worktree.
        createDirectoryLink outside (tmp </> ".test-data")
        findings <- surveyRetainedRoots tmp (tmp </> ".data")
        [rootFindingObservation f | f <- findings, rootFindingPath f == tmp </> ".data"]
          `shouldBe` [RootUnexaminable "not a directory"]
        [rootFindingObservation f | f <- findings, rootFindingPath f == tmp </> ".test-data"]
          `shouldBe` [RootUnexaminable "symbolic link resolving outside the worktree"]
    withSystemTempDirectory "prodbox-survey-inside" $ \tmp -> do
      createDirectoryIfMissing True (tmp </> "real" </> "entry")
      createDirectoryLink (tmp </> "real") (tmp </> ".test-data")
      findings <- surveyRetainedRoots tmp (tmp </> ".data")
      [rootFindingObservation f | f <- findings, rootFindingPath f == tmp </> ".test-data"]
        `shouldBe` [RootPresent 1]

  it "reports a root it cannot search as unexaminable and never as absent" $ do
    withSystemTempDirectory "prodbox-survey-denied" $ \tmp -> do
      let locked = tmp </> "locked"
          restore = setPermissions locked (allowAll emptyPermissions)
      createDirectoryIfMissing True (locked </> "inner")
      setPermissions locked emptyPermissions
      enforced <- (try (listDirectory locked) :: IO (Either IOException [FilePath]))
      -- Running with enough privilege to ignore permissions leaves nothing to
      -- observe; every other host must refuse.
      unless (isRight' enforced) $ do
        findings <- surveyRetainedRoots tmp (locked </> "root") `finally` restore
        [rootFindingObservation f | f <- findings, rootFindingPath f == locked </> "root"]
          `shouldSatisfy` all isUnexaminableObservation
        [rootFindingObservation f | f <- findings, rootFindingPath f == locked </> "root"]
          `shouldSatisfy` (not . null)

  it "does not drop a left-behind root it cannot search to its signature" $ do
    withSystemTempDirectory "prodbox-survey-denied-discovery" $ \tmp -> do
      let guarded = tmp </> "old-root" </> "vault"
          restore = setPermissions guarded (allowAll emptyPermissions)
      createDirectoryIfMissing True (guarded </> "vault" </> "0")
      setPermissions guarded emptyPermissions
      enforced <- (try (listDirectory guarded) :: IO (Either IOException [FilePath]))
      unless (isRight' enforced) $ do
        findings <- surveyRetainedRoots tmp (tmp </> ".data") `finally` restore
        [rootFindingObservation f | f <- findings, rootFindingPath f == tmp </> "old-root"]
          `shouldSatisfy` (\observations -> not (null observations) && all isUnexaminableObservation observations)
 where
  writeFileAt path contents = writeFile path contents
  allowAll = setOwnerReadable True . setOwnerWritable True . setOwnerSearchable True
  isUnexaminableObservation observation = case observation of
    RootUnexaminable _ -> True
    RootAbsent -> False
    RootPresent _ -> False
  listTree directory = do
    names <- listDirectory directory
    nested <-
      mapM
        ( \name -> do
            let path = directory </> name
            isDirectory <- doesDirectoryExist path
            children <- if isDirectory then listTree path else pure []
            pure (path : children)
        )
        (sort names)
    pure (concat nested)

-- The sole producer ----------------------------------------------------------

producerCases :: SuiteBuilder ()
producerCases = do
  it "confirms exactly one evidence shape and exits zero from the sealed value" $ do
    case confirmCascadeNoInstall positive of
      Right confirmed -> do
        confirmedNoInstallCascadeExit confirmed `shouldBe` ExitSuccess
        confirmedRetainedByDesign confirmed `shouldBe` [retainedRow]
        confirmedQueriedRegions confirmed `shouldBe` observedQueriedRegions positive
      Left reasons -> expectationFailure ("the positive control must confirm: " ++ show reasons)

  it "names the one refusal for each input varied away from the positive control" $ do
    reasonsOf positive {observedScope = CascadeAwsUndeclared, observedSweep = CascadeSweepNotOwed}
      `shouldBe` [RefusedNothingAuthored]
    reasonsOf positive {observedSweep = CascadeSweepNotOwed} `shouldBe` [RefusedSweepInconsistent]
    reasonsOf positive {observedScope = CascadeAwsScopeUnreadable "no config"}
      `shouldBe` [RefusedScopeUnreadable "no config"]
    reasonsOf positive {observedSweep = CascadeSweepNotRun "no credential"}
      `shouldBe` [RefusedSweepNotRun "no credential"]
    reasonsOf positive {observedSweep = CascadeSweepRan (TagSweepEscaped [] [escapedRow])}
      `shouldBe` [RefusedResidueEscaped (escapedRow :| [])]
    reasonsOf positive {observedSweep = CascadeSweepRan (TagSweepUnconfirmed "tagging api unreachable")}
      `shouldBe` [RefusedSweepUnconfirmed "tagging api unreachable"]
    reasonsOf positive {observedRoots = take 1 examinedRoots}
      `shouldBe` [RefusedRootNotExamined "/work/repo/.test-data"]
    reasonsOf
      positive
        { observedRoots =
            examinedRoots ++ [RetainedRootFinding RootDiscovered "/work/repo/old" (RootUnexaminable "denied")]
        }
      `shouldBe` [RefusedRootUnexaminable "/work/repo/old" "denied"]

  it "reports every applicable reason in a fixed order rather than the first" $ do
    let broken =
          positive
            { observedSweep = CascadeSweepRan (TagSweepEscaped [] [escapedRow])
            , observedQueriedRegions = [regionText FixtureEuWest2]
            , observedRoots = take 1 examinedRoots
            }
        tags = map reasonTag (reasonsOf broken)
    tags `shouldBe` ["root", "escaped", "regions"]

  it "confirms in exactly one cell of the whole evidence product" $ do
    let cells =
          [ observation
          | scope <- allScopes
          , sweep <- allSweeps
          , queried <- [observedQueriedRegions positive, [regionText FixtureEuWest2]]
          , account <- allAccounts
          , roots <- allRoots
          , let observation =
                  positive
                    { observedScope = scope
                    , observedSweep = sweep
                    , observedQueriedRegions = queried
                    , observedAccount = account
                    , observedRoots = roots
                    }
          ]
        confirming = [observation | observation <- cells, isRight' (confirmCascadeNoInstall observation)]
    length cells `shouldBe` (3 * 5 * 2 * 4 * 3)
    length confirming `shouldBe` 1
    confirming `shouldBe` [positive]
 where
  reasonTag :: NoInstallRefusal -> String
  reasonTag reason = case reason of
    RefusedNothingAuthored -> "nothing"
    RefusedScopeUnreadable _ -> "scope"
    RefusedRootNotExamined _ -> "root"
    RefusedRootUnexaminable _ _ -> "root"
    RefusedSweepInconsistent -> "inconsistent"
    RefusedSweepNotRun _ -> "notrun"
    RefusedResidueEscaped _ -> "escaped"
    RefusedSweepUnconfirmed _ -> "unconfirmed"
    RefusedRegionsNotCovered _ -> "regions"
    RefusedAccountNotCovered _ -> "account"
  allSweeps =
    [ CascadeSweepNotOwed
    , CascadeSweepNotRun "no credential"
    , CascadeSweepRan (TagSweepEscaped [] [escapedRow])
    , CascadeSweepRan (TagSweepUnconfirmed "unreachable")
    , CascadeSweepRan (TagSweepConfirmedClean [retainedRow])
    ]
  allAccounts =
    [ AccountProbed [(AuthoredHomeZone zoneA, HostedZoneVisible)]
    , AccountProbed [(AuthoredHomeZone zoneA, HostedZoneNotVisible "gone")]
    , AccountProbed [(AuthoredHomeZone zoneA, HostedZoneUnanswered "slow")]
    , AccountNotProbed
    ]
  allRoots =
    [ examinedRoots
    , take 1 examinedRoots
    , examinedRoots ++ [RetainedRootFinding RootDiscovered "/work/repo/old" (RootUnexaminable "denied")]
    ]

allScopes :: [CascadeAwsScope]
allScopes =
  [ CascadeAwsUndeclared
  , observedScope positive
  , CascadeAwsScopeUnreadable "no config"
  ]

-- Offline-first ordering -----------------------------------------------------

plannerCases :: SuiteBuilder ()
plannerCases = do
  it "asks AWS only when every refusal that needs no network answer has passed" $ do
    let plan scope roots = planNoInstallCascade scope "/work/repo" "/work/repo/.data" roots
    plan (observedScope positive) examinedRoots
      `shouldBe` NoInstallQueryAws (AuthoredHomeZone zoneA :| [AuthoredBackendRegion (regionOf FixtureCaCentral1)])
    plan CascadeAwsUndeclared examinedRoots
      `shouldBe` NoInstallRefuseOffline (RefusedNothingAuthored :| [])
    plan (CascadeAwsScopeUnreadable "x") examinedRoots
      `shouldBe` NoInstallRefuseOffline (RefusedScopeUnreadable "x" :| [])
    plan (observedScope positive) (take 1 examinedRoots)
      `shouldBe` NoInstallRefuseOffline (RefusedRootNotExamined "/work/repo/.test-data" :| [])

  it "reports the offline reasons of the plan as a prefix of what the producer reports" $ do
    forM_ allScopes $ \scope -> do
      let roots = take 1 examinedRoots
          offline = case planNoInstallCascade scope "/work/repo" "/work/repo/.data" roots of
            NoInstallRefuseOffline reasons -> NonEmpty.toList reasons
            NoInstallQueryAws _ -> []
          produced = reasonsOf positive {observedScope = scope, observedRoots = roots}
      unless (null offline) $ take (length offline) produced `shouldBe` offline

  it "classifies a refusal as unobserved unless AWS was asked" $ do
    noInstallObservationClass (RefusedNothingAuthored :| [RefusedRootNotExamined "x"])
      `shouldBe` NoInstallUnobserved
    noInstallObservationClass (RefusedSweepNotRun "no credential" :| []) `shouldBe` NoInstallUnobserved
    noInstallObservationClass (RefusedSweepUnconfirmed "x" :| [])
      `shouldBe` NoInstallObservedNotConfirmed
    noInstallObservationClass (RefusedResidueEscaped (escapedRow :| []) :| [])
      `shouldBe` NoInstallObservedNotConfirmed

-- Narration ------------------------------------------------------------------

narrationCases :: SuiteBuilder ()
narrationCases = do
  it "says what a confirmed sweep does not license" $ do
    case confirmCascadeNoInstall positive of
      Left reasons -> expectationFailure (show reasons)
      Right confirmed -> do
        let rendered = unlines (renderConfirmedNoInstallCascade confirmed)
        rendered
          `shouldSatisfy` containsAll
            [ "per-run residue"
            , "NOT an empty account"
            , "not a completion receipt"
            , "nothing was recorded"
            , "surveyed, not read"
            , "No exit status from this route authorizes deleting the retained root"
            , "untagged"
            , "route53.zone_id"
            , regionTextString FixtureCaCentral1
            , "(visible)"
            ]
        -- The overclaims this narration must never make.
        rendered `shouldSatisfy` (not . ("empty account" `isInfixOf`) . stripNot)
        rendered `shouldSatisfy` (not . ("Sprint " `isInfixOf`))

  it "names every retention carve-out even when the tag query returned none" $ do
    case confirmCascadeNoInstall positive {observedSweep = CascadeSweepRan (TagSweepConfirmedClean [])} of
      Left reasons -> expectationFailure (show reasons)
      Right confirmed -> do
        let rendered = unlines (renderConfirmedNoInstallCascade confirmed)
        rendered
          `shouldSatisfy` containsAll
            [ "none were returned by the tag query"
            , "absence from a tag query is not evidence they are gone"
            , "the pulumi_state_backend bucket"
            , "the aws-ses cross-substrate stack"
            , "retained-production EBS volumes"
            ]
    forM_ longLivedRetentionMarkers $ \marker -> carveOutDescription marker `shouldSatisfy` isJust'

  it
    "renders a refusal with what to do, and the observed-not-confirmed sentence does not borrow the silent one"
    $ do
      let blocks =
            unlines (renderNoInstallRefusals (RefusedNothingAuthored :| [RefusedSweepNotRun "no credential"]))
      blocks `shouldSatisfy` containsAll ["cluster delete --yes", "no Tagging API query was attempted"]
      retainedStateObservedNotConfirmedLine
        `shouldSatisfy` containsAll
          [ "did NOT confirm absence"
          , "NO completion receipt"
          , "no exit status from this route authorizes deleting it"
          ]
      retainedStateObservedNotConfirmedLine
        `shouldSatisfy` (not . ("no confirmed postflight sweep" `isInfixOf`))
 where
  regionTextString = Text.unpack . regionText
  -- "NOT an empty account" is the one sentence allowed to contain the phrase.
  stripNot = Text.unpack . Text.replace "NOT an empty account" "" . Text.pack
  isJust' value = case value of
    Just _ -> True
    Nothing -> False
  containsAll needles haystack = all (`isInfixOf` haystack) needles

-- The bounded page runner ----------------------------------------------------

boundedRunnerCases :: SuiteBuilder ()
boundedRunnerCases = do
  it "turns a page runner that never answered into an unconfirmed verdict, never a clean one" $ do
    let input =
          TagSweepInput
            { tagSweepEnvironment = []
            , tagSweepClusterName = Nothing
            , tagSweepWorkingDirectory = Nothing
            , tagSweepRunRegion = regionText FixtureEuWest2
            }
    discovered <-
      discoverClusterTaggedAwsResourcesWith
        (\_ -> pure (Failure "the call exceeded its wall-clock bound and was stopped"))
        input
    discovered `shouldSatisfy` either (isInfixOf "wall-clock bound") (const False)
    decideTagSweep TagSweepCascade discovered `shouldSatisfy` isUnconfirmed

  it "asks each region-and-filter question once and stops at the first failure" $ do
    calls <- newIORef (0 :: Int)
    let inputs =
          cascadeSweepInputs
            (sweepInputIn FixtureEuWest2)
            [AuthoredBackendRegion (regionOf FixtureCaCentral1)]
        emptyPage =
          Success
            ProcessOutput
              { processExitCode = ExitSuccess
              , processStdout = "{\"ResourceTagMappingList\": []}"
              , processStderr = ""
              }
        counting :: Result ProcessOutput -> a -> IO (Result ProcessOutput)
        counting result _ = modifyIORef' calls (+ 1) >> pure result
    answered <- discoverClusterTaggedAwsResourcesForAll (counting emptyPage) inputs
    answered `shouldBe` Right []
    -- The run region, the authored region and the global-service region: the
    -- global one is shared by both inputs and asked once.
    readIORef calls >>= (`shouldBe` 3)
    writeIORef calls 0
    refused <- discoverClusterTaggedAwsResourcesForAll (counting (Failure "no answer")) inputs
    refused `shouldSatisfy` either (isInfixOf "no answer") (const False)
    readIORef calls >>= (`shouldBe` 1)
 where
  isUnconfirmed verdict = case verdict of
    TagSweepUnconfirmed _ -> True
    TagSweepConfirmedClean _ -> False
    TagSweepEscaped _ _ -> False
