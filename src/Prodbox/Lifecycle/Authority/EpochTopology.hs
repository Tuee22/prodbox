{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Non-secret identities of the complete prepared cutover topology. The
-- inventory is an expected projection, not evidence that a backend changed.
-- Physical adapters must independently read the named binding back.
module Prodbox.Lifecycle.Authority.EpochTopology
  ( CutoverDigest
  , mkCutoverDigest
  , cutoverDigestText
  , CutoverSubstrate (..)
  , CutoverCapability (..)
  , CutoverBackend (..)
  , EpochTopologyBinding (..)
  , EpochTopology
  , EpochTopologyError (..)
  , mkEpochTopology
  , validateEpochTopology
  , epochTopologyDigest
  , epochTopologyBindings
  , epochTopologyBindingDigest
  , epochTopologyOldWriterBindings
  , requiredEpochTopologyBindings
  , validEpochTopologyBinding
  )
where

import Codec.Serialise (Serialise, serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)

newtype CutoverDigest = CutoverDigest Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkCutoverDigest :: Text -> Maybe CutoverDigest
mkCutoverDigest value
  | Text.length value == 64 && Text.all isLowerHex value = Just (CutoverDigest value)
  | otherwise = Nothing
 where
  isLowerHex c = c >= '0' && c <= '9' || c >= 'a' && c <= 'f'

cutoverDigestText :: CutoverDigest -> Text
cutoverDigestText (CutoverDigest value) = value

data CutoverSubstrate = CutoverHome | CutoverAws
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data CutoverCapability
  = CutoverProviderWorker
  | CutoverAuthorityBackup
  | CutoverTlsRetention
  | CutoverCredentialProvisioner
  | CutoverAdminActionRunner
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data CutoverBackend
  = CutoverProviderBackend
  | CutoverAuthorityBackupStore
  | CutoverTlsRetentionStore
  | CutoverGatewayDns
  | CutoverCertManager !CutoverSubstrate
  | CutoverAuthorityPrimaryStore
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | A binding digest covers the canonical non-secret metadata of the named
-- role: identity, coordinates, generation and, for a capability, its service,
-- ServiceAccount and policy. TLS and DNS keys name exact canonical scope and
-- coordinate digests; they never hash private keys or credential bytes.
data EpochTopologyBinding
  = AgentControllerBinding !CutoverSubstrate
  | AgentOneShotWorkerBinding !CutoverSubstrate
  | PendingAcceptedAuthorityBinding !CutoverSubstrate
  | HomeTlsEnvelopeLaneBinding
  | InForceConfigReferenceBinding
  | CapabilityServiceBinding !CutoverCapability
  | BackendCredentialGenerationBinding !CutoverBackend
  | BackendIssuerBinding !CutoverBackend
  | CommittedTlsCurrentBinding !CutoverSubstrate !CutoverDigest
  | ManagedDnsCoordinateBinding !CutoverSubstrate !CutoverDigest
  | AuthorityControllerBinding
  | RetainedAuthenticationEpochBinding
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data EpochTopology = EpochTopology
  { topologySubstrates :: !(Set CutoverSubstrate)
  , topologyTlsScopes :: !(Set (CutoverSubstrate, CutoverDigest))
  , topologyDnsCoordinates :: !(Set (CutoverSubstrate, CutoverDigest))
  , topologyBindingDigests :: !(Map EpochTopologyBinding CutoverDigest)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochTopologyError
  = EpochTopologyHomeMissing
  | EpochTopologyUndeclaredSubstrate
  | EpochTopologyInvalidDigest
  | EpochTopologyTooLarge
  | EpochTopologyBindingsDiffer
      !(Set EpochTopologyBinding)
      !(Set EpochTopologyBinding)
  deriving stock (Eq, Show)

-- | The caller derives the scope from retained Authority/config facts and
-- supplies independently observed canonical metadata for every required row.
-- Both declarations and rows are retained, so decoding cannot silently shrink
-- the declared scope to the rows that happened to be readable.
mkEpochTopology
  :: Set CutoverSubstrate
  -> Set (CutoverSubstrate, CutoverDigest)
  -> Set (CutoverSubstrate, CutoverDigest)
  -> Map EpochTopologyBinding CutoverDigest
  -> Either EpochTopologyError EpochTopology
mkEpochTopology substrates tls dns bindings = do
  let topology = EpochTopology substrates tls dns bindings
  validateEpochTopology topology
  pure topology

validateEpochTopology :: EpochTopology -> Either EpochTopologyError ()
validateEpochTopology topology
  | CutoverHome `Set.notMember` substrates = Left EpochTopologyHomeMissing
  | not (all (`Set.member` substrates) scopeSubstrates) = Left EpochTopologyUndeclaredSubstrate
  | not (all validDigest digests) = Left EpochTopologyInvalidDigest
  | Set.size required > 256 || Map.size bindings > 256 = Left EpochTopologyTooLarge
  | actual /= required =
      Left
        ( EpochTopologyBindingsDiffer
            (required `Set.difference` actual)
            (actual `Set.difference` required)
        )
  | otherwise = Right ()
 where
  substrates = topologySubstrates topology
  bindings = topologyBindingDigests topology
  scopes = Set.toList (topologyTlsScopes topology) ++ Set.toList (topologyDnsCoordinates topology)
  scopeSubstrates = map fst scopes
  digests = map snd scopes ++ Map.elems bindings ++ concatMap bindingKeyDigests (Map.keys bindings)
  validDigest digest = mkCutoverDigest (cutoverDigestText digest) == Just digest
  actual = Map.keysSet bindings
  required =
    requiredEpochTopologyBindings
      substrates
      (topologyTlsScopes topology)
      (topologyDnsCoordinates topology)

requiredEpochTopologyBindings
  :: Set CutoverSubstrate
  -> Set (CutoverSubstrate, CutoverDigest)
  -> Set (CutoverSubstrate, CutoverDigest)
  -> Set EpochTopologyBinding
requiredEpochTopologyBindings substrates tls dns =
  Set.fromList
    ( [ HomeTlsEnvelopeLaneBinding
      , InForceConfigReferenceBinding
      , AuthorityControllerBinding
      , RetainedAuthenticationEpochBinding
      ]
        ++ [CapabilityServiceBinding capability | capability <- [minBound .. maxBound]]
        ++ concatMap agentBindings (Set.toList substrates)
        ++ concatMap backendBindings backends
        ++ [CommittedTlsCurrentBinding substrate scope | (substrate, scope) <- Set.toList tls]
        ++ [ManagedDnsCoordinateBinding substrate coordinate | (substrate, coordinate) <- Set.toList dns]
    )
 where
  agentBindings substrate =
    [ AgentControllerBinding substrate
    , AgentOneShotWorkerBinding substrate
    , PendingAcceptedAuthorityBinding substrate
    ]
  backends =
    [ CutoverProviderBackend
    , CutoverAuthorityBackupStore
    , CutoverTlsRetentionStore
    , CutoverGatewayDns
    , CutoverAuthorityPrimaryStore
    ]
      ++ map CutoverCertManager (Set.toList substrates)
  backendBindings backend = [BackendCredentialGenerationBinding backend, BackendIssuerBinding backend]

epochTopologyBindings :: EpochTopology -> Set EpochTopologyBinding
epochTopologyBindings = Map.keysSet . topologyBindingDigests

epochTopologyBindingDigest :: EpochTopology -> EpochTopologyBinding -> Maybe CutoverDigest
epochTopologyBindingDigest topology binding = Map.lookup binding (topologyBindingDigests topology)

epochTopologyOldWriterBindings :: EpochTopology -> Set EpochTopologyBinding
epochTopologyOldWriterBindings = Set.filter isOldWriter . epochTopologyBindings
 where
  isOldWriter binding = case binding of
    PendingAcceptedAuthorityBinding _ -> True
    HomeTlsEnvelopeLaneBinding -> True
    BackendCredentialGenerationBinding _ -> True
    BackendIssuerBinding _ -> True
    AgentControllerBinding _ -> False
    AgentOneShotWorkerBinding _ -> False
    InForceConfigReferenceBinding -> False
    CapabilityServiceBinding _ -> False
    CommittedTlsCurrentBinding _ _ -> False
    ManagedDnsCoordinateBinding _ _ -> False
    AuthorityControllerBinding -> False
    RetainedAuthenticationEpochBinding -> True

epochTopologyDigest :: EpochTopology -> CutoverDigest
epochTopologyDigest topology =
  CutoverDigest
    ( Text.pack
        ( concatMap
            hexByte
            (ByteString.unpack (SHA256.hash (LazyByteString.toStrict (serialise (1 :: Word, topology)))))
        )
    )
 where
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

bindingKeyDigests :: EpochTopologyBinding -> [CutoverDigest]
bindingKeyDigests binding = case binding of
  CommittedTlsCurrentBinding _ digest -> [digest]
  ManagedDnsCoordinateBinding _ digest -> [digest]
  AgentControllerBinding _ -> []
  AgentOneShotWorkerBinding _ -> []
  PendingAcceptedAuthorityBinding _ -> []
  HomeTlsEnvelopeLaneBinding -> []
  InForceConfigReferenceBinding -> []
  CapabilityServiceBinding _ -> []
  BackendCredentialGenerationBinding _ -> []
  BackendIssuerBinding _ -> []
  AuthorityControllerBinding -> []
  RetainedAuthenticationEpochBinding -> []

validEpochTopologyBinding :: EpochTopologyBinding -> Bool
validEpochTopologyBinding = all validDigest . bindingKeyDigests
 where
  validDigest digest = mkCutoverDigest (cutoverDigestText digest) == Just digest
