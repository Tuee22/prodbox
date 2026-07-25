{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.68 conformance suite: the resource-envelope over-commitment proof.
--
-- Pure decode/compile tables prove @host_capacity ≥ cluster allocatable ≥ Σ
-- workload draw@ holds by construction: the non-saturating checked subtraction
-- refuses an over-draw (no silent clamp-to-zero), 'compileResourcePlan' of the
-- committed 'C.defaultResourcePlan' returns 'Right', and the over-reserved /
-- over-committed / workload-over-quota fixtures return 'Left'. Certification is
-- non-defaultable: with no committed profile every workload is
-- 'WorkloadUncertifiedUntilFirstProfile' (deployable); a satisfying profile
-- certifies and a violating one fails the whole compile.
module Allocation
  ( allocationSuite
  )
where

import Numeric.Natural (Natural)
import Prodbox.Capacity.Allocation
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.MeasuredProfile qualified as M
import TestSupport

-- | A fixed epoch far enough in the future that the fixture profiles are recent.
testNowNat :: Natural
testNowNat = 2_000_000_000

-- | The authored gateway workload from the default plan (750m CPU request/limit,
-- 512Mi memory limit).
gatewayWorkload :: C.WorkloadResourceProfile
gatewayWorkload =
  case [w | w <- C.workload_profiles C.defaultResourcePlan, C.profile_id w == "gateway"] of
    (w : _) -> w
    [] -> error "default plan is missing the gateway workload"

-- | A measured gateway profile that certifies cleanly against that envelope.
certifiedGatewayProfile :: M.MeasuredResourceProfile
certifiedGatewayProfile =
  M.MeasuredResourceProfile
    { M.profile_id = "gateway"
    , M.recorded_at = testNowNat - 1000
    , M.hot_path_digest = "current-digest"
    , M.sample_window_seconds = 1800
    , M.sample_count = 300
    , M.cpu_p95_milli = 400
    , M.cpu_p99_milli = 500
    , M.throttled_periods_ppm = 1000
    , M.rss_high_water_mib = 300
    , M.heap_high_water_bytes = 268_435_456
    , M.object_store_op_p99_millis = 50
    }

-- | The same profile with a p99 that no longer fits the authored 750m envelope
-- (p99 900 requires 1200m).
violatingGatewayProfile :: M.MeasuredResourceProfile
violatingGatewayProfile = certifiedGatewayProfile {M.cpu_p99_milli = 900}

-- | A minimal, valid single-workload plan (one @gateway@ namespace + workload).
miniPlan :: C.ResourcePlan
miniPlan =
  C.ResourcePlan
    { C.host_capacity = C.ResourceVector 8000 8192 100_000 100_000
    , C.rke2_reserved = C.ResourceVector 1000 1024 1024 1024
    , C.eviction_floor = C.ResourceVector 500 512 1024 1024
    , C.namespace_quotas = [C.NamespaceQuota "gateway" (C.ResourceVector 1000 1024 2048 2048)]
    , C.workload_profiles =
        [ C.WorkloadResourceProfile
            { C.profile_id = "gateway"
            , C.profile_namespace = "gateway"
            , C.replicas = 1
            , C.resources =
                C.ResourceEnvelope
                  { C.request = C.ResourceVector 750 512 512 1
                  , C.limit = C.ResourceVector 750 512 512 1
                  }
            }
        ]
    }

-- | The overall certification tag returned by a compile, or @"left"@ on failure.
compileTag :: Either CompileError SomeAllocatedPlan -> String
compileTag outcome = case outcome of
  Left _ -> "left"
  Right (SomeAllocatedPlan SCertified _) -> "certified"
  Right (SomeAllocatedPlan SUncertifiedUntilFirstProfile _) -> "uncertified"

allocationSuite :: SuiteBuilder ()
allocationSuite =
  describe "Sprint 1.68 resource-envelope over-commitment proof" $ do
    describe "non-saturating checked subtraction and the threaded budget" $ do
      it "subtracts when every axis fits" $
        C.resourceVectorSubtractChecked
          (C.ResourceVector 8000 8192 100 100)
          (C.ResourceVector 1000 1024 10 10)
          `shouldBe` Just (C.ResourceVector 7000 7168 90 90)

      it "refuses (never clamps) an underflow on any single axis" $ do
        C.resourceVectorSubtractChecked
          (C.ResourceVector 8000 8192 100 100)
          (C.ResourceVector 9000 1024 10 10)
          `shouldBe` Nothing
        C.resourceVectorSubtractChecked
          (C.ResourceVector 8000 8192 100 100)
          (C.ResourceVector 1000 1024 10 200)
          `shouldBe` Nothing

      it "reserveCluster refuses an over-reserved host" $ do
        let host = either (error . show) id (mkHostCapacity (C.ResourceVector 8000 8192 100 100))
        (clusterBudgetRemaining <$> reserveCluster host (C.ResourceVector 1000 1024 10 10))
          `shouldBe` Right (C.ResourceVector 7000 7168 90 90)
        reserveCluster host (C.ResourceVector 9000 1024 10 10)
          `shouldSatisfy` isLeftOutcome

      it "allocate reduces the remaining budget and Σ draw == allocatable − remaining" $ do
        let host = either (error . show) id (mkHostCapacity (C.ResourceVector 8000 8192 100 100))
            reserved = either (error . show) id (reserveCluster host (C.ResourceVector 0 0 0 0))
            drawn = allocate reserved (C.ResourceVector 3000 1000 10 10)
        (clusterBudgetRemaining <$> drawn)
          `shouldBe` Right (C.ResourceVector 5000 7192 90 90)
        (clusterBudgetDrawn <$> drawn)
          `shouldBe` Right (C.ResourceVector 3000 1000 10 10)

      it "allocate refuses an over-draw" $ do
        let host = either (error . show) id (mkHostCapacity (C.ResourceVector 8000 8192 100 100))
            reserved = either (error . show) id (reserveCluster host (C.ResourceVector 0 0 0 0))
        allocate reserved (C.ResourceVector 9000 1000 10 10)
          `shouldSatisfy` isLeftOutcome

    describe "compileResourcePlan on the committed default and over-commit fixtures" $ do
      it "compiles the committed defaultResourcePlan" $
        compileResourcePlan [] (const "") 0 C.defaultResourcePlan
          `shouldSatisfy` isRightOutcome

      it "rejects an over-reserved host" $
        compileResourcePlan
          []
          (const "")
          0
          C.defaultResourcePlan {C.rke2_reserved = C.ResourceVector 8000 2048 10_240 1024}
          `shouldSatisfy` isClusterOverReserved

      it "rejects a namespace quota that exceeds cluster allocatable" $
        compileResourcePlan [] (const "") 0 (bumpKeycloakQuotaCpu 7000)
          `shouldBe` Left (NamespaceQuotaExceedsAllocatable "keycloak")

      it "rejects concurrent namespace quotas that over-commit the cluster" $
        compileResourcePlan [] (const "") 0 (bumpApiQuotaMemory 2000)
          `shouldSatisfy` isClusterOverCommitted

      it "rejects a namespace whose workload draw exceeds its quota" $
        -- Shrink the `api` quota CPU (100m) below its workload draw (2×250m =
        -- 500m). `api` is neither `keycloak` nor `vscode`, so 'concurrentNamespaceQuotas'
        -- leaves it untouched and the earlier gates still pass; only the
        -- per-namespace draw check trips.
        compileResourcePlan [] (const "") 0 (shrinkApiQuotaCpu 100)
          `shouldBe` Left (WorkloadDrawExceedsQuota "api")

    describe "non-defaultable per-workload certification" $ do
      it "is UncertifiedUntilFirstProfile when no profile is committed" $
        certifyWorkload "current-digest" testNowNat C.defaultResourcePlan [] gatewayWorkload
          `shouldBe` Right WorkloadUncertifiedUntilFirstProfile

      it "certifies against a satisfying committed profile" $
        certifyWorkload
          "current-digest"
          testNowNat
          C.defaultResourcePlan
          [certifiedGatewayProfile]
          gatewayWorkload
          `shouldBe` Right (WorkloadCertified certifiedGatewayProfile)

      it "fails the compile against a violating committed profile" $
        certifyWorkload
          "current-digest"
          testNowNat
          C.defaultResourcePlan
          [violatingGatewayProfile]
          gatewayWorkload
          `shouldSatisfy` isLeftOutcome

    describe "the SomeAllocatedPlan tag is Certified iff every workload is" $ do
      it "tags a fully certified single-workload plan Certified" $
        compileTag
          (compileResourcePlan [certifiedGatewayProfile] (const "current-digest") testNowNat miniPlan)
          `shouldBe` "certified"

      it "tags the same plan Uncertified with no committed profile" $
        compileTag (compileResourcePlan [] (const "current-digest") testNowNat miniPlan)
          `shouldBe` "uncertified"

      it "tags a partially certified plan Uncertified" $
        -- gateway certifies, but the default plan's other workloads do not.
        compileTag
          ( compileResourcePlan
              [certifiedGatewayProfile]
              (const "current-digest")
              testNowNat
              C.defaultResourcePlan
          )
          `shouldBe` "uncertified"

    describe "the Guaranteed-QoS envelope witness" $ do
      it "accepts request == limit on every axis" $
        (guaranteedEnvelopeVector <$> mkGuaranteedEnvelope guaranteedEnvelope)
          `shouldBe` Right (C.ResourceVector 750 512 512 1)

      it "refuses a Burstable envelope (request /= limit)" $
        mkGuaranteedEnvelope burstableEnvelope
          `shouldSatisfy` isLeftOutcome
 where
  bumpKeycloakQuotaCpu newCpu =
    C.defaultResourcePlan
      { C.namespace_quotas =
          map
            ( \nq ->
                if C.namespace_name nq == "keycloak"
                  then nq {C.quota = (C.quota nq) {C.milli_cpu = newCpu}}
                  else nq
            )
            (C.namespace_quotas C.defaultResourcePlan)
      }
  bumpApiQuotaMemory newMem =
    C.defaultResourcePlan
      { C.namespace_quotas =
          map
            ( \nq ->
                if C.namespace_name nq == "api"
                  then nq {C.quota = (C.quota nq) {C.memory_mib = newMem}}
                  else nq
            )
            (C.namespace_quotas C.defaultResourcePlan)
      }
  shrinkApiQuotaCpu newCpu =
    C.defaultResourcePlan
      { C.namespace_quotas =
          map
            ( \nq ->
                if C.namespace_name nq == "api"
                  then nq {C.quota = (C.quota nq) {C.milli_cpu = newCpu}}
                  else nq
            )
            (C.namespace_quotas C.defaultResourcePlan)
      }
  guaranteedEnvelope =
    C.ResourceEnvelope
      { C.request = C.ResourceVector 750 512 512 1
      , C.limit = C.ResourceVector 750 512 512 1
      }
  burstableEnvelope =
    C.ResourceEnvelope
      { C.request = C.ResourceVector 250 512 512 1
      , C.limit = C.ResourceVector 750 512 512 1
      }

isLeftOutcome :: Either a b -> Bool
isLeftOutcome = either (const True) (const False)

isRightOutcome :: Either a b -> Bool
isRightOutcome = either (const False) (const True)

isClusterOverReserved :: Either CompileError b -> Bool
isClusterOverReserved (Left (ClusterOverReserved _ _)) = True
isClusterOverReserved _ = False

isClusterOverCommitted :: Either CompileError b -> Bool
isClusterOverCommitted (Left (ClusterOverCommitted _ _)) = True
isClusterOverCommitted _ = False
