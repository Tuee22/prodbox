{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.68 conformance suite: the resource-envelope over-commitment proof.
--
-- Pure decode/compile tables prove @host_capacity ≥ cluster allocatable ≥ Σ
-- workload draw@ holds by construction: the non-saturating checked subtraction
-- refuses an over-draw (no silent clamp-to-zero), 'compileResourcePlan' of the
-- committed 'C.defaultResourcePlan' returns 'Right', and the over-reserved /
-- over-committed fixtures return 'Left'. Certification is
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
import Prodbox.Capacity.Derivation qualified as D
import Prodbox.Capacity.MeasuredProfile qualified as M
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Capacity.Placement qualified as Placement
import Prodbox.Capacity.Render qualified as Render
import Prodbox.Substrate (Substrate (..))
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
    , C.workload_profiles =
        [ C.WorkloadResourceProfile
            { C.profile_id = "gateway"
            , C.profile_namespace = "gateway"
            , C.replicas = 1
            , C.workload_concurrency = C.Steady
            , C.surge = 0
            , C.workload_qos = C.Burstable
            , C.workload_demand =
                C.WorkloadDemandSpec
                  { C.cpu_demand = C.CpuDemandSpec 750 1000 0 0 "gateway"
                  , C.memory_demand = C.MemoryDemandSpec [512] 0
                  , C.ephemeral_demand = C.EphemeralDemandSpec [512] 0
                  , C.demanded_durable_storage_mib = 1
                  , C.demand_qos = C.Burstable
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
    describe "Sprint 1.71 derived workload resource contracts" $ do
      it "derives every envelope axis from demand terms with exact CPU rounding" $ do
        let demand =
              C.WorkloadDemandSpec
                { C.cpu_demand = C.CpuDemandSpec 100 2500 200000 100 "api-calibration"
                , C.memory_demand = C.MemoryDemandSpec [128, 64, 32] 96
                , C.ephemeral_demand = C.EphemeralDemandSpec [256, 128] 64
                , C.demanded_durable_storage_mib = 1024
                , C.demand_qos = C.Burstable
                }
        (D.derivedResourceEnvelope <$> D.deriveResourceEnvelope demand)
          `shouldBe` Right
            ( C.ResourceEnvelope
                (C.ResourceVector 300 224 384 1024)
                (C.ResourceVector 400 320 448 1024)
            )

      it "makes Guaranteed QoS request and limit identical" $ do
        let demand =
              C.WorkloadDemandSpec
                { C.cpu_demand = C.CpuDemandSpec 60 1000 0 999 "authority"
                , C.memory_demand = C.MemoryDemandSpec [80] 999
                , C.ephemeral_demand = C.EphemeralDemandSpec [256] 999
                , C.demanded_durable_storage_mib = 0
                , C.demand_qos = C.Guaranteed
                }
        (D.derivedResourceEnvelope <$> D.deriveResourceEnvelope demand)
          `shouldBe` Right
            ( C.ResourceEnvelope
                (C.ResourceVector 60 80 256 0)
                (C.ResourceVector 60 80 256 0)
            )

      it "rejects a demand with no calibration identity" $ do
        let demand =
              C.WorkloadDemandSpec
                { C.cpu_demand = C.CpuDemandSpec 1 1000 0 0 ""
                , C.memory_demand = C.MemoryDemandSpec [1] 0
                , C.ephemeral_demand = C.EphemeralDemandSpec [1] 0
                , C.demanded_durable_storage_mib = 0
                , C.demand_qos = C.Burstable
                }
        D.deriveResourceEnvelope demand `shouldBe` Left D.EmptyCalibrationProfile

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

      it "rejects concurrent workload draws that over-commit the cluster" $
        compileResourcePlan [] (const "") 0 (bumpWorkloadLimitMemory "api" 20_000)
          `shouldSatisfy` isClusterOverCommitted

      it "exposes allocatable, total, and per-workload draws from the proof" $ do
        let compiled =
              either
                (error . renderCompileError)
                id
                (compileResourcePlanUncertified miniPlan)
        planAllocatable compiled `shouldBe` C.ResourceVector 6500 6656 97_952 97_952
        planTotalDraw compiled `shouldBe` C.ResourceVector 750 512 512 1
        planWorkloadDraws compiled
          `shouldBe` [("gateway", C.ResourceVector 750 512 512 1)]

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

      it "requires every standing control-plane workload to be tagged Guaranteed" $ do
        let controlPlaneIds =
              [ "bootstrap-broker"
              , "lifecycle-authority"
              , "provider-worker"
              , "authority-backup"
              , "tls-retention"
              , "target-secret-agent"
              ]
        mapM_
          ( \profileId ->
              compileResourcePlanUncertified (setWorkloadQoS profileId C.Burstable C.defaultResourcePlan)
                `shouldBe` Left (ControlPlaneQoSNotGuaranteed profileId)
          )
          controlPlaneIds

      it "makes a non-Guaranteed envelope unrepresentable for a Guaranteed demand" $ do
        let badPlan =
              updateWorkload
                "bootstrap-broker"
                ( \workload ->
                    workload
                      { C.workload_demand =
                          (C.workload_demand workload)
                            { C.memory_demand =
                                (C.memory_demand (C.workload_demand workload))
                                  { C.bounded_memory_burst_mib = 64
                                  }
                            }
                      }
                )
                C.defaultResourcePlan
        compileResourcePlanUncertified badPlan `shouldSatisfy` isRightOutcome
        let profile =
              case [ p
                   | p <- C.workload_profiles badPlan
                   , C.profile_id p == "bootstrap-broker"
                   ] of
                p : _ -> p
                [] -> error "bootstrap-broker profile missing"
        C.request (C.resources profile) `shouldBe` C.limit (C.resources profile)

    describe "Sprint 3.28 unified resource rendering" $ do
      it "derives separate namespace request and limit admission axes" $ do
        Placement.planNamespaceAdmission SubstrateHomeLocal "vscode" C.defaultResourcePlan
          `shouldBe` Right
            ( C.ResourceEnvelope
                (C.ResourceVector 1880 3888 5728 112640)
                (C.ResourceVector 2525 5472 11456 112640)
            )

      it "renders the canonical seven-field quota spec from one function" $
        show (Render.resourceQuotaSpec (C.ResourceVector 1000 2048 4096 8192))
          `shouldContain` "requests.storage"

      it "renders runtime vectors and quantity strings byte-identically" $ do
        Render.cpuQuantity 750 `shouldBe` "750m"
        Render.memoryQuantity 512 `shouldBe` "512Mi"
        Render.renderResourceVectorRuntime (C.ResourceVector 750 512 1024 2048)
          `shouldBe` "cpu=750m,memory=512Mi,ephemeral-storage=1024Mi,durable-storage=2048Mi"

    describe "Sprint 4.52 observed-host allocation refinement" $ do
      it "accepts four independently sufficient observed axes" $ do
        let compiled = compileDefaultPlan
            observed =
              observedRoot
                (C.ResourceVector 8000 15872 100000 180000)
                "kubelet-device"
                "retained-device"
        compileResourcePlanAgainstObserved observed compiled `shouldBe` Right compiled

      it "names the independently insufficient observed dimension" $ do
        let compiled = compileDefaultPlan
            observed =
              observedRoot
                (C.ResourceVector 7999 15872 100000 180000)
                "kubelet-device"
                "retained-device"
        compileResourcePlanAgainstObserved observed compiled
          `shouldBe` Left (ObservedHostDimensionInsufficient "milli_cpu" 7999 8000)

      it "uses one joint storage budget when both paths resolve to one device" $ do
        let compiled = compileDefaultPlan
            insufficient =
              observedRoot
                (C.ResourceVector 8000 15872 200000 200000)
                "shared-device"
                "shared-device"
            sufficient =
              observedRoot
                (C.ResourceVector 8000 15872 280000 280000)
                "shared-device"
                "shared-device"
        compileResourcePlanAgainstObserved insufficient compiled
          `shouldBe` Left (ObservedHostSharedStorageInsufficient 200000 280000)
        compileResourcePlanAgainstObserved sufficient compiled `shouldBe` Right compiled
 where
  compileDefaultPlan =
    either
      (error . renderCompileError)
      id
      (compileResourcePlanUncertified C.defaultResourcePlan)
  observedRoot vector ephemeralDevice durableDevice =
    either
      error
      id
      ( Observed.mkObservedHostRoot
          vector
          (device ephemeralDevice)
          (device durableDevice)
      )
  device value =
    maybe (error "invalid observed-device fixture") id (Observed.mkStorageDeviceId value)
  bumpWorkloadLimitMemory profileId newMemory =
    updateWorkload
      profileId
      ( \workload ->
          workload
            { C.workload_demand =
                (C.workload_demand workload)
                  { C.memory_demand =
                      (C.memory_demand (C.workload_demand workload))
                        { C.steady_memory_terms_mib = [newMemory]
                        , C.bounded_memory_burst_mib = 0
                        }
                  }
            }
      )
      C.defaultResourcePlan
  setWorkloadQoS profileId qos =
    updateWorkload
      profileId
      ( \workload ->
          workload
            { C.workload_qos = qos
            , C.workload_demand = (C.workload_demand workload) {C.demand_qos = qos}
            }
      )
  updateWorkload profileId update plan =
    plan
      { C.workload_profiles =
          map
            (\workload -> if C.profile_id workload == profileId then update workload else workload)
            (C.workload_profiles plan)
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
