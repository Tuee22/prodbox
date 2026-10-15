{-# LANGUAGE OverloadedStrings #-}

-- | Naming a controller's child from a record that outlives the cluster.
--
-- The EKS stack's write-ahead ownership manifest is committed and read back
-- before any effect, and it already declares the families a cluster's
-- controllers create (the per-run volumes and the load balancer controller's
-- children) by registry key and registry coordinate digest. It carries no member
-- identities for them, and nothing that destroys a family reads any: the family
-- reap takes its name and tags from the registry coordinate. What was missing
-- is the function from an /escaped sweep row/ to that declaration, so that a
-- resource found by tag after its cluster is gone can be named as a member of a
-- family the stack declared before it acted.
--
-- __What this proves, and what it does not.__ A row proves a family and the
-- stack that owns it. It does not prove a run: the controllers' tag sets are
-- constant for a cluster name, so two runs' children carry identical tags. The
-- result therefore reports the scope as /supplied by the caller/, and the
-- narration says the run is not established. The attribution is sound under the
-- assumption that at most one live EKS run exists per account and region; a leaked
-- child of an earlier run is attributed to the family and the stack, never to a
-- scope it did not carry.
--
-- __Where the facts come from.__ The cascade postflight reads no manifest. It
-- builds its facts with 'manifestFactsFromRegistry', the entry set a creation
-- commits and its read-back compares, so what it can say is that the registry
-- declares a family in a stack's manifest and a row's tags match it; the
-- narration says that, and says no manifest was read. The refusals that compare
-- a declared entry with the registry ('DeclaredCoordinateDigestDisagrees', and
-- an entry that is absent) cannot fire from those facts. They exist for facts a
-- caller supplies from a record it read, and the unit tests exercise them over
-- constructed manifests; no reader of a durable manifest exists on the
-- postflight path.
--
-- __What it deliberately does not do.__ It writes nothing, adds no manifest
-- writer, and applies no stamp to a controller. Recording member ARNs would need
-- a second append against an immutable completion slot, which is a
-- persistence-protocol change, and would write data no destroy reads. DNS01
-- challenge records are not attributable here at all: a record set carries no
-- tag, the Tagging API cannot see it, and its family has no owning stack.
module Prodbox.Lifecycle.ControllerFamilyAttribution
  ( ManifestFacts (..)
  , MembershipFamily (..)
  , AttributedRow (..)
  , UnattributedReason (..)
  , coordinateMembershipTags
  , membershipFamilies
  , manifestFactsFromRegistry
  , attributeEscapedRows
  , renderEscapedAttributionNarration
  )
where

import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.TagSweep
  ( TagSweepVerdict (..)
  , TaggedResource (..)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ManagedResourceCoordinate (..)
  , ManagedResourceCoordinateDigest
  , ObservationEvidenceScope
  , RegisteredResourceKey
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestEntry (..)
  , OwnershipManifestError
  , initialManifestEntries
  , ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( SomeManagedResourceDescriptor (..)
  , managedResourceCoordinate
  , managedResourceCoordinateDigest
  , managedResourceKey
  , managedResourceRegistry
  )

-- | What a stack's write-ahead manifest declares. The entries are the manifest's
-- own, so a test builds this from a constructed manifest and the postflight
-- builds it from the registry; the two agree because the entry set is a pure
-- function of the stack key.
data ManifestFacts = ManifestFacts
  { manifestFactsStackKey :: !RegisteredResourceKey
  , manifestFactsScope :: !(Maybe ObservationEvidenceScope)
  -- ^ Present only when the caller read a manifest. It is reported back as
  -- supplied; the rows do not prove it.
  , manifestFactsEntries :: ![OwnershipManifestEntry]
  }

-- | A family a sweep row can be recognized as a member of: the tags every
-- member carries, and the registry coordinate digest the manifest declared it
-- under.
data MembershipFamily = MembershipFamily
  { membershipFamilyKey :: !RegisteredResourceKey
  , membershipFamilyOwner :: !RegisteredResourceKey
  , membershipFamilyTags :: ![(Text, Text)]
  , membershipFamilyCoordinateDigest :: !ManagedResourceCoordinateDigest
  }

data AttributedRow = AttributedRow
  { attributedArn :: !Text
  , attributedFamily :: !RegisteredResourceKey
  , attributedOwningStack :: !RegisteredResourceKey
  , attributedSuppliedScope :: !(Maybe ObservationEvidenceScope)
  -- ^ Supplied by the caller. The rows do not prove it.
  }

-- | Why a row was not attributed. Each is a refusal, never a guess.
data UnattributedReason
  = -- | No family's tags are all present on the resource.
    NoFamilyTagsMatch
  | -- | A family matches, and this manifest does not declare it (it belongs to
    -- another stack, or to none).
    FamilyMatchedButNotDeclared !RegisteredResourceKey
  | -- | The manifest declared the family under a coordinate digest the registry
    -- no longer gives it: the record predates a registry change, so it cannot
    -- vouch for the current definition.
    DeclaredCoordinateDigestDisagrees !RegisteredResourceKey
  | -- | More than one family matches; the rows cannot choose.
    AmbiguousFamilies ![RegisteredResourceKey]
  deriving (Eq, Show)

-- | The tags every member of a family carries, or 'Nothing' for a coordinate
-- that is not recognized by tags. Total over the coordinate type, so a new
-- coordinate shape is an exhaustiveness error until it is classified here.
coordinateMembershipTags :: ManagedResourceCoordinate -> Maybe [(Text, Text)]
coordinateMembershipTags coordinate = case coordinate of
  AwsLoadBalancerControllerFamilyCoordinate {awsLoadBalancerControllerTags = tags} -> Just tags
  AwsEbsPerRunFamilyCoordinate
    { awsEbsOwnershipTagKey = ownershipKey
    , awsEbsOwnershipTagValue = ownershipValue
    , awsEbsClusterOwnershipTagKey = clusterKey
    , awsEbsClusterOwnershipTagValue = clusterValue
    } -> Just [(ownershipKey, ownershipValue), (clusterKey, clusterValue)]
  LocalRke2Coordinate {} -> Nothing
  AwsPulumiStackCoordinate {} -> Nothing
  AwsEbsRetainedFamilyCoordinate {} -> Nothing
  AwsIamRoleFamilyCoordinate {} -> Nothing
  AwsRoute53ValidationZoneFamilyCoordinate {} -> Nothing
  AwsRoute53Dns01ChallengeRecordFamilyCoordinate {} -> Nothing

-- | Every family a stack's manifest declares that a tag can identify, derived
-- from the registry and the ownership edges, never authored.
membershipFamilies :: [MembershipFamily]
membershipFamilies =
  [ MembershipFamily
      { membershipFamilyKey = key
      , membershipFamilyOwner = owner
      , membershipFamilyTags = tags
      , membershipFamilyCoordinateDigest = managedResourceCoordinateDigest descriptor
      }
  | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
  , let key = managedResourceKey descriptor
  , Just tags <- [coordinateMembershipTags (managedResourceCoordinate descriptor)]
  , not (null tags)
  , owner <-
      [ ownershipEdgeStackKey edge | edge <- registeredOwnershipEdges, ownershipEdgeResourceKey edge == key
      ]
  ]

-- | The facts a stack's manifest carries when it has just been created: the
-- entry set is a pure function of the stack key, and the read-back re-derives
-- and compares it, so this equals the declared set.
manifestFactsFromRegistry :: RegisteredResourceKey -> Either OwnershipManifestError ManifestFacts
manifestFactsFromRegistry stackKey =
  ( \entries ->
      ManifestFacts
        { manifestFactsStackKey = stackKey
        , manifestFactsScope = Nothing
        , manifestFactsEntries = entries
        }
  )
    <$> initialManifestEntries stackKey

-- | Attribute each escaped ARN, in first-seen order. A sweep row is one
-- (ARN, tag) pair, so a resource's tags are gathered by ARN first; a family
-- matches only when every tag it requires is present.
attributeEscapedRows
  :: ManifestFacts -> [TaggedResource] -> [(Text, Either UnattributedReason AttributedRow)]
attributeEscapedRows facts rows =
  [ (arn, classify arn (Map.findWithDefault [] arn tagsByArn))
  | arn <- arnsInOrder
  ]
 where
  arnsInOrder = nub (map (Text.pack . taggedResourceArn) rows)
  tagsByArn =
    Map.fromListWith
      (flip (++))
      [ ( Text.pack (taggedResourceArn row)
        , [(Text.pack (taggedResourceMatchedTagKey row), Text.pack (taggedResourceMatchedTagValue row))]
        )
      | row <- rows
      ]
  classify arn tags = case [family | family <- membershipFamilies, all (`elem` tags) (membershipFamilyTags family)] of
    [] -> Left NoFamilyTagsMatch
    [family] -> declared arn family
    families -> Left (AmbiguousFamilies (map membershipFamilyKey families))
  declared arn family =
    case [ entry
         | entry <- manifestFactsEntries facts
         , ownershipManifestEntryKey entry == membershipFamilyKey family
         ] of
      [] -> Left (FamilyMatchedButNotDeclared (membershipFamilyKey family))
      entry : _
        | ownershipManifestEntryCoordinateDigest entry /= membershipFamilyCoordinateDigest family ->
            Left (DeclaredCoordinateDigestDisagrees (membershipFamilyKey family))
        | membershipFamilyOwner family /= manifestFactsStackKey facts ->
            Left (FamilyMatchedButNotDeclared (membershipFamilyKey family))
        | otherwise ->
            Right
              AttributedRow
                { attributedArn = arn
                , attributedFamily = membershipFamilyKey family
                , attributedOwningStack = manifestFactsStackKey facts
                , attributedSuppliedScope = manifestFactsScope facts
                }

-- | Narration appended to a cascade sweep's rendering. It is empty unless the
-- sweep found escaped residue, it reads the registry alone (no manifest, no
-- Authority, no network), says so, and can neither change the verdict nor the
-- exit code.
renderEscapedAttributionNarration :: TagSweepVerdict -> String
renderEscapedAttributionNarration verdict =
  -- Only an escaped verdict has rows to name; matching it in a comprehension
  -- keeps the other two verdicts from sharing one rendered value.
  concat [narrate escaped | TagSweepEscaped _ escaped <- [verdict]]
 where
  narrate escaped = case attributedRows escaped of
    [] -> ""
    attributed ->
      unlines
        ( "Escaped residue matched to the families the registry declares in each owning stack's write-ahead manifest (no manifest was read; this is the registry's declaration, not a record of the run):"
            : concatMap renderAttributed attributed
        )
  owners = nub [ownershipEdgeStackKey edge | edge <- registeredOwnershipEdges]
  attributedRows escaped =
    [ row
    | owner <- owners
    , Right facts <- [manifestFactsFromRegistry owner]
    , (_, Right row) <- attributeEscapedRows facts escaped
    ]
  renderAttributed row =
    [ "  - "
        ++ Text.unpack (attributedArn row)
        ++ ": its tags match family `"
        ++ keyText (attributedFamily row)
        ++ "`, which the registry declares in the write-ahead manifest of stack `"
        ++ keyText (attributedOwningStack row)
        ++ "`."
    , "    Its destroy route is the registered family reap, which takes its name and tags from the registry coordinate and needs no cluster."
    , "    The run is not established: these tags are the same for every run of that cluster name, so this names a family and a stack and not a run."
    ]
  keyText = Text.unpack . registeredResourceKeyText
