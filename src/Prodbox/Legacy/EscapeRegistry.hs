-- | Sprint 1.63: the machine-readable legacy-escape registry.
--
-- Counterexample @LCPC-2026-07-11@ and
-- [Standard P](../../../DEVELOPMENT_PLAN/development_plan_standards.md)'s
-- interim escape-path guard require that every pre-cutover legacy-escape
-- seam — the surfaces the lifecycle-control-plane redesign removes rather than
-- extends — be enumerated in one compiled registry, and that a source scan
-- match that registry bijectively. An unregistered escape marker fails
-- @prodbox dev check@; a registry entry whose marked call site has disappeared
-- fails it too. This keeps escape-path drift a seconds-fast build failure
-- rather than a surprise discovered in the multi-hour aggregate suite.
--
-- The five doctrine categories (see @code_quality.md § 3@) map onto the six
-- seams below (host-direct is split into its object-store and Vault-KV
-- surfaces). Each surviving call site carries a machine-readable marker comment
-- of the exact form @LEGACY-ESCAPE[<marker>]@; this module is the sole SSoT for
-- the marker set, the owning source file, and the removal-owner sprint. When a
-- seam's cutover sprint lands, the marked call site and its registry entry are
-- deleted together and the corresponding
-- [legacy ledger](../../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
-- row moves to @Completed@.
module Prodbox.Legacy.EscapeRegistry
  ( EscapeCategory (..)
  , LegacyEscapeSite (..)
  , registeredLegacyEscapeSites
  , escapeCategoryLabel
  , escapeMarkerOpen
  , escapeMarkerClose
  , legacyEscapeScanRoots
  , isLegacyEscapeScanFile
  , legacyEscapeRegistrySelfPath
  , parseEscapeMarkers
  , escapeRegistryViolations
  )
where

import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import System.FilePath (normalise)

-- | The five governed escape categories, with host-direct split into its two
-- physically distinct seams. Closed and exhaustive: a new escape kind must add
-- a constructor here (and a registry entry) rather than slip in untyped.
data EscapeCategory
  = -- | Lifecycle-authority / target-secret / object-store / bootstrap
    -- operations hosted on the gateway daemon's HTTP surface. Removed when the
    -- Bootstrap Broker, Lifecycle Authority, and Target Secret Agents take over
    -- these routes (Sprints @2.33@/@4.50@).
    GatewayHostedAuthorityRoutes
  | -- | The single shared operational @aws.*@ identity the suite-level IAM
    -- harness mints, projected into every AWS subprocess environment. Replaced
    -- by per-role Lifecycle-provider / Authority-backup / TLS-retention /
    -- Gateway-DNS / cert-manager-DNS01 / SES-SMTP generations (Sprints
    -- @3.26@/@4.49@/@4.50@/@7.33@/@8.11@).
    SharedOperationalAwsCredential
  | -- | The host CLI talking directly to the Model-B object store instead of
    -- through the Lifecycle Authority / Target Secret Agent (Sprint @4.50@).
    HostDirectObjectStore
  | -- | The host CLI reading Vault KV directly to resolve credentials instead
    -- of through the Lifecycle Authority's role-scoped projection
    -- (Sprint @4.49@).
    HostDirectVaultKv
  | -- | The @aws@ CLI subprocess (and its per-operation temp-file bodies) under
    -- every Model-B object-store operation. Sprint @1.66@ landed the native SigV4
    -- replacement ("Prodbox.Minio.ObjectStoreNative"); the subprocess path
    -- remains the default config-selectable rollback until native live-MinIO
    -- parity is proven, then it is deleted through the ledger.
    AwsCliObjectStoreSubprocess
  | -- | A fresh Vault Kubernetes-auth login performed per gateway request rather
    -- than a cached renewable session. The daemon's own service-account login
    -- was folded onto the cached "Prodbox.Vault.Session" by Sprint @1.64@; the
    -- surviving seam is the operator-secret handler's per-request operator-JWT
    -- exchange, removed with the authority route (Sprints @2.33@/@4.50@).
    PerRequestVaultLogin
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A single registered legacy-escape seam.
data LegacyEscapeSite = LegacyEscapeSite
  { escapeSiteMarker :: String
  -- ^ Unique kebab-case marker id; the source comment is @LEGACY-ESCAPE[<marker>]@.
  , escapeSiteCategory :: EscapeCategory
  , escapeSiteFile :: FilePath
  -- ^ Repo-relative source file that must carry exactly this marker.
  , escapeSiteDescription :: String
  , escapeSiteRemovalOwner :: String
  -- ^ Owning cutover sprint id(s).
  }
  deriving (Eq, Show)

escapeCategoryLabel :: EscapeCategory -> String
escapeCategoryLabel category =
  case category of
    GatewayHostedAuthorityRoutes -> "gateway-hosted authority routes"
    SharedOperationalAwsCredential -> "shared operational AWS credential"
    HostDirectObjectStore -> "host-direct object-store seam"
    HostDirectVaultKv -> "host-direct Vault-KV seam"
    AwsCliObjectStoreSubprocess -> "aws CLI subprocess object-store site"
    PerRequestVaultLogin -> "per-request Vault login"

-- | The authoritative registry. Exactly one surviving marked call site per
-- entry; the bijection check ('escapeRegistryViolations') enforces both
-- directions.
registeredLegacyEscapeSites :: [LegacyEscapeSite]
registeredLegacyEscapeSites =
  [ LegacyEscapeSite
      { escapeSiteMarker = "gateway-hosted-authority-routes"
      , escapeSiteCategory = GatewayHostedAuthorityRoutes
      , escapeSiteFile = "src/Prodbox/Gateway/Daemon.hs"
      , escapeSiteDescription =
          "handleParsedRequest hosts the bootstrap-Vault, Pulumi/authority "
            ++ "object-store, lifecycle authority CAS/clock, target-secret, and "
            ++ "operator-secret authority routes on the gateway daemon."
      , escapeSiteRemovalOwner = "2.33/4.50"
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "shared-operational-aws-credential"
      , escapeSiteCategory = SharedOperationalAwsCredential
      , escapeSiteFile = "src/Prodbox/Aws.hs"
      , escapeSiteDescription =
          "operationalAwsEnvironment projects the single shared operational "
            ++ "aws.* identity into every AWS subprocess environment; every "
            ++ "operational AWS action funnels through this seam."
      , escapeSiteRemovalOwner = "3.26/4.49/8.11"
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "host-direct-object-store"
      , escapeSiteCategory = HostDirectObjectStore
      , escapeSiteFile = "src/Prodbox/Pulumi/HostDirectObjectStore.hs"
      , escapeSiteDescription =
          "hostDirectGet/Put/DeletePulumiObject let the host CLI read and write "
            ++ "the Model-B object store directly instead of through the "
            ++ "Lifecycle Authority."
      , escapeSiteRemovalOwner = "4.50"
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "host-direct-vault-kv"
      , escapeSiteCategory = HostDirectVaultKv
      , escapeSiteFile = "src/Prodbox/Vault/Host.hs"
      , escapeSiteDescription =
          "readHostVaultKvField reads Vault KV directly from the host CLI to "
            ++ "resolve credentials instead of through an Authority role-scoped "
            ++ "projection."
      , escapeSiteRemovalOwner = "4.49"
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "host-direct-vault-root-token"
      , escapeSiteCategory = HostDirectVaultKv
      , escapeSiteFile = "src/Prodbox/Vault/Host.hs"
      , escapeSiteDescription =
          "loadReadyVaultRootToken loads the Vault root token directly from the "
            ++ "host CLI (to build AWS provider credentials and drive host-side "
            ++ "Vault lifecycle) instead of an Authority role-scoped projection."
      , escapeSiteRemovalOwner = "4.49/4.50"
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "aws-cli-object-store-subprocess"
      , escapeSiteCategory = AwsCliObjectStoreSubprocess
      , escapeSiteFile = "src/Prodbox/Minio/ObjectStore.hs"
      , escapeSiteDescription =
          "The Model-B object-store get/put/conditional-put/list/head/create/"
            ++ "delete operations shell out to the aws CLI s3api verbs with "
            ++ "per-operation temp-file bodies."
      , escapeSiteRemovalOwner = "1.66"
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "per-request-operator-secret-vault-login"
      , escapeSiteCategory = PerRequestVaultLogin
      , escapeSiteFile = "src/Prodbox/Gateway/Daemon.hs"
      , escapeSiteDescription =
          "writeOperatorSecret exchanges the operator's per-request JWT for a "
            ++ "Vault token under the operator-write role. Unlike the daemon's "
            ++ "own service-account login (folded onto the cached session by "
            ++ "Sprint 1.64), this login is inherently per-request; it leaves "
            ++ "the gateway when the operator-secret authority route does."
      , escapeSiteRemovalOwner = "2.33/4.50"
      }
  ]

-- | Opening delimiter of the source marker comment. Split from the closing
-- delimiter so this module's own source never contains a complete, scannable
-- marker token.
escapeMarkerOpen :: String
escapeMarkerOpen = "LEGACY-ESCAPE" ++ "["

escapeMarkerCloseChar :: Char
escapeMarkerCloseChar = ']'

escapeMarkerClose :: String
escapeMarkerClose = [escapeMarkerCloseChar]

-- | This module's repo-relative path. It is excluded from the scan so its
-- registry-id string literals are never mistaken for source markers.
legacyEscapeRegistrySelfPath :: FilePath
legacyEscapeRegistrySelfPath = "src/Prodbox/Legacy/EscapeRegistry.hs"

-- | The source roots the scan walks for escape markers.
legacyEscapeScanRoots :: [FilePath]
legacyEscapeScanRoots = ["src/", "app/"]

-- | Whether a repo-relative path participates in the escape-marker scan: a
-- Haskell source under a scan root, excluding this registry module itself.
isLegacyEscapeScanFile :: FilePath -> Bool
isLegacyEscapeScanFile path =
  ".hs" `isSuffixOf` path
    && any (`isPrefixOf` path) legacyEscapeScanRoots
    && normalise path /= normalise legacyEscapeRegistrySelfPath

-- | Extract every @LEGACY-ESCAPE[<marker>]@ occurrence from one file's
-- contents, pairing each marker id with the file it was found in.
parseEscapeMarkers :: FilePath -> String -> [(String, FilePath)]
parseEscapeMarkers path = go
 where
  go [] = []
  go contents =
    case breakOn escapeMarkerOpen contents of
      Nothing -> []
      Just afterOpen ->
        case span (/= headClose) afterOpen of
          (markerId, rest)
            | headClose `elemAtStart` rest && validMarker markerId ->
                (markerId, path) : go (drop 1 rest)
            | otherwise -> go afterOpen
  headClose = escapeMarkerCloseChar
  elemAtStart c (x : _) = c == x
  elemAtStart _ [] = False
  validMarker markerId =
    not (null markerId) && all isMarkerChar markerId
  isMarkerChar c = c `elem` markerCharset
  markerCharset = ['a' .. 'z'] ++ ['0' .. '9'] ++ "-"

-- | Find the text immediately after the first occurrence of @needle@.
breakOn :: String -> String -> Maybe String
breakOn needle = go
 where
  go [] = Nothing
  go haystack@(_ : rest)
    | needle `isPrefixOf` haystack = Just (drop (length needle) haystack)
    | otherwise = go rest

-- | The pure bijection check. @scannedFiles@ is @(relativePath, contents)@ for
-- every file admitted by 'isLegacyEscapeScanFile'. Returns one human-readable
-- violation per registry↔source disagreement, in a stable sorted order.
escapeRegistryViolations :: [(FilePath, String)] -> [String]
escapeRegistryViolations scannedFiles =
  sort
    (registryDefects ++ unregisteredDefects ++ missingDefects ++ mismatchDefects ++ duplicateDefects)
 where
  found :: [(String, FilePath)]
  found = concatMap (\(path, contents) -> parseEscapeMarkers path contents) scannedFiles

  registryByMarker :: Map.Map String LegacyEscapeSite
  registryByMarker =
    Map.fromList [(escapeSiteMarker site, site) | site <- registeredLegacyEscapeSites]

  registeredMarkers :: Set.Set String
  registeredMarkers = Map.keysSet registryByMarker

  foundCounts :: Map.Map String [FilePath]
  foundCounts =
    Map.fromListWith (++) [(marker, [path]) | (marker, path) <- found]

  -- A registry with duplicate marker ids is itself malformed.
  registryDefects :: [String]
  registryDefects =
    [ "duplicate registry marker id: " ++ marker
    | (marker, count) <- Map.toList markerDefinitionCounts
    , count > (1 :: Int)
    ]
   where
    markerDefinitionCounts =
      Map.fromListWith (+) [(escapeSiteMarker site, 1) | site <- registeredLegacyEscapeSites]

  unregisteredDefects :: [String]
  unregisteredDefects =
    [ "unregistered legacy-escape marker "
        ++ escapeMarkerOpen
        ++ marker
        ++ escapeMarkerClose
        ++ " found at "
        ++ path
        ++ "; add it to registeredLegacyEscapeSites or remove the marker."
    | (marker, paths) <- Map.toList foundCounts
    , not (Set.member marker registeredMarkers)
    , path <- take 1 (sort paths)
    ]

  missingDefects :: [String]
  missingDefects =
    [ "registered legacy-escape "
        ++ escapeSiteMarker site
        ++ " (declared in "
        ++ escapeSiteFile site
        ++ ") has no surviving "
        ++ escapeMarkerOpen
        ++ escapeSiteMarker site
        ++ escapeMarkerClose
        ++ " call site; delete the registry entry when its cutover sprint lands."
    | site <- registeredLegacyEscapeSites
    , not (Map.member (escapeSiteMarker site) foundCounts)
    ]

  mismatchDefects :: [String]
  mismatchDefects =
    [ "legacy-escape marker "
        ++ escapeMarkerOpen
        ++ marker
        ++ escapeMarkerClose
        ++ " found at "
        ++ path
        ++ " but the registry declares "
        ++ escapeSiteFile site
    | (marker, paths) <- Map.toList foundCounts
    , Just site <- [Map.lookup marker registryByMarker]
    , path <- paths
    , normalise path /= normalise (escapeSiteFile site)
    ]

  duplicateDefects :: [String]
  duplicateDefects =
    [ "legacy-escape marker "
        ++ escapeMarkerOpen
        ++ marker
        ++ escapeMarkerClose
        ++ " is registered once but appears at "
        ++ show (length paths)
        ++ " call sites: "
        ++ unwords (sort paths)
    | (marker, paths) <- Map.toList foundCounts
    , Set.member marker registeredMarkers
    , length paths > 1
    ]
