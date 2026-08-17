{-# LANGUAGE OverloadedStrings #-}

-- | Package-private constructors and canonical encoding for lifecycle
-- recovery capability metadata.  Production callers consume the opaque
-- facade; only the compiled program/graph and the focused proof suite mint
-- catalogs.
module Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal
  ( RecoveryCapability (..)
  , RecoveryCapabilitySet
  , RecoveryCapabilityCatalogDraft
  , RecoveryCapabilityCatalog
  , RecoveryCapabilityCatalogError (..)
  , noAdditionalRecoveryCapabilities
  , resumeOrdinaryCleanupCapabilities
  , targetGenerationRecoveryCapabilities
  , mergeRecoveryCapabilitySets
  , recoveryCapabilityName
  , recoveryCapabilitySetCapabilities
  , recoveryCapabilitySetNames
  , recoveryCapabilitySetDigest
  , recoveryCapabilitySetRequiresTargetAgent
  , mkRecoveryCapabilityCatalogDraft
  , sealRecoveryCapabilityCatalog
  , recoveryCapabilityCatalogEntries
  , recoveryCapabilityCatalogNodes
  , recoveryCapabilityCatalogCapabilitiesForNode
  , recoveryCapabilityCatalogOperationForNode
  , recoveryCapabilityCatalogDigest
  , recoveryCapabilityCatalogVersion
  , recoveryCapabilitySetVersion
  , recoveryCapabilityOperationIdentityVersion
  , bindRecoveryCapabilitiesToOperationIdentity
  )
where

import Data.List (group, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeId
  , CleanupOperationId
  , cleanupNodeIdText
  )

-- | Recovery abilities are facts about a durable cleanup obligation, not
-- credentials and not a caller-selected deployment profile.
data RecoveryCapability
  = ResumeOrdinaryCleanup
  | ResolveExactTargetCleanup
  deriving (Eq, Ord, Show)

newtype RecoveryCapabilitySet = RecoveryCapabilitySet (Set RecoveryCapability)
  deriving (Eq, Show)

data RecoveryCapabilityCatalogDraft = RecoveryCapabilityCatalogDraft
  { internalRecoveryCapabilityCatalogDraftEntries
      :: !(Map CleanupNodeId RecoveryCapabilitySet)
  , internalRecoveryCapabilityCatalogDraftDigest :: !Text
  }
  deriving (Eq, Show)

data RecoveryCapabilityCatalogEntry = RecoveryCapabilityCatalogEntry
  { internalRecoveryCapabilityCatalogEntryOperation :: !CleanupOperationId
  , internalRecoveryCapabilityCatalogEntryCapabilities :: !RecoveryCapabilitySet
  }
  deriving (Eq, Show)

data RecoveryCapabilityCatalog = RecoveryCapabilityCatalog
  { internalRecoveryCapabilityCatalogEntries
      :: !(Map CleanupNodeId RecoveryCapabilityCatalogEntry)
  , internalRecoveryCapabilityCatalogDigest :: !Text
  }
  deriving (Eq, Show)

data RecoveryCapabilityCatalogError
  = RecoveryCapabilityCatalogEmpty
  | RecoveryCapabilityCatalogDuplicateNode !CleanupNodeId
  | RecoveryCapabilityCatalogDuplicateOperationNode !CleanupNodeId
  | RecoveryCapabilityCatalogOperationNodeMismatch
      ![CleanupNodeId]
      ![CleanupNodeId]
  deriving (Eq, Show)

-- | Registry bindings contribute no Target-Agent ability until an exact,
-- source-backed target-generation obligation is added to the registry.
noAdditionalRecoveryCapabilities :: RecoveryCapabilitySet
noAdditionalRecoveryCapabilities = RecoveryCapabilitySet Set.empty

-- | Every current cleanup node is resumable by the ordinary recovery plane.
resumeOrdinaryCleanupCapabilities :: RecoveryCapabilitySet
resumeOrdinaryCleanupCapabilities =
  RecoveryCapabilitySet (Set.singleton ResumeOrdinaryCleanup)

-- | Internal-only fixture/future compiler input.  The public facade does not
-- export this value, so a caller cannot request Target Agent by choosing an
-- enum or constructing a set.
targetGenerationRecoveryCapabilities :: RecoveryCapabilitySet
targetGenerationRecoveryCapabilities =
  RecoveryCapabilitySet
    (Set.fromList [ResumeOrdinaryCleanup, ResolveExactTargetCleanup])

mergeRecoveryCapabilitySets
  :: RecoveryCapabilitySet
  -> RecoveryCapabilitySet
  -> RecoveryCapabilitySet
mergeRecoveryCapabilitySets
  (RecoveryCapabilitySet left)
  (RecoveryCapabilitySet right) =
    RecoveryCapabilitySet (Set.union left right)

recoveryCapabilityName :: RecoveryCapability -> Text
recoveryCapabilityName capability = case capability of
  ResumeOrdinaryCleanup -> "resume-ordinary-cleanup"
  ResolveExactTargetCleanup -> "resolve-exact-target-cleanup"

recoveryCapabilitySetCapabilities
  :: RecoveryCapabilitySet -> [RecoveryCapability]
recoveryCapabilitySetCapabilities (RecoveryCapabilitySet capabilities) =
  Set.toAscList capabilities

recoveryCapabilitySetNames :: RecoveryCapabilitySet -> [Text]
recoveryCapabilitySetNames =
  map recoveryCapabilityName . recoveryCapabilitySetCapabilities

recoveryCapabilitySetDigest :: RecoveryCapabilitySet -> Text
recoveryCapabilitySetDigest capabilities =
  sha256Canonical
    ( recoveryCapabilitySetVersion
        : recoveryCapabilitySetNames capabilities
    )

recoveryCapabilitySetRequiresTargetAgent :: RecoveryCapabilitySet -> Bool
recoveryCapabilitySetRequiresTargetAgent (RecoveryCapabilitySet capabilities) =
  ResolveExactTargetCleanup `Set.member` capabilities

mkRecoveryCapabilityCatalogDraft
  :: [(CleanupNodeId, RecoveryCapabilitySet)]
  -> Either RecoveryCapabilityCatalogError RecoveryCapabilityCatalogDraft
mkRecoveryCapabilityCatalogDraft entries = do
  if null entries
    then Left RecoveryCapabilityCatalogEmpty
    else Right ()
  case duplicateValues (map fst entries) of
    duplicateNode : _ ->
      Left (RecoveryCapabilityCatalogDuplicateNode duplicateNode)
    [] -> Right ()
  let indexed = Map.fromList entries
  pure
    RecoveryCapabilityCatalogDraft
      { internalRecoveryCapabilityCatalogDraftEntries = indexed
      , internalRecoveryCapabilityCatalogDraftDigest = catalogDigest indexed
      }

sealRecoveryCapabilityCatalog
  :: RecoveryCapabilityCatalogDraft
  -> [(CleanupNodeId, CleanupOperationId)]
  -> Either RecoveryCapabilityCatalogError RecoveryCapabilityCatalog
sealRecoveryCapabilityCatalog draft operationBindings = do
  case duplicateValues (map fst operationBindings) of
    duplicateNode : _ ->
      Left (RecoveryCapabilityCatalogDuplicateOperationNode duplicateNode)
    [] -> Right ()
  let expectedNodes = Map.keys (internalRecoveryCapabilityCatalogDraftEntries draft)
      observedNodes = Map.keys (Map.fromList operationBindings)
  if expectedNodes == observedNodes
    then Right ()
    else
      Left
        ( RecoveryCapabilityCatalogOperationNodeMismatch
            expectedNodes
            observedNodes
        )
  let operationIndex = Map.fromList operationBindings
      entries =
        Map.intersectionWith
          RecoveryCapabilityCatalogEntry
          operationIndex
          (internalRecoveryCapabilityCatalogDraftEntries draft)
  pure
    RecoveryCapabilityCatalog
      { internalRecoveryCapabilityCatalogEntries = entries
      , internalRecoveryCapabilityCatalogDigest =
          internalRecoveryCapabilityCatalogDraftDigest draft
      }

recoveryCapabilityCatalogEntries
  :: RecoveryCapabilityCatalog
  -> [(CleanupNodeId, CleanupOperationId, RecoveryCapabilitySet)]
recoveryCapabilityCatalogEntries =
  map renderEntry . Map.toAscList . internalRecoveryCapabilityCatalogEntries
 where
  renderEntry (nodeId, entry) =
    ( nodeId
    , internalRecoveryCapabilityCatalogEntryOperation entry
    , internalRecoveryCapabilityCatalogEntryCapabilities entry
    )

recoveryCapabilityCatalogNodes :: RecoveryCapabilityCatalog -> [CleanupNodeId]
recoveryCapabilityCatalogNodes =
  Map.keys . internalRecoveryCapabilityCatalogEntries

recoveryCapabilityCatalogCapabilitiesForNode
  :: CleanupNodeId
  -> RecoveryCapabilityCatalog
  -> Maybe RecoveryCapabilitySet
recoveryCapabilityCatalogCapabilitiesForNode nodeId =
  fmap internalRecoveryCapabilityCatalogEntryCapabilities
    . Map.lookup nodeId
    . internalRecoveryCapabilityCatalogEntries

recoveryCapabilityCatalogOperationForNode
  :: CleanupNodeId
  -> RecoveryCapabilityCatalog
  -> Maybe CleanupOperationId
recoveryCapabilityCatalogOperationForNode nodeId =
  fmap internalRecoveryCapabilityCatalogEntryOperation
    . Map.lookup nodeId
    . internalRecoveryCapabilityCatalogEntries

recoveryCapabilityCatalogDigest :: RecoveryCapabilityCatalog -> Text
recoveryCapabilityCatalogDigest = internalRecoveryCapabilityCatalogDigest

recoveryCapabilityCatalogVersion :: Text
recoveryCapabilityCatalogVersion = "lifecycle-recovery-capability-catalog/v1"

-- | Bind a canonical pre-capability operation identity to both its own exact
-- capability set and the complete catalog.  The compiler uses the result as
-- the v3 operation digest; changing any node's metadata changes every v3
-- operation identity and therefore the serialized CleanupGraph digest.
bindRecoveryCapabilitiesToOperationIdentity
  :: Text
  -> RecoveryCapabilityCatalogDraft
  -> RecoveryCapabilitySet
  -> Text
bindRecoveryCapabilitiesToOperationIdentity baseIdentity draft capabilities =
  sha256Canonical
    [ recoveryCapabilityOperationIdentityVersion
    , baseIdentity
    , recoveryCapabilityCatalogVersion
    , internalRecoveryCapabilityCatalogDraftDigest draft
    , recoveryCapabilitySetDigest capabilities
    ]

recoveryCapabilitySetVersion :: Text
recoveryCapabilitySetVersion = "lifecycle-recovery-capability-set/v1"

recoveryCapabilityOperationIdentityVersion :: Text
recoveryCapabilityOperationIdentityVersion = "lifecycle-cleanup-operation/v3"

catalogDigest :: Map CleanupNodeId RecoveryCapabilitySet -> Text
catalogDigest indexed =
  sha256Canonical
    ( recoveryCapabilityCatalogVersion
        : concatMap canonicalEntry (Map.toAscList indexed)
    )
 where
  canonicalEntry (nodeId, capabilities) =
    [ "node"
    , cleanupNodeIdText nodeId
    , recoveryCapabilitySetDigest capabilities
    ]

sha256Canonical :: [Text] -> Text
sha256Canonical fields =
  TextEncoding.decodeUtf8
    (hexSha256 (TextEncoding.encodeUtf8 (Text.concat (map canonicalField fields))))
 where
  canonicalField value =
    Text.pack (show (Text.length value)) <> ":" <> value

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues values =
  [ value
  | groupedValues@(value : _) <- group (sort values)
  , length groupedValues > 1
  ]
