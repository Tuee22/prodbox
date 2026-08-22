{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86, validation item 1: the frozen cascade composition.
--
-- One run in which the Lifecycle Authority is unavailable, every exact
-- per-stack observation is therefore unobservable, and the terminal audit is
-- handed exactly one returned tag mapping — the retained state bucket's full
-- two-tag set, which decodes as two rows for one ARN.
--
-- What the composition must show is not that any one of those pieces behaves,
-- which their own regressions already measure, but that they do not contaminate
-- each other: the audit reports one retained resource and no escapee, no cloud
-- node consumes the audit's answer, and every exact-stack failure survives as
-- its own node's outcome rather than being folded into one verdict.
module LifecycleTeardownCascadeFrozenComposition
  ( lifecycleTeardownCascadeFrozenCompositionSuite
  )
where

import Data.IORef
import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import LifecycleTeardownCloudRuntimeProduction
  ( ProductionCloudEffects (..)
  , buildRuntime
  , cloudOwnedPlans
  , tagFor
  )
import Prodbox.Lifecycle.AwsInventory
  ( AwsResourceCoordinate (AwsResourceCoordinate)
  , AwsResourceType (AwsResourceType)
  , AwsTag (..)
  , AwsTagRow (..)
  , awsInventorySize
  , mkArn
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( CascadeTerminalAuditBoundary (..)
  , cascadeTerminalAuditQueries
  , lowerCascadeTerminalAuditRows
  , observeCascadeTerminalAudit
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( runCompiledTeardownNode
  )
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation (TerminalAuditResult (..))
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedCatalog
  , RetainedNameBinding
  , mkRetainedNameBinding
  , retainedCatalogFor
  )
import TestSupport

lifecycleTeardownCascadeFrozenCompositionSuite :: SuiteBuilder ()
lifecycleTeardownCascadeFrozenCompositionSuite =
  describe "Sprint 4.86 frozen cascade composition" $ do
    it "keeps every exact per-stack failure as its own node outcome" $ do
      calls <- newIORef []
      built <- buildRuntime calls
      runtime <- mustRightIO built
      let compiled = compiledFor
          observePlans =
            [ plan
            | plan <- cloudOwnedPlans compiled
            , Just operation <-
                [compiledOperationForNode (cleanupNodeId plan) compiled]
            , isExactStackObserve operation
            ]
      observed <-
        mapM
          ( \plan -> do
              outcome <-
                runProductionCloudEffects
                  (runCompiledTeardownNode compiled plan)
                  runtime
              pure (tagFor compiled plan, outcome)
          )
          observePlans
      -- Three exact stack observations, three outcomes.  A composition that
      -- folded them into one verdict — the defect an aggregate exit status
      -- invites — would show up here as a shorter list.
      sort (map fst observed)
        `shouldBe` [ "observe/aws-eks"
                   , "observe/aws-eks-subzone"
                   , "observe/aws-test"
                   ]
      mapM_ (\(_, outcome) -> outcome `shouldSatisfy` isFailedNode) observed

    it "reports one retained audit resource from one returned two-tag mapping" $ do
      catalog <- mustRightIO frozenCatalog
      lowered <-
        mustRightIO (lowerCascadeTerminalAuditRows catalog retainedRows [])
      -- Two returned rows, one ARN: the retained state bucket, classified as
      -- retained rather than as an escapee.  The verdict is nonetheless
      -- unobservable, and the two facts are independent: the run's own region
      -- answers for no global service, so the region bound downgrades a
      -- would-be-clean verdict on its own.  Asserting only "not clean" would
      -- pass even if the bucket had been called an escapee, which is why both
      -- halves are pinned.
      auditInventorySize lowered `shouldBe` 1
      lowered `shouldSatisfy` (not . isFoundEscapes)
      lowered `shouldSatisfy` isRegionBoundedUnobservable

    it "never lets a cloud node consume the audit's answer" $ do
      calls <- newIORef []
      built <- buildRuntime calls
      runtime <- mustRightIO built
      auditCalls <- newIORef (0 :: Int)
      -- The audit is issued against its own boundary, entirely outside the
      -- cloud runtime.
      binding <- mustRightIO frozenBinding
      _ <-
        observeCascadeTerminalAudit
          ( CascadeTerminalAuditBoundary
              ( \_ -> do
                  modifyIORef' auditCalls (+ 1)
                  pure (Right retainedRows)
              )
          )
          binding
          compiledFor
          (ObservationRevision 1)
      issuedByAudit <- readIORef auditCalls
      issuedByAudit `shouldBe` length (cascadeTerminalAuditQueries binding)

      writeIORef auditCalls 0
      -- Driving every cloud-owned node issues no audit query at all: the cloud
      -- runtime does not own `AuditCascadeEscapes`, so no EKS drain or destroy
      -- can be selected from what the audit saw.
      mapM_
        ( \plan ->
            runProductionCloudEffects
              (runCompiledTeardownNode compiledFor plan)
              runtime
        )
        (cloudOwnedPlans compiledFor)
      readIORef auditCalls `shouldReturn` 0

    it "declines the audit node instead of answering it" $ do
      calls <- newIORef []
      built <- buildRuntime calls
      runtime <- mustRightIO built
      let auditPlans =
            [ plan
            | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiledFor)
            , Just AuditCascadeEscapes <-
                [compiledOperationForNode (cleanupNodeId plan) compiledFor]
            ]
      outcomes <-
        mapM
          ( \plan ->
              runProductionCloudEffects
                (runCompiledTeardownNode compiledFor plan)
                runtime
          )
          auditPlans
      length auditPlans `shouldBe` 1
      mapM_ (`shouldSatisfy` isNonCloudRefusal) outcomes

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------

auditInventorySize :: TerminalAuditResult -> Int
auditInventorySize = \case
  TerminalAuditConfirmedClean inventory -> awsInventorySize inventory
  TerminalAuditFoundEscapes inventory _ -> awsInventorySize inventory
  TerminalAuditUnobservable inventory _ -> awsInventorySize inventory

isFoundEscapes :: TerminalAuditResult -> Bool
isFoundEscapes = \case
  TerminalAuditFoundEscapes _ _ -> True
  _ -> False

-- | Unobservable for the region bound alone: every carried failure names the
-- tagging API's global-service endpoint rather than anything the returned
-- mapping said.
isRegionBoundedUnobservable :: TerminalAuditResult -> Bool
isRegionBoundedUnobservable = \case
  TerminalAuditUnobservable _ failures ->
    all regionBound (NonEmpty.toList failures)
  _ -> False
 where
  regionBound (ObservationFailure detail) =
    Text.isInfixOf "endpoint" detail

isExactStackObserve :: TeardownOperation surface -> Bool
isExactStackObserve = \case
  ObserveRegisteredTarget target ->
    registeredTargetKey target
      `elem` [AwsEksKey, AwsEksSubzoneKey, AwsTestKey]
  _ -> False

isFailedNode :: CleanupNodeOutcome -> Bool
isFailedNode = \case
  CleanupNodeFailed _ -> True
  _ -> False

isNonCloudRefusal :: CleanupNodeOutcome -> Bool
isNonCloudRefusal = \case
  CleanupNodeFailed detail ->
    Text.isInfixOf "non-cloud operation" detail
  _ -> False

frozenBinding :: Either Text RetainedNameBinding
frozenBinding =
  firstShow
    ( mkRetainedNameBinding
        frozenStateBucketName
        "prodbox-frozen-ses-capture"
        "frozen.example.test"
        "aws-eks-test-cluster"
    )

frozenCatalog :: Either Text (RetainedCatalog 'Cascade)
frozenCatalog = do
  binding <- frozenBinding
  firstShow (retainedCatalogFor CascadeSurface frozenAwsScope binding)

frozenStateBucketName :: Text
frozenStateBucketName = "prodbox-frozen-pulumi-state"

-- | One returned @ResourceTagMapping@ carrying the retained state bucket's
-- full two-tag set, which the decoder lowers to two rows for one ARN.
retainedRows :: [AwsTagRow]
retainedRows =
  [ bucketRow (AwsTag "prodbox.io/managed-by" "prodbox")
  , bucketRow (AwsTag "prodbox.io/role" "pulumi-state")
  ]
 where
  bucketRow tag =
    AwsTagRow
      { awsTagRowArn =
          mustRight (mkArn ("arn:aws:s3:::" <> frozenStateBucketName))
      , awsTagRowScope = frozenAwsScope
      , awsTagRowResourceType = AwsResourceType "s3:bucket"
      , awsTagRowCoordinate = AwsResourceCoordinate frozenStateBucketName
      , awsTagRowTag = Just tag
      }

compiledFor :: CompiledDesiredAbsenceProgram 'Cascade
compiledFor =
  mustRight
    ( compileDesiredAbsenceGraph
        (mustRight (mkCleanupRunId "production-cloud-runtime-run"))
        (LinuxRke2FoundationId "home-rke2")
        (Just frozenAwsScope)
        CascadeSurface
    )

frozenAwsScope :: AwsScope
frozenAwsScope =
  AwsScope
    (AwsAccountId "123456789012")
    (AwsRegion "ca-central-1")

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = either (Left . Text.pack . show) Right

mustRight :: (Show left) => Either left right -> right
mustRight = \case
  Left err -> error ("expected Right, got Left " <> show err)
  Right value -> value

mustRightIO :: (Show left) => Either left right -> IO right
mustRightIO = \case
  Left err -> expectationFailure (show err) >> fail "expected Right"
  Right value -> pure value
