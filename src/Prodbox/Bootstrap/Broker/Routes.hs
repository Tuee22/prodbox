-- | Closed HTTP route registry for the pre-Vault Bootstrap Broker.
--
-- Every route projects to one of the four broker capability operations.  The
-- registry intentionally has no variable path escape and no generic Vault,
-- object-store, mesh, DNS, provider, authority, or target-secret route.
module Prodbox.Bootstrap.Broker.Routes
  ( BrokerRoute (..)
  , BrokerHttpMethod (..)
  , BrokerOperationClass (..)
  , BrokerMutationClass (..)
  , BrokerBodyRequirement (..)
  , BrokerRouteSpec
  , allBrokerRoutes
  , brokerOperationCapabilityOp
  , brokerRouteSpec
  , brokerRouteMethod
  , brokerRouteOperationClass
  , brokerRouteCapabilityOp
  , brokerRouteMutationClass
  , brokerRouteIsMutation
  , brokerRouteBodyRequirement
  , brokerRoutePath
  , brokerRouteForPath
  , brokerRouteForRequest
  )
where

import Data.List (find)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityOp (..)
  )

-- | The complete Bootstrap Broker route surface.
data BrokerRoute
  = BrokerHealth
  | BrokerReadiness
  | BrokerVaultStatus
  | BrokerVaultInitialize
  | BrokerVaultUnseal
  | BrokerVaultSeal
  | BrokerVaultRotateUnlockBundle
  | BrokerVaultRotateTransitKey
  | BrokerVaultBaselineReconcile
  | BrokerVaultPkiStatus
  | BrokerVaultPkiIssueTestCertificate
  | BrokerVaultResetAmbiguousInitialization
  | BrokerChildCustodyCommit
  | BrokerChildRecoveryDeliver
  | BrokerChildRecoveryObserve
  deriving (Eq, Ord, Show, Enum, Bounded)

data BrokerHttpMethod
  = BrokerGet
  | BrokerPost
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The only four operation classes the Broker router may select.
data BrokerOperationClass
  = BrokerBootstrapObserve
  | BrokerBootstrapMutate
  | BrokerBaselineReconcile
  | BrokerPkiOperate
  deriving (Eq, Ord, Show, Enum, Bounded)

data BrokerMutationClass
  = BrokerReadOnly
  | BrokerMutating
  deriving (Eq, Ord, Show, Enum, Bounded)

data BrokerBodyRequirement
  = BrokerBodyForbidden
  | BrokerBodyRequired
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Metadata for one registered route.  The constructor stays private so no
-- caller can manufacture a route specification outside this closed registry.
data BrokerRouteSpec = BrokerRouteSpec
  { specMethod :: BrokerHttpMethod
  , specOperationClass :: BrokerOperationClass
  , specMutationClass :: BrokerMutationClass
  , specBodyRequirement :: BrokerBodyRequirement
  , specPath :: String
  }
  deriving (Eq, Show)

allBrokerRoutes :: [BrokerRoute]
allBrokerRoutes = [minBound .. maxBound]

brokerOperationCapabilityOp :: BrokerOperationClass -> CapabilityOp
brokerOperationCapabilityOp operationClass = case operationClass of
  BrokerBootstrapObserve -> OpVaultBootstrapObserve
  BrokerBootstrapMutate -> OpVaultBootstrapMutate
  BrokerBaselineReconcile -> OpVaultBaselineReconcile
  BrokerPkiOperate -> OpVaultPkiOperate

brokerRouteSpec :: BrokerRoute -> BrokerRouteSpec
brokerRouteSpec route = case route of
  BrokerHealth ->
    readOnlySpec BrokerGet BrokerBootstrapObserve BrokerBodyForbidden "/healthz"
  BrokerReadiness ->
    readOnlySpec BrokerGet BrokerBootstrapObserve BrokerBodyForbidden "/readyz"
  BrokerVaultStatus ->
    readOnlySpec
      BrokerGet
      BrokerBootstrapObserve
      BrokerBodyForbidden
      "/v1/bootstrap/vault/status"
  BrokerVaultInitialize ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/vault/init"
  BrokerVaultUnseal ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/vault/unseal"
  BrokerVaultSeal ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/vault/seal"
  BrokerVaultRotateUnlockBundle ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/vault/rotate-unlock-bundle"
  BrokerVaultRotateTransitKey ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/vault/rotate-transit-key"
  BrokerVaultBaselineReconcile ->
    mutationSpec BrokerBaselineReconcile "/v1/bootstrap/vault/baseline/reconcile"
  BrokerVaultPkiStatus ->
    readOnlySpec
      BrokerGet
      BrokerPkiOperate
      BrokerBodyForbidden
      "/v1/bootstrap/vault/pki/status"
  BrokerVaultPkiIssueTestCertificate ->
    mutationSpec BrokerPkiOperate "/v1/bootstrap/vault/pki/issue-test-cert"
  BrokerVaultResetAmbiguousInitialization ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/vault/ambiguous-init/reset"
  BrokerChildCustodyCommit ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/child/custody/commit"
  BrokerChildRecoveryDeliver ->
    mutationSpec BrokerBootstrapMutate "/v1/bootstrap/child/recovery/deliver"
  BrokerChildRecoveryObserve ->
    readOnlySpec
      BrokerPost
      BrokerBootstrapObserve
      BrokerBodyRequired
      "/v1/bootstrap/child/recovery/status"

readOnlySpec
  :: BrokerHttpMethod
  -> BrokerOperationClass
  -> BrokerBodyRequirement
  -> String
  -> BrokerRouteSpec
readOnlySpec method operationClass bodyRequirement path =
  BrokerRouteSpec
    { specMethod = method
    , specOperationClass = operationClass
    , specMutationClass = BrokerReadOnly
    , specBodyRequirement = bodyRequirement
    , specPath = path
    }

mutationSpec :: BrokerOperationClass -> String -> BrokerRouteSpec
mutationSpec operationClass path =
  BrokerRouteSpec
    { specMethod = BrokerPost
    , specOperationClass = operationClass
    , specMutationClass = BrokerMutating
    , specBodyRequirement = BrokerBodyRequired
    , specPath = path
    }

brokerRouteMethod :: BrokerRoute -> BrokerHttpMethod
brokerRouteMethod = specMethod . brokerRouteSpec

brokerRouteOperationClass :: BrokerRoute -> BrokerOperationClass
brokerRouteOperationClass = specOperationClass . brokerRouteSpec

brokerRouteCapabilityOp :: BrokerRoute -> CapabilityOp
brokerRouteCapabilityOp = brokerOperationCapabilityOp . brokerRouteOperationClass

brokerRouteMutationClass :: BrokerRoute -> BrokerMutationClass
brokerRouteMutationClass = specMutationClass . brokerRouteSpec

brokerRouteIsMutation :: BrokerRoute -> Bool
brokerRouteIsMutation route = case brokerRouteMutationClass route of
  BrokerReadOnly -> False
  BrokerMutating -> True

brokerRouteBodyRequirement :: BrokerRoute -> BrokerBodyRequirement
brokerRouteBodyRequirement = specBodyRequirement . brokerRouteSpec

brokerRoutePath :: BrokerRoute -> String
brokerRoutePath = specPath . brokerRouteSpec

-- | Exact reverse lookup.  Only complete registered paths match.
brokerRouteForPath :: String -> Maybe BrokerRoute
brokerRouteForPath path = find ((== path) . brokerRoutePath) allBrokerRoutes

-- | Exact method-and-path reverse lookup used by the HTTP dispatcher.
brokerRouteForRequest :: BrokerHttpMethod -> String -> Maybe BrokerRoute
brokerRouteForRequest method path =
  find
    (\route -> brokerRouteMethod route == method && brokerRoutePath route == path)
    allBrokerRoutes
