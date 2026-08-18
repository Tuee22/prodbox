{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The terminal escape audit's retained-matcher and query catalog.
--
-- A terminal audit asks one question over a discovered inventory: is every
-- resource that still exists one this surface intends to keep?  Answering it
-- needs two catalogs the repository previously did not have.
--
-- * The __query catalog__ says what the audit asked for.  Anything outside the
--   queries it names is simply not in the audit's field of view, so a clean
--   verdict claims nothing about it.  The catalog is symbolic — tag keys and
--   tag pairs — so this module names no provider command and renders no argv.
-- * The __retained-matcher catalog__ says which resources are intentionally
--   retained.  Every matcher is an /exact/ identity: either a fully-qualified
--   ARN composed from the audited 'AwsScope' plus a validated name binding, or
--   a registered long-lived family whose membership coordinate comes from the
--   compiled lifecycle registry.
--
-- The distinction that matters is against the superseded tag classifier in
-- "Prodbox.Lifecycle.TagSweep".  That classifier read a retention marker off a
-- provider row and concluded the resource was retained, so any escapee that
-- acquired a retention tag was laundered into the retained set.  Here a runtime
-- tag can only witness membership in a family whose lifecycle class the
-- registry already fixed statically; it can never mint, change, or recover a
-- 'Prodbox.Lifecycle.Teardown.Model.LifecycleClass', and a resource that is not
-- named by an exact matcher is an escapee no matter what it is tagged with.
--
-- Retention is surface-indexed.  Total decommission retains nothing, because
-- destroying the retained set is what it is for; operational teardown owns the
-- operational credentials and therefore does not retain them; every other
-- surface retains the shared long-lived infrastructure.  The catalog is indexed
-- by its surface so one surface's retained-set digest cannot be presented as
-- another's.
module Prodbox.Lifecycle.Teardown.RetainedInventory
  ( -- * Declared retained families
    RetainedCategory (..)
  , retainedCategoryText
  , RetainedFamily (..)
  , retainedFamilyText
  , retainedFamilyCategory
  , RetainedCardinality (..)
  , retainedFamilyCardinality
  , RetainedDiscoverability (..)

    -- * The dynamic name binding
  , RetainedNameBinding
  , retainedStateBucketName
  , retainedCaptureBucketName
  , retainedSenderDomain
  , retainedClusterTagName
  , RetainedBindingError (..)
  , mkRetainedNameBinding

    -- * Matchers
  , RetainedMatchRule (..)
  , RetainedMatcher
  , retainedMatcherFamily
  , retainedMatcherCategory
  , retainedMatcherCardinality
  , retainedMatcherDiscoverability
  , retainedMatcherRule
  , retainedVolumeResourceType
  , retainedMatcherCreatorTags
  , retainedFamilyTaggingApiReach

    -- * The surface-indexed catalog
  , RetainedCatalog
  , retainedCatalogSurface
  , retainedCatalogAwsScope
  , retainedCatalogMatchers
  , RetainedCatalogError (..)
  , retainedCatalogFor
  , retainedSetDigestFor

    -- * The query catalog
  , TerminalAuditQuery (..)
  , terminalAuditQueryCatalog
  , terminalAuditQueryDigestFor
  , clusterOwnershipTagPrefix
  , auditQueryCoversTag

    -- * Classification
  , RetainedClassification (..)
  , RetainedPartition (..)
  , classifyRetainedResource
  , classifyRetainedInventory
  , terminalAuditResultFor
  )
where

import Data.List (nub, sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.AwsInventory
  ( Arn
  , ArnError
  , AwsInventory
  , AwsResource (..)
  , AwsResourceType (..)
  , arnText
  , awsInventoryResources
  , mkArn
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass
  , AwsCredentialDescriptor
  , CredentialLifetime (..)
  , awsCredentialDescriptorClass
  , awsCredentialDescriptorLifetime
  , awsCredentialDescriptorPolicy
  , awsCredentialDescriptorPrincipal
  , managedAwsCredentialInventory
  )
import Prodbox.Lifecycle.OwnedResourceTags
  ( longLivedPulumiStateBucketTags
  , sesCaptureBucketTags
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , CleanupSurfaceWitness
  , LifecycleClass (..)
  , ManagedResourceCoordinate (..)
  , ObservationFailure (..)
  , RegisteredResourceKey
  , RegistryRevision (..)
  , cleanupSurfaceFromWitness
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditQueryDigest (..)
  , TerminalAuditResult (..)
  , TerminalAuditRetainedSetDigest (..)
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( RegisteredIdentity
  , lifecycleRegistry
  , lifecycleRegistryRevision
  , registeredIdentityCoordinate
  , registeredIdentityKey
  , registeredIdentityLifecycleClass
  )
import Prodbox.Lifecycle.Teardown.TaggingApiReach
  ( TaggingApiReach (..)
  , globalServiceTaggingRegion
  , unreachedGlobalService
  , unreachedGlobalServicesFrom
  )

-- | The four declared retained categories.  They exist so an operator-facing
-- report can group the retained set by why it survives, and so a catalog
-- completeness test can assert that no category silently lost its members.
data RetainedCategory
  = -- | Long-lived object storage: the Pulumi state backend and the SES
    -- capture bucket.
    RetainedS3Category
  | -- | The retained SES sending and receiving configuration.
    RetainedSesCategory
  | -- | Shared IAM identities: the operational principal and every managed
    -- credential family whose lifetime outlives the audited surface.
    RetainedSharedIdentityCategory
  | -- | A registered long-lived family of unbounded cardinality, matched by
    -- the compiled registry's own membership coordinate.
    RetainedDynamicFamilyCategory
  deriving (Bounded, Enum, Eq, Ord, Show)

retainedCategoryText :: RetainedCategory -> Text
retainedCategoryText category = case category of
  RetainedS3Category -> "s3"
  RetainedSesCategory -> "ses"
  RetainedSharedIdentityCategory -> "shared"
  RetainedDynamicFamilyCategory -> "dynamic"

-- | One declared retained family.  A family is a reason for retention, not a
-- resource: 'RetainedRegisteredLongLivedFamily' can cover any number of
-- volumes, while every other constructor covers exactly one resource.
data RetainedFamily
  = RetainedLongLivedPulumiStateBucket
  | RetainedSesCaptureBucket
  | RetainedSesDomainIdentity
  | RetainedSesReceiptRuleSet
  | RetainedOperationalIamPrincipal
  | RetainedManagedCredentialPrincipal !AwsCredentialClass
  | RetainedManagedCredentialPolicy !AwsCredentialClass
  | RetainedRegisteredLongLivedFamily !RegisteredResourceKey
  deriving (Eq, Ord, Show)

retainedFamilyText :: RetainedFamily -> Text
retainedFamilyText family = case family of
  RetainedLongLivedPulumiStateBucket -> "long-lived-pulumi-state-bucket"
  RetainedSesCaptureBucket -> "ses-capture-bucket"
  RetainedSesDomainIdentity -> "ses-domain-identity"
  RetainedSesReceiptRuleSet -> "ses-receipt-rule-set"
  RetainedOperationalIamPrincipal -> "operational-iam-principal"
  RetainedManagedCredentialPrincipal credentialClass ->
    "managed-credential-principal/" <> Text.pack (show credentialClass)
  RetainedManagedCredentialPolicy credentialClass ->
    "managed-credential-policy/" <> Text.pack (show credentialClass)
  RetainedRegisteredLongLivedFamily key ->
    "registered-long-lived-family/" <> registeredResourceKeyText key

retainedFamilyCategory :: RetainedFamily -> RetainedCategory
retainedFamilyCategory family = case family of
  RetainedLongLivedPulumiStateBucket -> RetainedS3Category
  RetainedSesCaptureBucket -> RetainedS3Category
  RetainedSesDomainIdentity -> RetainedSesCategory
  RetainedSesReceiptRuleSet -> RetainedSesCategory
  RetainedOperationalIamPrincipal -> RetainedSharedIdentityCategory
  RetainedManagedCredentialPrincipal {} -> RetainedSharedIdentityCategory
  RetainedManagedCredentialPolicy {} -> RetainedSharedIdentityCategory
  RetainedRegisteredLongLivedFamily {} -> RetainedDynamicFamilyCategory

-- | How many resources one family may legitimately cover.
data RetainedCardinality
  = ExactlyOneRetained
  | AnyNumberRetained
  deriving (Bounded, Enum, Eq, Ord, Show)

retainedFamilyCardinality :: RetainedFamily -> RetainedCardinality
retainedFamilyCardinality family = case family of
  RetainedRegisteredLongLivedFamily {} -> AnyNumberRetained
  _ -> ExactlyOneRetained

-- | Whether the query catalog can return this family at all.  An untagged
-- resource is outside the audit's field of view: it cannot be an escapee, and
-- its absence from a discovery result is not evidence that it is gone.
--
-- This is __derived__ rather than authored.  It was a per-matcher flag until
-- the SES capture bucket disproved that arrangement: the catalog declared the
-- family discoverable while its supported writer — the Provider Worker\'s
-- @ReconcileSesCaptureBucket@ intent — created the bucket carrying no tag at
-- all, so the audit could neither confirm the retained bucket present nor find
-- it escaped, and the declared-but-absent report fired forever.  Discoverability
-- is a consequence of three facts — what the writer authors, what the queries
-- ask for, and whether the audited region answers for the family\'s service —
-- and is computed from exactly those.
data RetainedDiscoverability
  = DiscoverableByAuditQuery
  | NotDiscoverableByAuditQuery
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The Tagging API reach of the resource each retained family names.
--
-- Total over the family universe, so a new retained family must state its
-- reach before it can be declared discoverable in any region.  The IAM arms
-- are the load-bearing ones: they author no tag today, so the region axis
-- changes nothing for them /now/ — but the moment a writer starts tagging the
-- operational principal, an audit taken outside 'globalServiceTaggingRegion'
-- would report it permanently absent-declared.  Deriving discoverability
-- through this map makes that impossible rather than unlikely.
retainedFamilyTaggingApiReach :: RetainedFamily -> TaggingApiReach
retainedFamilyTaggingApiReach family = case family of
  RetainedLongLivedPulumiStateBucket -> ReachableWhenTagged
  RetainedSesCaptureBucket -> ReachableWhenTagged
  RetainedSesDomainIdentity ->
    UntaggableByTaggingApi "a classic SES identity accepts no tags"
  RetainedSesReceiptRuleSet ->
    UntaggableByTaggingApi "a classic SES receipt rule set accepts no tags"
  RetainedOperationalIamPrincipal -> ReachableWhenTaggedFromGlobalRegion "iam"
  RetainedManagedCredentialPrincipal {} -> ReachableWhenTaggedFromGlobalRegion "iam"
  RetainedManagedCredentialPolicy {} -> ReachableWhenTaggedFromGlobalRegion "iam"
  RetainedRegisteredLongLivedFamily {} -> ReachableWhenTagged

-- | The prodbox-owned tags this family\'s production writer authors.
--
-- An exact-ARN family carries whatever its writer puts on the resource; a
-- registered family carries its membership coordinate, which the compiled
-- registry owns.  An empty list means no writer authors a tag the audit could
-- ask about — either the resource type accepts none, or the identity is
-- registry-owned rather than tag-discovered.
retainedMatcherCreatorTags :: RetainedFamily -> RetainedMatchRule -> [(Text, Text)]
retainedMatcherCreatorTags family rule = case rule of
  RetainedMatchFamilyCoordinate _ tagKey tagValue -> [(tagKey, tagValue)]
  RetainedMatchExactArn _ -> case family of
    RetainedLongLivedPulumiStateBucket -> longLivedPulumiStateBucketTags
    RetainedSesCaptureBucket -> sesCaptureBucketTags
    RetainedSesDomainIdentity -> []
    RetainedSesReceiptRuleSet -> []
    RetainedOperationalIamPrincipal -> []
    RetainedManagedCredentialPrincipal {} -> []
    RetainedManagedCredentialPolicy {} -> []
    RetainedRegisteredLongLivedFamily {} -> []

-- | The operator-configured names the retained set depends on.  The catalog
-- refuses to be built from raw text: every field passes 'mkRetainedNameBinding'
-- first, so a blank or whitespace-bearing value cannot compose an ARN that
-- silently matches nothing.
data RetainedNameBinding = RetainedNameBinding
  { internalStateBucketName :: !Text
  , internalCaptureBucketName :: !Text
  , internalSenderDomain :: !Text
  , internalClusterTagName :: !Text
  }
  deriving (Eq, Ord, Show)

retainedStateBucketName :: RetainedNameBinding -> Text
retainedStateBucketName = internalStateBucketName

retainedCaptureBucketName :: RetainedNameBinding -> Text
retainedCaptureBucketName = internalCaptureBucketName

retainedSenderDomain :: RetainedNameBinding -> Text
retainedSenderDomain = internalSenderDomain

retainedClusterTagName :: RetainedNameBinding -> Text
retainedClusterTagName = internalClusterTagName

data RetainedBindingError
  = RetainedBindingFieldEmpty !Text
  | RetainedBindingFieldNotCanonical !Text !Text
  deriving (Eq, Show)

-- | Build the binding.  Field names are carried in the error so a
-- configuration defect names the field it came from.
mkRetainedNameBinding
  :: Text
  -- ^ @pulumi_state_backend.bucket_name@
  -> Text
  -- ^ @ses.capture_bucket@
  -> Text
  -- ^ @ses.sender_domain@
  -> Text
  -- ^ the per-run EKS cluster name used by the ownership tag query
  -> Either RetainedBindingError RetainedNameBinding
mkRetainedNameBinding stateBucket captureBucket senderDomain clusterName = do
  validatedState <- canonicalField "pulumi_state_backend.bucket_name" stateBucket
  validatedCapture <- canonicalField "ses.capture_bucket" captureBucket
  validatedDomain <- canonicalField "ses.sender_domain" senderDomain
  validatedCluster <- canonicalField "aws-eks.cluster_name" clusterName
  Right
    RetainedNameBinding
      { internalStateBucketName = validatedState
      , internalCaptureBucketName = validatedCapture
      , internalSenderDomain = validatedDomain
      , internalClusterTagName = validatedCluster
      }

canonicalField :: Text -> Text -> Either RetainedBindingError Text
canonicalField field raw
  | Text.null raw = Left (RetainedBindingFieldEmpty field)
  | raw /= Text.strip raw = Left (RetainedBindingFieldNotCanonical field raw)
  | Text.any (`elem` (" \t\r\n\NUL" :: String)) raw =
      Left (RetainedBindingFieldNotCanonical field raw)
  | otherwise = Right raw

-- | How one matcher recognizes its resource.
data RetainedMatchRule
  = -- | Exactly this ARN, composed from the audited scope and the binding.
    RetainedMatchExactArn !Arn
  | -- | Membership in a registered long-lived family: the resource type the
    -- audit normalizes volumes to, plus the family's own membership
    -- coordinate as the compiled registry declares it.
    RetainedMatchFamilyCoordinate !AwsResourceType !Text !Text
  deriving (Eq, Ord, Show)

-- | The canonical resource type a normalized EBS volume carries.  The audit
-- adapter is responsible for producing this exact rendering; a matcher that
-- named a family coordinate without also pinning the type would let an
-- arbitrary resource wearing the family tag into the retained set.
retainedVolumeResourceType :: AwsResourceType
retainedVolumeResourceType = AwsResourceType "ec2:volume"

data RetainedMatcher = RetainedMatcher
  { internalMatcherFamily :: !RetainedFamily
  , internalMatcherDiscoverability :: !RetainedDiscoverability
  , internalMatcherRule :: !RetainedMatchRule
  }
  deriving (Eq, Ord, Show)

retainedMatcherFamily :: RetainedMatcher -> RetainedFamily
retainedMatcherFamily = internalMatcherFamily

retainedMatcherCategory :: RetainedMatcher -> RetainedCategory
retainedMatcherCategory = retainedFamilyCategory . internalMatcherFamily

retainedMatcherCardinality :: RetainedMatcher -> RetainedCardinality
retainedMatcherCardinality = retainedFamilyCardinality . internalMatcherFamily

retainedMatcherDiscoverability :: RetainedMatcher -> RetainedDiscoverability
retainedMatcherDiscoverability = internalMatcherDiscoverability

retainedMatcherRule :: RetainedMatcher -> RetainedMatchRule
retainedMatcherRule = internalMatcherRule

-- | The catalog for one cleanup surface.  Constructors stay private so a
-- retained set can only come from 'retainedCatalogFor'.
data RetainedCatalog (surface :: CleanupSurface) = RetainedCatalog
  { internalCatalogSurface :: !CleanupSurface
  , internalCatalogAwsScope :: !AwsScope
  , internalCatalogMatchers :: ![RetainedMatcher]
  }
  deriving (Eq, Show)

retainedCatalogSurface :: RetainedCatalog surface -> CleanupSurface
retainedCatalogSurface = internalCatalogSurface

-- | The AWS account and region the catalog's exact ARNs were composed for.  A
-- consumer joins this to its own proof of scope, so a catalog built for one
-- account cannot supply the retained set of another.
retainedCatalogAwsScope :: RetainedCatalog surface -> AwsScope
retainedCatalogAwsScope = internalCatalogAwsScope

retainedCatalogMatchers :: RetainedCatalog surface -> [RetainedMatcher]
retainedCatalogMatchers = internalCatalogMatchers

data RetainedCatalogError
  = -- | A composed ARN was not well formed.  Carries the family it was being
    -- composed for so the defective input is identifiable.
    RetainedCatalogArnInvalid !RetainedFamily !ArnError
  | -- | Two matchers recognize the same resource, so classification would not
    -- be a function.
    RetainedCatalogDuplicateRule !RetainedMatchRule
  | -- | The compiled registry declares a long-lived family whose coordinate
    -- is not a family-membership coordinate, so no membership rule exists.
    RetainedCatalogUnmatchableFamily !RegisteredResourceKey
  deriving (Eq, Show)

-- | Build the retained catalog for one surface.
--
-- The surface witness fixes the index, so a catalog built for cascade cannot
-- be handed to a total-decommission audit.  Total decommission retains
-- nothing; operational teardown owns the operational principal and the
-- operational credential families and therefore does not retain them.
retainedCatalogFor
  :: CleanupSurfaceWitness surface
  -> AwsScope
  -> RetainedNameBinding
  -> Either RetainedCatalogError (RetainedCatalog surface)
retainedCatalogFor surfaceWitness scope binding = do
  declared <- surfaceRules
  let matchers =
        map (uncurry (mkRetainedMatcher (awsScopeRegion scope) queries)) declared
  case duplicateRules matchers of
    duplicate : _ -> Left (RetainedCatalogDuplicateRule duplicate)
    [] ->
      Right
        RetainedCatalog
          { internalCatalogSurface = surface
          , internalCatalogAwsScope = scope
          , internalCatalogMatchers = sort matchers
          }
 where
  surface = cleanupSurfaceFromWitness surfaceWitness

  queries = terminalAuditQueryCatalog binding

  surfaceRules
    | surface == TotalDecommission = Right []
    | otherwise = do
        storage <- storageRules scope binding
        identities <- identityRules surface scope
        families <- registeredFamilyRules
        Right (storage ++ identities ++ families)

  duplicateRules matchers =
    [ rule
    | rule <- nub (map internalMatcherRule matchers)
    , length (filter ((== rule) . internalMatcherRule) matchers) > 1
    ]

-- | Assemble one matcher, deriving its discoverability from the tags its
-- writer authors, the queries the audit issues, and whether the audited region
-- answers for the family's service.
--
-- All three are necessary and none is sufficient: an untagged family is
-- returned by no query anywhere, a tagged family outside the query catalog is
-- never asked for, and a tagged, queried, global-service family is still
-- returned by nothing when the audit issues its queries in another region.
mkRetainedMatcher
  :: AwsRegion
  -> [TerminalAuditQuery]
  -> RetainedFamily
  -> RetainedMatchRule
  -> RetainedMatcher
mkRetainedMatcher region queries family rule =
  RetainedMatcher
    { internalMatcherFamily = family
    , internalMatcherDiscoverability =
        if tagged && regionAnswers
          then DiscoverableByAuditQuery
          else NotDiscoverableByAuditQuery
    , internalMatcherRule = rule
    }
 where
  tagged =
    any (auditQueryCoversTag queries) (retainedMatcherCreatorTags family rule)

  regionAnswers =
    case unreachedGlobalService region (retainedFamilyTaggingApiReach family) of
      Nothing -> True
      Just _ -> False

storageRules
  :: AwsScope
  -> RetainedNameBinding
  -> Either RetainedCatalogError [(RetainedFamily, RetainedMatchRule)]
storageRules scope binding =
  sequence
    [ exactRule
        RetainedLongLivedPulumiStateBucket
        (bucketArnText (internalStateBucketName binding))
    , exactRule
        RetainedSesCaptureBucket
        (bucketArnText (internalCaptureBucketName binding))
    , exactRule
        RetainedSesDomainIdentity
        (sesArnText scope "identity" (internalSenderDomain binding))
    , exactRule
        RetainedSesReceiptRuleSet
        (sesArnText scope "receipt-rule-set" retainedReceiptRuleSetName)
    ]

-- | Every shared IAM identity the audited surface keeps.
--
-- Managed credential families come from 'managedAwsCredentialInventory', so a
-- new credential class joins the retained set (or, when it is run-scoped,
-- stays outside it) without a second list to keep in step.
identityRules
  :: CleanupSurface
  -> AwsScope
  -> Either RetainedCatalogError [(RetainedFamily, RetainedMatchRule)]
identityRules surface scope =
  sequence
    ( [ exactRule
          RetainedOperationalIamPrincipal
          (iamArnText scope "user" operationalIamPrincipalName)
      | surface /= OperationalTeardown
      ]
        ++ concat
          [ [ exactRule
                (RetainedManagedCredentialPrincipal (awsCredentialDescriptorClass descriptor))
                (iamArnText scope "user" (awsCredentialDescriptorPrincipal descriptor))
            , exactRule
                (RetainedManagedCredentialPolicy (awsCredentialDescriptorClass descriptor))
                (iamArnText scope "policy" (awsCredentialDescriptorPolicy descriptor))
            ]
          | descriptor <- managedAwsCredentialInventory
          , retainsCredentialLifetime surface descriptor
          ]
    )

-- | Which managed credential lifetimes survive one surface.  A run-scoped
-- credential never survives: it is per-run by construction, so finding one
-- after a cleanup is an escape.
retainsCredentialLifetime :: CleanupSurface -> AwsCredentialDescriptor -> Bool
retainsCredentialLifetime surface descriptor =
  case awsCredentialDescriptorLifetime descriptor of
    RunScopedCredential -> False
    OperationalCredential -> surface /= OperationalTeardown
    LongLivedCredential -> True
    RetainedCustodyCredential -> True

-- | Long-lived registry entries contribute family-membership matchers.  The
-- membership coordinate is read from the compiled registry, never asserted by
-- a caller, so the family a runtime tag can witness is exactly the family the
-- registry statically classified 'LongLived'.
registeredFamilyRules
  :: Either RetainedCatalogError [(RetainedFamily, RetainedMatchRule)]
registeredFamilyRules =
  traverse familyRule (filter isLongLived lifecycleRegistry)
 where
  isLongLived :: RegisteredIdentity -> Bool
  isLongLived identity =
    registeredIdentityLifecycleClass identity == Just LongLived

  familyRule identity =
    case registeredIdentityCoordinate identity of
      AwsEbsRetainedFamilyCoordinate tagKey tagValue ->
        Right
          ( RetainedRegisteredLongLivedFamily (registeredIdentityKey identity)
          , RetainedMatchFamilyCoordinate retainedVolumeResourceType tagKey tagValue
          )
      _ -> Left (RetainedCatalogUnmatchableFamily (registeredIdentityKey identity))

exactRule
  :: RetainedFamily
  -> Text
  -> Either RetainedCatalogError (RetainedFamily, RetainedMatchRule)
exactRule family raw = case mkArn raw of
  Left err -> Left (RetainedCatalogArnInvalid family err)
  Right arn -> Right (family, RetainedMatchExactArn arn)

bucketArnText :: Text -> Text
bucketArnText bucket = "arn:aws:s3:::" <> bucket

sesArnText :: AwsScope -> Text -> Text -> Text
sesArnText scope resourcePath name =
  Text.intercalate
    ":"
    [ "arn"
    , "aws"
    , "ses"
    , regionText (awsScopeRegion scope)
    , accountText (awsScopeAccountId scope)
    , resourcePath <> "/" <> name
    ]

iamArnText :: AwsScope -> Text -> Text -> Text
iamArnText scope resourcePath name =
  Text.intercalate
    ":"
    [ "arn"
    , "aws"
    , "iam"
    , ""
    , accountText (awsScopeAccountId scope)
    , resourcePath <> "/" <> name
    ]

accountText :: AwsAccountId -> Text
accountText (AwsAccountId value) = value

regionText :: AwsRegion -> Text
regionText (AwsRegion value) = value

-- | The receive rule set the retained @aws-ses@ program declares.  It is a
-- fixed program constant rather than operator configuration, so it is not part
-- of 'RetainedNameBinding'.
retainedReceiptRuleSetName :: Text
retainedReceiptRuleSetName = "prodbox-receive-rule-set"

-- | The operational IAM principal.  Mirrors @Prodbox.Aws.prodboxIamUserName@,
-- which lives in an effectful module this pure catalog must not import; a unit
-- case pins the two together so they cannot drift.
operationalIamPrincipalName :: Text
operationalIamPrincipalName = "prodbox"

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

-- | Digest the retained set.  The rendering is canonical, NUL-framed, and
-- carries the surface and registry revision, so a catalog built for another
-- surface or against another registry revision produces a different digest and
-- is refused where the audit scope is checked.
retainedSetDigestFor :: RetainedCatalog surface -> TerminalAuditRetainedSetDigest
retainedSetDigestFor catalog =
  TerminalAuditRetainedSetDigest
    (TextEncoding.decodeUtf8 (hexSha256 (TextEncoding.encodeUtf8 canonical)))
 where
  canonical =
    Text.intercalate
      "\NUL"
      ( "terminal-audit-retained-set/v1"
          : registryRevisionText lifecycleRegistryRevision
          : Text.pack (show (internalCatalogSurface catalog))
          : accountText (awsScopeAccountId (internalCatalogAwsScope catalog))
          : regionText (awsScopeRegion (internalCatalogAwsScope catalog))
          : map renderMatcher (sort (internalCatalogMatchers catalog))
      )

  renderMatcher matcher =
    Text.intercalate
      "\GS"
      [ retainedCategoryText (retainedMatcherCategory matcher)
      , retainedFamilyText (internalMatcherFamily matcher)
      , Text.pack (show (retainedMatcherCardinality matcher))
      , Text.pack (show (internalMatcherDiscoverability matcher))
      , renderRule (internalMatcherRule matcher)
      ]

  renderRule rule = case rule of
    RetainedMatchExactArn arn -> "exact-arn/" <> arnText arn
    RetainedMatchFamilyCoordinate (AwsResourceType resourceType) tagKey tagValue ->
      Text.intercalate
        "/"
        ["family-coordinate", resourceType, tagKey, tagValue]

-- | One discovery query.  Symbolic on purpose: this module names the tag
-- families the audit asks about and never the provider command that asks.
data TerminalAuditQuery
  = AuditQueryTagKey !Text
  | AuditQueryTagPair !Text !Text
  deriving (Eq, Ord, Show)

-- | The queries whose union is the audit's field of view.  Every prodbox-owned
-- tag family appears, so a retained resource carrying any of them is returned
-- and classified rather than falling outside the audit unseen.
terminalAuditQueryCatalog :: RetainedNameBinding -> [TerminalAuditQuery]
terminalAuditQueryCatalog binding =
  sort
    [ AuditQueryTagPair "prodbox.io/managed-by" "prodbox"
    , AuditQueryTagKey "prodbox.io/role"
    , AuditQueryTagKey "prodbox.io/substrate"
    , AuditQueryTagKey "prodbox.io/lifecycle"
    , AuditQueryTagKey ("kubernetes.io/cluster/" <> internalClusterTagName binding)
    ]

-- | The per-run Kubernetes cluster-ownership tag family.
--
-- Its full key embeds the cluster name, which the query catalog binds at run
-- time and a provisioning program templates, so key equality is the wrong
-- relation for this one family and prefix membership is the right one.
clusterOwnershipTagPrefix :: Text
clusterOwnershipTagPrefix = "kubernetes.io/cluster/"

-- | Would the audit\'s query catalog return a resource carrying this tag?
--
-- This is the whole of the audit\'s field of view: a resource carrying no
-- covered tag is returned by no query, so it can neither be classified retained
-- nor found escaped.
auditQueryCoversTag :: [TerminalAuditQuery] -> (Text, Text) -> Bool
auditQueryCoversTag queries (key, value) = any covers queries
 where
  covers query = case query of
    AuditQueryTagKey queryKey ->
      queryKey == key || bothClusterOwnership queryKey
    AuditQueryTagPair queryKey queryValue ->
      queryKey == key && queryValue == value

  bothClusterOwnership queryKey =
    clusterOwnershipTagPrefix `Text.isPrefixOf` queryKey
      && clusterOwnershipTagPrefix `Text.isPrefixOf` key

terminalAuditQueryDigestFor :: [TerminalAuditQuery] -> TerminalAuditQueryDigest
terminalAuditQueryDigestFor queries =
  TerminalAuditQueryDigest
    (TextEncoding.decodeUtf8 (hexSha256 (TextEncoding.encodeUtf8 canonical)))
 where
  canonical =
    Text.intercalate
      "\NUL"
      ("terminal-audit-query/v1" : map renderQuery (sort (nub queries)))

  renderQuery query = case query of
    AuditQueryTagKey key -> "tag-key/" <> key
    AuditQueryTagPair key value -> Text.intercalate "/" ["tag-pair", key, value]

-- | What the catalog says about one discovered resource.
data RetainedClassification
  = RetainedByDesign !RetainedFamily
  | EscapedResidue
  deriving (Eq, Show)

-- | The audit's three answers over a discovered inventory.
data RetainedPartition = RetainedPartition
  { retainedPartitionRetained :: ![(AwsResource, RetainedFamily)]
  , retainedPartitionEscaped :: ![AwsResource]
  , retainedPartitionAbsentDeclared :: ![RetainedFamily]
  -- ^ Discoverable families of cardinality one that the query catalog
  -- should have returned and did not.  This is a retention defect, not an
  -- escape, and is reported separately so the two are never conflated.
  }
  deriving (Eq, Show)

classifyRetainedResource
  :: RetainedCatalog surface -> AwsResource -> RetainedClassification
classifyRetainedResource catalog resource =
  case filter (matchesResource resource) (internalCatalogMatchers catalog) of
    matcher : _ -> RetainedByDesign (internalMatcherFamily matcher)
    [] -> EscapedResidue

matchesResource :: AwsResource -> RetainedMatcher -> Bool
matchesResource resource matcher = case internalMatcherRule matcher of
  RetainedMatchExactArn arn -> awsResourceArn resource == arn
  RetainedMatchFamilyCoordinate resourceType tagKey tagValue ->
    awsResourceType resource == resourceType
      && Map.lookup tagKey (awsResourceTags resource) == Just tagValue

classifyRetainedInventory
  :: RetainedCatalog surface -> AwsInventory -> RetainedPartition
classifyRetainedInventory catalog inventory =
  RetainedPartition
    { retainedPartitionRetained = retained
    , retainedPartitionEscaped = escaped
    , retainedPartitionAbsentDeclared = absentDeclared
    }
 where
  classified =
    [ (resource, classifyRetainedResource catalog resource)
    | resource <- awsInventoryResources inventory
    ]

  retained =
    [ (resource, family)
    | (resource, RetainedByDesign family) <- classified
    ]

  escaped = [resource | (resource, EscapedResidue) <- classified]

  observedFamilies = map snd retained

  absentDeclared =
    sort
      [ family
      | matcher <- internalCatalogMatchers catalog
      , internalMatcherDiscoverability matcher == DiscoverableByAuditQuery
      , retainedMatcherCardinality matcher == ExactlyOneRetained
      , let family = internalMatcherFamily matcher
      , family `notElem` observedFamilies
      ]

-- | Lower a discovered inventory to the audit's typed result.  Only an
-- inventory with no escapees may claim clean; a missing declared retained
-- resource does not make the surface dirty and therefore does not enter this
-- verdict, which is why callers read 'retainedPartitionAbsentDeclared'
-- separately.
--
-- __Clean is additionally bounded by the audited region.__  The audit issues
-- its queries in the audited scope's own region, and the Tagging API returns
-- global-service resources (IAM, Route 53) only from
-- 'globalServiceTaggingRegion'.  An audit taken elsewhere therefore asked
-- about none of the global-service families this repository provisions, and
-- finding no escapee among the resources it /did/ ask for is not evidence that
-- none exists.  That is a non-answer, so it is reported as one: the escaped
-- and clean arms are unchanged, and the would-be-clean arm becomes
-- 'TerminalAuditUnobservable' naming each unqueried service.  An escape found
-- is still an escape — a blind spot cannot make a discovered escapee retained
-- — so only the clean arm is bounded.
terminalAuditResultFor
  :: RetainedCatalog surface -> AwsInventory -> TerminalAuditResult
terminalAuditResultFor catalog inventory =
  case NonEmpty.nonEmpty (retainedPartitionEscaped partition) of
    Just escaped -> TerminalAuditFoundEscapes inventory escaped
    Nothing -> case NonEmpty.nonEmpty regionBlindSpots of
      Nothing -> TerminalAuditConfirmedClean inventory
      Just failures -> TerminalAuditUnobservable inventory failures
 where
  partition = classifyRetainedInventory catalog inventory

  auditedRegion = awsScopeRegion (internalCatalogAwsScope catalog)

  regionBlindSpots =
    [ ObservationFailure
        ( "terminal-audit/tagging-api-query: the Resource Groups Tagging API \
          \returns "
            <> service
            <> " resources only from the "
            <> globalServiceTaggingRegion
            <> " endpoint, and this audit issued its queries in "
            <> regionText auditedRegion
            <> ", so no "
            <> service
            <> " resource was asked about and the absence of one from this \
               \inventory is not evidence that it is gone."
        )
    | service <- unreachedGlobalServicesFrom auditedRegion
    ]
