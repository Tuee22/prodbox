{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the cascade's terminal escape audit, from issued queries to
-- the observation the evidence constructor consumes.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 6](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- says the global cluster\/ownership tag audit runs only after exact
-- obligations have been re-observed, reports normalized distinct resources,
-- partitions intentionally retained @LongLived@ resources, and fails on
-- escapees or incomplete observation.  Every part of that decision already
-- existed — the retained matcher catalog, the query catalog, the
-- classification, and the region-bounded verdict — and nothing assembled them:
-- there was no way to get from a set of issued queries to a
-- 'TerminalAuditObservation', so the cascade's terminal arm had no producer.
--
-- Four properties carry the design.
--
--   * __The queries are a union, issued separately.__  The Resource Groups
--     Tagging API intersects the tag filters within one call, so the audit's
--     field of view — any prodbox-owned tag family — is several calls unioned
--     by ARN rather than one call carrying several filters.  Issuing them as
--     one call is the exact defect Sprint @4.77@ found in the sweep, and it is
--     not reintroduced here.
--
--   * __A query that went unanswered is a blind spot, and a blind spot is not
--     clean.__  Rows that did come back are still classified, because an
--     escapee found through one query is an escapee whatever the others did.
--     But a run with an unanswered query cannot claim the surface is clean, so
--     a would-be-clean verdict is downgraded to unobservable carrying that
--     query's failure.  This is the same asymmetry the region-bounded verdict
--     already applies, preserved rather than re-decided.
--
--   * __A decoder conflict is a refusal to take the audit.__  Two returned rows
--     that disagree about one ARN's scope, type, coordinate, or tag value mean
--     the audit's own view is incoherent.  No resource in it is trustworthy
--     enough to classify, so no verdict is produced at all — rather than
--     resolving the disagreement by preferring a row.
--
--   * __The audit scope is derived, never authored.__  It comes from the
--     compiled run's own observation scope through the same derivation
--     'mkCascadeTerminalAuditEvidence' checks against, so an audit cannot be
--     taken under a scope that constructor would then reject for a reason the
--     operator cannot see.
--
-- The pure kernel classifies and lowers.  Issuing the queries lives behind an
-- injected boundary, and this module deliberately wires no production one: on
-- the AWS substrate those queries are a Provider effect owned by Sprint @7.36@,
-- and reaching for a host-direct tagging call here would add an unregistered
-- escape path.
module Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( -- * Issuing the audit
    CascadeTerminalAuditBoundary (..)
  , cascadeTerminalAuditQueries

    -- * Producing the observation
  , CascadeTerminalAuditRefusal (..)
  , renderCascadeTerminalAuditRefusal
  , lowerCascadeTerminalAuditRows
  , observeCascadeTerminalAudit

    -- * Regression over the package-private fixture
  , CascadeTerminalAuditRegression
  , fixedCascadeTerminalAuditRegression
  , cascadeTerminalAuditRegressionEveryQueryIssuedSeparately
  , cascadeTerminalAuditRegressionScopeAcceptedByEvidence
  , cascadeTerminalAuditRegressionRetainedIsNotAnEscapee
  , cascadeTerminalAuditRegressionEscapeeRefused
  , cascadeTerminalAuditRegressionBlindQueryIsNotClean
  , cascadeTerminalAuditRegressionEscapeeOutranksBlindQuery
  , cascadeTerminalAuditRegressionDecoderConflictRefused
  , cascadeTerminalAuditRegressionForeignRegionIsNeverClean
  )
where

import Data.Either (lefts, rights)
import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.AwsInventory
  ( AwsInventoryFailure
  , AwsResourceCoordinate (AwsResourceCoordinate)
  , AwsResourceType (AwsResourceType)
  , AwsTag (..)
  , AwsTagRow (..)
  , mkArn
  , normalizeAwsTagRows
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( cascadeAuditScope
  , mkCascadeTerminalAuditEvidence
  , withCascadePreUninstallInputsInternal
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceObservationScope
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (AwsAccountId)
  , AwsRegion (AwsRegion)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , CleanupSurfaceWitness (CascadeSurface)
  , ObservationFailure (ObservationFailure)
  , ObservationRevision (ObservationRevision)
  , evidenceAwsScope
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditObservation (..)
  , TerminalAuditResult (..)
  , TerminalAuditScopeError
  , mkTerminalAuditScope
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedCatalog
  , RetainedCatalogError
  , RetainedNameBinding
  , TerminalAuditQuery (..)
  , mkRetainedNameBinding
  , retainedCatalogFor
  , retainedSetDigestFor
  , terminalAuditQueryCatalog
  , terminalAuditQueryDigestFor
  , terminalAuditResultFor
  )

-- ---------------------------------------------------------------------------
-- Issuing the audit
-- ---------------------------------------------------------------------------

-- | The injected query boundary.
--
-- One query at a time, because the audit's field of view is their union and
-- the provider API intersects the filters inside a single call.  A query that
-- could not be answered returns its own failure rather than an empty row set,
-- so \"asked and found nothing\" and \"never asked\" stay distinct.
newtype CascadeTerminalAuditBoundary m = CascadeTerminalAuditBoundary
  { auditIssueQuery
      :: TerminalAuditQuery -> m (Either ObservationFailure [AwsTagRow])
  }

-- | The queries whose union is the audit's field of view, in catalog order.
cascadeTerminalAuditQueries :: RetainedNameBinding -> [TerminalAuditQuery]
cascadeTerminalAuditQueries = terminalAuditQueryCatalog

-- ---------------------------------------------------------------------------
-- Producing the observation
-- ---------------------------------------------------------------------------

-- | Why no audit observation could be produced at all.
--
-- These are refusals to /take/ the audit.  A taken audit that found escapees,
-- or that could not see everything, is not a refusal — it is a verdict, and it
-- travels inside the observation as a 'TerminalAuditResult'.
data CascadeTerminalAuditRefusal
  = CascadeTerminalAuditCatalogUnavailable !RetainedCatalogError
  | CascadeTerminalAuditScopeUnavailable !TerminalAuditScopeError
  | -- | The compiled run names no AWS scope, so there is no account and region
    -- the audit could be taken in.
    CascadeTerminalAuditNoAwsScope
  | CascadeTerminalAuditDecoderConflict !AwsInventoryFailure
  deriving (Eq, Show)

renderCascadeTerminalAuditRefusal :: CascadeTerminalAuditRefusal -> String
renderCascadeTerminalAuditRefusal = \case
  CascadeTerminalAuditCatalogUnavailable err ->
    "The cascade terminal audit has no retained catalog to classify against: "
      ++ show err
  CascadeTerminalAuditScopeUnavailable err ->
    "The cascade terminal audit has no valid audit scope: " ++ show err
  CascadeTerminalAuditNoAwsScope ->
    "The cascade terminal audit was asked for a run that names no AWS scope; \
    \the no-AWS arm is a distinct witness, not an empty audit."
  CascadeTerminalAuditDecoderConflict conflict ->
    "The cascade terminal audit's returned rows disagree about one resource, \
    \so its own view is incoherent and no verdict is produced: "
      ++ show conflict

-- | Lower the rows the queries returned, together with the queries that could
-- not be answered, into the audit's typed result.
--
-- Rows that came back are classified regardless of what failed, because a
-- discovered escapee is an escapee; and a clean partition is downgraded to
-- unobservable when any query went unanswered, because \"found nothing among
-- the things I asked about\" is not \"there is nothing\" when part of the
-- question was never put.
lowerCascadeTerminalAuditRows
  :: RetainedCatalog 'Cascade
  -> [AwsTagRow]
  -> [ObservationFailure]
  -> Either AwsInventoryFailure TerminalAuditResult
lowerCascadeTerminalAuditRows catalog rows unanswered = do
  inventory <- normalizeAwsTagRows rows
  pure $ case terminalAuditResultFor catalog inventory of
    TerminalAuditFoundEscapes observed escaped ->
      TerminalAuditFoundEscapes observed escaped
    TerminalAuditUnobservable observed failures ->
      TerminalAuditUnobservable observed (NonEmpty.prependList unanswered failures)
    TerminalAuditConfirmedClean observed ->
      case NonEmpty.nonEmpty unanswered of
        Nothing -> TerminalAuditConfirmedClean observed
        Just failures -> TerminalAuditUnobservable observed failures

-- | Issue every query, classify what came back, and package the observation
-- the cascade's terminal arm consumes.
observeCascadeTerminalAudit
  :: (Monad m)
  => CascadeTerminalAuditBoundary m
  -> RetainedNameBinding
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> ObservationRevision
  -> m (Either CascadeTerminalAuditRefusal (TerminalAuditObservation 'Cascade))
observeCascadeTerminalAudit boundary binding compiled revision =
  case evidenceAwsScope observationScope of
    Nothing -> pure (Left CascadeTerminalAuditNoAwsScope)
    Just awsScope -> case retainedCatalogFor CascadeSurface awsScope binding of
      Left err -> pure (Left (CascadeTerminalAuditCatalogUnavailable err))
      Right catalog ->
        case mkTerminalAuditScope
          CascadeSurface
          (cascadeAuditScope observationScope)
          (terminalAuditQueryDigestFor (terminalAuditQueryCatalog binding))
          (retainedSetDigestFor catalog) of
          Left err -> pure (Left (CascadeTerminalAuditScopeUnavailable err))
          Right auditScope -> do
            answered <- traverse (auditIssueQuery boundary) queries
            let rows = concat (rights answered)
                unanswered = lefts answered
            pure $ case lowerCascadeTerminalAuditRows catalog rows unanswered of
              Left conflict -> Left (CascadeTerminalAuditDecoderConflict conflict)
              Right result ->
                Right
                  TerminalAuditObservation
                    { terminalAuditScope = auditScope
                    , terminalAuditRevision = revision
                    , terminalAuditResult = result
                    }
 where
  observationScope = compiledDesiredAbsenceObservationScope compiled
  queries = cascadeTerminalAuditQueries binding

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

data CascadeTerminalAuditRegression = CascadeTerminalAuditRegression
  { cascadeTerminalAuditRegressionEveryQueryIssuedSeparately :: !Bool
  , cascadeTerminalAuditRegressionScopeAcceptedByEvidence :: !Bool
  , cascadeTerminalAuditRegressionRetainedIsNotAnEscapee :: !Bool
  , cascadeTerminalAuditRegressionEscapeeRefused :: !Bool
  , cascadeTerminalAuditRegressionBlindQueryIsNotClean :: !Bool
  , cascadeTerminalAuditRegressionEscapeeOutranksBlindQuery :: !Bool
  , cascadeTerminalAuditRegressionDecoderConflictRefused :: !Bool
  , cascadeTerminalAuditRegressionForeignRegionIsNeverClean :: !Bool
  }

fixedCascadeTerminalAuditRegression
  :: IO (Either Text CascadeTerminalAuditRegression)
fixedCascadeTerminalAuditRegression =
  case fixedAuditScenario of
    Left err -> pure (Left err)
    Right scenario -> Right <$> runFixedAuditRegression scenario

data FixedAuditScenario = FixedAuditScenario
  { fixedAuditCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedAuditBinding :: !RetainedNameBinding
  , fixedAuditRunScope :: !AwsScope
  , fixedAuditRunCatalog :: !(RetainedCatalog 'Cascade)
  , fixedAuditGlobalCatalog :: !(RetainedCatalog 'Cascade)
  , fixedAuditRetainedRows :: ![AwsTagRow]
  , fixedAuditEscapeeRows :: ![AwsTagRow]
  , fixedAuditConflictingRows :: ![AwsTagRow]
  }

-- | The compiled run's own AWS scope is deliberately not the global tagging
-- region, so it exercises the region bound; a second catalog in the global
-- region exercises the verdicts the region bound would otherwise mask.
fixedAuditScenario :: Either Text FixedAuditScenario
fixedAuditScenario = do
  compiled <-
    withCascadePreUninstallInputsInternal
      "cleanup-run/terminal-audit-fixed-regression"
      (\program _run _absence _credentials _audit -> program)
  binding <-
    firstShown
      ( mkRetainedNameBinding
          fixedStateBucketName
          "prodbox-fixed-ses-capture"
          "fixed.example.test"
          "aws-eks-test-cluster"
      )
  runScope <-
    maybe
      (Left "the fixed cascade run names no AWS scope")
      Right
      (evidenceAwsScope (compiledDesiredAbsenceObservationScope compiled))
  runCatalog <- firstShown (retainedCatalogFor CascadeSurface runScope binding)
  globalCatalog <-
    firstShown
      ( retainedCatalogFor
          CascadeSurface
          runScope {awsScopeRegion = AwsRegion globalTaggingRegion}
          binding
      )
  bucketArn <- firstShown (mkArn ("arn:aws:s3:::" <> fixedStateBucketName))
  escapeeArn <-
    firstShown (mkArn "arn:aws:eks:us-east-1:111122223333:cluster/prodbox-escapee")
  let bucketRow resourceType tag =
        AwsTagRow
          { awsTagRowArn = bucketArn
          , awsTagRowScope = fixedRowScope
          , awsTagRowResourceType = resourceType
          , awsTagRowCoordinate = AwsResourceCoordinate fixedStateBucketName
          , awsTagRowTag = Just tag
          }
      managedByTag = AwsTag "prodbox.io/managed-by" "prodbox"
  pure
    FixedAuditScenario
      { fixedAuditCompiled = compiled
      , fixedAuditBinding = binding
      , fixedAuditRunScope = runScope
      , fixedAuditRunCatalog = runCatalog
      , fixedAuditGlobalCatalog = globalCatalog
      , -- One returned ResourceTagMapping carrying the retained state bucket's
        -- full two-tag set, decoded as two rows for one ARN.
        fixedAuditRetainedRows =
          [ bucketRow bucketResourceType managedByTag
          , bucketRow bucketResourceType (AwsTag "prodbox.io/role" "pulumi-state")
          ]
      , -- A prodbox-tagged resource no matcher retains.
        fixedAuditEscapeeRows =
          [ AwsTagRow
              { awsTagRowArn = escapeeArn
              , awsTagRowScope = fixedRowScope
              , awsTagRowResourceType = AwsResourceType "eks:cluster"
              , awsTagRowCoordinate = AwsResourceCoordinate "prodbox-escapee"
              , awsTagRowTag = Just managedByTag
              }
          ]
      , -- Two rows for one ARN that disagree about its resource type.
        fixedAuditConflictingRows =
          [ bucketRow bucketResourceType managedByTag
          , bucketRow (AwsResourceType "eks:cluster") managedByTag
          ]
      }

runFixedAuditRegression :: FixedAuditScenario -> IO CascadeTerminalAuditRegression
runFixedAuditRegression scenario = do
  issued <- newIORef []
  _ <-
    observeCascadeTerminalAudit
      ( CascadeTerminalAuditBoundary
          ( \query -> do
              modifyIORef' issued (++ [query])
              pure (Right [])
          )
      )
      binding
      (fixedAuditCompiled scenario)
      (ObservationRevision 1)
  observedQueries <- readIORef issued
  pure
    CascadeTerminalAuditRegression
      { cascadeTerminalAuditRegressionEveryQueryIssuedSeparately =
          observedQueries == queries && length queries == 5
      , cascadeTerminalAuditRegressionScopeAcceptedByEvidence =
          scopeAcceptedByEvidence scenario
      , cascadeTerminalAuditRegressionRetainedIsNotAnEscapee =
          globalResult (fixedAuditRetainedRows scenario) [] == Right True
      , cascadeTerminalAuditRegressionEscapeeRefused =
          fmap isEscape (globalLowered (fixedAuditEscapeeRows scenario) []) == Right True
      , cascadeTerminalAuditRegressionBlindQueryIsNotClean =
          fmap isUnobservable (globalLowered [] [unanswered]) == Right True
      , cascadeTerminalAuditRegressionEscapeeOutranksBlindQuery =
          fmap isEscape (globalLowered (fixedAuditEscapeeRows scenario) [unanswered]) == Right True
      , cascadeTerminalAuditRegressionDecoderConflictRefused =
          isDecoderConflict
            ( runIdentity
                ( observeCascadeTerminalAudit
                    (CascadeTerminalAuditBoundary (const (Identity (Right (fixedAuditConflictingRows scenario)))))
                    binding
                    (fixedAuditCompiled scenario)
                    (ObservationRevision 1)
                )
            )
      , cascadeTerminalAuditRegressionForeignRegionIsNeverClean =
          fmap isUnobservable (runLowered [] []) == Right True
      }
 where
  binding = fixedAuditBinding scenario
  queries = cascadeTerminalAuditQueries binding
  unanswered = ObservationFailure "query unavailable"

  globalLowered rows failures =
    lowerCascadeTerminalAuditRows (fixedAuditGlobalCatalog scenario) rows failures

  runLowered rows failures =
    lowerCascadeTerminalAuditRows (fixedAuditRunCatalog scenario) rows failures

  globalResult rows failures = fmap isClean (globalLowered rows failures)

  isClean = \case
    TerminalAuditConfirmedClean _ -> True
    _ -> False

  isEscape = \case
    TerminalAuditFoundEscapes _ _ -> True
    _ -> False

  isUnobservable = \case
    TerminalAuditUnobservable _ _ -> True
    _ -> False

  isDecoderConflict = \case
    Left (CascadeTerminalAuditDecoderConflict _) -> True
    _ -> False

-- | Whether the scope this module derives is the one the evidence constructor
-- expects.
--
-- The compiled run's region is not the global tagging region, so its audit can
-- never report clean; the check therefore substitutes a clean verdict under the
-- /derived/ scope and asks the constructor to accept it.  What is under test is
-- the scope derivation, and only that.
scopeAcceptedByEvidence :: FixedAuditScenario -> Bool
scopeAcceptedByEvidence scenario =
  case runIdentity
    ( observeCascadeTerminalAudit
        (CascadeTerminalAuditBoundary (const (Identity (Right []))))
        (fixedAuditBinding scenario)
        (fixedAuditCompiled scenario)
        (ObservationRevision 1)
    ) of
    Left _ -> False
    Right observation ->
      case normalizeAwsTagRows [] of
        Left _ -> False
        Right emptyInventory ->
          case mkCascadeTerminalAuditEvidence
            (fixedAuditRunCatalog scenario)
            (fixedAuditCompiled scenario)
            observation {terminalAuditResult = TerminalAuditConfirmedClean emptyInventory} of
            Left _ -> False
            Right _ -> True

-- ---------------------------------------------------------------------------
-- Fixture rows
-- ---------------------------------------------------------------------------

-- | The scope every fixture row is returned in.  It is the global tagging
-- region because the verdict fixtures classify against the global catalog; the
-- run-scoped catalog is exercised separately for exactly the region bound.
fixedRowScope :: AwsScope
fixedRowScope =
  AwsScope
    { awsScopeAccountId = AwsAccountId "111122223333"
    , awsScopeRegion = AwsRegion globalTaggingRegion
    }

bucketResourceType :: AwsResourceType
bucketResourceType = AwsResourceType "s3:bucket"

fixedStateBucketName :: Text
fixedStateBucketName = "prodbox-fixed-state"

globalTaggingRegion :: Text
globalTaggingRegion = "us-east-1"

firstShown :: (Show err) => Either err value -> Either Text value
firstShown = either (Left . Text.pack . show) Right
