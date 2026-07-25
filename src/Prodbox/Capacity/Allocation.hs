{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.68: make cluster/host resource over-commitment __unrepresentable__.
--
-- A live @prodbox test all --substrate home-local@ counterexample (the gateway
-- pinned at its authored CPU limit, ~93% cgroup throttle, periodic RTS
-- heap-overflow) passed every runtime-'Either' capacity validation yet still
-- failed at runtime — proof that 'Prodbox.Capacity.Config.validateResourcePlan'
-- lets an illegal state be __represented__ and then rejected, rather than making
-- it unbuildable. This module moves the nesting into an opaque proof so an
-- over-committed plan has no deployable representation, mirroring the in-tree
-- 'Prodbox.ControlPlane.Capacity.ServiceCapacityPlan' /
-- 'Prodbox.Capacity.RuntimeMemory.RuntimeMemoryPlan' opaque-proof idiom.
--
-- The proof is built only by the total 'compileResourcePlan'. Its two nesting
-- inequalities are construction witnesses rather than post-hoc checks:
--
-- @
-- allocatable = host_capacity − (rke2_reserved + eviction_floor)   -- 'reserveCluster'
--     ⇒ allocatable ≤ host_capacity   (non-saturating subtraction cannot underflow)
--
-- Σ concurrent-namespace draw ≤ allocatable                        -- threaded 'allocate'
--     ⇒ the single-node cluster is never over-committed
-- @
--
-- Each 'WorkloadAllocation' additionally carries a non-defaultable, non-erasable
-- 'WorkloadCertification'. With no committed measured profile every workload is
-- 'WorkloadUncertifiedUntilFirstProfile' (which stays deployable — blocking it
-- would deadlock the run that produces the first profile); a committed profile is
-- checked through the Sprint-1.65 'certifyMeasuredProfile'. The phantom index
-- @c :: Certification@ on 'AllocatedResourcePlan' is 'Certified' iff every
-- workload is; 'SomeAllocatedPlan' pairs the plan with its singleton witness.
--
-- The raw 'Prodbox.Capacity.Config.ResourcePlan' remains the @FromDhall@/@ToDhall@
-- decode surface; this opaque proof is derived once at the config boundary and is
-- never stored (threading it into the write-side renderers is Sprints 3.27/4.52).
module Prodbox.Capacity.Allocation
  ( -- * Certification index
    Certification (..)
  , SCertification (..)
  , WorkloadCertification (..)
  , someCertification

    -- * Guaranteed-QoS envelope witness
  , GuaranteedEnvelope
  , mkGuaranteedEnvelope
  , guaranteedEnvelopeVector

    -- * Host capacity and the threaded cluster budget
  , HostCapacity
  , mkHostCapacity
  , hostCapacityVector
  , ClusterBudget
  , reserveCluster
  , allocate
  , clusterBudgetAllocatable
  , clusterBudgetRemaining
  , clusterBudgetDrawn

    -- * Per-workload allocation
  , WorkloadAllocation
  , workloadAllocationProfileId
  , workloadAllocationNamespace
  , workloadAllocationDraw
  , CertifiedWorkload
  , certifiedWorkloadAllocation
  , certifiedWorkloadCertification
  , certifyWorkload

    -- * The opaque proof
  , AllocatedResourcePlan
  , SomeAllocatedPlan (..)
  , allocatedPlanClusterBudget
  , allocatedPlanWorkloads
  , CompileError (..)
  , renderCompileError
  , compileResourcePlan
  )
where

import Control.Monad (foldM, foldM_, forM_, unless)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config
  ( NamespaceQuota (..)
  , ResourceEnvelope (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  , WorkloadResourceProfile (..)
  , plusResourceVector
  , resourceVectorFitsWithin
  , resourceVectorScale
  , resourceVectorSubtractChecked
  , validateRawResourcePlanShape
  )
import Prodbox.Capacity.Config qualified as Config
import Prodbox.Capacity.MeasuredProfile
  ( MeasuredProfileDefect
  , MeasuredResourceProfile
  , certifyMeasuredProfile
  , renderMeasuredProfileDefect
  )
import Prodbox.Capacity.MeasuredProfile qualified as Measured

-- | The overall certification of a compiled plan, used as a type-level phantom on
-- 'AllocatedResourcePlan'. There is no defaultable @Uncertified@ value at the
-- term level that a caller can synthesize: the index is discovered by
-- 'compileResourcePlan' from the per-workload facts and returned inside
-- 'SomeAllocatedPlan'.
data Certification
  = Certified
  | UncertifiedUntilFirstProfile
  deriving (Eq, Show)

-- | Runtime singleton for the 'Certification' phantom.
data SCertification (c :: Certification) where
  SCertified :: SCertification 'Certified
  SUncertifiedUntilFirstProfile :: SCertification 'UncertifiedUntilFirstProfile

deriving instance Eq (SCertification c)

deriving instance Show (SCertification c)

-- | The demoted 'Certification' value carried by a singleton.
someCertification :: SCertification c -> Certification
someCertification SCertified = Certified
someCertification SUncertifiedUntilFirstProfile = UncertifiedUntilFirstProfile

-- | The certification status of a single workload allocation. Non-defaultable:
-- it is produced only by 'certifyWorkload'.
data WorkloadCertification
  = -- | A committed measured profile certifies the authored envelope.
    WorkloadCertified MeasuredResourceProfile
  | -- | No measured profile is committed for this workload yet. Deployable — the
    -- first healthy run is what produces the profile (Sprint 5.21).
    WorkloadUncertifiedUntilFirstProfile
  deriving (Eq, Show)

-- | An envelope proven to be Guaranteed-QoS: @request == limit@ on every axis.
-- 'Prodbox.Capacity.Config.mkResourceEnvelope' only proves @request ≤ limit@
-- (Burstable), so a control-plane workload that must never be throttled or
-- OOM-ranked ahead of its request uses this stricter witness. The constructor is
-- hidden; the only way to obtain one is 'mkGuaranteedEnvelope'.
newtype GuaranteedEnvelope = GuaranteedEnvelope ResourceVector
  deriving (Eq, Show)

-- | Prove an envelope is Guaranteed-QoS. Fails when any axis has @request ≠ limit@.
mkGuaranteedEnvelope :: ResourceEnvelope -> Either CompileError GuaranteedEnvelope
mkGuaranteedEnvelope envelope
  | request envelope == limit envelope = Right (GuaranteedEnvelope (limit envelope))
  | otherwise = Left (EnvelopeNotGuaranteed (request envelope) (limit envelope))

-- | The proven Guaranteed request/limit vector.
guaranteedEnvelopeVector :: GuaranteedEnvelope -> ResourceVector
guaranteedEnvelopeVector (GuaranteedEnvelope vector) = vector

-- | The authored host capacity. Hidden constructor: a 'ClusterBudget' can only be
-- reserved from a validated 'HostCapacity'.
newtype HostCapacity = HostCapacity ResourceVector
  deriving (Eq, Show)

-- | Accept a host-capacity vector. Every axis must be positive.
mkHostCapacity :: ResourceVector -> Either CompileError HostCapacity
mkHostCapacity vector
  | milli_cpu vector > 0
  , memory_mib vector > 0
  , ephemeral_storage_mib vector > 0
  , durable_storage_mib vector > 0 =
      Right (HostCapacity vector)
  | otherwise = Left (HostCapacityNotPositive vector)

-- | The validated host-capacity vector.
hostCapacityVector :: HostCapacity -> ResourceVector
hostCapacityVector (HostCapacity vector) = vector

-- | The cluster allocatable budget threaded through workload allocations. Hidden
-- constructor: @allocatable@ is fixed at 'reserveCluster'; @remaining@ only ever
-- decreases through 'allocate'. Because both use the non-saturating subtraction,
-- @allocatable ≤ host_capacity@ and @Σ draw ≤ allocatable@ hold by construction.
data ClusterBudget = ClusterBudget
  { clusterAllocatableVector :: ResourceVector
  , clusterRemainingVector :: ResourceVector
  }
  deriving (Eq, Show)

-- | Reserve the cluster allocatable from host capacity by subtracting the
-- combined RKE2 reservation and eviction floor. Fails (never clamps) when the
-- reservation exceeds host capacity, so the returned allocatable is a witness of
-- @allocatable ≤ host_capacity@.
reserveCluster :: HostCapacity -> ResourceVector -> Either CompileError ClusterBudget
reserveCluster (HostCapacity host) reservation =
  case resourceVectorSubtractChecked host reservation of
    Nothing -> Left (ClusterOverReserved host reservation)
    Just allocatable ->
      Right
        ClusterBudget
          { clusterAllocatableVector = allocatable
          , clusterRemainingVector = allocatable
          }

-- | Draw one vector from the threaded budget. Fails (never clamps) on an
-- over-draw, so a successful fold witnesses @Σ draw ≤ allocatable@.
allocate :: ClusterBudget -> ResourceVector -> Either CompileError ClusterBudget
allocate budget draw =
  case resourceVectorSubtractChecked (clusterRemainingVector budget) draw of
    Nothing -> Left (ClusterOverCommitted (clusterRemainingVector budget) draw)
    Just remaining -> Right budget {clusterRemainingVector = remaining}

-- | The fixed allocatable the budget was reserved with.
clusterBudgetAllocatable :: ClusterBudget -> ResourceVector
clusterBudgetAllocatable = clusterAllocatableVector

-- | The budget still available after every threaded draw.
clusterBudgetRemaining :: ClusterBudget -> ResourceVector
clusterBudgetRemaining = clusterRemainingVector

-- | The total drawn so far: @allocatable − remaining@. The subtraction is total
-- because @remaining ≤ allocatable@ by construction.
clusterBudgetDrawn :: ClusterBudget -> ResourceVector
clusterBudgetDrawn budget =
  case resourceVectorSubtractChecked
    (clusterAllocatableVector budget)
    (clusterRemainingVector budget) of
    Just drawn -> drawn
    -- Unreachable: 'reserveCluster'/'allocate' keep remaining ≤ allocatable.
    Nothing -> ResourceVector 0 0 0 0

-- | One workload's admitted draw against the cluster: @replicas × limit@. Hidden
-- constructor; produced only inside 'compileResourcePlan'.
data WorkloadAllocation = WorkloadAllocation
  { workloadAllocationProfileId_ :: Text
  , workloadAllocationNamespace_ :: Text
  , workloadAllocationDraw_ :: ResourceVector
  }
  deriving (Eq, Show)

-- | The workload profile id.
workloadAllocationProfileId :: WorkloadAllocation -> Text
workloadAllocationProfileId = workloadAllocationProfileId_

-- | The workload's namespace.
workloadAllocationNamespace :: WorkloadAllocation -> Text
workloadAllocationNamespace = workloadAllocationNamespace_

-- | The workload's admitted draw (@replicas × limit@).
workloadAllocationDraw :: WorkloadAllocation -> ResourceVector
workloadAllocationDraw = workloadAllocationDraw_

-- | A workload allocation paired with its certification. Hidden constructor.
data CertifiedWorkload = CertifiedWorkload
  { certifiedWorkloadAllocation_ :: WorkloadAllocation
  , certifiedWorkloadCertification_ :: WorkloadCertification
  }
  deriving (Eq, Show)

-- | The workload's admitted draw.
certifiedWorkloadAllocation :: CertifiedWorkload -> WorkloadAllocation
certifiedWorkloadAllocation = certifiedWorkloadAllocation_

-- | The workload's certification status.
certifiedWorkloadCertification :: CertifiedWorkload -> WorkloadCertification
certifiedWorkloadCertification = certifiedWorkloadCertification_

-- | Certify one workload against its committed measured profile, if any. With no
-- matching profile the workload is 'WorkloadUncertifiedUntilFirstProfile'
-- (deployable). With a matching profile that fails Sprint-1.65 certification the
-- whole compile fails. Reuses 'certifyMeasuredProfile'.
certifyWorkload
  :: Text
  -- ^ current hot-path source digest for this workload
  -> Natural
  -- ^ now, epoch seconds
  -> ResourcePlan
  -> [MeasuredResourceProfile]
  -> WorkloadResourceProfile
  -> Either CompileError WorkloadCertification
certifyWorkload currentDigest now plan profiles workload =
  case find ((== profile_id workload) . Measured.profile_id) profiles of
    Nothing -> Right WorkloadUncertifiedUntilFirstProfile
    Just profile ->
      case certifyMeasuredProfile currentDigest now plan profile of
        [] -> Right (WorkloadCertified profile)
        defects -> Left (WorkloadCertificationFailed (profile_id workload) defects)

-- | An opaque proof that a 'ResourcePlan' is neither over-reserved nor
-- over-committed, indexed by its overall certification. Hidden constructor:
-- built only by 'compileResourcePlan'.
data AllocatedResourcePlan (c :: Certification) = AllocatedResourcePlan
  { allocatedClusterBudget :: ClusterBudget
  , allocatedWorkloads :: [CertifiedWorkload]
  }
  deriving (Eq, Show)

-- | The threaded cluster budget after all concurrent-namespace draws.
allocatedPlanClusterBudget :: AllocatedResourcePlan c -> ClusterBudget
allocatedPlanClusterBudget = allocatedClusterBudget

-- | The per-workload certified allocations, one per authored workload profile.
allocatedPlanWorkloads :: AllocatedResourcePlan c -> [CertifiedWorkload]
allocatedPlanWorkloads = allocatedWorkloads

-- | An 'AllocatedResourcePlan' whose certification index has been existentially
-- packed with its runtime singleton. The tag is 'Certified' iff every workload is.
data SomeAllocatedPlan where
  SomeAllocatedPlan :: SCertification c -> AllocatedResourcePlan c -> SomeAllocatedPlan

instance Eq SomeAllocatedPlan where
  SomeAllocatedPlan tagLeft planLeft == SomeAllocatedPlan tagRight planRight =
    someCertification tagLeft == someCertification tagRight
      && allocatedWorkloads planLeft == allocatedWorkloads planRight
      && allocatedClusterBudget planLeft == allocatedClusterBudget planRight

instance Show SomeAllocatedPlan where
  show (SomeAllocatedPlan tag plan) =
    "SomeAllocatedPlan " ++ show (someCertification tag) ++ " " ++ show plan

-- | Every way a plan can fail to compile into a proof.
data CompileError
  = -- | A decode-time shape check failed (delegated to
    -- 'validateRawResourcePlanShape').
    PlanShapeInvalid String
  | -- | Host capacity has a non-positive axis (host).
    HostCapacityNotPositive ResourceVector
  | -- | @rke2_reserved + eviction_floor@ exceeds host capacity (host, reservation).
    ClusterOverReserved ResourceVector ResourceVector
  | -- | A namespace quota exceeds cluster allocatable (namespace).
    NamespaceQuotaExceedsAllocatable Text
  | -- | The concurrent namespace quotas over-draw the allocatable
    -- (remaining, offending draw).
    ClusterOverCommitted ResourceVector ResourceVector
  | -- | A namespace's workload draw exceeds its quota (namespace).
    WorkloadDrawExceedsQuota Text
  | -- | A committed measured profile fails certification (profile id, defects).
    WorkloadCertificationFailed Text [MeasuredProfileDefect]
  | -- | An envelope required to be Guaranteed-QoS is Burstable (request, limit).
    EnvelopeNotGuaranteed ResourceVector ResourceVector
  deriving (Eq, Show)

-- | Render a compile error for the @dev check@ over-commit gate and diagnostics.
renderCompileError :: CompileError -> String
renderCompileError err = case err of
  PlanShapeInvalid message ->
    "resource plan shape invalid: " ++ message
  HostCapacityNotPositive vector ->
    "host capacity must be positive on every axis: " ++ renderVector vector
  ClusterOverReserved host reservation ->
    "rke2_reserved + eviction_floor "
      ++ renderVector reservation
      ++ " exceeds host_capacity "
      ++ renderVector host
  NamespaceQuotaExceedsAllocatable namespace ->
    "namespace quota `"
      ++ Text.unpack namespace
      ++ "` exceeds cluster allocatable capacity"
  ClusterOverCommitted remaining draw ->
    "concurrent namespace quotas over-commit the cluster: draw "
      ++ renderVector draw
      ++ " exceeds remaining allocatable "
      ++ renderVector remaining
  WorkloadDrawExceedsQuota namespace ->
    "workload draw for namespace `"
      ++ Text.unpack namespace
      ++ "` exceeds that namespace quota"
  WorkloadCertificationFailed profileId defects ->
    "workload `"
      ++ Text.unpack profileId
      ++ "` fails measured certification: "
      ++ unwords (map renderMeasuredProfileDefect defects)
  EnvelopeNotGuaranteed requested limited ->
    "envelope must be Guaranteed-QoS (request == limit); request "
      ++ renderVector requested
      ++ " limit "
      ++ renderVector limited
 where
  renderVector vector =
    "{cpu="
      ++ show (milli_cpu vector)
      ++ "m, mem="
      ++ show (memory_mib vector)
      ++ "Mi, eph="
      ++ show (ephemeral_storage_mib vector)
      ++ "Mi, dur="
      ++ show (durable_storage_mib vector)
      ++ "Mi}"

-- | The single smart constructor for the over-commitment proof. Total: every
-- rejection is a structured 'CompileError'. On success it returns a
-- 'SomeAllocatedPlan' whose singleton tag is 'Certified' iff every workload
-- certified against a committed measured profile.
--
-- Order of proof (each step's failure is a distinct 'CompileError'):
--
-- 1. decode-time shape ('validateRawResourcePlanShape');
-- 2. reserve allocatable ≤ host_capacity ('reserveCluster');
-- 3. each namespace quota ≤ allocatable;
-- 4. Σ concurrent-namespace quota ≤ allocatable (threaded 'allocate');
-- 5. each namespace's workload draw ≤ its quota;
-- 6. per-workload measured certification ('certifyWorkload').
compileResourcePlan
  :: [MeasuredResourceProfile]
  -- ^ committed measured profiles
  -> (Text -> Text)
  -- ^ current hot-path source digest for a workload id
  -> Natural
  -- ^ now, epoch seconds
  -> ResourcePlan
  -> Either CompileError SomeAllocatedPlan
compileResourcePlan profiles digestFor now plan = do
  -- (1) shape
  either (Left . PlanShapeInvalid) Right (validateRawResourcePlanShape plan)
  -- (2) reserve allocatable ≤ host_capacity
  host <- mkHostCapacity (host_capacity plan)
  let reservation = rke2_reserved plan `plusResourceVector` eviction_floor plan
  reserved <- reserveCluster host reservation
  let allocatable = clusterBudgetAllocatable reserved
  -- (3) each namespace quota ≤ allocatable
  forM_ (namespace_quotas plan) $ \namespaceQuota ->
    unless
      (quota namespaceQuota `resourceVectorFitsWithin` allocatable)
      (Left (NamespaceQuotaExceedsAllocatable (namespace_name namespaceQuota)))
  -- (4) Σ concurrent-namespace quota ≤ allocatable, threaded so it holds by
  -- construction.
  threaded <-
    foldM
      allocate
      reserved
      (map quota (Config.concurrentNamespaceQuotas plan))
  -- (5) each namespace's workload draw ≤ its quota.
  forM_ (namespace_quotas plan) $ \namespaceQuota -> do
    let namespaceName = namespace_name namespaceQuota
        draws =
          [ workloadProfileDraw workload
          | workload <- workload_profiles plan
          , profile_namespace workload == namespaceName
          ]
    foldM_ (namespaceQuotaBudget (quota namespaceQuota) namespaceName) (quota namespaceQuota) draws
  -- (6) per-workload certification + allocation.
  certifiedWorkloads <-
    traverse
      ( \workload -> do
          certification <-
            certifyWorkload (digestFor (profile_id workload)) now plan profiles workload
          pure
            CertifiedWorkload
              { certifiedWorkloadAllocation_ =
                  WorkloadAllocation
                    { workloadAllocationProfileId_ = profile_id workload
                    , workloadAllocationNamespace_ = profile_namespace workload
                    , workloadAllocationDraw_ = workloadProfileDraw workload
                    }
              , certifiedWorkloadCertification_ = certification
              }
      )
      (workload_profiles plan)
  let compiled =
        AllocatedResourcePlan
          { allocatedClusterBudget = threaded
          , allocatedWorkloads = certifiedWorkloads
          }
  pure (packCertification certifiedWorkloads compiled)

-- | Draw a namespace's workload against a budget seeded from its quota, mapping an
-- over-draw to 'WorkloadDrawExceedsQuota' for that namespace.
namespaceQuotaBudget
  :: ResourceVector -> Text -> ResourceVector -> ResourceVector -> Either CompileError ResourceVector
namespaceQuotaBudget _quota namespaceName remaining draw =
  case resourceVectorSubtractChecked remaining draw of
    Nothing -> Left (WorkloadDrawExceedsQuota namespaceName)
    Just remaining' -> Right remaining'

-- | Pack the compiled plan with the singleton for its overall certification tag.
packCertification :: [CertifiedWorkload] -> AllocatedResourcePlan c -> SomeAllocatedPlan
packCertification certifiedWorkloads plan
  | all isCertified certifiedWorkloads =
      SomeAllocatedPlan SCertified (retagCertified plan)
  | otherwise =
      SomeAllocatedPlan SUncertifiedUntilFirstProfile (retagUncertified plan)
 where
  isCertified workload =
    case certifiedWorkloadCertification_ workload of
      WorkloadCertified _ -> True
      WorkloadUncertifiedUntilFirstProfile -> False

-- | Re-index the phantom. The fields are certification-independent, so this is a
-- total structural retag.
retagCertified :: AllocatedResourcePlan c -> AllocatedResourcePlan 'Certified
retagCertified (AllocatedResourcePlan budget workloads) =
  AllocatedResourcePlan budget workloads

retagUncertified :: AllocatedResourcePlan c -> AllocatedResourcePlan 'UncertifiedUntilFirstProfile
retagUncertified (AllocatedResourcePlan budget workloads) =
  AllocatedResourcePlan budget workloads

-- | @replicas × limit@: the admitted draw for one workload profile.
workloadProfileDraw :: WorkloadResourceProfile -> ResourceVector
workloadProfileDraw workload =
  resourceVectorScale (replicas workload) (limit (resources workload))
