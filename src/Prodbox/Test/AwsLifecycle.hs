{-# LANGUAGE OverloadedStrings #-}

-- | The lifecycle scope declares its field before querying it. Its verdicts
-- concern that field only; retained families and omitted joins stay explicit.
module Prodbox.Test.AwsLifecycle
  ( AwsLifecycleExercise (..)
  , LifecycleFieldMember (..)
  , LifecycleFieldCoverage (..)
  , lifecycleFieldCoverage
  , lifecycleNotCovered
  , renderLifecycleCoverage
  , lifecycleExerciseStacks
  , lifecycleExerciseCleanupTargets
  , lifecycleExerciseProviderBodyRequestMaximum
  , lifecycleExerciseRecordedOutputReadMaximum
  , AwsLifecycleBoundary (..)
  , AwsLifecycleProgram (..)
  , AwsLifecycleStage (..)
  , AwsLifecycleError (..)
  , runAwsLifecycleExercise
  , renderAwsLifecycleError
  ) where

import Control.Monad (foldM_, unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.AwsLifecycleBudget qualified as Budget
import Prodbox.Infra.AwsFieldAudit (FieldAudit (..))
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding)
import Prodbox.Lifecycle.Teardown.Model (RegisteredResourceKey (..))
import System.Exit (ExitCode (..))

data AwsLifecycleExercise = AwsStackCycles | AwsTestVpcCanary
  deriving (Eq, Show, Enum, Bounded)

lifecycleExerciseStacks :: AwsLifecycleExercise -> [AuditStack]
lifecycleExerciseStacks exercise = case exercise of
  AwsStackCycles -> [AuditAwsTest, AuditAwsEks]
  AwsTestVpcCanary -> [AuditAwsTest]

-- Three independent audits surround each cycle. The public create performs
-- scope observation, its admitted reconcile, and its closing field inventory.
-- The public destroy performs before/after inventories and one fenced destroy.
-- Recorded output reads use the Authority checkpoint path, not Provider RPCs.
lifecycleExerciseProviderBodyRequestMaximum :: AwsLifecycleExercise -> Natural
lifecycleExerciseProviderBodyRequestMaximum =
  Budget.awsLifecycleProviderBodyRequestMaximum . lifecycleWorkload

lifecycleExerciseRecordedOutputReadMaximum :: AwsLifecycleExercise -> Natural
lifecycleExerciseRecordedOutputReadMaximum =
  Budget.awsLifecycleRecordedOutputReadMaximum . lifecycleWorkload

lifecycleWorkload :: AwsLifecycleExercise -> Budget.AwsLifecycleWorkload
lifecycleWorkload exercise = case exercise of
  AwsStackCycles -> Budget.AwsStackCycleWorkload
  AwsTestVpcCanary -> Budget.AwsTestVpcCanaryWorkload

-- Actual creators in each standalone drill. No chart, hosted zone or DNS01
-- solver is entered by either program; the canary creates only in aws-test.
lifecycleExerciseCleanupTargets :: AwsLifecycleExercise -> [RegisteredResourceKey]
lifecycleExerciseCleanupTargets exercise = case exercise of
  AwsTestVpcCanary -> [AwsTestKey, AwsTestVpcCniInterfacesKey, AwsTestCanarySecurityGroupsKey]
  AwsStackCycles ->
    [ AwsEksKey
    , AwsTestKey
    , AwsEbsPerRunTestKey
    , AwsEksIamRoleFamilyKey
    , AwsEksLoadBalancerControllerFamilyKey
    , AwsEksVpcCniInterfacesKey
    , AwsTestVpcCniInterfacesKey
    , AwsEksClusterSecurityGroupsKey
    , AwsTestCanarySecurityGroupsKey
    ]

-- | The doctrine's field, the audit's additional classes, and the omitted
-- bindings/brackets. An extension must decide its coverage explicitly.
data LifecycleFieldMember
  = VpcByOwnershipTags
  | VpcByRecordedIdentifier
  | VpcSubnets
  | VpcRouteTables
  | VpcInternetGateways
  | VpcSecurityGroups
  | VpcNetworkInterfaces
  | VpcNatGateways
  | VpcEndpoints
  | VpcInstances
  | VpcLoadBalancers
  | EksCluster
  | EksNodeGroup
  | EksAddons
  | EksOidcProvider
  | RegisteredIamRoles
  | RegisteredIamPolicies
  | PerRunEbsVolumes
  | RetainedEbsFamily
  | ValidationHostedZoneFamily
  | PerRunSubzone
  | RunScopeTagJoin
  | SubzoneDestroyBracket
  | SesDestroyBracket
  | CascadeDestroyBracket
  | PersistentIdentifierConfidentiality
  deriving (Eq, Ord, Show, Enum, Bounded)

data LifecycleFieldCoverage
  = EnumeratedField !AuditClass
  | FieldNotCovered !Text
  deriving (Eq, Show)

lifecycleFieldCoverage :: AwsLifecycleExercise -> LifecycleFieldMember -> LifecycleFieldCoverage
lifecycleFieldCoverage exercise member = case declaredMember member of
  Left reason -> FieldNotCovered reason
  Right class'
    | class' `elem` concatMap auditStackClasses (lifecycleExerciseStacks exercise) ->
        EnumeratedField class'
    | otherwise -> FieldNotCovered "this drill does not select the stack that enumerates this class"

declaredMember :: LifecycleFieldMember -> Either Text AuditClass
declaredMember member = case member of
  VpcByOwnershipTags -> Right AuditVpc
  VpcByRecordedIdentifier ->
    Left
      "the audit locates the VPC by exact Name and managed-by tags, without joining the recorded VPC identifier"
  VpcSubnets -> Right AuditSubnet
  VpcRouteTables -> Right AuditRouteTable
  VpcInternetGateways -> Right AuditInternetGateway
  VpcSecurityGroups -> Right AuditSecurityGroup
  VpcNetworkInterfaces -> Right AuditNetworkInterface
  VpcNatGateways -> Right AuditNatGateway
  VpcEndpoints -> Right AuditVpcEndpoint
  VpcInstances -> Right AuditInstance
  VpcLoadBalancers -> Right AuditLoadBalancer
  EksCluster -> Right AuditEksCluster
  EksNodeGroup -> Right AuditEksNodeGroup
  EksAddons -> Right AuditEksAddon
  EksOidcProvider -> Right AuditOidcProvider
  RegisteredIamRoles -> Right AuditIamRole
  RegisteredIamPolicies -> Right AuditIamPolicy
  PerRunEbsVolumes -> Right AuditEbsVolume
  RetainedEbsFamily -> Left "retained EBS is retained by design; this audit does not enumerate or report that family"
  ValidationHostedZoneFamily -> Left "the lifecycle-tagged validation hosted-zone family is outside the stack audit"
  PerRunSubzone -> Left "the command does not resolve the per-run hosted-zone identifier into the subzone audit"
  RunScopeTagJoin -> Left "the stack inventory is not joined to run-scope tags"
  SubzoneDestroyBracket -> Left "the aws-subzone destroy verb has no closing field-inventory bracket"
  SesDestroyBracket -> Left "the long-lived aws-ses stack and its destroy bracket are outside this scope"
  CascadeDestroyBracket -> Left "the home cascade and its per-run destroy bracket are outside this scope"
  PersistentIdentifierConfidentiality -> Left "Authority settlement retains bounded resource identifiers; decision D9 remains open"

fieldMemberLabel :: LifecycleFieldMember -> Text
fieldMemberLabel member = case member of
  VpcByOwnershipTags -> "vpc-by-ownership-tags"
  VpcByRecordedIdentifier -> "recorded-vpc-binding"
  VpcSubnets -> "subnets"
  VpcRouteTables -> "route-tables"
  VpcInternetGateways -> "internet-gateways"
  VpcSecurityGroups -> "security-groups"
  VpcNetworkInterfaces -> "network-interfaces"
  VpcNatGateways -> "nat-gateways"
  VpcEndpoints -> "vpc-endpoints"
  VpcInstances -> "instances"
  VpcLoadBalancers -> "load-balancers"
  EksCluster -> "eks-cluster"
  EksNodeGroup -> "eks-node-group"
  EksAddons -> "eks-addons"
  EksOidcProvider -> "oidc-provider"
  RegisteredIamRoles -> "registered-iam-roles"
  RegisteredIamPolicies -> "registered-iam-policies"
  PerRunEbsVolumes -> "per-run-ebs-volumes"
  RetainedEbsFamily -> "retained-ebs-family"
  ValidationHostedZoneFamily -> "validation-hosted-zone-family"
  PerRunSubzone -> "per-run-subzone"
  RunScopeTagJoin -> "run-scope-tag-join"
  SubzoneDestroyBracket -> "subzone-destroy-bracket"
  SesDestroyBracket -> "ses-destroy-bracket"
  CascadeDestroyBracket -> "cascade-destroy-bracket"
  PersistentIdentifierConfidentiality -> "persistent-identifier-confidentiality"

lifecycleNotCovered :: AwsLifecycleExercise -> [Text]
lifecycleNotCovered exercise =
  [ fieldMemberLabel member <> ": " <> reason
  | member <- [minBound .. maxBound]
  , FieldNotCovered reason <- [lifecycleFieldCoverage exercise member]
  ]

renderLifecycleCoverage :: AwsLifecycleExercise -> [Text]
renderLifecycleCoverage exercise =
  [ "AWS_LIFECYCLE_FIELD "
      <> fieldMemberLabel member
      <> " "
      <> render (lifecycleFieldCoverage exercise member)
  | member <- [minBound .. maxBound]
  ]
 where
  render coverage = case coverage of
    EnumeratedField class' -> "enumerated=" <> auditClassLabel class'
    FieldNotCovered reason -> "not-covered=" <> reason

data AwsLifecycleStage
  = LifecycleBeforeCreate
  | LifecycleCreate
  | LifecycleAfterCreate
  | LifecyclePlant
  | LifecycleDestroy
  | LifecycleAfterDestroy
  deriving (Eq, Show, Enum, Bounded)

data AwsLifecycleError
  = LifecycleBoundaryFailed !AwsLifecycleStage !AuditStack !Text
  | LifecycleCommandFailed !AwsLifecycleStage !AuditStack !ExitCode
  | LifecycleFieldWrongStack !AwsLifecycleStage !AuditStack
  | LifecycleFieldScopeChanged !AwsLifecycleStage !AuditStack
  | LifecycleFieldIncomplete !AwsLifecycleStage !AuditStack
  | LifecycleFieldWrongVerdict !AwsLifecycleStage !AuditStack !Text
  deriving (Eq, Show)

data AwsLifecycleBoundary m = AwsLifecycleBoundary
  { emitLifecycleFieldCoverage :: [Text] -> m ()
  , observeLifecycleField :: AuditStack -> m (Either Text FieldAudit)
  , reconcileLifecycleStack :: AuditStack -> m (Either Text ExitCode)
  , destroyLifecycleStack :: AuditStack -> m (Either Text ExitCode)
  }

-- | Only the canary program carries a plant effect. An ordinary cycle cannot
-- accidentally acquire it, and needs no refusal placeholder for an absent cap.
data AwsLifecycleProgram m
  = AwsStackCycleProgram !(AwsLifecycleBoundary m)
  | AwsTestVpcCanaryProgram !(AwsLifecycleBoundary m) !(m (Either Text ExitCode))

data FieldExpectation = EmptyField | PresentField

-- | Coverage is emitted before the first read. Each cycle starts from a
-- positively controlled empty field, observes presence after create, and
-- finishes with an independent empty-field read. The outer durable harness
-- owns cleanup on every failure or cancellation; this body never substitutes
-- a provider exit or local record for the final observation.
runAwsLifecycleExercise
  :: (Monad m)
  => AuditBinding
  -> AwsLifecycleProgram m
  -> m (Either AwsLifecycleError ())
runAwsLifecycleExercise registeredBinding program = runExceptT $ do
  lift (emitLifecycleFieldCoverage boundary (renderLifecycleCoverage exercise))
  foldM_ runStack (Just registeredBinding) (lifecycleExerciseStacks exercise)
 where
  (boundary, exercise) = case program of
    AwsStackCycleProgram supplied -> (supplied, AwsStackCycles)
    AwsTestVpcCanaryProgram supplied _ -> (supplied, AwsTestVpcCanary)
  runStack previous stack = do
    binding <- observe LifecycleBeforeCreate EmptyField stack previous
    command LifecycleCreate stack (reconcileLifecycleStack boundary stack)
    _ <- observe LifecycleAfterCreate PresentField stack (Just binding)
    case program of
      AwsStackCycleProgram _ -> pure ()
      AwsTestVpcCanaryProgram _ plant -> command LifecyclePlant stack plant
    command LifecycleDestroy stack (destroyLifecycleStack boundary stack)
    Just <$> observe LifecycleAfterDestroy EmptyField stack (Just binding)
  command stage stack action = do
    code <- ExceptT (first (LifecycleBoundaryFailed stage stack) <$> action)
    unless (code == ExitSuccess) (throwE (LifecycleCommandFailed stage stack code))
  observe stage expected stack previous = do
    audit <-
      ExceptT (first (LifecycleBoundaryFailed stage stack) <$> observeLifecycleField boundary stack)
    unless
      (fieldAuditStack audit == stack && auditObservationStack (fieldAuditObservation audit) == stack)
      (throwE (LifecycleFieldWrongStack stage stack))
    let binding = fieldAuditBinding audit
        observation = fieldAuditObservation audit
    case previous of
      Just established | established /= binding -> throwE (LifecycleFieldScopeChanged stage stack)
      _ -> pure ()
    unless
      ( auditObservationControl observation == AuditControlSeen
          && all ((== Nothing) . auditAnswerGap) (Map.elems (auditObservationAnswers observation))
      )
      (throwE (LifecycleFieldIncomplete stage stack))
    unless
      (expectedVerdict expected (auditVerdict observation))
      (throwE (LifecycleFieldWrongVerdict stage stack (auditVerdictLabel (auditVerdict observation))))
    pure (binding :: AuditBinding)
  expectedVerdict expected verdict = case (expected, verdict) of
    (EmptyField, AuditClean) -> True
    (EmptyField, AuditResidue _) -> False
    (EmptyField, AuditUnobservable _ _) -> False
    (PresentField, AuditClean) -> False
    (PresentField, AuditResidue _) -> True
    (PresentField, AuditUnobservable _ _) -> False

renderAwsLifecycleError :: AwsLifecycleError -> Text
renderAwsLifecycleError err = case err of
  LifecycleBoundaryFailed stage stack detail -> context stage stack <> "boundary failed: " <> detail
  LifecycleCommandFailed stage stack code -> context stage stack <> "command failed: " <> Text.pack (show code)
  LifecycleFieldWrongStack stage stack -> context stage stack <> "inventory names another stack"
  LifecycleFieldScopeChanged stage stack -> context stage stack <> "provider account/region changed during the exercise"
  LifecycleFieldIncomplete stage stack -> context stage stack <> "inventory is incomplete or its positive control is unseen"
  LifecycleFieldWrongVerdict stage stack verdict -> context stage stack <> "unexpected field verdict " <> verdict
 where
  context stage stack = Text.pack (show stage) <> " " <> auditStackLabel stack <> ": "
