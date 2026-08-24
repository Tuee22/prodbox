{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.84: the terminal audit's field of view.
--
-- The audit decides over what its tag queries return, so a resource carrying no
-- queried tag is never returned at all — and @TerminalAuditConfirmedClean@ then
-- reads exactly like a statement about a resource the audit never saw.  These
-- cases pin the join that measures that claim instead of asserting it, and the
-- shape of the defect it found: a provisioning program resource whose only tag
-- is @Name@.
module LifecycleTeardownAuditFieldOfView
  ( lifecycleTeardownAuditFieldOfViewSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.AuditFieldOfView
  ( AuditFieldOfView (..)
  , DeclaredAwsResource (..)
  , ProvisioningProgramParseError (..)
  , auditFieldOfViewViolations
  , classifyAuditFieldOfView
  , parseProvisioningProgram
  )
import Prodbox.Lifecycle.Teardown.Model (AwsRegion (..))
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( TerminalAuditQuery (..)
  , auditQueryCoversTag
  , clusterOwnershipTagPrefix
  , mkRetainedNameBinding
  , terminalAuditQueryCatalog
  )
import Prodbox.Lifecycle.Teardown.TaggingApiReach
  ( TaggingApiReach (..)
  , classifyTaggingApiReach
  , globalServiceTaggingRegion
  , globalServicesRequiringGlobalRegion
  , taggingApiReachTable
  , unreachedGlobalService
  , unreachedGlobalServicesFrom
  )
import TestSupport

lifecycleTeardownAuditFieldOfViewSuite :: SuiteBuilder ()
lifecycleTeardownAuditFieldOfViewSuite =
  describe "Sprint 4.84 terminal-audit field of view" $ do
    describe "the provisioning-program reader" $ do
      it "reads each resource's logical name, provider type, and authored tags" $
        parseProvisioningProgram "fixture" program
          `shouldBe` Right
            [ DeclaredAwsResource
                { declaredResourceProgram = "fixture"
                , declaredResourceName = "vpc"
                , declaredResourceType = "aws:ec2:Vpc"
                , declaredResourceTags =
                    [("Name", "${stackName}-vpc"), ("prodbox.io/managed-by", "prodbox")]
                }
            , DeclaredAwsResource
                { declaredResourceProgram = "fixture"
                , declaredResourceName = "node0"
                , declaredResourceType = "aws:ec2:Instance"
                , declaredResourceTags = [("Name", "${stackName}-node-0")]
                }
            , DeclaredAwsResource
                { declaredResourceProgram = "fixture"
                , declaredResourceName = "rta0"
                , declaredResourceType = "aws:ec2:RouteTableAssociation"
                , declaredResourceTags = []
                }
            ]

      it "does not read an indented comment that ends in a colon as a resource" $
        fmap (map declaredResourceName) (parseProvisioningProgram "fixture" program)
          `shouldBe` Right ["vpc", "node0", "rta0"]

      it "refuses a program with no resources section" $
        parseProvisioningProgram "fixture" "config: {}\n"
          `shouldBe` Left (ProgramHasNoResourcesSection "fixture")

      it "refuses an empty resources section rather than reading it as covered" $
        parseProvisioningProgram "fixture" "resources:\noutputs: {}\n"
          `shouldBe` Left (ProgramDeclaresNoResources "fixture")

      it "refuses a resource with no type, whose reach is unknowable" $
        parseProvisioningProgram
          "fixture"
          "resources:\n  vpc:\n    properties:\n      cidrBlock: \"10.0.0.0/16\"\n"
          `shouldBe` Left (ProgramResourceHasNoType "fixture" "vpc")

      it "refuses a duplicated logical name" $
        parseProvisioningProgram
          "fixture"
          "resources:\n  vpc:\n    type: aws:ec2:Vpc\n  vpc:\n    type: aws:ec2:Vpc\n"
          `shouldBe` Left (ProgramResourceDeclaredTwice "fixture" "vpc")

      it "refuses a tag block at an indentation it does not model" $
        parseProvisioningProgram
          "fixture"
          "resources:\n  vpc:\n    type: aws:ec2:Vpc\n    properties:\n      spec:\n        tags:\n          Name: x\n"
          `shouldBe` Left (ProgramTagBlockNotRecognized "fixture" 8)

    describe "Tagging API reach" $ do
      it "separates regional, global-service, untaggable, and non-AWS types" $ do
        classifyTaggingApiReach "aws:ec2:Instance" `shouldBe` Just ReachableWhenTagged
        classifyTaggingApiReach "aws:iam:Role"
          `shouldBe` Just (ReachableWhenTaggedFromGlobalRegion "iam")
        classifyTaggingApiReach "aws:ses:DomainIdentity" `shouldSatisfy` isUntaggable
        classifyTaggingApiReach "pulumi:providers:aws" `shouldSatisfy` isNotAws

      it "refuses an unknown type instead of assuming either answer" $
        classifyTaggingApiReach "aws:rds:Instance" `shouldBe` Nothing

    describe "the region axis" $ do
      -- The global-service list is derived from the reach table rather than
      -- authored beside it, so this pins the derivation rather than a copy: a
      -- new global-service type joins the list without a second edit.
      it "derives its global services from the reach table itself" $ do
        globalServicesRequiringGlobalRegion `shouldBe` ["iam", "route53"]
        [ service
          | (_, ReachableWhenTaggedFromGlobalRegion service) <- taggingApiReachTable
          ]
          `shouldSatisfy` \services ->
            all (`elem` services) globalServicesRequiringGlobalRegion

      it "reaches a global service only from the global-service region" $ do
        unreachedGlobalService
          (AwsRegion globalServiceTaggingRegion)
          (ReachableWhenTaggedFromGlobalRegion "iam")
          `shouldBe` Nothing
        unreachedGlobalService
          (AwsRegion (fixtureAwsRegion FixtureEuWest2))
          (ReachableWhenTaggedFromGlobalRegion "iam")
          `shouldBe` Just "iam"

      -- A regional resource lives in the audited region, which is where the
      -- audit issues its queries, so the region can never exclude it.  Naming a
      -- region for an untaggable or non-AWS type would misattribute why it is
      -- outside the field of view.
      it "attributes only global-service exclusion to the region" $ do
        unreachedGlobalService (AwsRegion (fixtureAwsRegion FixtureEuWest2)) ReachableWhenTagged
          `shouldBe` Nothing
        unreachedGlobalService
          (AwsRegion (fixtureAwsRegion FixtureEuWest2))
          (UntaggableByTaggingApi "no tags")
          `shouldBe` Nothing
        unreachedGlobalService
          (AwsRegion (fixtureAwsRegion FixtureEuWest2))
          (NotAnAwsResource "a provider")
          `shouldBe` Nothing

      it "has a blind spot exactly outside the global-service region" $ do
        unreachedGlobalServicesFrom (AwsRegion globalServiceTaggingRegion)
          `shouldBe` []
        unreachedGlobalServicesFrom (AwsRegion (fixtureAwsRegion FixtureEuWest2))
          `shouldBe` globalServicesRequiringGlobalRegion

    describe "query coverage" $ do
      it "requires the exact value for a tag-pair query" $ do
        auditQueryCoversTag queries ("prodbox.io/managed-by", "prodbox")
          `shouldBe` True
        auditQueryCoversTag queries ("prodbox.io/managed-by", "someone-else")
          `shouldBe` False

      it "matches the cluster-ownership family by prefix, not by bound name" $ do
        auditQueryCoversTag
          queries
          (clusterOwnershipTagPrefix <> "${clusterName}", "shared")
          `shouldBe` True
        auditQueryCoversTag queries ("Name", "anything") `shouldBe` False

    describe "the join" $ do
      it "places a resource carrying only Name outside the field of view" $
        classifyAuditFieldOfView queries (declared "aws:ec2:Instance" [("Name", "n")])
          `shouldBe` OutsideFieldOfViewUntagged

      it "places a queried tag inside it and names the covering key" $
        classifyAuditFieldOfView
          queries
          (declared "aws:ec2:Instance" [("Name", "n"), ("prodbox.io/managed-by", "prodbox")])
          `shouldBe` WithinAuditFieldOfView "prodbox.io/managed-by"

      it "excuses a type with no tag surface rather than demanding a tag" $
        classifyAuditFieldOfView queries (declared "aws:route53:Record" [])
          `shouldSatisfy` isOutsideByType

      it "still demands a tag from a global-service type, whose reach is a region" $
        classifyAuditFieldOfView queries (declared "aws:iam:Role" [("Name", "n")])
          `shouldBe` OutsideFieldOfViewUntagged

      it "fails an unclassified type as a violation, not as coverage" $
        auditFieldOfViewViolations queries [declared "aws:rds:Instance" []]
          `shouldSatisfy` \violations -> length violations == 1

      it "reports exactly the untagged taggable resources" $
        length
          ( auditFieldOfViewViolations
              queries
              [ declared "aws:ec2:Instance" [("Name", "n")]
              , declared "aws:ec2:RouteTableAssociation" []
              , declared "aws:ec2:Vpc" [("prodbox.io/substrate", "aws")]
              ]
          )
          `shouldBe` 1

      it "names the audited tag families in the violation it reports" $
        unwords (auditFieldOfViewViolations queries [declared "aws:ec2:Instance" []])
          `shouldSatisfy` \rendered ->
            "prodbox.io/managed-by=prodbox" `isInfixOfString` rendered
              && (Text.unpack clusterOwnershipTagPrefix ++ "<cluster>")
                `isInfixOfString` rendered
 where
  isUntaggable reach = case reach of
    Just (UntaggableByTaggingApi _) -> True
    _ -> False

  isNotAws reach = case reach of
    Just (NotAnAwsResource _) -> True
    _ -> False

  isOutsideByType verdict = case verdict of
    OutsideFieldOfViewByType _ -> True
    _ -> False

  declared resourceType tags =
    DeclaredAwsResource
      { declaredResourceProgram = "fixture"
      , declaredResourceName = "resource"
      , declaredResourceType = resourceType
      , declaredResourceTags = tags
      }

isInfixOfString :: String -> String -> Bool
isInfixOfString needle haystack =
  Text.isInfixOf (Text.pack needle) (Text.pack haystack)

-- | The catalog evaluated at a deliberately synthetic binding: only the tag
-- families matter here, and the one name-bearing query is matched by family.
queries :: [TerminalAuditQuery]
queries = case mkRetainedNameBinding "state" "capture" "sender.invalid" "cluster" of
  Left _ -> []
  Right binding -> terminalAuditQueryCatalog binding

program :: Text
program =
  Text.unlines
    [ "config:"
    , "  operatorCidr:"
    , "    type: string"
    , "resources:"
    , "  vpc:"
    , "    type: aws:ec2:Vpc"
    , "    properties:"
    , "      cidrBlock: \"10.90.0.0/16\""
    , "      tags:"
    , "        Name: ${stackName}-vpc"
    , "        prodbox.io/managed-by: prodbox"
    , ""
    , "  # The per-run compute nodes:"
    , "  node0:"
    , "    type: aws:ec2:Instance"
    , "    properties:"
    , "      instanceType: t3.large"
    , "      tags:"
    , "        Name: ${stackName}-node-0"
    , ""
    , "  rta0:"
    , "    type: aws:ec2:RouteTableAssociation"
    , "    properties:"
    , "      subnetId: ${publicSubnet0.id}"
    , ""
    , "outputs:"
    , "  vpcId: ${vpc.id}"
    ]
