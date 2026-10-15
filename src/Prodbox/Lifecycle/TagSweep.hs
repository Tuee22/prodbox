{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.11: postflight tag-sweep helpers for destructive
-- lifecycle commands. The doctrine in
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 6@
-- mandates that every destructive lifecycle command end with a call
-- to 'discoverClusterTaggedAwsResources' (and, for the long-lived
-- classes, the equivalent long-lived-tag query). A non-empty result
-- is a hard failure.
--
-- This sprint introduces the Pulumi-tracked residue path only.
-- Sprint 4.12 extends the scan to the full cluster-tag query
-- (@kubernetes.io/cluster/<cluster-name>@ + @prodbox.io/*@) once the
-- K8s drain phase lands.
module Prodbox.Lifecycle.TagSweep
  ( TaggedResource (..)
  , TagSweepInput (..)
  , TagSweepScope (..)
  , TagSweepVerdict (..)
  , decideTagSweep
  , tagSweepVerdictExit
  , renderTagSweepVerdict
  , discoverClusterTaggedAwsResources
  , discoverClusterTaggedAwsResourcesWith
  , discoverClusterTaggedAwsResourcesForAll
  , boundedTagPageRunner
  , tagSweepRegions
  , tagSweepQueries
  , unionTaggedResources
  , taggedResourceRowsFor
  , renderTagSweepRefusal
  , prodboxManagedByTagKey
  , prodboxManagedByTagValue
  , ebsLifecycleTagKey
  , ebsRetainedLifecycleValue
  , ebsTestScopedLifecycleValue
  , ebsClusterOwnedTagKey
  , EbsTagPartition (..)
  , longLivedRetentionMarkers
  , isRetainedLongLived
  , partitionRetainedLongLived
  , partitionEbsTagRows
  , isRetainedEbsTag
  )
where

import Data.List (intercalate, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Error (AppError (..))
import Prodbox.Lifecycle.TaggedResourceQuery
  ( TaggedPageRunner
  , TaggedResourceEntry (..)
  , TaggedResourceFilter (..)
  , TaggedResourceListing (..)
  , TaggedResourceQueryInput (..)
  , discoverTaggedResourcesVia
  )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( KillableSubprocessLimits (..)
  , KillableSubprocessOutcome (..)
  , captureSubprocessKillable
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

-- | Input to the tag-sweep discoverer. The caller supplies the
-- @aws@-CLI environment (operational @aws.*@ or admin credentials)
-- and the tag-filter expressions. Two filter classes are supported:
-- the @kubernetes.io/cluster/<cluster-name>@ family (EKS-tagged AWS
-- resources surface here) and the prodbox-owned @prodbox.io/*@ tag
-- family.
data TagSweepInput = TagSweepInput
  { tagSweepEnvironment :: [(String, String)]
  , tagSweepClusterName :: Maybe String
  -- ^ Used to build the @kubernetes.io/cluster/<name>@ filter when
  -- the operator has named the cluster.
  , tagSweepWorkingDirectory :: Maybe FilePath
  , tagSweepRunRegion :: !Text
  -- ^ The region this cluster lifecycle provisioned into.  Required: the
  -- Tagging API answers for the region it is called in, so a sweep that
  -- does not say which region it asked cannot say what its empty answer
  -- covers.
  }
  deriving (Eq, Show)

-- | One AWS resource returned by the tag-sweep. Holds the resource's
-- ARN and the tag key that caused it to surface (used in the refusal
-- message so operators can see *why* each resource counted).
data TaggedResource = TaggedResource
  { taggedResourceArn :: String
  , taggedResourceMatchedTagKey :: String
  , taggedResourceMatchedTagValue :: String
  }
  deriving (Eq, Show)

-- | Query the AWS Resource Tagging API for any resource carrying a
-- prodbox-owned tag. Returns @Right []@ when the sweep is clean; the caller
-- lowers the result to a verdict through 'decideTagSweep', which is where the
-- fail-closed rule lives.
--
-- Sprint 4.77: the sweep is **one query per filter set, unioned by ARN**.
--
-- Two independent defects made the single-query form send neither the filter
-- it named nor the relation it wanted:
--
-- 1. The AWS CLI parses list-valued options with @store@, so a repeated option
--    replaces the earlier occurrence. The argv passed @--tag-filters@ twice,
--    and only the last survived, leaving the sweep structurally blind to
--    precisely the controller-created ENIs, ALBs, and security groups it
--    exists to backstop, which carry the cluster tag and not the ownership tag.
-- 2. The Tagging API **ANDs** the @TagFilters@ within one call. Even had both
--    reached AWS, one call with two filters asks for resources carrying *both*
--    tags; the sweep wants either. The OR is therefore two calls unioned, not
--    one call with two filters.
--
-- __Sprint 6.5: the sweep is also one query per region, and it follows its
-- cursor.__ Both were measured against the 2026-09-07 residue, which had to be
-- cleared by hand from outside the product. The sweep passed no region and read
-- one response body, so it saw one region, one page, and — because IAM is a
-- global service whose rows are returned only from
-- 'Prodbox.Aws.Region.awsGlobalServiceRegion' — no IAM role at all. The
-- listing now comes from "Prodbox.Lifecycle.TaggedResourceQuery", whose shape
-- the native-family observer already used: an explicit @--region@, the cursor
-- followed to exhaustion, a repeated cursor refused, and a bounded page count
-- beyond which truncation fails rather than shortening.
--
-- A failure of *any* constituent query fails the whole discovery, so a partial
-- union is never reported as a complete one.
discoverClusterTaggedAwsResources
  :: TagSweepInput -> IO (Either String [TaggedResource])
discoverClusterTaggedAwsResources = discoverClusterTaggedAwsResourcesWith captureSubprocessResult

-- | 'discoverClusterTaggedAwsResources' over an explicit page runner. A path
-- that used to be offline (a cascade with no cluster) passes
-- 'boundedTagPageRunner', so an AWS call that never answers fails the discovery
-- and the verdict becomes 'TagSweepUnconfirmed' rather than a hang.
discoverClusterTaggedAwsResourcesWith
  :: TaggedPageRunner -> TagSweepInput -> IO (Either String [TaggedResource])
discoverClusterTaggedAwsResourcesWith runner input =
  discoverClusterTaggedAwsResourcesForAll runner [input]

-- | The queries of several inputs that differ only in region, each issued once
-- and in order, stopping at the first failure.
--
-- A fan-out over authored regions repeats the global-service region for every
-- input; deduplicating the @(region, filter)@ pairs asks each question once. A
-- failure of any query fails the whole discovery, so there is nothing to gain
-- from asking the rest, and on a path that used to be offline every further call
-- is another wait on a service that is not answering.
discoverClusterTaggedAwsResourcesForAll
  :: TaggedPageRunner -> [TagSweepInput] -> IO (Either String [TaggedResource])
discoverClusterTaggedAwsResourcesForAll runner inputs = case inputs of
  [] -> pure (Right [])
  shared : _ -> go shared (nub (concatMap tagSweepQueries inputs)) []
 where
  go _ [] gathered = pure (Right (unionTaggedResources (reverse gathered)))
  go shared ((regionValue, filterValue) : remaining) gathered = do
    listed <-
      discoverTaggedResourcesVia
        runner
        TaggedResourceQueryInput
          { taggedResourceQueryEnvironment = tagSweepEnvironment shared
          , taggedResourceQueryWorkingDirectory = tagSweepWorkingDirectory shared
          , taggedResourceQueryFilter = filterValue
          , taggedResourceQueryRegion = regionValue
          }
    case listed of
      Left err -> pure (Left err)
      Right listing ->
        go
          shared
          remaining
          (concatMap (taggedResourceRowsFor filterValue) (taggedResourceListingEntries listing) : gathered)

-- | The regions one sweep asks, in order, without repeats.
--
-- Two, and the second is not a widening of scope. The run's own region answers
-- for everything this lifecycle provisioned there; the global-service region
-- answers for IAM, which prodbox creates and which a regional call cannot
-- return at all. A deployment that already runs in the global-service region
-- asks once.
tagSweepRegions :: TagSweepInput -> [Text]
tagSweepRegions input =
  nub [tagSweepRunRegion input, awsGlobalServiceRegion]

-- | A page runner with a wall-clock bound. The child leads its own process
-- group and is stopped by SIGTERM and then SIGKILL, so a call that never
-- answers cannot strand the caller. A timeout is a failure, never an empty page.
boundedTagPageRunner :: TaggedPageRunner
boundedTagPageRunner spec = do
  outcome <-
    captureSubprocessKillable
      KillableSubprocessLimits
        { killableSubprocessTimeoutMicros = 120 * 1000000
        , killableSubprocessKillGraceMicros = 10 * 1000000
        }
      spec
  pure $ case outcome of
    Left err -> Failure (Text.unpack (errorMsg err))
    Right (KillableSubprocessCompleted output) -> Success output
    Right (KillableSubprocessTimedOut _) ->
      Failure "the call exceeded its wall-clock bound and was stopped"

-- | Every (region, filter) pair this sweep issues as its own call.
tagSweepQueries :: TagSweepInput -> [(Text, TaggedResourceFilter)]
tagSweepQueries input =
  [ (regionValue, filterValue)
  | regionValue <- tagSweepRegions input
  , filterValue <- filters
  ]
 where
  filters =
    TaggedResourceTagPairFilter
      (Text.pack prodboxManagedByTagKey)
      (Text.pack prodboxManagedByTagValue)
      : [ TaggedResourceTagKeyFilter
            (Text.pack ("kubernetes.io/cluster/" ++ name))
        | Just name <- [tagSweepClusterName input]
        ]

-- | One returned resource becomes one row per tag it carries.
--
-- An entry carrying no readable tag still becomes a row, attributed to the
-- filter that returned it. Dropping it — which the superseded parser did — is
-- residue becoming absence: the API returned the resource *because* it matched,
-- so the match is a fact even when the tag list is not readable from the row.
taggedResourceRowsFor :: TaggedResourceFilter -> TaggedResourceEntry -> [TaggedResource]
taggedResourceRowsFor filterValue entry = case taggedResourceEntryTags entry of
  [] -> [TaggedResource arn matchedKey matchedValue]
  tags -> [TaggedResource arn (Text.unpack key) (Text.unpack value) | (key, value) <- tags]
 where
  arn = Text.unpack (taggedResourceEntryArn entry)
  (matchedKey, matchedValue) = case filterValue of
    TaggedResourceTagKeyFilter key -> (Text.unpack key, "")
    TaggedResourceTagPairFilter key value -> (Text.unpack key, Text.unpack value)

-- | Concatenate the per-query results and drop rows that appear in more than
-- one query. A resource carrying both the ownership tag and the cluster tag is
-- returned by both calls; the union keys on the whole @(ARN, key, value)@ row,
-- so a resource stays represented by every distinct tag row it actually has —
-- which is what 'partitionRetainedLongLived' and 'partitionEbsTagRows' both
-- decide over.
unionTaggedResources :: [[TaggedResource]] -> [TaggedResource]
unionTaggedResources = nub . concat

-- | Sprint 4.76: which sweep-owning surface is asking
-- (@lifecycle_reconciliation_doctrine.md § 5@ assigns the mandatory
-- sweep to exactly two commands). The scopes differ in one respect only:
-- the cascade carves out intentionally-retained long-lived shared
-- infrastructure, and @nuke@ does not, because destroying it is what
-- @nuke@ is for.
data TagSweepScope
  = TagSweepCascade
  | TagSweepNuke
  deriving (Eq, Show)

-- | The sweep's verdict. Three-valued on purpose: "the API said there is
-- nothing", "the API said there is something", and "the API did not
-- answer" are three facts, and § 6 requires the third to be treated as
-- the second, never as the first.
data TagSweepVerdict
  = -- | Confirmed clean. Carries the rows retained by design (always
    -- empty under 'TagSweepNuke').
    TagSweepConfirmedClean [TaggedResource]
  | -- | @(retained-by-design, escaped)@. Escaped is non-empty.
    TagSweepEscaped [TaggedResource] [TaggedResource]
  | -- | The Tagging API could not be reached or its answer could not be
    -- read. Absence is unconfirmed.
    TagSweepUnconfirmed String
  deriving (Eq, Show)

-- | Pure decision over a discovery result. Total over the query's
-- @Either@ and over the scope, so the fail-closed rule is a property of
-- this function rather than of each call site's @case@.
decideTagSweep :: TagSweepScope -> Either String [TaggedResource] -> TagSweepVerdict
decideTagSweep scope discovery = case discovery of
  Left err -> TagSweepUnconfirmed err
  Right resources ->
    let (retained, escaped) = case scope of
          TagSweepCascade -> partitionRetainedLongLived resources
          TagSweepNuke -> ([], resources)
     in if null escaped
          then TagSweepConfirmedClean retained
          else TagSweepEscaped retained escaped

-- | Fail-closed: only a confirmed-clean sweep passes.
tagSweepVerdictExit :: TagSweepVerdict -> ExitCode
tagSweepVerdictExit verdict = case verdict of
  TagSweepConfirmedClean _ -> ExitSuccess
  TagSweepEscaped _ _ -> ExitFailure 1
  TagSweepUnconfirmed _ -> ExitFailure 1

-- | Operator-visible narration for a verdict. The clean sentence is the
-- only one that asserts absence, and it is reachable only from
-- 'TagSweepConfirmedClean'.
renderTagSweepVerdict :: TagSweepScope -> TagSweepVerdict -> String
renderTagSweepVerdict scope verdict = case verdict of
  TagSweepConfirmedClean retained ->
    unlines
      (retainedNotice retained ++ [label ++ ": clean (the Tagging API confirmed no escaped residue)."])
  TagSweepEscaped retained escaped ->
    unlines
      ( retainedNotice retained
          ++ [ label
                 ++ ": "
                 ++ show (length escaped)
                 ++ " resource(s) still tagged — operator action required:"
             ]
      )
      ++ renderTagSweepRefusal escaped
  TagSweepUnconfirmed err ->
    unlines
      [ label ++ ": UNCONFIRMED — the AWS Resource Tagging API could not be read: " ++ err
      , "Could not observe the absence of residue, which is treated as \"residue may be"
      , "present\", never as \"residue is absent\". Resolve AWS connectivity / credentials"
      , "and re-run the sweep before claiming this teardown finished cleanly."
      ]
 where
  label = case scope of
    TagSweepCascade -> "Postflight tag sweep"
    TagSweepNuke -> "Terminal tag sweep"
  retainedNotice retained =
    let arns = nub (map taggedResourceArn retained)
     in [ label
            ++ ": "
            ++ show (length arns)
            ++ " intentionally-retained long-lived resource(s) left in place by design "
            ++ "(destroyed only by `prodbox nuke`): "
            ++ intercalate ", " arns
            ++ "."
        | not (null arns)
        ]

renderTagSweepRefusal :: [TaggedResource] -> String
renderTagSweepRefusal resources =
  unlines
    ( [ "Postflight tag sweep refused: AWS resources carrying prodbox or"
      , "cluster tags still exist after the destructive command completed."
      , ""
      , "These resources escaped the per-stack destroys and the K8s drain"
      , "phase; manual cleanup is required before the operator can claim"
      , "the teardown finished cleanly:"
      , ""
      ]
        ++ map renderResource resources
    )
 where
  renderResource resource =
    "  - "
      ++ taggedResourceArn resource
      ++ " (matched tag: "
      ++ taggedResourceMatchedTagKey resource
      ++ ")"

prodboxManagedByTagKey :: String
prodboxManagedByTagKey = "prodbox.io/managed-by"

prodboxManagedByTagValue :: String
prodboxManagedByTagValue = "prodbox"

ebsLifecycleTagKey :: String
ebsLifecycleTagKey = "prodbox.io/lifecycle"

ebsRetainedLifecycleValue :: String
ebsRetainedLifecycleValue = "retained-ebs"

ebsTestScopedLifecycleValue :: String
ebsTestScopedLifecycleValue = "per-run-test"

ebsClusterOwnedTagKey :: String -> String
ebsClusterOwnedTagKey clusterName = "kubernetes.io/cluster/" ++ clusterName

-- | The @(tag key, tag value)@ pairs that mark a resource as
-- intentionally-RETAINED long-lived shared infrastructure — the
-- @pulumi_state_backend@ S3 bucket, the @aws-ses@ cross-substrate stack, and
-- production-retained EBS volumes backing static Retain PVs. These survive
-- @cluster delete@ (even @--cascade@) by design and are destroyed only by their
-- explicit long-lived lifecycle surface; the cascade postflight tag sweep must
-- NOT flag them as escaped residue (Standard:
-- lifecycle_reconciliation_doctrine.md — Resource Lifecycle Classes). @nuke@'s
-- own sweep does NOT use this carve-out, since it exists to destroy these
-- resources.
longLivedRetentionMarkers :: [(String, String)]
longLivedRetentionMarkers =
  [ ("prodbox.io/role", "long-lived-pulumi-state")
  , ("prodbox.io/substrate", "shared")
  , (ebsLifecycleTagKey, ebsRetainedLifecycleValue)
  ]

-- | True when a tag row marks its resource as intentionally-retained long-lived
-- shared infrastructure (one of 'longLivedRetentionMarkers').
isRetainedLongLived :: TaggedResource -> Bool
isRetainedLongLived resource =
  (taggedResourceMatchedTagKey resource, taggedResourceMatchedTagValue resource)
    `elem` longLivedRetentionMarkers

-- | Split a tag-sweep result into @(retained, escaped)@. A resource (keyed by
-- ARN) is RETAINED when ANY of its tag rows is a long-lived-retention marker;
-- every tag row of a retained ARN goes to the retained list, so a genuine
-- escapee that merely shares one common tag (e.g. @prodbox.io/managed-by@) with
-- a retained resource is still classified as escaped. Pure, so the cascade
-- postflight refuses on @escaped@ only and reports @retained@ as expected.
partitionRetainedLongLived :: [TaggedResource] -> ([TaggedResource], [TaggedResource])
partitionRetainedLongLived resources =
  let retainedArns = [taggedResourceArn r | r <- resources, isRetainedLongLived r]
      isRetainedArn r = taggedResourceArn r `elem` retainedArns
   in (filter isRetainedArn resources, filter (not . isRetainedArn) resources)

data EbsTagPartition = EbsTagPartition
  { retainedEbsTagRows :: [TaggedResource]
  , testScopedEbsTagRows :: [TaggedResource]
  , otherEbsTagRows :: [TaggedResource]
  }
  deriving (Eq, Show)

-- | Partition tag rows for EBS lifecycle handling. Retained-production markers
-- win over test-scoped markers for the same ARN; test-scoped EBS requires both
-- @prodbox.io/lifecycle=per-run-test@ and the EKS ownership tag
-- @kubernetes.io/cluster/<name>=owned@ on the same resource.
partitionEbsTagRows :: String -> [TaggedResource] -> EbsTagPartition
partitionEbsTagRows clusterName resources =
  EbsTagPartition
    { retainedEbsTagRows = filter isRetainedArn resources
    , testScopedEbsTagRows = filter isTestScopedArn resources
    , otherEbsTagRows =
        filter
          (\resource -> not (isRetainedArn resource) && not (isTestScopedArn resource))
          resources
    }
 where
  retainedArns =
    [ taggedResourceArn resource
    | resource <- resources
    , isRetainedEbsTag resource
    ]
  testScopedArns =
    [ arn
    | arn <- map taggedResourceArn resources
    , arn `notElem` retainedArns
    , hasTag arn ebsLifecycleTagKey ebsTestScopedLifecycleValue
    , hasTag arn (ebsClusterOwnedTagKey clusterName) "owned"
    ]
  isRetainedArn resource = taggedResourceArn resource `elem` retainedArns
  isTestScopedArn resource = taggedResourceArn resource `elem` testScopedArns
  hasTag arn key value =
    any
      ( \resource ->
          taggedResourceArn resource == arn
            && taggedResourceMatchedTagKey resource == key
            && taggedResourceMatchedTagValue resource == value
      )
      resources

isRetainedEbsTag :: TaggedResource -> Bool
isRetainedEbsTag resource =
  taggedResourceMatchedTagKey resource == ebsLifecycleTagKey
    && taggedResourceMatchedTagValue resource == ebsRetainedLifecycleValue
