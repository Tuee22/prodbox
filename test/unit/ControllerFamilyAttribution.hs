{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.43: a controller's child, named after its cluster is gone.
--
-- The demonstration is over a constructed write-ahead manifest and synthetic
-- sweep rows, with no Authority and no AWS call, because that is the claim: the
-- record that names a family existed before the effect, so a row found by tag
-- afterwards can be joined to it. Every negative control varies exactly one fact
-- and expects the refusal that fact earns, because an attribution that names the
-- wrong family, or a scope the rows never carried, is worse than none.
module ControllerFamilyAttribution
  ( controllerFamilyAttributionSuite
  )
where

import Data.List (isInfixOf, sort, sortOn)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( registeredStackCreationRunScope
  )
import Prodbox.Lifecycle.ControllerFamilyAttribution
import Prodbox.Lifecycle.TagSweep
  ( TagSweepVerdict (..)
  , TaggedResource (..)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegisteredResourceKey (..)
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestEntry (..)
  , initialWriteAheadManifestWrite
  , mkWriteAheadManifestIntent
  , ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , ownershipManifestWriteEntries
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( SomeManagedResourceDescriptor (..)
  , lifecycleRegistryRevision
  , managedResourceCoordinate
  , managedResourceKey
  , managedResourceRegistry
  )
import TestSupport

controllerFamilyAttributionSuite :: SuiteBuilder ()
controllerFamilyAttributionSuite =
  describe "Sprint 7.43 controller-created children named from the declared manifest" $ do
    familyCases
    attributionCases
    narrationCases

-- Fixtures -------------------------------------------------------------------

-- | The scope a registered-stack creation commits its manifest under: the
-- explicit per-run surface, the run scope the lane stamps, and the AWS scope the
-- Provider proof supplies.
creationScope :: ObservationEvidenceScope
creationScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (registeredStackCreationRunScope 1)
    (LinuxRke2FoundationId "linux-rke2/fixture")
    (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
    ReconcileDesiredPresent

-- | The facts a real creation commits: built from the same constructed write-ahead
-- manifest the lane builds, on the surface the lane builds it on.
manifestFactsFor :: RegisteredResourceKey -> ManifestFacts
manifestFactsFor stackKey =
  case mkWriteAheadManifestIntent ExplicitPerRunSurface stackKey creationScope of
    Left err -> error (show err)
    Right intent ->
      ManifestFacts
        { manifestFactsStackKey = stackKey
        , manifestFactsScope = Just creationScope
        , manifestFactsEntries = ownershipManifestWriteEntries (initialWriteAheadManifestWrite intent)
        }

familyTags :: RegisteredResourceKey -> [(Text, Text)]
familyTags key =
  case [membershipFamilyTags family | family <- membershipFamilies, membershipFamilyKey family == key] of
    tags : _ -> tags
    [] -> error ("no membership family for " ++ show key)

-- | One sweep row per tag, as the sweep produces them.
rowsFor :: Text -> [(Text, Text)] -> [TaggedResource]
rowsFor arn tags =
  [ TaggedResource
      { taggedResourceArn = Text.unpack arn
      , taggedResourceMatchedTagKey = Text.unpack key
      , taggedResourceMatchedTagValue = Text.unpack value
      }
  | (key, value) <- tags
  ]

loadBalancerArn, volumeArn, strayArn :: Text
loadBalancerArn = "arn:aws:elasticloadbalancing:fixture:000000000000:loadbalancer/net/fixture/1"
volumeArn = "arn:aws:ec2:fixture:000000000000:volume/vol-0fixture"
strayArn = "arn:aws:ec2:fixture:000000000000:vpc/vpc-0stray"

outcomes :: ManifestFacts -> [TaggedResource] -> [(Text, Either UnattributedReason AttributedRow)]
outcomes = attributeEscapedRows

reasonOf :: (Text, Either UnattributedReason AttributedRow) -> Maybe UnattributedReason
reasonOf (_, outcome) = either Just (const Nothing) outcome

familyOf :: (Text, Either UnattributedReason AttributedRow) -> Maybe RegisteredResourceKey
familyOf (_, outcome) = either (const Nothing) (Just . attributedFamily) outcome

-- Families --------------------------------------------------------------------

familyCases :: SuiteBuilder ()
familyCases = do
  it "recognizes by tag exactly the two coordinates a tag can identify" $ do
    let recognized =
          sort
            [ managedResourceKey descriptor
            | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
            , isJust (coordinateMembershipTags (managedResourceCoordinate descriptor))
            ]
    recognized `shouldBe` [AwsEbsPerRunTestKey, AwsEksLoadBalancerControllerFamilyKey]

  it "derives its families from the registry and the ownership edges" $ do
    sortOn membershipFamilyKey membershipFamilies
      `shouldSatisfy` ( \families -> map membershipFamilyKey families == [AwsEbsPerRunTestKey, AwsEksLoadBalancerControllerFamilyKey]
                      )
    map membershipFamilyOwner membershipFamilies `shouldBe` [AwsEksKey, AwsEksKey]
    all (not . null . membershipFamilyTags) membershipFamilies `shouldBe` True

  it
    "leaves the ownership relation and the declared entries that the destroy families assume untouched"
    $ do
      -- This sprint adds no writer and changes no durable shape, so the edges the
      -- manifest is seeded from, and the empty identity lists on the declared
      -- families, are exactly what they were.
      sort
        [(ownershipEdgeStackKey edge, ownershipEdgeResourceKey edge) | edge <- registeredOwnershipEdges]
        `shouldBe` [ (AwsEksKey, AwsEbsPerRunTestKey)
                   , (AwsEksKey, AwsEksIamRoleFamilyKey)
                   , (AwsEksKey, AwsEksLoadBalancerControllerFamilyKey)
                   ]
      let entries = manifestFactsEntries (manifestFactsFor AwsEksKey)
      sort (map ownershipManifestEntryKey entries)
        `shouldBe` [AwsEksKey, AwsEbsPerRunTestKey, AwsEksIamRoleFamilyKey, AwsEksLoadBalancerControllerFamilyKey]
      all (null . ownershipManifestEntryObservedIdentities) entries `shouldBe` True

-- Attribution ------------------------------------------------------------------

attributionCases :: SuiteBuilder ()
attributionCases = do
  it "names a load balancer child and a volume as members of families the EKS manifest declared" $ do
    let facts = manifestFactsFor AwsEksKey
        rows =
          rowsFor loadBalancerArn (familyTags AwsEksLoadBalancerControllerFamilyKey)
            ++ rowsFor volumeArn (familyTags AwsEbsPerRunTestKey)
        result = outcomes facts rows
    map fst result `shouldBe` [loadBalancerArn, volumeArn]
    map familyOf result
      `shouldBe` [Just AwsEksLoadBalancerControllerFamilyKey, Just AwsEbsPerRunTestKey]
    [attributedOwningStack row | (_, Right row) <- result] `shouldBe` [AwsEksKey, AwsEksKey]
    -- The scope is the caller's, reported back; the rows did not carry it.
    [attributedSuppliedScope row | (_, Right row) <- result]
      `shouldBe` [Just creationScope, Just creationScope]

  it "refuses a partial tag set, and names nothing for tags only a retained resource carries" $ do
    let facts = manifestFactsFor AwsEksKey
        partial = take 1 (familyTags AwsEksLoadBalancerControllerFamilyKey)
    map reasonOf (outcomes facts (rowsFor loadBalancerArn partial))
      `shouldBe` [Just NoFamilyTagsMatch]
    map
      reasonOf
      ( outcomes
          facts
          ( rowsFor
              strayArn
              [("prodbox.io/role", "long-lived-pulumi-state"), ("prodbox.io/managed-by", "prodbox")]
          )
      )
      `shouldBe` [Just NoFamilyTagsMatch]

  it "refuses a tag key that is present with a different value" $ do
    let facts = manifestFactsFor AwsEksKey
        revalue matches replacement tags =
          [(tagKey, if matches tagKey then replacement else value) | (tagKey, value) <- tags]
        loadBalancerTags = familyTags AwsEksLoadBalancerControllerFamilyKey
        volumeTags = familyTags AwsEbsPerRunTestKey
    -- Every key a family needs is present; one carries another cluster's value.
    map
      reasonOf
      ( outcomes
          facts
          (rowsFor loadBalancerArn (revalue (== "prodbox.io/cluster") "another-cluster" loadBalancerTags))
      )
      `shouldBe` [Just NoFamilyTagsMatch]
    -- A shared cluster tag is not an owned one.
    map
      reasonOf
      ( outcomes
          facts
          (rowsFor volumeArn (revalue ("kubernetes.io/cluster/" `Text.isPrefixOf`) "shared" volumeTags))
      )
      `shouldBe` [Just NoFamilyTagsMatch]
    -- The unmodified tags still attribute, so the control varies one fact.
    map familyOf (outcomes facts (rowsFor loadBalancerArn loadBalancerTags))
      `shouldBe` [Just AwsEksLoadBalancerControllerFamilyKey]

  it "refuses a family the manifest does not declare, such as a stack that owns none" $ do
    let rows = rowsFor loadBalancerArn (familyTags AwsEksLoadBalancerControllerFamilyKey)
    map reasonOf (outcomes (manifestFactsFor AwsTestKey) rows)
      `shouldBe` [Just (FamilyMatchedButNotDeclared AwsEksLoadBalancerControllerFamilyKey)]
    -- With no declaration at all, the sweep alone names no family.
    map reasonOf (outcomes (manifestFactsFor AwsEksKey) {manifestFactsEntries = []} rows)
      `shouldBe` [Just (FamilyMatchedButNotDeclared AwsEksLoadBalancerControllerFamilyKey)]

  it "refuses entries that another stack's facts carry, even when the entries declare the family" $ do
    -- The entries declare the family, so the entry lookup succeeds; the facts
    -- name a stack that does not own it, so the owner check is what refuses.
    let rows = rowsFor loadBalancerArn (familyTags AwsEksLoadBalancerControllerFamilyKey)
        facts = (manifestFactsFor AwsEksKey) {manifestFactsStackKey = AwsTestKey}
    map reasonOf (outcomes facts rows)
      `shouldBe` [Just (FamilyMatchedButNotDeclared AwsEksLoadBalancerControllerFamilyKey)]

  it "gives the production fact source the same entries and outcomes as a constructed manifest" $ do
    -- The postflight reads no manifest: its facts are the registry's, which are
    -- the entry set a creation commits. This pins that premise, so a change in
    -- one cannot make the other's narration untrue.
    case manifestFactsFromRegistry AwsEksKey of
      Left err -> expectationFailure ("the registry facts could not be built: " ++ show err)
      Right production -> do
        let constructed = manifestFactsFor AwsEksKey
            rows =
              rowsFor loadBalancerArn (familyTags AwsEksLoadBalancerControllerFamilyKey)
                ++ rowsFor volumeArn (familyTags AwsEbsPerRunTestKey)
                ++ rowsFor strayArn [("prodbox.io/run-scope", "stray")]
            normalized facts = sortOn ownershipManifestEntryKey (manifestFactsEntries facts)
        normalized production `shouldBe` normalized constructed
        manifestFactsStackKey production `shouldBe` manifestFactsStackKey constructed
        -- It carries no scope, because no record was read to supply one.
        manifestFactsScope production `shouldBe` Nothing
        map reasonOf (outcomes production rows) `shouldBe` map reasonOf (outcomes constructed rows)
        map familyOf (outcomes production rows) `shouldBe` map familyOf (outcomes constructed rows)

  it "refuses a record whose declared coordinate digest disagrees with the registry" $ do
    let facts = manifestFactsFor AwsEksKey
        otherDigest =
          case [ ownershipManifestEntryCoordinateDigest entry
               | entry <- manifestFactsEntries facts
               , ownershipManifestEntryKey entry == AwsEbsPerRunTestKey
               ] of
            digest : _ -> digest
            [] -> error "the EKS manifest declares no per-run volume family"
        drifted =
          facts
            { manifestFactsEntries =
                [ if ownershipManifestEntryKey entry == AwsEksLoadBalancerControllerFamilyKey
                    then entry {ownershipManifestEntryCoordinateDigest = otherDigest}
                    else entry
                | entry <- manifestFactsEntries facts
                ]
            }
    map
      reasonOf
      (outcomes drifted (rowsFor loadBalancerArn (familyTags AwsEksLoadBalancerControllerFamilyKey)))
      `shouldBe` [Just (DeclaredCoordinateDigestDisagrees AwsEksLoadBalancerControllerFamilyKey)]

  it "refuses to choose between two families a resource's tags both satisfy" $ do
    let both = familyTags AwsEksLoadBalancerControllerFamilyKey ++ familyTags AwsEbsPerRunTestKey
    map reasonOf (outcomes (manifestFactsFor AwsEksKey) (rowsFor strayArn both))
      `shouldBe` [Just (AmbiguousFamilies [AwsEbsPerRunTestKey, AwsEksLoadBalancerControllerFamilyKey])]

-- Narration ----------------------------------------------------------------------

narrationCases :: SuiteBuilder ()
narrationCases = do
  it "says what an attribution proves and what it does not, and only for escaped residue" $ do
    let rows = rowsFor loadBalancerArn (familyTags AwsEksLoadBalancerControllerFamilyKey)
        rendered = renderEscapedAttributionNarration (TagSweepEscaped [] rows)
    rendered
      `shouldSatisfy` ("its tags match family `aws-eks-load-balancer-controller-family`" `isInfixOf`)
    rendered
      `shouldSatisfy` ("declares in the write-ahead manifest of stack `aws-eks`" `isInfixOf`)
    rendered `shouldSatisfy` ("needs no cluster" `isInfixOf`)
    rendered `shouldSatisfy` ("The run is not established" `isInfixOf`)
    -- It says what it consulted: the registry, and no record of the run.
    rendered `shouldSatisfy` ("no manifest was read" `isInfixOf`)
    rendered `shouldSatisfy` ("not a record of the run" `isInfixOf`)
    -- It never claims that a stack's own manifest vouched for the rows.
    rendered `shouldSatisfy` (not . ("declared the family" `isInfixOf`))
    rendered `shouldSatisfy` (not . ("before it acted" `isInfixOf`))
    rendered `shouldSatisfy` (not . ("before any effect" `isInfixOf`))
    renderEscapedAttributionNarration (TagSweepConfirmedClean rows) `shouldBe` ""
    renderEscapedAttributionNarration (TagSweepUnconfirmed "unreachable") `shouldBe` ""

  it "adds nothing for escaped rows no declared family accounts for" $ do
    renderEscapedAttributionNarration
      (TagSweepEscaped [] (rowsFor strayArn [("prodbox.io/run-scope", "stray")]))
      `shouldBe` ""
