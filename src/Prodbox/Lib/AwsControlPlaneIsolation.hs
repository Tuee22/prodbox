{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lib.AwsControlPlaneIsolation
  ( AwsControlPlaneRole (..)
  , AwsCapability (..)
  , AwsRoleTransport (..)
  , AwsTransportLocation (..)
  , AwsIsolationDefect (..)
  , AwsEksIamNames (..)
  , ControllerOwnerDescriptor (..)
  , ControllerOwnerState (..)
  , ControllerOwnerRefusal (..)
  , AwsFaultScenario (..)
  , AwsFaultDisposition (..)
  , canonicalAwsRoleTransports
  , roleCapabilities
  , validateAwsControlPlaneIsolation
  , mkAwsEksIamNames
  , registerControllerOwnerUid
  , enableControllerOwner
  , registerControllerChildArn
  , registerControllerChildArns
  , awsFaultDisposition
  )
where

import Codec.Serialise (Serialise)
import Data.Char (isAsciiLower, isDigit)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)

data AwsControlPlaneRole
  = AwsBootstrapBroker
  | AwsGatewayDiagnostics
  | AwsTargetSecretAgent
  | RetainedHomeAuthorityClient
  | AwsProviderWorker
  deriving (Eq, Ord, Show, Enum, Bounded)

data AwsCapability
  = BootstrapCustody
  | GatewayMeshDiagnostics
  | TargetMaterialization
  | LifecycleAuthorityOperation
  | RegisteredAwsProviderMutation
  deriving (Eq, Ord, Show)

data AwsRoleTransport = AwsRoleTransport
  { awsTransportRole :: AwsControlPlaneRole
  , awsTransportLocation :: AwsTransportLocation
  , awsTransportNamespace :: Text
  , awsTransportService :: Text
  , awsTransportPort :: Int
  }
  deriving (Eq, Ord, Show)

data AwsTransportLocation = AwsEksService | RetainedHomeService
  deriving (Eq, Ord, Show)

data AwsIsolationDefect
  = AwsRoleMissing AwsControlPlaneRole
  | AwsRoleDuplicated AwsControlPlaneRole
  | AwsServiceTransportShared Text
  | AwsGatewayAuthorityCapabilityPresent
  | AwsGatewayProviderCapabilityPresent
  | AwsAuthorityProjectedAsEksWorkload
  deriving (Eq, Show)

data AwsEksIamNames = AwsEksIamNames
  { awsEksClusterRoleName :: Text
  , awsEksNodeRoleName :: Text
  , awsEksLoadBalancerControllerRoleName :: Text
  }
  deriving (Eq, Show)

data ControllerOwnerDescriptor = ControllerOwnerDescriptor
  { controllerOwnerAccount :: Text
  , controllerOwnerRegion :: Text
  , controllerOwnerCluster :: Text
  , controllerOwnerResourceName :: Text
  , controllerOwnerManifestDigest :: Text
  , controllerOwnerTags :: [(Text, Text)]
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data ControllerOwnerState
  = ControllerOwnerRegisteredInert ControllerOwnerDescriptor
  | ControllerOwnerUidRegistered ControllerOwnerDescriptor Text
  | ControllerOwnerEnabled ControllerOwnerDescriptor Text
  | ControllerChildArnsRegistered ControllerOwnerDescriptor Text [Text]
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data ControllerOwnerRefusal
  = ControllerOwnerWrongPhase
  | ControllerOwnerEmptyUid
  | ControllerOwnerUidConflict
  | ControllerChildEmptyArn
  | ControllerChildArnDuplicated !Text
  deriving (Eq, Show)

data AwsFaultScenario
  = AwsGatewaySaturated
  | AwsGatewayLost
  | AwsTargetAgentRestarted
  | AwsAuthorityTransportInterrupted
  | AwsEksReplaced
  | AwsVaultDelayed
  | AwsMinioDelayed
  | AwsRunCancelled
  | AwsCleanupInterrupted
  deriving (Eq, Ord, Show, Enum, Bounded)

data AwsFaultDisposition = AwsFaultDisposition
  { perRunResourcesConvergeAbsent :: Bool
  , retainedSesRemainsPresent :: Bool
  , retainedAuthorityRemainsReadable :: Bool
  , gatewayMayAuthorizeLifecycle :: Bool
  }
  deriving (Eq, Show)

canonicalAwsRoleTransports :: [AwsRoleTransport]
canonicalAwsRoleTransports =
  [ AwsRoleTransport
      AwsBootstrapBroker
      AwsEksService
      "bootstrap-broker"
      "bootstrap-broker"
      controlPlaneListenPort
  , AwsRoleTransport AwsGatewayDiagnostics AwsEksService "gateway" "gateway-daemon" 8080
  , AwsRoleTransport AwsTargetSecretAgent AwsEksService "target-secret-agent" "target-secret-agent" 8704
  , AwsRoleTransport
      RetainedHomeAuthorityClient
      RetainedHomeService
      "lifecycle-authority"
      "lifecycle-authority"
      8701
  , AwsRoleTransport AwsProviderWorker AwsEksService "provider-worker" "provider-worker" 8702
  ]

roleCapabilities :: AwsControlPlaneRole -> [AwsCapability]
roleCapabilities role = case role of
  AwsBootstrapBroker -> [BootstrapCustody]
  AwsGatewayDiagnostics -> [GatewayMeshDiagnostics]
  AwsTargetSecretAgent -> [TargetMaterialization]
  RetainedHomeAuthorityClient -> [LifecycleAuthorityOperation]
  AwsProviderWorker -> [RegisteredAwsProviderMutation]

validateAwsControlPlaneIsolation
  :: [AwsRoleTransport]
  -> Either AwsIsolationDefect ()
validateAwsControlPlaneIsolation transports = do
  mapM_ validateRole [minBound .. maxBound]
  mapM_ validateLocation transports
  case duplicate (map awsTransportService transports) of
    Just service -> Left (AwsServiceTransportShared service)
    Nothing -> Right ()
  if LifecycleAuthorityOperation `elem` roleCapabilities AwsGatewayDiagnostics
    then Left AwsGatewayAuthorityCapabilityPresent
    else Right ()
  if RegisteredAwsProviderMutation `elem` roleCapabilities AwsGatewayDiagnostics
    then Left AwsGatewayProviderCapabilityPresent
    else Right ()
 where
  validateRole role = case length (filter ((== role) . awsTransportRole) transports) of
    0 -> Left (AwsRoleMissing role)
    1 -> Right ()
    _ -> Left (AwsRoleDuplicated role)
  validateLocation transport = case (awsTransportRole transport, awsTransportLocation transport) of
    (RetainedHomeAuthorityClient, RetainedHomeService) -> Right ()
    (RetainedHomeAuthorityClient, AwsEksService) -> Left AwsAuthorityProjectedAsEksWorkload
    (_, AwsEksService) -> Right ()
    (role, RetainedHomeService) -> Left (AwsRoleMissing role)

mkAwsEksIamNames :: Text -> Text -> Either Text AwsEksIamNames
mkAwsEksIamNames runId clusterId = do
  run <- validateSegment "run" runId
  cluster <- validateSegment "cluster" clusterId
  let prefix = "prodbox-" <> run <> "-" <> cluster
  Right
    AwsEksIamNames
      { awsEksClusterRoleName = prefix <> "-cluster-role"
      , awsEksNodeRoleName = prefix <> "-node-role"
      , awsEksLoadBalancerControllerRoleName = prefix <> "-lbc-role"
      }

registerControllerOwnerUid
  :: Text
  -> ControllerOwnerState
  -> Either ControllerOwnerRefusal ControllerOwnerState
registerControllerOwnerUid uid state
  | Text.null (Text.strip uid) = Left ControllerOwnerEmptyUid
  | otherwise = case state of
      ControllerOwnerRegisteredInert descriptor ->
        Right (ControllerOwnerUidRegistered descriptor uid)
      ControllerOwnerUidRegistered descriptor observed
        | observed == uid -> Right (ControllerOwnerUidRegistered descriptor observed)
        | otherwise -> Left ControllerOwnerUidConflict
      ControllerOwnerEnabled _ _ -> Left ControllerOwnerWrongPhase
      ControllerChildArnsRegistered {} -> Left ControllerOwnerWrongPhase

enableControllerOwner
  :: ControllerOwnerState
  -> Either ControllerOwnerRefusal ControllerOwnerState
enableControllerOwner state = case state of
  ControllerOwnerUidRegistered descriptor uid -> Right (ControllerOwnerEnabled descriptor uid)
  ControllerOwnerEnabled descriptor uid -> Right (ControllerOwnerEnabled descriptor uid)
  ControllerChildArnsRegistered {} -> Left ControllerOwnerWrongPhase
  _ -> Left ControllerOwnerWrongPhase

registerControllerChildArn
  :: Text
  -> ControllerOwnerState
  -> Either ControllerOwnerRefusal ControllerOwnerState
registerControllerChildArn arn = registerControllerChildArns [arn]

-- | CAS-enrich the controller owner with every exact child ARN observed so
-- far.  A controller owns a family (load balancer, listeners, target groups,
-- and security groups), not one resource.  Enrichment is monotone and
-- idempotent: a retry may repeat an ARN, while a duplicate inside one provider
-- observation is rejected because it is not a normalized family.
registerControllerChildArns
  :: [Text]
  -> ControllerOwnerState
  -> Either ControllerOwnerRefusal ControllerOwnerState
registerControllerChildArns rawArns state = do
  validatedArns <- traverse validateArn rawArns
  let arns = sort validatedArns
  case firstDuplicate validatedArns of
    Just duplicateArn -> Left (ControllerChildArnDuplicated duplicateArn)
    Nothing -> case state of
      ControllerOwnerEnabled descriptor uid ->
        Right (ControllerChildArnsRegistered descriptor uid arns)
      ControllerChildArnsRegistered descriptor uid observed ->
        Right
          ( ControllerChildArnsRegistered
              descriptor
              uid
              (observed ++ filter (`notElem` observed) arns)
          )
      _ -> Left ControllerOwnerWrongPhase
 where
  validateArn raw
    | Text.null value = Left ControllerChildEmptyArn
    | otherwise = Right value
   where
    value = Text.strip raw

  firstDuplicate values = go [] values
   where
    go _ [] = Nothing
    go seen (value : remaining)
      | value `elem` seen = Just value
      | otherwise = go (value : seen) remaining

awsFaultDisposition :: AwsFaultScenario -> AwsFaultDisposition
awsFaultDisposition _ =
  AwsFaultDisposition
    { perRunResourcesConvergeAbsent = True
    , retainedSesRemainsPresent = True
    , retainedAuthorityRemainsReadable = True
    , gatewayMayAuthorizeLifecycle = False
    }

validateSegment :: Text -> Text -> Either Text Text
validateSegment label raw
  | Text.null value = Left (label <> " id must not be empty")
  | Text.length value > 24 = Left (label <> " id exceeds 24 characters")
  | Text.head value == '-' || Text.last value == '-' =
      Left (label <> " id must not start or end with '-'")
  | Text.all validCharacter value = Right value
  | otherwise = Left (label <> " id must contain only lowercase DNS-label characters")
 where
  value = Text.strip raw
  validCharacter character = isAsciiLower character || isDigit character || character == '-'

duplicate :: (Ord value) => [value] -> Maybe value
duplicate values = go [] values
 where
  go _ [] = Nothing
  go seen (value : remaining)
    | value `elem` seen = Just value
    | otherwise = go (value : seen) remaining
