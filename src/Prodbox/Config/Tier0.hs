{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
--     storage, pulumi_state_backend, plus the operational @aws.*@ /
--     @acme.eab_*@ 'SecretRef.Vault' __pointers__) become the
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

    -- * Floor projection (pure)
  , projectBasics

    -- * Secret-free guard (pure)
  , tier0CarriesNoSecretValues

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
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
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
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Config.Basics
  ( ParentRef (..)
  , SealMode (..)
  , UnencryptedBasics (..)
  )
import Prodbox.Config.FloorDhall (loadUnencryptedBasics, loadUnencryptedBasicsAtPath)
import Prodbox.Repo
  ( resolveTier0ConfigPath
  )
import Prodbox.Settings
  ( AcmeSection
  , AwsCredentialsRef (..)
  , AwsSubstrateSection
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
  , minio_bucket :: Text
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
  , storage :: StorageSection
  , pulumi_state_backend :: PulumiStateBackendSection
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

-- | The host CLI's default binary context: a 'HostOrchestrator' frame that may
-- reach the durable store and authenticate to Vault. The cluster id mirrors the
-- former hard-coded @prodbox-home@ default until an operator authors a real
-- @prodbox.dhall@; the MinIO coordinates default to the in-cluster Service DNS
-- + the @prodbox-state@ bucket.
defaultProdboxContext :: ProdboxContext
defaultProdboxContext =
  ProdboxContext
    { project = "prodbox"
    , binary = "prodbox"
    , context_kind = HostOrchestrator
    , cluster_id = "prodbox-home"
    , vault_address = "http://127.0.0.1:31820"
    , minio_endpoint = "http://minio.prodbox.svc.cluster.local:9000"
    , minio_bucket = "prodbox-state"
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
    , storage = Settings.storage base
    , pulumi_state_backend = Settings.pulumi_state_backend base
    }
 where
  base = Settings.defaultConfigFile

-- | Sprint 1.42 Part B: project a 'Settings.ConfigFile' (the legacy
-- @prodbox-config.dhall@ payload) onto the Tier-0 'ProdboxParameters'. The two
-- records are field-for-field identical (same nine non-secret sections, same
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
    , storage = Settings.storage cf
    , pulumi_state_backend = Settings.pulumi_state_backend cf
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

-- | The in-cluster gateway daemon's default binary context — the 'Daemon'-frame
-- variant of 'defaultProdboxContext'. This is the context a freshly started
-- prodbox\/gateway container has /before/ any ConfigMap is mounted: the binary
-- is the @gateway@ daemon frame, it still reaches the durable store and
-- authenticates to Vault (via Vault Kubernetes auth in-cluster), and the
-- non-secret parameters are shared field-for-field with the host default so the
-- two surfaces cannot drift (Sprint 1.40, config_doctrine.md §0).
defaultDaemonContext :: ProdboxContext
defaultDaemonContext =
  defaultProdboxContext
    { binary = "gateway"
    , context_kind = Daemon
    }

-- | The Tier-0 binary-context record baked into the prodbox\/gateway container
-- as the default @prodbox.dhall@ (config_doctrine.md §0, §3). It reuses the
-- shared non-secret 'defaultProdboxParameters' (so the @aws.*@ /
-- @acme.eab_*@ fields stay 'SecretRef.Vault' pointers — asserted secret-free by
-- 'tier0CarriesNoSecretValues') and the 'Daemon'-frame 'defaultDaemonContext'.
-- The cluster daemon OVERWRITES this default from the @gateway-config-<nodeId>@
-- ConfigMap mount at startup; see 'loadDaemonBinaryContext'.
defaultDaemonProjectConfig :: ProdboxProjectConfig
defaultDaemonProjectConfig =
  defaultProjectConfig
    { context = defaultDaemonContext
    }

-- | Where the daemon's Tier-0 binary context comes from on a given start — the
-- provenance the daemon logs. The ConfigMap mount OVERWRITES the container
-- default (config_doctrine.md §0); the compiled-in default is the last-resort
-- fallback when neither file is present (e.g. a smoke run with no image asset).
data Tier0Source
  = -- | Decoded from the @gateway-config-<nodeId>@ ConfigMap-mounted
    -- @prodbox.dhall@ (the overwrite path).
    Tier0FromConfigMap FilePath
  | -- | Decoded from the baked-in container default @prodbox.dhall@.
    Tier0FromContainerDefault FilePath
  | -- | No on-disk file present; fell back to the compiled-in
    -- 'defaultDaemonProjectConfig'.
    Tier0FromCompiledDefault
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
-- daemon's other Dhall loaders). Pure-by-construction: the Tier-0 record carries
-- no secret values, so no SecretRef resolution happens here.
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
    Right config -> Right config

-- | Load the gateway daemon's Tier-0 binary context using hostbootstrap's
-- per-frame context-init pattern (Sprint 1.40, config_doctrine.md §0):
--
--   1. If the @gateway-config-<nodeId>@ ConfigMap supplies a @prodbox.dhall@
--      sibling next to the runtime @config.dhall@, decode it — the ConfigMap
--      OVERWRITES the container default.
--   2. Otherwise decode the baked-in container-default @prodbox.dhall@.
--   3. If neither file is present, fall back to the compiled-in
--      'defaultDaemonProjectConfig' so a freshly started container always has a
--      valid binary context.
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
        else pure (Right (Tier0FromCompiledDefault, defaultDaemonProjectConfig))
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
    }

-- | A Tier-0 record must carry no secret __values__ — every sensitive field is a
-- 'SecretRef.Vault' pointer (non-secret coordinates) or a non-secret literal.
-- This pure guard returns 'True' when no 'SecretRefTestPlaintext' (the only
-- 'SecretRef' arm that carries a literal value) appears anywhere in the Tier-0
-- parameters. The Sprint 1.39 secret-free unit test asserts it; a record with a
-- literal credential is rejected (config_doctrine.md §10).
tier0CarriesNoSecretValues :: ProdboxProjectConfig -> Bool
tier0CarriesNoSecretValues config =
  not (any secretRefIsValue (tier0SecretRefs (parameters config)))

-- | Every 'SecretRef' carried anywhere in the Tier-0 parameters — the operational
-- @aws.*@ credential pointers and the optional @acme.eab_*@ pointers.
tier0SecretRefs :: ProdboxParameters -> [SecretRef]
tier0SecretRefs params =
  [ awsCredentialAccessKeyId awsRefs
  , awsCredentialSecretAccessKey awsRefs
  ]
    ++ catMaybes
      [ awsCredentialSessionToken awsRefs
      , Settings.eab_key_id acmeSection
      , Settings.eab_hmac_key acmeSection
      ]
 where
  awsRefs = aws params
  acmeSection = acme params

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
renderProjectConfigDhall :: ProdboxProjectConfig -> Text
renderProjectConfigDhall config =
  tier0Header <> Core.pretty (injectedValue (Dhall.inject @ProdboxProjectConfig) config) <> "\n"

-- | Render an injected (encoded) Haskell value as a Dhall 'Expr'.
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
--   2. Otherwise it RECONSTRUCTS @prodbox.dhall@ from the best available source,
--      preferring an existing (but unreadable-as-floor) Tier-0 @prodbox.dhall@
--      (decoded via 'decodeProjectConfigDhall') so the floor matches the
--      operator-authored binary context;
--   3. else it falls back to 'defaultProjectConfig' with the known local cluster
--      identity (cluster id, this cluster's Vault address, Shamir seal mode, no
--      parent) — the same identity @vault init@ stamps for the root cluster —
--      with the caller-supplied Vault address overriding the default so it tracks
--      'Prodbox.Vault.Host.hostVaultAddress'.
--
-- The reconstruction writes through 'writeTier0', so the floor read back by
-- 'loadUnencryptedBasics' is exactly the projection of the written record.
ensureBasicsFloor :: FilePath -> Text -> IO (Either String ())
ensureBasicsFloor repoRoot vaultAddress = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  ensureBasicsFloorAtPath tier0Path vaultAddress

-- | Self-heal the Tier-0 floor at an EXPLICIT prodbox.dhall path.
-- 'ensureBasicsFloor' resolves the binary-sibling path and delegates here; the
-- path-injection seam in-process unit tests exercise directly. Sprint 1.48.
ensureBasicsFloorAtPath :: FilePath -> Text -> IO (Either String ())
ensureBasicsFloorAtPath tier0Path vaultAddress = do
  existing <- loadUnencryptedBasicsAtPath tier0Path
  case existing of
    Right _ -> pure (Right ())
    Left _ -> do
      tier0Present <- doesFileExist tier0Path
      reconstructed <-
        if tier0Present
          then do
            decoded <- decodeProjectConfigDhall tier0Path
            pure (either (const fallbackConfig) id decoded)
          else pure fallbackConfig
      writeResult <- writeTier0AtPath tier0Path reconstructed
      case writeResult of
        Left err ->
          pure
            ( Left
                ("self-heal of the Tier-0 sealed-Vault basics floor failed: " ++ err)
            )
        Right () -> do
          writeOutputLine
            ( "Reconstructed the missing Tier-0 sealed-Vault basics floor (prodbox.dhall) for cluster `"
                ++ Text.unpack (cluster_id (context reconstructed))
                ++ "`."
            )
          pure (Right ())
 where
  baseContext = context defaultProjectConfig
  fallbackConfig =
    defaultProjectConfig
      { context = baseContext {vault_address = vaultAddress}
      }

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
