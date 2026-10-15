{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | What it means for two qualification cycles to have run on one deployment.
--
-- A cycle's artifact names its run: the cleanup run id, owner and terminal
-- permit are derived from the cycle label, and every operation id hashes the
-- run id, so two cycles' run-scoped topology and wiring digests can never be
-- equal. An identity compared across cycles therefore has to be built from what
-- does not name a run: the executable source, the generated config, the
-- component images, the shape of the compiled program, and the digests derived
-- from the source. This module is that identity, as parts, a key over them,
-- and the difference between two sets of parts.
--
-- Git head, the dirty bit, the whole-tree manifest digest and the running
-- binary are /annotations/: recorded beside a cycle and never keyed by default,
-- because agents never commit and an operator commit of byte-identical content
-- must not reset a count of consecutive cycles.
module Prodbox.Test.Qualification.CascadeCycleIdentity
  ( KeyPolicy (..)
  , canonicalKeyPolicy
  , keyPolicyDigest
  , IdentityKey
  , identityKeyText
  , mkIdentityKey
  , IdentityComponent (..)
  , identityComponentName
  , CycleIdentityParts (..)
  , CycleAnnotations (..)
  , RecomputedLocalParts (..)
  , CompareOnlyParts (..)
  , annotationsOf
  , assembleCurrentIdentity
  , partsOfIdentity
  , partsFromLocal
  , refreshSourceParts
  , identityKeyOfParts
  , localKeyOfParts
  , localKeyOfLocal
  , diffParts
  , replacementDerivedDigests
  , topologyWiringDigest
  , imageSetDigest
  , normalizeImages
  )
where

import Data.ByteString qualified as ByteString
import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , QualificationIdentity (..)
  , hashPublicEvidence
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceIdentity
  , SourceManifestPolicyIdentity (..)
  , SourceScope (..)
  , WorktreeState (..)
  , gitHeadText
  , sourceGitHead
  , sourceManifestDigest
  , sourceManifestEntryCount
  , sourceManifestPolicyIdentity
  , sourceWorktreeState
  )

-- Key policy ------------------------------------------------------------------

-- | What an identity key covers. Changing either field, the partition of
-- components, or a derived-digest tag changes 'keyPolicyDigest' and therefore
-- every key, which resets a count of consecutive cycles by construction.
data KeyPolicy = KeyPolicy
  { keyPolicyScope :: !SourceScope
  -- ^ Which part of the worktree the keyed source digest covers.
  , keyPolicyGitProvenance :: !Bool
  -- ^ Whether git head and the dirty bit are keyed (otherwise only recorded).
  }
  deriving stock (Eq, Show)

-- | Documentation is not an executable input, and agents never commit, so the
-- canonical policy keys the executable surface and records git provenance.
canonicalKeyPolicy :: KeyPolicy
canonicalKeyPolicy =
  KeyPolicy
    { keyPolicyScope = ExecutableSurface
    , keyPolicyGitProvenance = False
    }

keyPolicyDigest :: KeyPolicy -> Text
keyPolicyDigest policy =
  digestText
    ( fieldsDigest
        ( [ "prodbox-cycle-key-policy/v1"
          , case keyPolicyScope policy of
              FullSurface -> "source:full"
              ExecutableSurface -> "source:executable"
          , if keyPolicyGitProvenance policy then "git:keyed" else "git:recorded"
          ]
            ++ map identityComponentName [minBound .. maxBound]
            ++ [interpreterTag, persistenceTag, cleanupSchemaTag]
        )
    )

-- Identity key ------------------------------------------------------------------

newtype IdentityKey = IdentityKey Text
  deriving stock (Eq, Ord, Show)

identityKeyText :: IdentityKey -> Text
identityKeyText (IdentityKey value) = value

-- | Only for a parser that reads back a key it wrote.
mkIdentityKey :: Text -> Maybe IdentityKey
mkIdentityKey raw
  | Text.length raw == 64 && Text.all isLowerHex raw = Just (IdentityKey raw)
  | otherwise = Nothing
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

-- | The components a key is made of, in the order they are encoded. A diff names
-- these, so a stale or differing identity says which one moved.
data IdentityComponent
  = ComponentKeyPolicy
  | ComponentSource
  | ComponentSourcePolicy
  | ComponentGitProvenance
  | ComponentGeneratedConfig
  | ComponentImages
  | ComponentTopologyWiring
  | ComponentResourceEnvelope
  | ComponentLoadFault
  | ComponentInterpreter
  | ComponentPersistence
  | ComponentCleanupSchema
  deriving stock (Bounded, Enum, Eq, Ord, Show)

identityComponentName :: IdentityComponent -> Text
identityComponentName component = case component of
  ComponentKeyPolicy -> "key-policy"
  ComponentSource -> "source"
  ComponentSourcePolicy -> "source-policy"
  ComponentGitProvenance -> "git-provenance"
  ComponentGeneratedConfig -> "generated-config"
  ComponentImages -> "component-images"
  ComponentTopologyWiring -> "topology-wiring-shape"
  ComponentResourceEnvelope -> "resource-envelope"
  ComponentLoadFault -> "load-fault"
  ComponentInterpreter -> "interpreter"
  ComponentPersistence -> "persistence"
  ComponentCleanupSchema -> "cleanup-schema"

-- Parts ---------------------------------------------------------------------------

-- | Everything a key is computed from. Equal parts mean one deployment; the
-- difference between two sets names the components that moved.
data CycleIdentityParts = CycleIdentityParts
  { partsKeyPolicyDigest :: !Text
  , partsSourceManifestDigest :: !Text
  , partsSourcePolicy :: !SourceManifestPolicyIdentity
  , partsSourceEntryCount :: !Int
  , partsGitProvenance :: !(Maybe (Text, WorktreeState))
  -- ^ Present only when the key policy keys it.
  , partsGeneratedConfig :: !PublicEvidenceDigest
  , partsComponentImages :: ![PublicEvidenceDigest]
  -- ^ Sorted and unique, because two containers may run one image.
  , partsTopologyWiring :: !PublicEvidenceDigest
  , partsResourceEnvelope :: !PublicEvidenceDigest
  , partsLoadFault :: !PublicEvidenceDigest
  , partsInterpreter :: !PublicEvidenceDigest
  , partsPersistence :: !PublicEvidenceDigest
  , partsCleanupSchema :: !PublicEvidenceDigest
  }
  deriving stock (Eq, Show)

-- | Recorded beside a cycle and printed in a receipt, never part of a key.
data CycleAnnotations = CycleAnnotations
  { annotationGitHead :: !Text
  , annotationWorktree :: !WorktreeState
  , annotationFullManifestDigest :: !Text
  , annotationFullEntryCount :: !Int
  , annotationBinaryDigest :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | What a process can recompute from the repository alone.
data RecomputedLocalParts = RecomputedLocalParts
  { localExecutableSource :: !SourceIdentity
  , localFullSource :: !SourceIdentity
  , localGeneratedConfig :: !PublicEvidenceDigest
  , localResourceEnvelope :: !PublicEvidenceDigest
  , localLoadFault :: !PublicEvidenceDigest
  }

-- | What can only be compared. The cluster is gone after the cascade, so the
-- images that ran and the shape of the program that ran are carried by the
-- artifact and checked against the ledger, never recomputed.
data CompareOnlyParts = CompareOnlyParts
  { compareImages :: ![PublicEvidenceDigest]
  , compareTopologyWiring :: !PublicEvidenceDigest
  }

annotationsOf :: SourceIdentity -> Maybe Text -> CycleAnnotations
annotationsOf fullSource binaryDigest =
  CycleAnnotations
    { annotationGitHead = gitHeadText (sourceGitHead fullSource)
    , annotationWorktree = sourceWorktreeState fullSource
    , annotationFullManifestDigest = sourceManifestDigest fullSource
    , annotationFullEntryCount = sourceManifestEntryCount fullSource
    , annotationBinaryDigest = binaryDigest
    }

-- | The qualification identity the recomputed and compared parts describe. It is
-- built over the source the key policy covers, so a witness minted from it is
-- bound to the same thing the key is.
assembleCurrentIdentity
  :: KeyPolicy -> RecomputedLocalParts -> CompareOnlyParts -> QualificationIdentity
assembleCurrentIdentity policy local compared =
  QualificationIdentity
    { qualificationSourceIdentity = source
    , qualificationGeneratedConfigDigest = localGeneratedConfig local
    , qualificationComponentImageDigests = normalizeImages (compareImages compared)
    , qualificationTopologyWiringDigest = compareTopologyWiring compared
    , qualificationResourceEnvelopeDigest = localResourceEnvelope local
    , qualificationLoadFaultDigest = localLoadFault local
    , qualificationInterpreterDigest = interpreter
    , qualificationPersistenceDigest = persistence
    , qualificationCleanupSchemaDigest = cleanupSchema
    }
 where
  source = case keyPolicyScope policy of
    FullSurface -> localFullSource local
    ExecutableSurface -> localExecutableSource local
  (interpreter, persistence, cleanupSchema) =
    replacementDerivedDigests (sourceManifestDigest source)

-- | The parts of an identity. This and 'assembleCurrentIdentity' are the one
-- pair every computation of parts goes through, so the writer, the attestation
-- and the observer cannot compute them two ways.
partsOfIdentity :: KeyPolicy -> QualificationIdentity -> CycleIdentityParts
partsOfIdentity policy identity =
  CycleIdentityParts
    { partsKeyPolicyDigest = keyPolicyDigest policy
    , partsSourceManifestDigest = sourceManifestDigest source
    , partsSourcePolicy = sourceManifestPolicyIdentity source
    , partsSourceEntryCount = sourceManifestEntryCount source
    , partsGitProvenance = gitProvenanceOf policy source
    , partsGeneratedConfig = qualificationGeneratedConfigDigest identity
    , partsComponentImages = normalizeImages (qualificationComponentImageDigests identity)
    , partsTopologyWiring = qualificationTopologyWiringDigest identity
    , partsResourceEnvelope = qualificationResourceEnvelopeDigest identity
    , partsLoadFault = qualificationLoadFaultDigest identity
    , partsInterpreter = qualificationInterpreterDigest identity
    , partsPersistence = qualificationPersistenceDigest identity
    , partsCleanupSchema = qualificationCleanupSchemaDigest identity
    }
 where
  source = qualificationSourceIdentity identity

partsFromLocal
  :: KeyPolicy -> RecomputedLocalParts -> CompareOnlyParts -> CycleIdentityParts
partsFromLocal policy local compared =
  partsOfIdentity policy (assembleCurrentIdentity policy local compared)

-- | The same parts after the source was captured again: the source-derived
-- fields move together, because the derived digests are functions of the
-- keyed manifest digest.
refreshSourceParts :: KeyPolicy -> SourceIdentity -> CycleIdentityParts -> CycleIdentityParts
refreshSourceParts policy source parts =
  parts
    { partsSourceManifestDigest = sourceManifestDigest source
    , partsSourcePolicy = sourceManifestPolicyIdentity source
    , partsSourceEntryCount = sourceManifestEntryCount source
    , partsGitProvenance = gitProvenanceOf policy source
    , partsInterpreter = interpreter
    , partsPersistence = persistence
    , partsCleanupSchema = cleanupSchema
    }
 where
  (interpreter, persistence, cleanupSchema) =
    replacementDerivedDigests (sourceManifestDigest source)

gitProvenanceOf :: KeyPolicy -> SourceIdentity -> Maybe (Text, WorktreeState)
gitProvenanceOf policy source
  | keyPolicyGitProvenance policy =
      Just (gitHeadText (sourceGitHead source), sourceWorktreeState source)
  | otherwise = Nothing

-- Key and difference ---------------------------------------------------------------

identityKeyOfParts :: CycleIdentityParts -> IdentityKey
identityKeyOfParts parts =
  IdentityKey
    ( digestText
        ( fieldsDigest
            [ "prodbox-cycle-identity-key/v1"
            , partsKeyPolicyDigest parts
            , partsSourceManifestDigest parts
            , renderPolicy (partsSourcePolicy parts)
            , Text.pack (show (partsSourceEntryCount parts))
            , maybe "git:unkeyed" renderProvenance (partsGitProvenance parts)
            , publicEvidenceDigestText (partsGeneratedConfig parts)
            , imageSetDigest (partsComponentImages parts)
            , publicEvidenceDigestText (partsTopologyWiring parts)
            , publicEvidenceDigestText (partsResourceEnvelope parts)
            , publicEvidenceDigestText (partsLoadFault parts)
            , publicEvidenceDigestText (partsInterpreter parts)
            , publicEvidenceDigestText (partsPersistence parts)
            , publicEvidenceDigestText (partsCleanupSchema parts)
            ]
        )
    )

renderPolicy :: SourceManifestPolicyIdentity -> Text
renderPolicy policy =
  Text.intercalate
    ":"
    [ sourcePolicyIdentifier policy
    , Text.pack (show (sourcePolicyVersion policy))
    , sourcePolicyDigest policy
    ]

renderProvenance :: (Text, WorktreeState) -> Text
renderProvenance (gitHead, worktree) =
  "git:" <> gitHead <> ":" <> renderWorktree worktree

renderWorktree :: WorktreeState -> Text
renderWorktree worktree = case worktree of
  WorktreeClean -> "clean"
  WorktreeDirty -> "dirty"

-- | A key over the parts a process can recompute, leaving out the component
-- images and the shape of the compiled program.
--
-- Those two are unknowable until a cycle observes them, and the images are
-- rebuilt by the very edits a cutover makes, so the full key a post-activation
-- pair will have cannot be predicted when the deletion is recorded. What can be
-- said at that moment is which tree the deletion was recorded on, and this key
-- says it.
localKeyOfParts :: CycleIdentityParts -> IdentityKey
localKeyOfParts parts =
  IdentityKey
    ( digestText
        ( fieldsDigest
            [ "prodbox-cycle-local-key/v1"
            , partsKeyPolicyDigest parts
            , partsSourceManifestDigest parts
            , renderPolicy (partsSourcePolicy parts)
            , Text.pack (show (partsSourceEntryCount parts))
            , maybe "git:unkeyed" renderProvenance (partsGitProvenance parts)
            , publicEvidenceDigestText (partsGeneratedConfig parts)
            , publicEvidenceDigestText (partsResourceEnvelope parts)
            , publicEvidenceDigestText (partsLoadFault parts)
            , publicEvidenceDigestText (partsInterpreter parts)
            , publicEvidenceDigestText (partsPersistence parts)
            , publicEvidenceDigestText (partsCleanupSchema parts)
            ]
        )
    )

-- | The local key of the tree a process has now, which needs nothing the
-- cluster would have had to supply.
localKeyOfLocal :: KeyPolicy -> RecomputedLocalParts -> IdentityKey
localKeyOfLocal policy local =
  localKeyOfParts (partsFromLocal policy local unobservedCompareOnlyParts)
 where
  -- Neither enters the local key; they are only needed to build the parts.
  unobservedCompareOnlyParts =
    CompareOnlyParts
      { compareImages = []
      , compareTopologyWiring = hashPublicEvidence "unobserved"
      }

-- | The components that differ, in encoding order. Empty exactly when the keys
-- are equal.
diffParts :: CycleIdentityParts -> CycleIdentityParts -> [IdentityComponent]
diffParts left right =
  [ component
  | (component, differs) <-
      [ (ComponentKeyPolicy, partsKeyPolicyDigest left /= partsKeyPolicyDigest right)
      ,
        ( ComponentSource
        , partsSourceManifestDigest left /= partsSourceManifestDigest right
            || partsSourceEntryCount left /= partsSourceEntryCount right
        )
      , (ComponentSourcePolicy, partsSourcePolicy left /= partsSourcePolicy right)
      , (ComponentGitProvenance, partsGitProvenance left /= partsGitProvenance right)
      , (ComponentGeneratedConfig, partsGeneratedConfig left /= partsGeneratedConfig right)
      , (ComponentImages, partsComponentImages left /= partsComponentImages right)
      , (ComponentTopologyWiring, partsTopologyWiring left /= partsTopologyWiring right)
      , (ComponentResourceEnvelope, partsResourceEnvelope left /= partsResourceEnvelope right)
      , (ComponentLoadFault, partsLoadFault left /= partsLoadFault right)
      , (ComponentInterpreter, partsInterpreter left /= partsInterpreter right)
      , (ComponentPersistence, partsPersistence left /= partsPersistence right)
      , (ComponentCleanupSchema, partsCleanupSchema left /= partsCleanupSchema right)
      ]
  , differs
  ]

-- Derived digests --------------------------------------------------------------------

-- | The interpreter, persistence and cleanup-schema digests of the replacement
-- composition, as functions of the keyed source manifest digest. Given that
-- digest they carry no information of their own; they exist so a writer and a
-- consumer that disagree about a formula disagree visibly.
replacementDerivedDigests
  :: Text -> (PublicEvidenceDigest, PublicEvidenceDigest, PublicEvidenceDigest)
replacementDerivedDigests sourceDigest =
  ( tagged interpreterTag
  , tagged persistenceTag
  , tagged cleanupSchemaTag
  )
 where
  tagged tag = hashPublicEvidence (sourceDigest <> "\NUL" <> tag)

interpreterTag, persistenceTag, cleanupSchemaTag :: Text
interpreterTag = "descriptor-bound-cascade-dispatch/v2"
persistenceTag = "cleanup-program-descriptor/v2\NULauthority-aggregate/v1"
cleanupSchemaTag = "cleanup-run-report/v1\NULcascade-complete-evidence/v1"

-- | The topology and wiring of the compiled cascade program with everything
-- that names a run held constant, so two cycles of one deployment agree.
topologyWiringDigest :: Text -> Text -> PublicEvidenceDigest
topologyWiringDigest topologyShape wiringShape =
  fieldsDigest ["prodbox-topology-wiring-shape/v1", topologyShape, wiringShape]

-- | A digest of the set of component images, whatever order or multiplicity they
-- were observed in.
imageSetDigest :: [PublicEvidenceDigest] -> Text
imageSetDigest images =
  digestText (fieldsDigest (map publicEvidenceDigestText (normalizeImages images)))

normalizeImages :: [PublicEvidenceDigest] -> [PublicEvidenceDigest]
normalizeImages = nub . sort

-- Encoding --------------------------------------------------------------------------

-- | A length-prefixed encoding, so no two field lists encode alike.
fieldsDigest :: [Text] -> PublicEvidenceDigest
fieldsDigest = hashPublicEvidence . Text.concat . map encodeField
 where
  encodeField value =
    Text.pack (show (ByteString.length (TextEncoding.encodeUtf8 value))) <> ":" <> value

digestText :: PublicEvidenceDigest -> Text
digestText = publicEvidenceDigestText
