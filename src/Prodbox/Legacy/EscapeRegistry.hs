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
-- The surviving doctrine categories (see @code_quality.md § 3@) map onto the
-- seams below. Each surviving call site carries a machine-readable marker comment
-- of the exact form @LEGACY-ESCAPE[<marker>]@; this module is the sole SSoT for
-- the marker set, the owning source file, and the removal-owner sprint. When a
-- seam's cutover sprint lands, the marked call site and its registry entry are
-- deleted together and the corresponding
-- [legacy ledger](../../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
-- row moves to @Completed@.
--
-- Sprint @4.84@ closes the gap that made the bijection alone insufficient. A
-- marker↔entry bijection proves that every /marked/ escape is registered; it
-- cannot prove that an unmarked surviving escape was ever inventoried. The
-- registry therefore also carries a __coverage__ layer: each still-Pending
-- compatibility seam named by the deletion ledger declares the exact source
-- symbol that names it and the complete set of files allowed to mention that
-- symbol. A mention anywhere else fails the build even though the bijection
-- stays satisfied, and a declared site that no longer mentions its symbol fails
-- too, so a deleted seam cannot leave a stale declaration behind.
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
  , EscapeCoverageRule (..)
  , escapeCoverageRules
  , tokenOccursIn
  , escapeRegistryViolations
  )
where

import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import System.FilePath (normalise)

-- | The governed escape categories. Closed and exhaustive: a new escape kind must add
-- a constructor here (and a registry entry) rather than slip in untyped.
data EscapeCategory
  = -- | The @aws@ CLI subprocess (and its per-operation temp-file bodies) under
    -- every Model-B object-store operation. Sprint @1.66@ landed the native SigV4
    -- replacement ("Prodbox.Minio.ObjectStoreNative"); the subprocess path
    -- remains the default config-selectable rollback until native live-MinIO
    -- parity is proven, then it is deleted through the ledger.
    AwsCliObjectStoreSubprocess
  | -- | The general-purpose Tier-0 @aws.*@ aggregate and the legacy host reader
    -- family that still represent the registered Lifecycle-provider identity
    -- outside its fenced Provider-Worker ownership.
    Tier0GenericAwsCredentialAggregate
  | -- | Host-direct MinIO transport used as an operational recovery path
    -- instead of the retained Authority's own object-store seam.
    HostDirectMinioTransport
  | -- | The bespoke cascade executor that orchestrates destruction outside the
    -- lifecycle-owned desired-absence program.
    BespokeCascadeExecutor
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
  , escapeSiteDeletionCondition :: String
  -- ^ What must be true before the marked call site and this entry are deleted
  -- together.
  }
  deriving (Eq, Show)

escapeCategoryLabel :: EscapeCategory -> String
escapeCategoryLabel category =
  case category of
    AwsCliObjectStoreSubprocess -> "aws CLI subprocess object-store site"
    Tier0GenericAwsCredentialAggregate ->
      "generic Tier-0 aws.* Lifecycle-provider credential aggregate/reader"
    HostDirectMinioTransport -> "host-direct MinIO transport"
    BespokeCascadeExecutor -> "bespoke cascade executor"

-- | The authoritative registry. Exactly one surviving marked call site per
-- entry; the bijection check ('escapeRegistryViolations') enforces both
-- directions.
registeredLegacyEscapeSites :: [LegacyEscapeSite]
registeredLegacyEscapeSites =
  [ LegacyEscapeSite
      { escapeSiteMarker = "aws-cli-object-store-subprocess"
      , escapeSiteCategory = AwsCliObjectStoreSubprocess
      , escapeSiteFile = "src/Prodbox/Minio/ObjectStore.hs"
      , escapeSiteDescription =
          "The Model-B object-store get/put/conditional-put/list/head/create/"
            ++ "delete operations shell out to the aws CLI s3api verbs with "
            ++ "per-operation temp-file bodies."
      , escapeSiteRemovalOwner = "1.66"
      , escapeSiteDeletionCondition =
          "Native SigV4 object-store parity is proven against live MinIO and "
            ++ "the config-selectable rollback is withdrawn."
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "tier0-generic-aws-credential-aggregate"
      , escapeSiteCategory = Tier0GenericAwsCredentialAggregate
      , escapeSiteFile = "src/Prodbox/Settings.hs"
      , escapeSiteDescription =
          "The generic Tier-0 aws.* aggregate projects the registered "
            ++ "Lifecycle-provider credential, and its resolver is reachable "
            ++ "outside the fenced Provider Worker."
      , escapeSiteRemovalOwner = "4.50"
      , escapeSiteDeletionCondition =
          "Every remaining operation selects its role-specific capability or "
            ++ "session, so no caller outside the Provider Worker can select "
            ++ "or materialize the Lifecycle-provider credential."
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "lifecycle-provider-vault-field-projection"
      , escapeSiteCategory = Tier0GenericAwsCredentialAggregate
      , escapeSiteFile = "src/Prodbox/CLI/Vault.hs"
      , escapeSiteDescription =
          "The operator-facing Vault surface still projects the "
            ++ "Lifecycle-provider credential's fields by name."
      , escapeSiteRemovalOwner = "4.50"
      , escapeSiteDeletionCondition =
          "The same condition as the Tier-0 aggregate: the projection is "
            ++ "deleted with the aggregate it describes."
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "host-lifecycle-provider-credential-reader"
      , escapeSiteCategory = Tier0GenericAwsCredentialAggregate
      , escapeSiteFile = "src/Prodbox/Aws.hs"
      , escapeSiteDescription =
          "Legacy host AWS control flow still names the Lifecycle-provider "
            ++ "target-credential reader."
      , escapeSiteRemovalOwner = "4.50"
      , escapeSiteDeletionCondition =
          "Host AWS control flow routes every mutation through the Authority "
            ++ "and the fenced Provider Worker."
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "host-minio-port-forward-transport"
      , escapeSiteCategory = HostDirectMinioTransport
      , escapeSiteFile = "src/Prodbox/Infra/MinioBackend.hs"
      , escapeSiteDescription =
          "Host-direct MinIO transport retained as an operational recovery "
            ++ "path beside the retained Authority's own object-store seam."
      , escapeSiteRemovalOwner = "4.50"
      , escapeSiteDeletionCondition =
          "The dedicated config and object-store services own every read and "
            ++ "write, and the host-direct recovery path is withdrawn."
      }
  , LegacyEscapeSite
      { escapeSiteMarker = "bespoke-cascade-executor"
      , escapeSiteCategory = BespokeCascadeExecutor
      , escapeSiteFile = "src/Prodbox/CLI/Rke2.hs"
      , escapeSiteDescription =
          "The cascade is orchestrated by a bespoke executor rather than by a "
            ++ "lifecycle-owned desired-absence program."
      , escapeSiteRemovalOwner = "6.5"
      , escapeSiteDeletionCondition =
          "Sprint 6.5 completes the qualified single-writer cutover to the "
            ++ "descriptor-bound cleanup runner."
      }
  ]

-- | One still-Pending compatibility seam, bound to the exact source symbol that
-- names it and to every file allowed to mention that symbol.
--
-- This is the part the marker bijection cannot express. A marker proves that a
-- call site the author chose to annotate is registered; a coverage rule proves
-- that the seam has not grown a second, unannotated call site somewhere else,
-- and that its declared sites still exist.
data EscapeCoverageRule = EscapeCoverageRule
  { coverageRuleCategory :: EscapeCategory
  , coverageRuleSymbol :: String
  -- ^ Matched as a whole identifier token, so a longer identifier that merely
  -- contains this one is not an occurrence.
  , coverageRuleSites :: [FilePath]
  -- ^ Every repo-relative scanned file permitted to mention the symbol.  The
  -- first entry is the anchor and must also be a registered marker site of the
  -- same category.  A Haddock-quoted reference such as @\'Module.symbol\'@ is
  -- not an occurrence, because the trailing quote is an identifier character in
  -- Haskell; documentation-only mentions therefore need no site.
  , coverageRuleLedgerRow :: String
  }
  deriving (Eq, Show)

escapeCoverageRules :: [EscapeCoverageRule]
escapeCoverageRules =
  [ EscapeCoverageRule
      { coverageRuleCategory = AwsCliObjectStoreSubprocess
      , coverageRuleSymbol = "ObjectStoreSubprocess"
      , coverageRuleSites =
          [ "src/Prodbox/Minio/ObjectStore.hs"
          , "src/Prodbox/Minio/ObjectStoreTypes.hs"
          ]
      , coverageRuleLedgerRow = "aws CLI object-store backend selection"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = Tier0GenericAwsCredentialAggregate
      , coverageRuleSymbol = "operationalAwsCredentialsRef"
      , coverageRuleSites = ["src/Prodbox/Settings.hs"]
      , coverageRuleLedgerRow = "generic Tier-0 aws.* aggregate"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = Tier0GenericAwsCredentialAggregate
      , coverageRuleSymbol = "resolveLifecycleProviderCredentials"
      , coverageRuleSites =
          [ "src/Prodbox/Settings.hs"
          , "src/Prodbox/TestValidation.hs"
          ]
      , coverageRuleLedgerRow = "generic Tier-0 aws.* aggregate"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = Tier0GenericAwsCredentialAggregate
      , coverageRuleSymbol = "lifecycleProviderAwsVaultFields"
      , coverageRuleSites = ["src/Prodbox/CLI/Vault.hs"]
      , coverageRuleLedgerRow = "legacy host Lifecycle-provider reader family"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = Tier0GenericAwsCredentialAggregate
      , coverageRuleSymbol = "readLifecycleProviderTargetCredentials"
      , coverageRuleSites = ["src/Prodbox/Aws.hs"]
      , coverageRuleLedgerRow = "legacy host Lifecycle-provider reader family"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = HostDirectMinioTransport
      , coverageRuleSymbol = "withMinioPortForward"
      , coverageRuleSites =
          [ "src/Prodbox/Infra/MinioBackend.hs"
          , "src/Prodbox/EffectInterpreter.hs"
          , "src/Prodbox/Vault/Host.hs"
          ]
      , coverageRuleLedgerRow = "host MinIO transport"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = HostDirectMinioTransport
      , coverageRuleSymbol = "withCurrentMinioPortForward"
      , coverageRuleSites = ["src/Prodbox/Infra/MinioBackend.hs"]
      , coverageRuleLedgerRow = "host MinIO transport"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = BespokeCascadeExecutor
      , coverageRuleSymbol = "runNativeDeleteCascade"
      , coverageRuleSites =
          ["src/Prodbox/CLI/Rke2.hs"]
      , coverageRuleLedgerRow = "bespoke cascade executor"
      }
  , EscapeCoverageRule
      { coverageRuleCategory = BespokeCascadeExecutor
      , coverageRuleSymbol = "runCascadeDrainResult"
      , coverageRuleSites =
          [ "src/Prodbox/CLI/Rke2.hs"
          , "src/Prodbox/TestRunner.hs"
          ]
      , coverageRuleLedgerRow = "bespoke cascade executor"
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

-- | Whether @symbol@ occurs in @contents@ as a whole identifier token.  Token
-- matching rather than substring matching matters: @AwsCliObjectStoreSubprocess@
-- contains @ObjectStoreSubprocess@, and a substring rule would report the
-- longer constructor as an occurrence of the shorter seam symbol.
tokenOccursIn :: String -> String -> Bool
tokenOccursIn symbol contents
  | null symbol = False
  | otherwise = go ' ' contents
 where
  go previous remaining = case remaining of
    [] -> False
    (character : rest)
      | symbol `isPrefixOf` remaining
      , not (isIdentifierCharacter previous)
      , not (isIdentifierCharacter (charAfter remaining)) ->
          True
      | otherwise -> go character rest

  charAfter remaining = case drop (length symbol) remaining of
    (character : _) -> character
    [] -> ' '

  isIdentifierCharacter character =
    character `elem` identifierCharset

  identifierCharset =
    ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ "_'"

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
    ( registryDefects
        ++ unregisteredDefects
        ++ missingDefects
        ++ mismatchDefects
        ++ duplicateDefects
        ++ coverageDriftDefects
        ++ staleCoverageDefects
        ++ unanchoredCoverageDefects
    )
 where
  -- Coverage: a mention of a seam's symbol outside its declared site set is an
  -- escape nobody inventoried, whether or not it carries a marker.
  coverageDriftDefects :: [String]
  coverageDriftDefects =
    [ "unregistered "
        ++ escapeCategoryLabel (coverageRuleCategory rule)
        ++ " call site: "
        ++ coverageRuleSymbol rule
        ++ " is mentioned at "
        ++ path
        ++ ", which is not a declared coverage site for the "
        ++ coverageRuleLedgerRow rule
        ++ " ledger row; add the site to escapeCoverageRules with its marker, "
        ++ "or route the call through the replacement."
    | rule <- escapeCoverageRules
    , (path, contents) <- scannedFiles
    , tokenOccursIn (coverageRuleSymbol rule) contents
    , not (any (samePath path) (coverageRuleSites rule))
    ]

  -- The other direction: a declared site whose symbol is gone is a stale
  -- declaration, so deleting the source without deleting the entry fails.
  staleCoverageDefects :: [String]
  staleCoverageDefects =
    [ "stale coverage site "
        ++ site
        ++ " for "
        ++ coverageRuleSymbol rule
        ++ ": the declared file no longer mentions the symbol; delete the "
        ++ "coverage site (and its registry entry when the seam is gone)."
    | rule <- escapeCoverageRules
    , site <- coverageRuleSites rule
    , not (mentions site (coverageRuleSymbol rule))
    ]

  -- Every coverage rule anchors on a registered marker site of its own
  -- category, so a seam cannot be inventoried by symbol alone with no marked,
  -- owned, condition-bearing entry behind it.
  unanchoredCoverageDefects :: [String]
  unanchoredCoverageDefects =
    [ "coverage rule for "
        ++ coverageRuleSymbol rule
        ++ " has no registered "
        ++ escapeCategoryLabel (coverageRuleCategory rule)
        ++ " marker entry at its anchor site "
        ++ show (take 1 (coverageRuleSites rule))
    | rule <- escapeCoverageRules
    , anchor <- take 1 (coverageRuleSites rule)
    , not
        ( any
            ( \site ->
                escapeSiteCategory site == coverageRuleCategory rule
                  && samePath anchor (escapeSiteFile site)
            )
            registeredLegacyEscapeSites
        )
    ]

  mentions :: FilePath -> String -> Bool
  mentions site symbol =
    any
      (\(path, contents) -> samePath path site && tokenOccursIn symbol contents)
      scannedFiles

  samePath :: FilePath -> FilePath -> Bool
  samePath left right = normalise left == normalise right

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
