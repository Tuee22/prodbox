{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- | Sprint 1.39: __Tier 0__ — the binary-owned, project-local non-secret
-- config surface. A single @prodbox.dhall@ carrying a
-- @{ parameters, context, witness }@ record shaped to align with
-- @hostbootstrap@'s binary-context contract, so the eventual refactor onto
-- @hostbootstrap@ is a clean extension rather than a rewrite
-- (config_doctrine.md §0).
--
-- This module folds two prior surfaces into one typed record:
--
--   * the former @.data\/prodbox\/unencrypted-basics.json@ fields (Sprint
--     1.38: cluster id, this cluster's Vault address, seal mode, optional
--     parent reference) become the 'ProdboxContext' (topology + capabilities);
--   * the non-secret sections of the seed\/propose @prodbox-config.dhall@
--     (route53, aws_substrate, ses, domain, acme.{email,server}, deployment,
--     capacity, cluster_topology, storage, pulumi_state_backend, plus the
--     operational @aws.*@ / @acme.eab_*@ 'SecretRef.Vault' __pointers__) become the
--     'ProdboxParameters'.
--
-- It carries __only non-secret data__. Secrets are 'SecretRef.Vault' pointers
-- (non-secret coordinates), never inline secret values — asserted by
-- 'tier0CarriesNoSecretValues' and the Sprint 1.39 unit test
-- (config_doctrine.md §10).
--
-- The dependency-free sealed-Vault bootstrap floor is __projected__ from this
-- record's @context@ by the pure 'projectBasics'; that same projection is read
-- straight off @prodbox.dhall@ by
-- 'Prodbox.Config.FloorDhall.loadUnencryptedBasics' before Vault is reachable
-- (config_doctrine.md §1a). Sprint 7.18: there is no separate derived
-- @prodbox-basics.json@ artifact — @prodbox.dhall@ is the sole floor source.
module Prodbox.Config.Tier0
  ( -- * The Tier-0 binary-context record
    ProdboxProjectConfig (..)
  , ProdboxContext (..)
  , ProdboxTopology (..)
  , ProdboxParameters (..)
  , ContextKind (..)
  , Capability (..)
  , Tier0SealMode (..)
  , Tier0ParentRef (..)

    -- * Defaults
  , defaultProjectConfig
  , defaultProdboxContext
  , defaultProdboxParameters
  , configFileToTier0Parameters
  , writeOperatorParametersToTier0
  , writeOperatorDeploymentConfigToTier0
  , writeTier0FloorPreservingParameters

    -- * In-cluster daemon binary context (Sprint 1.40)
  , defaultDaemonProjectConfig
  , defaultDaemonContext
  , Tier0Source (..)
  , daemonConfigMapTier0Path
  , decodeProjectConfigDhall
  , loadDaemonBinaryContext

    -- * Schema-from-Haskell render (pure)
  , renderProjectConfigDhall
  , tier0RecordWitness
  , tier0WitnessPrefix
  , stampTier0Witness
  , renderProdboxContextDhall

    -- * Floor projection (pure)
  , projectBasics

    -- * Secret-free guard (pure)
  , tier0CarriesNoSecretValues
  , tier0SecretValueFields

    -- * Write side (IO)
  , writeTier0
  , writeTier0AtPath

    -- * Idempotent host-level basics floor (Sprint 1.39 self-heal)
  , ensureBasicsFloor
  , ensureBasicsFloorAtPath
  , ensureChildBasicsFloor
  , ensureChildBasicsFloorAtPath
  )
where

import Control.Exception (SomeException, displayException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Void (Void)
import Dhall
  ( FromDhall (..)
  , ToDhall (..)
  )
import Dhall qualified
import Dhall.Core (Expr)
import Dhall.Core qualified as Core
import Dhall.Src (Src)
import GHC.Generics (Generic)
import Numeric (showHex)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Capacity.Allocation (compileResourcePlanUncertified)
import Prodbox.Capacity.Config (ResourceVector, resource_plan)
import Prodbox.Capacity.Placement (concurrentPlanDraws)
import Prodbox.Config.Basics
  ( ParentRef (..)
  , SealMode (..)
  , UnencryptedBasics (..)
  )
import Prodbox.Config.ComponentGraph (ComponentNode)
import Prodbox.Config.FloorDhall (loadUnencryptedBasicsAtPath)
import Prodbox.Config.RetainedArtifacts (RetainedArtifactsSection)
import Prodbox.Repo
  ( resolveTier0ConfigPath
  )
import Prodbox.Settings
  ( AcmeSection
  , AwsCredentialsRef (..)
  , AwsSubstrateSection
  , CapacitySection
  , ClusterTopology
  , DeploymentSection
  , DomainSection
  , PulumiStateBackendSection
  , Route53Section
  , SesSection
  , StorageSection
  )
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef (SecretRef (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

-- | The kind of binary frame this context describes — mirrors
-- @hostbootstrap@'s @contextKind@ discriminator. The host CLI is a
-- 'HostOrchestrator'; the in-cluster gateway runs as a 'Daemon'; ordinary
-- workload Pods are 'ClusterService'. 'OtherContext' keeps the union open for
-- additional frames a later @hostbootstrap@ refactor introduces without a
-- breaking schema change.
data ContextKind
  = HostOrchestrator
  | Daemon
  | ClusterService
  | OtherContext
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A non-secret capability the binary frame is allowed to exercise. The
-- @DurableStore@ capability marks a frame that may reach the shared
-- Vault-Transit-enveloped MinIO object store (Tier 2); other capabilities name
-- the non-secret seams a frame uses. This is intentionally an open ADT (not a
-- bag of strings) so the capability set is exhaustively matched.
data Capability
  = DurableStore
  | VaultAuth
  | PublicEdge
  | OtherCapability
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The Tier-0 projection of how this cluster's Vault unseals. Mirrors
-- 'Prodbox.Config.Basics.SealMode' but is Dhall-encodable (the Basics type is
-- JSON-only). The two are bridged by 'projectBasics'.
data Tier0SealMode
  = Tier0Shamir
  | Tier0Transit
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The Tier-0 projection of a child cluster's parent reference. Carries no
-- credentials — only the parent's identity, Vault address, and the Transit key
-- name the child's seal is bound to (mirrors 'Prodbox.Config.Basics.ParentRef').
data Tier0ParentRef = Tier0ParentRef
  { parent_cluster_id :: Text
  , parent_vault_address :: Text
  , parent_transit_key :: Text
  , parent_authority_endpoint :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The cluster topology projected from the former unencrypted basics: the seal
-- mode and (for a child) the parent reference it auto-unseals against. This is
-- the non-secret coordinate set a host reads before Vault is reachable.
data ProdboxTopology = ProdboxTopology
  { seal_mode :: Tier0SealMode
  , parent_ref :: Maybe Tier0ParentRef
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The binary context — @hostbootstrap@'s @BinaryContext@ shape. It names the
-- project\/binary, the frame kind, the cluster identity + Vault address (the
-- bootstrap floor coordinates), the durable object-store endpoint\/bucket, the
-- seal topology, and the capability set. None of these are secret.
data ProdboxContext = ProdboxContext
  { project :: Text
  , binary :: Text
  , context_kind :: ContextKind
  , cluster_id :: Text
  , vault_address :: Text
  , minio_endpoint :: Text
  , topology :: ProdboxTopology
  , capabilities :: [Capability]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The non-secret parameters — the former non-secret sections of
-- @prodbox-config.dhall@. The @aws@ and @acme.eab_*@ fields are
-- 'SecretRef.Vault' __pointers__ only; no secret value is carried here.
data ProdboxParameters = ProdboxParameters
  { aws :: AwsCredentialsRef
  , route53 :: Route53Section
  , aws_substrate :: AwsSubstrateSection
  , ses :: SesSection
  , domain :: DomainSection
  , acme :: AcmeSection
  , deployment :: DeploymentSection
  , capacity :: CapacitySection
  , cluster_topology :: ClusterTopology
  , storage :: StorageSection
  , pulumi_state_backend :: PulumiStateBackendSection
  , retained_artifacts :: RetainedArtifactsSection
  , components :: [ComponentNode]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The Tier-0 binary-context record: @{ parameters, context, witness }@.
-- @witness@ is an open list of non-secret attestation strings; it starts empty
-- and exists so a later @hostbootstrap@ refactor can attach witnesses without a
-- schema break.
data ProdboxProjectConfig = ProdboxProjectConfig
  { parameters :: ProdboxParameters
  , context :: ProdboxContext
  , witness :: [Text]
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The format version stamped into the derived 'UnencryptedBasics' floor. The
-- floor schema is owned by "Prodbox.Config.Basics" (Sprint 1.38); Tier 0
-- projects onto it.
basicsFormatVersionV1 :: Int
basicsFormatVersionV1 = 1

-- | The host CLI's unauthored binary context. Capability shape is compiled;
-- deployment identity and endpoints stay empty until @config setup@ authors
-- them.
defaultProdboxContext :: ProdboxContext
defaultProdboxContext =
  ProdboxContext
    { project = "prodbox"
    , binary = "prodbox"
    , context_kind = HostOrchestrator
    , cluster_id = ""
    , vault_address = ""
    , minio_endpoint = ""
    , topology =
        ProdboxTopology
          { seal_mode = Tier0Shamir
          , parent_ref = Nothing
          }
    , capabilities = [DurableStore, VaultAuth]
    }

-- | The default Tier-0 parameters reuse the non-secret sections of
-- 'defaultConfigFile' (the existing typed source of truth for those defaults),
-- so the two surfaces cannot drift.
defaultProdboxParameters :: ProdboxParameters
defaultProdboxParameters =
  ProdboxParameters
    { aws = Settings.aws base
    , route53 = Settings.route53 base
    , aws_substrate = Settings.aws_substrate base
    , ses = Settings.ses base
    , domain = Settings.domain base
    , acme = Settings.acme base
    , deployment = Settings.deployment base
    , capacity = Settings.capacity base
    , cluster_topology = Settings.cluster_topology base
    , storage = Settings.storage base
    , pulumi_state_backend = Settings.pulumi_state_backend base
    , retained_artifacts = Settings.retained_artifacts base
    , components = Settings.components base
    }
 where
  base = Settings.defaultConfigFile

-- | Sprint 1.42 Part B: project a 'Settings.ConfigFile' (the legacy
-- @prodbox-config.dhall@ payload) onto the Tier-0 'ProdboxParameters'. The two
-- records are field-for-field identical (same ten non-secret sections, same
-- 'SecretRef.Vault'-pointer shape), so this is a total rename. Used by the
-- authoring surface (@config setup@ / @aws setup@) to write the operator's
-- non-secret config into @prodbox.dhall@'s @parameters@ block instead of the
-- retired standalone file.
configFileToTier0Parameters :: Settings.ConfigFile -> ProdboxParameters
configFileToTier0Parameters cf =
  ProdboxParameters
    { aws = Settings.aws cf
    , route53 = Settings.route53 cf
    , aws_substrate = Settings.aws_substrate cf
    , ses = Settings.ses cf
    , domain = Settings.domain cf
    , acme = Settings.acme cf
    , deployment = Settings.deployment cf
    , capacity = Settings.capacity cf
    , cluster_topology = Settings.cluster_topology cf
    , storage = Settings.storage cf
    , pulumi_state_backend = Settings.pulumi_state_backend cf
    , retained_artifacts = Settings.retained_artifacts cf
    , components = Settings.components cf
    }

-- | The default Tier-0 binary-context record.
defaultProjectConfig :: ProdboxProjectConfig
defaultProjectConfig =
  ProdboxProjectConfig
    { parameters = defaultProdboxParameters
    , context = defaultProdboxContext
    , witness = []
    }

-- | Sprint 1.42 Part B: write the operator's non-secret config into the Tier-0
-- @prodbox.dhall@'s @parameters@ block, PRESERVING the established @context@ and
-- @witness@. Reads the current @prodbox.dhall@ when present (so a @config setup@
-- re-author never clobbers the cluster's binary context — cluster id, Vault
-- address, seal mode, parent ref); falls back to 'defaultProjectConfig' before
-- first establishment. This is the authoring counterpart to 'loadConfigFile'
-- reading @parameters@, and the replacement for the retired
-- @prodbox-config.dhall@ writer.
writeOperatorParametersToTier0 :: FilePath -> Settings.ConfigFile -> IO (Either String ())
writeOperatorParametersToTier0 repoRoot config = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  existing <- decodeProjectConfigDhall tier0Path
  let base = either (const defaultProjectConfig) id existing
      merged = base {parameters = configFileToTier0Parameters config}
  writeTier0 repoRoot merged

-- | Author parameters and deployment-varying context in one Tier-0 write.
-- Used by interactive @config setup@ so validation never observes freshly
-- authored parameters beside compiled or stale context coordinates.
writeOperatorDeploymentConfigToTier0
  :: FilePath
  -> Settings.ConfigFile
  -> Settings.DeploymentContextInput
  -> IO (Either String ())
writeOperatorDeploymentConfigToTier0 repoRoot config contextInput = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  existing <- decodeProjectConfigDhall tier0Path
  let base = either (const defaultProjectConfig) id existing
      currentContext = context base
      authoredContext =
        currentContext
          { cluster_id = Settings.contextInputClusterId contextInput
          , vault_address = Settings.contextInputVaultAddress contextInput
          , minio_endpoint = Settings.contextInputMinioEndpoint contextInput
          }
      merged =
        base
          { parameters = configFileToTier0Parameters config
          , context = authoredContext
          }
  writeTier0 repoRoot merged

-- | Sprint 1.42 Part B / Sprint 7.25: establish the Tier-0 floor at first-ever
-- bring-up (@vault init@) by stamping the cluster identity (cluster id + Vault
-- address) into the @context@ of the EXISTING @prodbox.dhall@, PRESERVING its
-- operator-authored @parameters@/@witness@. There is **no fallback default**:
-- if @prodbox.dhall@ is absent or unreadable this FAILS fast rather than
-- synthesizing a default config — the file must already exist, authored by
-- @prodbox config setup@ (operator) or the test harness. The reconcile preflight
-- ([Settings.loadConfigFile]) already gates on it, so by @vault init@ it is
-- present; a standalone @vault init@ with no config now errors clearly instead of
-- silently inventing one.
writeTier0FloorPreservingParameters :: FilePath -> Text -> Text -> IO (Either String ())
writeTier0FloorPreservingParameters repoRoot clusterId vaultAddress = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  existing <- decodeProjectConfigDhall tier0Path
  case existing of
    Left err ->
      pure
        ( Left
            ( "cannot stamp the Tier-0 cluster identity: `prodbox.dhall` is required but absent or "
                ++ "unreadable ("
                ++ err
                ++ "). Generate it with `prodbox config setup` (or the test harness) first — the "
                ++ "binary does not synthesize a default config."
            )
        )
    Right base -> do
      let projectConfig =
            base
              { context =
                  (context base)
                    { cluster_id = clusterId
                    , vault_address = vaultAddress
                    }
              }
      writeTier0 repoRoot projectConfig

-- | The unauthored in-cluster gateway rendering template: the 'Daemon'-frame
-- variant of 'defaultProdboxContext'. It supplies only capability shape.
-- Deployment identity and endpoints remain empty until chart/config rendering
-- projects an authored context; this value is never a missing-file fallback.
defaultDaemonContext :: ProdboxContext
defaultDaemonContext =
  defaultProdboxContext
    { binary = "gateway"
    , context_kind = Daemon
    }

-- | The Tier-0 gateway rendering template (config_doctrine.md §0, §3). It
-- reuses the shared non-secret 'defaultProdboxParameters' and the unauthored
-- 'defaultDaemonContext'. A rendered file must exist at one of the explicit
-- paths accepted by 'loadDaemonBinaryContext'; absence refuses.
defaultDaemonProjectConfig :: ProdboxProjectConfig
defaultDaemonProjectConfig =
  defaultProjectConfig
    { context = defaultDaemonContext
    }

-- | Where the daemon's Tier-0 binary context comes from on a given start — the
-- provenance the daemon logs. The ConfigMap mount OVERWRITES the container
-- file; no compiled deployment identity exists when neither file is present.
data Tier0Source
  = -- | Decoded from the @gateway-config-<nodeId>@ ConfigMap-mounted
    -- @prodbox.dhall@ (the overwrite path).
    Tier0FromConfigMap FilePath
  | -- | Decoded from the baked-in container default @prodbox.dhall@.
    Tier0FromContainerDefault FilePath
  deriving (Eq, Show)

-- | The Tier-0 @prodbox.dhall@ path inside the existing @gateway-config-<nodeId>@
-- ConfigMap directory mount (@/etc/gateway/config@). When present this OVERWRITES
-- the container default. It is a sibling of the daemon's runtime
-- @config.dhall@ in the same directory mount, so the kubelet's atomic @..data@
-- symlink swap that already fires the daemon's fsnotify reload covers it too
-- (config_doctrine.md §6, §7).
daemonConfigMapTier0Path :: FilePath -> FilePath
daemonConfigMapTier0Path configDir = configDir <> "/prodbox.dhall"

-- | Decode a Tier-0 @prodbox.dhall@ file to a 'ProdboxProjectConfig', wrapping
-- any decode failure as a @Left String@ rather than an exception (mirrors the
-- daemon's other Dhall loaders). No SecretRef resolution happens here.
--
-- Sprint 1.82: \"the Tier-0 record carries no secret values\" used to be an
-- assertion in this Haddock with nothing behind it on this path.
-- 'tier0CarriesNoSecretValues' existed, was exported, was documented as the
-- guard that rejects a record carrying a literal credential — and had zero
-- production call sites, so it guarded nothing. It is now the last step of the
-- one Tier-0 decode gate, which is where the sentence above becomes true.
--
-- The bound is worth stating rather than implying. The operational @aws.*@ arm
-- was already refused on the CLI path by
-- 'Prodbox.Settings.validateAwsCredentialsRef', but that runs over the decoded
-- @parameters@ in 'Prodbox.Settings.validateConfig' and never over this record,
-- so the in-cluster daemon binary context ('loadDaemonBinaryContext') and the
-- Sprint 0.24 drift gate both reached a full Tier-0 record with no such check at
-- all — and @acme.eab_*@ had no local-tier check on any path.
decodeProjectConfigDhall :: FilePath -> IO (Either String ProdboxProjectConfig)
decodeProjectConfigDhall path = do
  result <- try (Dhall.inputFile Dhall.auto path) :: IO (Either SomeException ProdboxProjectConfig)
  pure $ case result of
    Left err ->
      Left
        ( "failed to decode Tier-0 prodbox.dhall binary context `"
            ++ path
            ++ "`: "
            ++ displayException err
        )
    Right config -> case tier0SecretValueFields config of
      [] -> Right config
      fields -> Left (tier0SecretValueRefusal path fields)

-- | The decode refusal for a Tier-0 record carrying a literal secret value.
--
-- It names the offending fields and never the values: the whole reason this
-- refusal exists is that those bytes must not travel, and a diagnostic that
-- quoted them would put a credential into every log that captured the failure
-- (config_doctrine.md §10, vault_doctrine.md §20).
tier0SecretValueRefusal :: FilePath -> [Text] -> String
tier0SecretValueRefusal path fields =
  "Tier-0 prodbox.dhall `"
    ++ path
    ++ "` carries literal secret values in "
    ++ Text.unpack (Text.intercalate ", " fields)
    ++ ". Tier-0 is non-secret: every sensitive field must be a "
    ++ "SecretRef.Vault pointer. Regenerate it with `prodbox config generate`."

-- | Load the gateway daemon's Tier-0 binary context using hostbootstrap's
-- per-frame context-init pattern (Sprint 1.40, config_doctrine.md §0):
--
--   1. If the @gateway-config-<nodeId>@ ConfigMap supplies a @prodbox.dhall@
--      sibling next to the runtime @config.dhall@, decode it — the ConfigMap
--      OVERWRITES the container default.
--   2. Otherwise decode the baked-in container-default @prodbox.dhall@.
--   3. If neither file is present, refuse and name the authoring remedy. An
--      unauthored template is not a deployment context.
--
-- The returned 'Tier0Source' is the provenance the daemon logs. This decode
-- carries NO secrets — the parameters' sensitive fields are 'SecretRef.Vault'
-- pointers resolved later through the daemon's Vault Kubernetes-auth identity,
-- never here.
loadDaemonBinaryContext
  :: FilePath
  -- ^ The @gateway-config-<nodeId>@ ConfigMap directory mount
  -- (e.g. @/etc/gateway/config@).
  -> FilePath
  -- ^ The non-ConfigMap container-default @prodbox.dhall@ path — the
  -- binary-sibling config the image generates at build (`prodbox config
  -- generate`), resolved via 'Prodbox.Repo.resolveTier0ConfigPath' (Sprint 1.49).
  -> IO (Either String (Tier0Source, ProdboxProjectConfig))
loadDaemonBinaryContext configMapDir containerDefaultPath = do
  let configMapPath = daemonConfigMapTier0Path configMapDir
  configMapPresent <- doesFileExist configMapPath
  if configMapPresent
    then decodeFrom (Tier0FromConfigMap configMapPath) configMapPath
    else do
      containerDefaultPresent <- doesFileExist containerDefaultPath
      if containerDefaultPresent
        then decodeFrom (Tier0FromContainerDefault containerDefaultPath) containerDefaultPath
        else
          pure
            ( Left
                ( "gateway Tier-0 deployment context is missing: neither `"
                    ++ configMapPath
                    ++ "` nor `"
                    ++ containerDefaultPath
                    ++ "` exists. Author deployment configuration with `prodbox config setup` "
                    ++ "and reconcile the gateway ConfigMap."
                )
            )
 where
  decodeFrom source path = do
    decoded <- decodeProjectConfigDhall path
    pure (fmap (source,) decoded)

-- | Project the dependency-free sealed-Vault bootstrap floor from a Tier-0
-- record. This is a __pure__ function of the Tier-0 context (the parameters and
-- witness never reach the floor). It mirrors
-- 'Prodbox.Config.FloorDhall.projectFloorContext', which performs the same
-- projection on the floor sub-record decoded straight off @prodbox.dhall@; the
-- Sprint 1.39 @writeTier0@ round-trip test pins the two against each other.
projectBasics :: ProdboxProjectConfig -> UnencryptedBasics
projectBasics config =
  UnencryptedBasics
    { basicsClusterId = cluster_id ctx
    , basicsVaultAddress = vault_address ctx
    , basicsSealMode = toBasicsSealMode (seal_mode topo)
    , basicsParentRef = fmap toBasicsParentRef (parent_ref topo)
    , basicsFormatVersion = basicsFormatVersionV1
    }
 where
  ctx = context config
  topo = topology ctx

toBasicsSealMode :: Tier0SealMode -> SealMode
toBasicsSealMode mode = case mode of
  Tier0Shamir -> SealModeShamir
  Tier0Transit -> SealModeTransit

toBasicsParentRef :: Tier0ParentRef -> ParentRef
toBasicsParentRef ref =
  ParentRef
    { parentRefClusterId = parent_cluster_id ref
    , parentRefVaultAddress = parent_vault_address ref
    , parentRefTransitKey = parent_transit_key ref
    , parentRefAuthorityEndpoint = parent_authority_endpoint ref
    }

-- | A Tier-0 record must carry no secret __values__ — every sensitive field is a
-- 'SecretRef.Vault' pointer (non-secret coordinates) or a non-secret literal.
-- This pure guard returns 'True' when no 'SecretRefTestPlaintext' (the only
-- 'SecretRef' arm that carries a literal value) appears anywhere in the Tier-0
-- parameters. The Sprint 1.39 secret-free unit test asserts it; a record with a
-- literal credential is rejected (config_doctrine.md §10).
tier0CarriesNoSecretValues :: ProdboxProjectConfig -> Bool
tier0CarriesNoSecretValues = null . tier0SecretValueFields

-- | The dotted Tier-0 field names carrying a literal secret __value__, in record
-- order. Empty is the only admissible state; the list exists so the decode gate
-- can name what it refused rather than reporting that something, somewhere, was
-- a literal.
--
-- Sprint 1.82.
tier0SecretValueFields :: ProdboxProjectConfig -> [Text]
tier0SecretValueFields config =
  [name | (name, ref) <- tier0SecretRefs (parameters config), secretRefIsValue ref]

-- | Every 'SecretRef' carried anywhere in the Tier-0 parameters, paired with the
-- dotted field name it came from.
--
-- Sprint 1.82: this is a __positional__ constructor pattern for the same reason
-- 'Prodbox.Settings.validateLocalConfig' is (Sprint 1.81). As a list of
-- accessors it never mentioned the record, so a new section carrying a
-- 'SecretRef' would have been omitted silently and the guard would have kept
-- returning 'True' about a field it could not see. The arity is now a compile
-- error at the one place that must decide whether a new section can carry a
-- secret value. Sections bound with a leading underscore carry no 'SecretRef'
-- today; that is a decision recorded here, not an omission.
tier0SecretRefs :: ProdboxParameters -> [(Text, SecretRef)]
tier0SecretRefs
  ( ProdboxParameters
      awsSection
      _route53Section
      _awsSubstrateSection
      _sesSection
      _domainSection
      acmeSection
      _deploymentSection
      _capacitySection
      _clusterTopologySection
      _storageSection
      _pulumiStateBackendSection
      _retainedArtifactsSection
      _componentNodes
    ) =
    [ ("aws.access_key_id", awsCredentialAccessKeyId awsSection)
    , ("aws.secret_access_key", awsCredentialSecretAccessKey awsSection)
    ]
      ++ catMaybes
        [ ("aws.session_token",) <$> awsCredentialSessionToken awsSection
        , ("acme.eab_key_id",) <$> Settings.eab_key_id acmeSection
        , ("acme.eab_hmac_key",) <$> Settings.eab_hmac_key acmeSection
        ]

-- | 'True' for a 'SecretRef' arm that carries a literal secret __value__ (only
-- 'SecretRefTestPlaintext'). 'SecretRefVault' \/ 'SecretRefTransitKey' \/
-- 'SecretRefPrompt' carry non-secret coordinates only.
secretRefIsValue :: SecretRef -> Bool
secretRefIsValue ref = case ref of
  SecretRefTestPlaintext _ -> True
  SecretRefVault _ -> False
  SecretRefTransitKey _ -> False
  SecretRefPrompt _ -> False

-- We work on @Expr Src Void@; 'Dhall.Core.pretty' renders it back to Dhall
-- source text. The empty annotation type is the one used by the Dhall AST.
type DhallExpr = Expr Src Void

-- | Render a Tier-0 record as @prodbox.dhall@ source text from the Haskell
-- source of truth — the same @'Dhall.inject' \/ 'Dhall.embed'@ mechanism
-- "Prodbox.Config.SchemaDhall" uses for @prodbox-config-types.dhall@. The
-- emitted text round-trips through @'Dhall.inputFile' 'Dhall.auto'@ back to the
-- record because the 'ToDhall' instances mirror the 'FromDhall' decoders
-- field-for-field. (Sprint 1.39.)
--
-- Sprint 1.72: when the embedded resource plan compiles (the common case), the
-- config is emitted with the Ring-1 over-commit shim
-- ('planGuardedConfigBody') — an inlined @assert@ that recomputes the cluster
-- allocatable from the file's OWN host numbers and fails to type-check (so the
-- file no longer loads through 'decodeProjectConfigDhall') if the emitted plan
-- over-commits (resource_scaling_doctrine.md §2C, Ring 1). If the plan cannot be
-- compiled at all — an invalid plan the Haskell Ring-2 decode gate rejects
-- regardless — the historical unguarded body is emitted so this renderer stays
-- total and never forces the partial capacity projection.
renderProjectConfigDhall :: ProdboxProjectConfig -> Text
renderProjectConfigDhall unstamped =
  case compileResourcePlanUncertified plan of
    Right _ -> tier0Header <> planGuardedConfigBody config (concurrentPlanDraws plan)
    Left _ -> tier0Header <> plainConfigBody config
 where
  -- Sprint 0.29: the generator stamps the record's own witness before
  -- rendering, so the emitted file carries a value derived from the record it
  -- represents. See 'stampTier0Witness'.
  config = stampTier0Witness unstamped
  plan = resource_plan (capacity (parameters config))

-- | Sprint 0.29 (pure). The generator-stamped witness over a Tier-0 record's
-- semantic content.
--
-- __What this closes.__ Sprint @0.24@'s drift gate compares the sibling
-- @prodbox.dhall@'s text against the canonical re-render of the record it
-- decodes to. That catches representational drift, and its first mutation
-- exercise proved it cannot catch a hand edit to a **primitive that round-trips
-- unchanged**: a re-typed @route53.zone_id@ decodes to that value and re-renders
-- to that value, so the edited file *is* the generator's output for the record it
-- carries. No text comparison can separate the two, because there is nothing to
-- compare — the file is self-consistent.
--
-- The witness breaks that self-consistency by carrying a value the record's own
-- content determines. After a hand edit the file holds the *old* witness beside
-- the *new* primitive; the drift gate re-renders the decoded record, stamps a
-- witness computed from the edited content, and the two disagree. The existing
-- text comparison then fires — no new gate is needed, only a field that cannot
-- be edited consistently by hand.
--
-- __The digest covers @parameters@ and @context@ and not @witness@__, which is
-- forced rather than chosen: a witness over a record containing itself has no
-- fixed point. That is also the bound. An operator who edits a primitive *and*
-- recomputes the witness defeats this, exactly as they would defeat any in-file
-- stamp; what it removes is the silent edit, not the deliberate one.
--
-- Tier-0 carries no secret values (`tier0CarriesNoSecretValues` is the decode
-- gate that keeps it so), so digesting the rendered record introduces no
-- plaintext-secret hash — the prohibition
-- [Standard P](../../../DEVELOPMENT_PLAN/development_plan_standards.md) places on
-- evidence digests.
tier0RecordWitness :: ProdboxProjectConfig -> Text
tier0RecordWitness config =
  tier0WitnessPrefix
    <> sha256Hex
      ( TextEncoding.encodeUtf8
          ( Core.pretty (injectedValue (Dhall.inject @ProdboxParameters) (parameters config))
              <> "\n"
              <> renderProdboxContextDhall (context config)
          )
      )

-- | Sprint 0.29: the witness scheme identifier. A future scheme appends a new
-- prefix rather than silently changing what the same-shaped string means.
tier0WitnessPrefix :: Text
tier0WitnessPrefix = "prodbox-tier0-witness-v1:"

-- | Sprint 0.29 (pure). Replace a record's witness list with its computed
-- witness. Idempotent: the digest ignores the witness field, so stamping a
-- stamped record yields the same record.
stampTier0Witness :: ProdboxProjectConfig -> ProdboxProjectConfig
stampTier0Witness config = config {witness = [tier0RecordWitness config]}

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered

-- | Sprint 5.30: the @context@ sub-record rendered by the same generic encoder
-- the whole document uses.
--
-- Exported so a test fixture that must author its own @parameters@ expression as
-- text still derives the envelope around it, instead of restating
-- 'ProdboxContext' as a second hand-maintained encoder — the shape that made
-- Sprint @1.80@'s tightening a silent breakage
-- ([chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md)).
renderProdboxContextDhall :: ProdboxContext -> Text
renderProdboxContextDhall =
  Core.pretty . injectedValue (Dhall.inject @ProdboxContext)

-- | The historical body: the injected config record rendered directly. Used only
-- as the totality fallback for a plan that cannot compile (which the Haskell
-- Ring-2 decode gate rejects anyway).
plainConfigBody :: ProdboxProjectConfig -> Text
plainConfigBody config =
  Core.pretty (injectedValue (Dhall.inject @ProdboxProjectConfig) config) <> "\n"

-- | Sprint 1.72: the Ring-1 over-commit-guarded body. Emits the config bound as
-- @cfg@, the precomputed concurrent workload draws (the same
-- 'concurrentPlanDraws' the Haskell Ring-2 proof threads), and a small inlined
-- copy of the capacity algebra that recomputes the reservation and cluster
-- allocatable from @cfg@'s own host numbers and asserts the plan fits. Because
-- @cfg@ references no lemma binding, every @let@ (including the @assert@)
-- normalizes away and the file's normal form is exactly the config record — so
-- extraction through @'Dhall.inputFile' 'Dhall.auto'@ is unchanged, while an
-- over-committed emitted file fails the @assert@ at type-check time.
planGuardedConfigBody :: ProdboxProjectConfig -> [ResourceVector] -> Text
planGuardedConfigBody config draws =
  Text.concat
    [ planLemmaPreamble
    , "let cfg = "
    , Core.pretty (injectedValue (Dhall.inject @ProdboxProjectConfig) config)
    , "\n\nlet concurrentDraws\n    : List RV\n    = "
    , Core.pretty (injectedValue (Dhall.inject @[ResourceVector]) draws)
    , "\n\n"
    , planAssertBody
    , "\nin  cfg\n"
    ]

-- | The inlined capacity algebra prepended to a plan-guarded @prodbox.dhall@.
-- Copied textually from @dhall\/capacity\/Schema.dhall@ (the canonical source)
-- because the binary-sibling config cannot import the Prelude or that schema. Only
-- the operators the over-commit assert needs are inlined: @lessOrEq@ (the
-- @Natural\/isZero@ fit witness — never a bare saturating subtract), @vectorPlus@,
-- @vectorFitsWithin@, @zeroVector@, and @sumVectors@.
planLemmaPreamble :: Text
planLemmaPreamble =
  Text.unlines
    [ "let RV"
    , "    : Type"
    , "    = { milli_cpu : Natural"
    , "      , memory_mib : Natural"
    , "      , ephemeral_storage_mib : Natural"
    , "      , durable_storage_mib : Natural"
    , "      }"
    , ""
    , "let lessOrEq ="
    , "      \\(a : Natural) -> \\(b : Natural) -> Natural/isZero (Natural/subtract b a)"
    , ""
    , "let vectorPlus ="
    , "      \\(left : RV) ->"
    , "      \\(right : RV) ->"
    , "        { milli_cpu = left.milli_cpu + right.milli_cpu"
    , "        , memory_mib = left.memory_mib + right.memory_mib"
    , "        , ephemeral_storage_mib = left.ephemeral_storage_mib + right.ephemeral_storage_mib"
    , "        , durable_storage_mib = left.durable_storage_mib + right.durable_storage_mib"
    , "        }"
    , ""
    , "let vectorFitsWithin ="
    , "      \\(inner : RV) ->"
    , "      \\(outer : RV) ->"
    , "            lessOrEq inner.milli_cpu outer.milli_cpu"
    , "        &&  lessOrEq inner.memory_mib outer.memory_mib"
    , "        &&  lessOrEq inner.ephemeral_storage_mib outer.ephemeral_storage_mib"
    , "        &&  lessOrEq inner.durable_storage_mib outer.durable_storage_mib"
    , ""
    , "let zeroVector"
    , "    : RV"
    , "    = { milli_cpu = 0, memory_mib = 0, ephemeral_storage_mib = 0, durable_storage_mib = 0 }"
    , ""
    , "let sumVectors ="
    , "      \\(entries : List RV) -> List/fold RV entries RV vectorPlus zeroVector"
    , ""
    ]

-- | The Ring-1 over-commit assertion appended after @cfg@ and @concurrentDraws@.
-- It recomputes the reservation and cluster allocatable from @cfg@'s own host
-- numbers (so a hand-edited oversized @host_capacity@ or inflated reservation is
-- caught) and asserts both @reservation ≤ host_capacity@ and
-- @Σ draws ≤ allocatable@. The clamping @Natural\/subtract@ only constructs
-- @allocatable@; the fit itself is @lessOrEq@ \/ @Natural\/isZero@, and the
-- independent @reservation ≤ host@ conjunct rejects any over-reservation, so a
-- clamp can never coexist with a passing assert.
planAssertBody :: Text
planAssertBody =
  Text.unlines
    [ "let reservation"
    , "    : RV"
    , "    = vectorPlus"
    , "        cfg.parameters.capacity.resource_plan.rke2_reserved"
    , "        cfg.parameters.capacity.resource_plan.eviction_floor"
    , ""
    , "let hostCapacity"
    , "    : RV"
    , "    = cfg.parameters.capacity.resource_plan.host_capacity"
    , ""
    , "let allocatable"
    , "    : RV"
    , "    = { milli_cpu = Natural/subtract reservation.milli_cpu hostCapacity.milli_cpu"
    , "      , memory_mib = Natural/subtract reservation.memory_mib hostCapacity.memory_mib"
    , "      , ephemeral_storage_mib ="
    , "          Natural/subtract reservation.ephemeral_storage_mib hostCapacity.ephemeral_storage_mib"
    , "      , durable_storage_mib ="
    , "          Natural/subtract reservation.durable_storage_mib hostCapacity.durable_storage_mib"
    , "      }"
    , ""
    , "let planFits"
    , "    : Bool"
    , "    =     vectorFitsWithin reservation hostCapacity"
    , "      &&  vectorFitsWithin (sumVectors concurrentDraws) allocatable"
    , ""
    , "let _ = assert : planFits === True"
    ]

-- | Render an injected (encoded) Haskell value as a Dhall 'Expr' for pretty
-- printing.
injectedValue :: Dhall.Encoder a -> a -> DhallExpr
injectedValue encoder value = Core.denote (Dhall.embed encoder value)

tier0Header :: Text
tier0Header =
  Text.unlines
    [ "-- prodbox.dhall"
    , "-- Tier 0: the binary-owned, project-local NON-SECRET config"
    , "-- (config_doctrine.md §0). Carries { parameters, context, witness } and"
    , "-- NEVER a secret value — sensitive fields are SecretRef.Vault pointers"
    , "-- only. The sealed-Vault bootstrap floor is projected straight off this"
    , "-- file's `context` (Prodbox.Config.FloorDhall); there is no separate"
    , "-- derived JSON floor. Generated from the Haskell ProdboxProjectConfig"
    , "-- source of truth (Prodbox.Config.Tier0); edit the Haskell types, then"
    , "-- regenerate. (Sprint 1.39 / 7.18.)"
    , ""
    ]

-- | Write the Tier-0 @prodbox.dhall@ at the repository root. This is the single
-- write path that establishes the non-secret binary context: call it where the
-- cluster identity is first established (e.g. @prodbox vault init@) so the
-- sealed-Vault bootstrap floor — projected straight off @prodbox.dhall@'s
-- @context@ ('Prodbox.Config.FloorDhall.loadUnencryptedBasics') — reflects the
-- real cluster identity rather than a hard-coded default.
--
-- Sprint 7.18: there is no longer a separate derived @prodbox-basics.json@
-- artifact to write beside it; @prodbox.dhall@ IS the floor source, so a single
-- self-contained Dhall file (generated or locally authored, never
-- version-controlled) is the whole non-secret surface.
writeTier0 :: FilePath -> ProdboxProjectConfig -> IO (Either String ())
writeTier0 repoRoot config = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  writeTier0AtPath tier0Path config

-- | Write a Tier-0 prodbox.dhall to an EXPLICIT path. 'writeTier0' resolves the
-- binary-sibling path ('resolveTier0ConfigPath') and delegates here; this is
-- the path-injection seam in-process unit tests exercise directly. Sprint 1.48.
writeTier0AtPath :: FilePath -> ProdboxProjectConfig -> IO (Either String ())
writeTier0AtPath tier0Path config = do
  writeResult <-
    try
      ( do
          createDirectoryIfMissing True (takeDirectory tier0Path)
          TextIO.writeFile tier0Path (renderProjectConfigDhall config)
      )
      :: IO (Either SomeException ())
  pure $ case writeResult of
    Left err ->
      Left
        ( "Failed to write Tier-0 prodbox.dhall at `"
            ++ tier0Path
            ++ "`: "
            ++ displayException err
        )
    Right () -> Right ()

-- | Sprint 1.39 (self-heal): idempotently guarantee the Tier-0 @prodbox.dhall@
-- — the sole source of the dependency-free sealed-Vault bootstrap floor — exists
-- at @repoRoot@.
--
-- @prodbox.dhall@ is written by @vault init@ at first-ever bring-up, but on a
-- REBUILD against a durable Vault PV @vault init@ early-returns (Vault is
-- already initialized) so it is never (re)written — and a cluster initialized
-- before Sprint 1.39 never had one at all. Every consumer of the floor
-- ('Prodbox.Settings.loadUnencryptedBasics' — the per-run Pulumi destroy, the
-- AWS provider credential loader, and the Rke2 reconcile sites) then fails
-- "Missing unencrypted basics file". This guard closes that gap: call it on
-- every @cluster reconcile@ AFTER @vault init@/@unseal@ succeed, so the floor is
-- self-healed whether or not @vault init@ actually ran this reconcile.
--
-- It is dependency-light and safe to call on every reconcile:
--
--   1. If a valid floor already loads ('loadUnencryptedBasics' projects it off
--      @prodbox.dhall@'s @context@ and validates), it is a NO-OP success.
--   2. Otherwise it refuses with the missing operator fields named. A root
--      cluster id cannot be reconstructed from the caller-supplied Vault
--      address, and substituting one here would create a second config owner.
ensureBasicsFloor :: FilePath -> Settings.ValidatedDeploymentContext -> IO (Either String ())
ensureBasicsFloor repoRoot context = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  ensureBasicsFloorAtPath tier0Path context

-- | Self-heal the Tier-0 floor at an EXPLICIT prodbox.dhall path.
-- 'ensureBasicsFloor' resolves the binary-sibling path and delegates here; the
-- path-injection seam in-process unit tests exercise directly. Sprint 1.48.
ensureBasicsFloorAtPath
  :: FilePath
  -> Settings.ValidatedDeploymentContext
  -> IO (Either String ())
ensureBasicsFloorAtPath tier0Path context = do
  existing <- loadUnencryptedBasicsAtPath tier0Path
  case existing of
    Right basics
      | basicsClusterId basics /= Settings.deploymentClusterId context ->
          pure
            ( Left
                ( "Tier-0 basics cluster_id does not match the validated deployment context: `"
                    ++ Text.unpack (basicsClusterId basics)
                    ++ "` /= `"
                    ++ Text.unpack (Settings.deploymentClusterId context)
                    ++ "`"
                )
            )
      | basicsVaultAddress basics /= Settings.deploymentVaultAddress context ->
          pure
            ( Left
                ( "Tier-0 basics vault_address does not match the validated deployment context: `"
                    ++ Text.unpack (basicsVaultAddress basics)
                    ++ "` /= `"
                    ++ Text.unpack (Settings.deploymentVaultAddress context)
                    ++ "`"
                )
            )
      | otherwise -> pure (Right ())
    Left err ->
      pure
        ( Left
            ( "cannot reconstruct the Tier-0 sealed-Vault basics floor without an "
                ++ "operator-authored context.cluster_id and context.vault_address: "
                ++ err
                ++ ". Run `prodbox config setup`."
            )
        )

-- | Sprint 1.39 (self-heal): the child-cluster analog of 'ensureBasicsFloor'.
-- A child cluster's floor is Transit seal mode carrying its parent reference,
-- which 'ensureBasicsFloor''s root-default fallback cannot reconstruct. The
-- federated lifecycle path has the child identity + parent reference in scope,
-- so it supplies them here. Behaviour mirrors 'ensureBasicsFloor': no-op when a
-- valid floor already loads; otherwise reconstruct, preferring an existing
-- Tier-0 @prodbox.dhall@ and falling back to a child record built from the
-- supplied identity.
ensureChildBasicsFloor
  :: FilePath
  -- ^ Repository root.
  -> Text
  -- ^ This child cluster's id.
  -> Text
  -- ^ This child cluster's Vault address.
  -> Tier0ParentRef
  -- ^ The parent reference this child auto-unseals against.
  -> IO (Either String ())
ensureChildBasicsFloor repoRoot childId vaultAddress parentRef = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  ensureChildBasicsFloorAtPath tier0Path childId vaultAddress parentRef

-- | Self-heal the child Tier-0 floor at an EXPLICIT prodbox.dhall path.
-- 'ensureChildBasicsFloor' resolves the binary-sibling path and delegates here;
-- the path-injection seam in-process unit tests exercise directly. Sprint 1.48.
ensureChildBasicsFloorAtPath
  :: FilePath -> Text -> Text -> Tier0ParentRef -> IO (Either String ())
ensureChildBasicsFloorAtPath tier0Path childId vaultAddress parentRef = do
  existing <- loadUnencryptedBasicsAtPath tier0Path
  case existing of
    Right _ -> pure (Right ())
    Left _ -> do
      tier0Present <- doesFileExist tier0Path
      reconstructed <-
        if tier0Present
          then do
            decoded <- decodeProjectConfigDhall tier0Path
            pure (either (const childFallbackConfig) id decoded)
          else pure childFallbackConfig
      writeResult <- writeTier0AtPath tier0Path reconstructed
      case writeResult of
        Left err ->
          pure
            ( Left
                ("self-heal of the Tier-0 child sealed-Vault basics floor failed: " ++ err)
            )
        Right () -> do
          writeOutputLine
            ( "Reconstructed the missing Tier-0 child sealed-Vault basics floor (prodbox.dhall) for cluster `"
                ++ Text.unpack (cluster_id (context reconstructed))
                ++ "`."
            )
          pure (Right ())
 where
  baseContext = context defaultProjectConfig
  childFallbackConfig =
    defaultProjectConfig
      { context =
          baseContext
            { cluster_id = childId
            , vault_address = vaultAddress
            , topology =
                ProdboxTopology
                  { seal_mode = Tier0Transit
                  , parent_ref = Just parentRef
                  }
            }
      }
