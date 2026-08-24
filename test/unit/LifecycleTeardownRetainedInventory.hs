{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.84: the terminal retained matcher and query catalog.
--
-- The catalog exists so a terminal escape audit can tell an intentionally
-- retained resource from an escapee.  The superseded classifier in
-- "Prodbox.Lifecycle.TagSweep" read a retention marker off a provider row, so
-- anything wearing that marker was retained; these cases pin the replacement's
-- exact-identity rule, its surface indexing, and the two failures the old
-- classifier could not express — an escapee wearing a retention tag, and a
-- declared retained resource that is missing.
module LifecycleTeardownRetainedInventory
  ( lifecycleTeardownRetainedInventorySuite
  )
where

import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws (prodboxIamUserName)
import Prodbox.Lifecycle.AwsInventory
  ( Arn
  , AwsInventory
  , AwsResource (..)
  , AwsResourceCoordinate (..)
  , AwsResourceType (..)
  , AwsTag (..)
  , AwsTagRow (..)
  , arnText
  , mkArn
  , normalizeAwsTagRows
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , awsCredentialDescriptor
  , awsCredentialDescriptorPrincipal
  )
import Prodbox.Lifecycle.OwnedResourceTags
  ( longLivedPulumiStateBucketTags
  , sesCaptureBucketTags
  )
import Prodbox.Lifecycle.TagSweep
  ( TaggedResource (..)
  , partitionRetainedLongLived
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , ObservationFailure (..)
  , RegisteredResourceKey (..)
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditResult (..)
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedBindingError (..)
  , RetainedCardinality (..)
  , RetainedCatalog
  , RetainedCategory (..)
  , RetainedClassification (..)
  , RetainedDiscoverability (..)
  , RetainedFamily (..)
  , RetainedMatchRule (..)
  , RetainedNameBinding
  , RetainedPartition (..)
  , TerminalAuditQuery (..)
  , auditQueryCoversTag
  , classifyRetainedInventory
  , classifyRetainedResource
  , mkRetainedNameBinding
  , retainedCatalogAwsScope
  , retainedCatalogFor
  , retainedCatalogMatchers
  , retainedCatalogSurface
  , retainedFamilyCardinality
  , retainedFamilyTaggingApiReach
  , retainedMatcherCategory
  , retainedMatcherCreatorTags
  , retainedMatcherDiscoverability
  , retainedMatcherFamily
  , retainedMatcherRule
  , retainedSetDigestFor
  , retainedVolumeResourceType
  , terminalAuditQueryCatalog
  , terminalAuditQueryDigestFor
  , terminalAuditResultFor
  )
import Prodbox.Lifecycle.Teardown.TaggingApiReach
  ( TaggingApiReach (..)
  , globalServiceTaggingRegion
  , globalServicesRequiringGlobalRegion
  )
import Prodbox.Ses.Readiness (sesReceiveRuleSetName)
import TestSupport

lifecycleTeardownRetainedInventorySuite :: SuiteBuilder ()
lifecycleTeardownRetainedInventorySuite =
  describe "Sprint 4.84 terminal retained matcher catalog" $ do
    describe "the name binding" $ do
      it "refuses an empty or uncanonical configured name, naming the field" $ do
        mkRetainedNameBinding "" captureBucket senderDomain clusterName
          `shouldBe` Left
            (RetainedBindingFieldEmpty "pulumi_state_backend.bucket_name")
        mkRetainedNameBinding stateBucket " padded " senderDomain clusterName
          `shouldBe` Left
            (RetainedBindingFieldNotCanonical "ses.capture_bucket" " padded ")
        mkRetainedNameBinding stateBucket captureBucket "a domain" clusterName
          `shouldBe` Left
            (RetainedBindingFieldNotCanonical "ses.sender_domain" "a domain")

    describe "the catalog" $ do
      it "covers all four declared categories" $ do
        sort (map retainedMatcherCategory (retainedCatalogMatchers cascadeCatalog))
          `shouldSatisfy` \categories ->
            all (`elem` categories) [minBound .. maxBound :: RetainedCategory]

      it "carries the audited scope and surface it was composed for" $ do
        retainedCatalogSurface cascadeCatalog `shouldBe` Cascade
        retainedCatalogAwsScope cascadeCatalog `shouldBe` auditedScope

      it "retains nothing under total decommission" $
        retainedCatalogMatchers totalDecommissionCatalog `shouldBe` []

      it "drops the operational principal on the surface that owns it" $ do
        let cascadeFamilies = catalogFamilies cascadeCatalog
            operationalFamilies = catalogFamilies operationalTeardownCatalog
        cascadeFamilies `shouldSatisfy` elem RetainedOperationalIamPrincipal
        operationalFamilies
          `shouldSatisfy` notElem RetainedOperationalIamPrincipal
        cascadeFamilies
          `shouldSatisfy` elem
            (RetainedManagedCredentialPrincipal LifecycleProviderCredential)
        operationalFamilies
          `shouldSatisfy` notElem
            (RetainedManagedCredentialPrincipal LifecycleProviderCredential)

      it "never retains a run-scoped credential family on any surface" $ do
        let runScoped =
              RetainedManagedCredentialPrincipal AwsRunCertManagerDns01Credential
        catalogFamilies cascadeCatalog `shouldSatisfy` notElem runScoped
        catalogFamilies operationalTeardownCatalog
          `shouldSatisfy` notElem runScoped
        catalogFamilies totalDecommissionCatalog
          `shouldSatisfy` notElem runScoped

      it "declares the long-lived EBS family and only that family as dynamic" $
        [ family
        | family <- catalogFamilies cascadeCatalog
        , retainedFamilyCardinality family == AnyNumberRetained
        ]
          `shouldBe` [RetainedRegisteredLongLivedFamily AwsEbsProductionRetainedKey]

      it "mirrors the operational IAM principal name" $
        prodboxIamUserName `shouldBe` ("prodbox" :: Text)

      it "composes the SES rule-set matcher from the program's own rule-set name" $
        -- The catalog cannot import the effectful module that owns this name, so
        -- the two would drift silently: a renamed rule set would leave the
        -- retained matcher composing an ARN for an identity that no longer
        -- exists, and the retained-set digest encoding it.
        [ arnText arn
        | matcher <- retainedCatalogMatchers cascadeCatalog
        , retainedMatcherFamily matcher == RetainedSesReceiptRuleSet
        , RetainedMatchExactArn arn <- [retainedMatcherRule matcher]
        ]
          `shouldBe` [ ("arn:aws:ses:" <> (fixtureAwsRegion FixtureUsEast1) <> ":111122223333:receipt-rule-set/")
                         <> Text.pack sesReceiveRuleSetName
                     ]

      it "composes managed credential principals from the credential inventory" $
        awsCredentialDescriptorPrincipal
          (awsCredentialDescriptor AuthorityBackupStoreCredential)
          `shouldBe` ("prodbox-authority-backup-store" :: Text)

    describe "the retained-set digest" $ do
      it "separates surface, account, and configured names" $ do
        let cascadeDigest = retainedSetDigestFor cascadeCatalog
        cascadeDigest
          `shouldNotBe` retainedSetDigestFor operationalTeardownCatalog
        cascadeDigest `shouldNotBe` retainedSetDigestFor otherAccountCatalog
        cascadeDigest `shouldNotBe` retainedSetDigestFor otherBucketCatalog

      it "is stable for the same surface, scope, and binding" $
        retainedSetDigestFor cascadeCatalog
          `shouldBe` retainedSetDigestFor (mustCatalog CascadeSurface auditedScope binding)

    describe "the query catalog" $ do
      it "asks for every prodbox-owned tag family plus the cluster tag" $
        terminalAuditQueryCatalog binding
          `shouldBe` sort
            [ AuditQueryTagPair "prodbox.io/managed-by" "prodbox"
            , AuditQueryTagKey "prodbox.io/role"
            , AuditQueryTagKey "prodbox.io/substrate"
            , AuditQueryTagKey "prodbox.io/lifecycle"
            , AuditQueryTagKey "kubernetes.io/cluster/aws-eks-test-cluster"
            ]

      it "digests the query set independently of its order" $
        terminalAuditQueryDigestFor (terminalAuditQueryCatalog binding)
          `shouldBe` terminalAuditQueryDigestFor
            (reverse (terminalAuditQueryCatalog binding))

    describe "classification" $ do
      it "retains the exact state bucket and the exact capture bucket" $ do
        classifyRetainedResource cascadeCatalog (resourceFor stateBucketArn "s3" [])
          `shouldBe` RetainedByDesign RetainedLongLivedPulumiStateBucket
        classifyRetainedResource cascadeCatalog (resourceFor captureBucketArn "s3" [])
          `shouldBe` RetainedByDesign RetainedSesCaptureBucket

      it "retains a volume in the registered long-lived family" $
        classifyRetainedResource
          cascadeCatalog
          ( resourceForType
              retainedVolumeArn
              retainedVolumeResourceType
              [("prodbox.io/lifecycle", "retained-ebs")]
          )
          `shouldBe` RetainedByDesign
            (RetainedRegisteredLongLivedFamily AwsEbsProductionRetainedKey)

      it "refuses to launder an escapee that merely wears a retention tag" $ do
        -- The superseded tag classifier retains this row; the exact catalog
        -- does not, because no matcher names this ARN and the resource is not
        -- a volume in the registered family.
        partitionRetainedLongLived
          [ TaggedResource
              (Text.unpack (arnText escapedBucketArn))
              "prodbox.io/substrate"
              "shared"
          ]
          `shouldSatisfy` (not . null . fst)
        classifyRetainedResource
          cascadeCatalog
          (resourceFor escapedBucketArn "s3" [("prodbox.io/substrate", "shared")])
          `shouldBe` EscapedResidue

      it "refuses a non-volume resource wearing the retained family tag" $
        classifyRetainedResource
          cascadeCatalog
          ( resourceFor
              escapedBucketArn
              "s3"
              [("prodbox.io/lifecycle", "retained-ebs")]
          )
          `shouldBe` EscapedResidue

      it "escapes every retained identity once the surface stops retaining it" $
        classifyRetainedResource
          totalDecommissionCatalog
          (resourceFor stateBucketArn "s3" [])
          `shouldBe` EscapedResidue

    describe "discoverability is derived from the writer, not authored" $ do
      it "declares a family discoverable exactly when its writer authors a queried tag" $ do
        map
          retainedMatcherDiscoverability
          ( filter
              ((== RetainedSesCaptureBucket) . retainedMatcherFamily)
              (retainedCatalogMatchers cascadeCatalog)
          )
          `shouldBe` [DiscoverableByAuditQuery]
        map
          retainedMatcherDiscoverability
          ( filter
              ((== RetainedSesDomainIdentity) . retainedMatcherFamily)
              (retainedCatalogMatchers cascadeCatalog)
          )
          `shouldBe` [NotDiscoverableByAuditQuery]

      it "reports no creator tag for an identity the registry owns rather than tags" $ do
        retainedMatcherCreatorTags
          RetainedOperationalIamPrincipal
          (RetainedMatchExactArn stateBucketArn)
          `shouldBe` []
        retainedMatcherCreatorTags
          RetainedSesCaptureBucket
          (RetainedMatchExactArn stateBucketArn)
          `shouldBe` sesCaptureBucketTags

      it "keeps the two retained bucket writers inside the audit's field of view" $ do
        any (auditQueryCoversTag catalogQueries) longLivedPulumiStateBucketTags
          `shouldBe` True
        any (auditQueryCoversTag catalogQueries) sesCaptureBucketTags
          `shouldBe` True

      it "keeps the capture bucket carved out of the surviving cascade sweep" $ do
        -- The ownership tag makes the bucket visible to the legacy sweep for the
        -- first time. Without a retention marker in the same authored set that
        -- new visibility would report the retained bucket as an escape and fail
        -- every cascade postflight.
        let rows =
              [ TaggedResource
                  (Text.unpack (arnText captureBucketArn))
                  (Text.unpack key)
                  (Text.unpack value)
              | (key, value) <- sesCaptureBucketTags
              ]
        snd (partitionRetainedLongLived rows) `shouldBe` []
        map taggedResourceMatchedTagKey (fst (partitionRetainedLongLived rows))
          `shouldSatisfy` elem "prodbox.io/managed-by"

      it "takes a registered family's creator tags from its membership coordinate" $
        retainedMatcherCreatorTags
          (RetainedRegisteredLongLivedFamily AwsEbsProductionRetainedKey)
          (RetainedMatchFamilyCoordinate retainedVolumeResourceType "prodbox.io/lifecycle" "retained-ebs")
          `shouldBe` [("prodbox.io/lifecycle", "retained-ebs")]

    describe "the audit verdict" $ do
      it "confirms clean when the inventory holds only retained resources" $ do
        let partition = classifyRetainedInventory cascadeCatalog retainedOnlyInventory
        -- The inventory is ARN-keyed, so the retained rows arrive in ARN order.
        map snd (retainedPartitionRetained partition)
          `shouldBe` [RetainedSesCaptureBucket, RetainedLongLivedPulumiStateBucket]
        retainedPartitionEscaped partition `shouldBe` []
        retainedPartitionAbsentDeclared partition `shouldBe` []
        terminalAuditResultFor cascadeCatalog retainedOnlyInventory
          `shouldSatisfy` isConfirmedClean

      it "reports an escapee separately from a missing declared resource" $ do
        let partition = classifyRetainedInventory cascadeCatalog escapedInventory
        map snd (retainedPartitionRetained partition)
          `shouldBe` [RetainedLongLivedPulumiStateBucket]
        length (retainedPartitionEscaped partition) `shouldBe` 1
        retainedPartitionAbsentDeclared partition
          `shouldBe` [RetainedSesCaptureBucket]
        terminalAuditResultFor cascadeCatalog escapedInventory
          `shouldSatisfy` isFoundEscapes

      it "does not treat a missing declared resource as an escape" $
        terminalAuditResultFor cascadeCatalog stateBucketOnlyInventory
          `shouldSatisfy` isConfirmedClean

    -- The audit issues its queries in the audited scope's own region, and the
    -- Tagging API returns IAM and Route 53 only from the global-service
    -- region.  The cases above therefore hold only because 'auditedScope' is
    -- that region; composed at the canonical regression region, the same
    -- inventories asked about
    -- no IAM resource at all, and calling that clean is the exact shape of a
    -- non-answer inhabiting an answer that this phase exists to remove.
    describe "the audited region bounds what clean may claim" $ do
      it "refuses clean from a region that answers for no global service" $ do
        terminalAuditResultFor outOfRegionCatalog retainedOnlyInventory
          `shouldSatisfy` isUnobservable
        terminalAuditResultFor outOfRegionCatalog stateBucketOnlyInventory
          `shouldSatisfy` isUnobservable

      it "names each unqueried service and the region that did not ask" $
        unobservableDetails
          (terminalAuditResultFor outOfRegionCatalog retainedOnlyInventory)
          `shouldSatisfy` \details ->
            length details == length globalServicesRequiringGlobalRegion
              && all
                (\service -> any (Text.isInfixOf service) details)
                globalServicesRequiringGlobalRegion
              && all (Text.isInfixOf (fixtureAwsRegion FixtureCaCentral1)) details

      -- A blind spot cannot launder a discovered escapee into a retained one:
      -- what the audit did see is still true.
      it "still reports an escape it did find outside the global region" $
        terminalAuditResultFor outOfRegionCatalog escapedInventory
          `shouldSatisfy` isFoundEscapes

      -- IAM families author no queried tag today, so this is the property
      -- rather than the current value: discoverability is derived through the
      -- region, so a writer that starts tagging the operational principal
      -- cannot make an out-of-region audit report it permanently missing.
      it "never calls a global-service family discoverable outside that region" $
        [ retainedMatcherDiscoverability matcher
        | matcher <- retainedCatalogMatchers outOfRegionCatalog
        , isGlobalServiceFamily (retainedMatcherFamily matcher)
        ]
          `shouldSatisfy` all (== NotDiscoverableByAuditQuery)

      it "gives the two regions different retained-set digests" $
        retainedSetDigestFor cascadeCatalog
          `shouldSatisfy` (/= retainedSetDigestFor outOfRegionCatalog)

stateBucket :: Text
stateBucket = "prodbox-state"

captureBucket :: Text
captureBucket = "prodbox-ses-capture"

senderDomain :: Text
senderDomain = "test.example.invalid"

clusterName :: Text
clusterName = "aws-eks-test-cluster"

binding :: RetainedNameBinding
binding =
  mustRight (mkRetainedNameBinding stateBucket captureBucket senderDomain clusterName)

-- | The audited scope.  Its region is the global-service region, which is the
-- only region from which the Tagging API answers for IAM and Route 53 and
-- therefore the only region in which a terminal audit may mint a clean
-- witness.  Nothing supplies it by default -- Sprint 1.91 emptied the seeded
-- @aws.region@ -- so an operator who has configured any other region audits
-- from a scope in which the global services are simply not asked about, which
-- is the case 'outOfRegionScope' below exercises.
auditedScope :: AwsScope
auditedScope =
  AwsScope (AwsAccountId "111122223333") (AwsRegion globalServiceTaggingRegion)

-- | The same account and binding audited from a region that answers for no
-- global service.  Everything regional is still queried; IAM and Route 53 are
-- not asked about at all.
outOfRegionScope :: AwsScope
outOfRegionScope =
  AwsScope (AwsAccountId "111122223333") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

catalogQueries :: [TerminalAuditQuery]
catalogQueries = terminalAuditQueryCatalog binding

cascadeCatalog :: RetainedCatalog 'Cascade
cascadeCatalog = mustCatalog CascadeSurface auditedScope binding

-- | The cascade catalog composed for a region outside the global-service
-- region.  Its clean verdict is bounded; that bound is what these fixtures
-- exist to exercise.
outOfRegionCatalog :: RetainedCatalog 'Cascade
outOfRegionCatalog = mustCatalog CascadeSurface outOfRegionScope binding

operationalTeardownCatalog :: RetainedCatalog 'OperationalTeardown
operationalTeardownCatalog =
  mustCatalog OperationalTeardownSurface auditedScope binding

totalDecommissionCatalog :: RetainedCatalog 'TotalDecommission
totalDecommissionCatalog =
  mustCatalog TotalDecommissionSurface auditedScope binding

otherAccountCatalog :: RetainedCatalog 'Cascade
otherAccountCatalog =
  mustCatalog
    CascadeSurface
    (AwsScope (AwsAccountId "444455556666") (AwsRegion globalServiceTaggingRegion))
    binding

otherBucketCatalog :: RetainedCatalog 'Cascade
otherBucketCatalog =
  mustCatalog
    CascadeSurface
    auditedScope
    ( mustRight
        (mkRetainedNameBinding "prodbox-other-state" captureBucket senderDomain clusterName)
    )

mustCatalog
  :: CleanupSurfaceWitness surface
  -> AwsScope
  -> RetainedNameBinding
  -> RetainedCatalog surface
mustCatalog surfaceWitness scope nameBinding =
  mustRight (retainedCatalogFor surfaceWitness scope nameBinding)

catalogFamilies :: RetainedCatalog surface -> [RetainedFamily]
catalogFamilies = map retainedMatcherFamily . retainedCatalogMatchers

stateBucketArn :: Arn
stateBucketArn = mustArn "arn:aws:s3:::prodbox-state"

captureBucketArn :: Arn
captureBucketArn = mustArn "arn:aws:s3:::prodbox-ses-capture"

escapedBucketArn :: Arn
escapedBucketArn = mustArn "arn:aws:s3:::prodbox-run-leftover"

retainedVolumeArn :: Arn
retainedVolumeArn =
  mustArn
    ("arn:aws:ec2:" <> (fixtureAwsRegion FixtureUsEast1) <> ":111122223333:volume/vol-0retained")

retainedOnlyInventory :: AwsInventory
retainedOnlyInventory =
  mustInventory
    [ tagRow stateBucketArn (AwsResourceType "s3") Nothing
    , tagRow captureBucketArn (AwsResourceType "s3") Nothing
    ]

escapedInventory :: AwsInventory
escapedInventory =
  mustInventory
    [ tagRow stateBucketArn (AwsResourceType "s3") Nothing
    , tagRow
        escapedBucketArn
        (AwsResourceType "s3")
        (Just (AwsTag "prodbox.io/substrate" "shared"))
    ]

stateBucketOnlyInventory :: AwsInventory
stateBucketOnlyInventory =
  mustInventory [tagRow stateBucketArn (AwsResourceType "s3") Nothing]

resourceFor :: Arn -> Text -> [(Text, Text)] -> AwsResource
resourceFor arn resourceType = resourceForType arn (AwsResourceType resourceType)

resourceForType :: Arn -> AwsResourceType -> [(Text, Text)] -> AwsResource
resourceForType arn resourceType tags =
  AwsResource
    { awsResourceArn = arn
    , awsResourceScope = auditedScope
    , awsResourceType = resourceType
    , awsResourceCoordinate = AwsResourceCoordinate "fixture"
    , awsResourceTags = Map.fromList tags
    }

tagRow :: Arn -> AwsResourceType -> Maybe AwsTag -> AwsTagRow
tagRow arn resourceType tag =
  AwsTagRow
    { awsTagRowArn = arn
    , awsTagRowScope = auditedScope
    , awsTagRowResourceType = resourceType
    , awsTagRowCoordinate = AwsResourceCoordinate "fixture"
    , awsTagRowTag = tag
    }

isConfirmedClean :: TerminalAuditResult -> Bool
isConfirmedClean result = case result of
  TerminalAuditConfirmedClean _ -> True
  _ -> False

isFoundEscapes :: TerminalAuditResult -> Bool
isFoundEscapes result = case result of
  TerminalAuditFoundEscapes _ _ -> True
  _ -> False

isUnobservable :: TerminalAuditResult -> Bool
isUnobservable result = case result of
  TerminalAuditUnobservable _ _ -> True
  _ -> False

unobservableDetails :: TerminalAuditResult -> [Text]
unobservableDetails result = case result of
  TerminalAuditUnobservable _ failures ->
    [detail | ObservationFailure detail <- NonEmpty.toList failures]
  _ -> []

-- | Which retained families the Tagging API answers for only from the
-- global-service region.
isGlobalServiceFamily :: RetainedFamily -> Bool
isGlobalServiceFamily family =
  case retainedFamilyTaggingApiReach family of
    ReachableWhenTaggedFromGlobalRegion _ -> True
    _ -> False

mustArn :: Text -> Arn
mustArn = mustRight . mkArn

mustInventory :: [AwsTagRow] -> AwsInventory
mustInventory = mustRight . normalizeAwsTagRows

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
