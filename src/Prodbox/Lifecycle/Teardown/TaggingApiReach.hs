{-# LANGUAGE OverloadedStrings #-}

-- | Which resources a Resource Groups Tagging API query can return, and from
-- where.
--
-- The terminal escape audit issues tag queries and reads a verdict off the
-- union of what they return.  Two independent facts decide whether a resource
-- can appear in that union at all:
--
-- 1. __Does the type have a tag surface the API enumerates?__  An SES receipt
--    rule or an S3 object is returned by no tag query however it is tagged.
-- 2. __Was the query issued in a region that answers for it?__  The Tagging
--    API is regional.  A regional resource is returned by a query issued in
--    the region that holds it, and a global-service resource (IAM, Route 53)
--    is returned only from the global-service region.
--
-- The repository measured the first fact and corrected it; the second was left
-- bound to nothing.  The audit composes its queries from the audited scope,
-- issues them in that scope's own region, and the region never entered any
-- type — so whether a tagged IAM role was inside or outside the audit's field
-- of view was a fact about the configured region that nothing recorded.
-- The compiled default the config seeded happened to be the global-service
-- region, which is exactly what made the dependency invisible: every
-- observation to date was taken from the one region in which the unbound claim
-- is true.  Sprint 1.91 emptied that seed, so an unconfigured deployment now
-- refuses rather than silently landing in the one region that hid the bug.
--
-- This module is the binding.  It is a leaf so that both the provisioning-time
-- join ("Prodbox.Lifecycle.Teardown.AuditFieldOfView") and the audit-time
-- verdict ("Prodbox.Lifecycle.Teardown.RetainedInventory") decide reach from
-- one table rather than from two agreeing statements.
module Prodbox.Lifecycle.Teardown.TaggingApiReach
  ( -- * Reach
    TaggingApiReach (..)
  , taggingApiReachTable
  , classifyTaggingApiReach

    -- * The region axis
  , globalServiceTaggingRegion
  , isGlobalServiceTaggingRegion
  , globalServicesRequiringGlobalRegion
  , unreachedGlobalService
  , unreachedGlobalServicesFrom
  )
where

import Data.List (nub, sort)
import Data.Text (Text)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Lifecycle.Teardown.Model (AwsRegion (..))

-- | How far the Resource Groups Tagging API reaches for one resource type.
--
-- The two reachable arms differ only in which region answers for them, and
-- both still require a tag the query catalog asks for: an untagged resource is
-- returned by no query in any region.
data TaggingApiReach
  = -- | A regional resource: returned by a tag query issued in the region that
    -- holds it.  prodbox provisions these into the audited scope's own region,
    -- which is where the audit issues its queries, so this arm is reachable
    -- from every audited region.
    ReachableWhenTagged
  | -- | A global-service resource (IAM, Route 53).  The Tagging API returns
    -- these only from 'globalServiceTaggingRegion'.  Carries the service so a
    -- report can name what an audit outside that region did not ask about.
    ReachableWhenTaggedFromGlobalRegion !Text
  | -- | The type has no tag surface the Tagging API can return it through:
    -- either AWS exposes no tags for it at all, or it is not a resource the
    -- Tagging API enumerates.  Carries the reason.
    UntaggableByTaggingApi !Text
  | -- | Not an AWS resource: a provider declaration or another provider's type.
    NotAnAwsResource !Text
  deriving (Eq, Show)

-- | The region whose Tagging API endpoint answers for global services.
globalServiceTaggingRegion :: Text
globalServiceTaggingRegion = awsGlobalServiceRegion

isGlobalServiceTaggingRegion :: AwsRegion -> Bool
isGlobalServiceTaggingRegion (AwsRegion region) =
  region == globalServiceTaggingRegion

-- | Every provider type this repository provisions, with its reach.
--
-- This is a table rather than a @case@ so that
-- 'globalServicesRequiringGlobalRegion' can be /derived from it/ instead of
-- restated beside it.  A hand-authored list of global services joined to
-- nothing is the same defect shape as the hand-authored query catalog this
-- module's region axis exists to bound.
taggingApiReachTable :: [(Text, TaggingApiReach)]
taggingApiReachTable =
  [ ("aws:ec2:Vpc", ReachableWhenTagged)
  , ("aws:ec2:InternetGateway", ReachableWhenTagged)
  , ("aws:ec2:RouteTable", ReachableWhenTagged)
  , ("aws:ec2:Subnet", ReachableWhenTagged)
  , ("aws:ec2:SecurityGroup", ReachableWhenTagged)
  , ("aws:ec2:Instance", ReachableWhenTagged)
  , ("aws:ec2:Volume", ReachableWhenTagged)
  , ("aws:eks:Cluster", ReachableWhenTagged)
  , ("aws:eks:NodeGroup", ReachableWhenTagged)
  , ("aws:eks:Addon", ReachableWhenTagged)
  , ("aws:s3:Bucket", ReachableWhenTagged)
  , ("aws:iam:Role", ReachableWhenTaggedFromGlobalRegion "iam")
  , ("aws:iam:Policy", ReachableWhenTaggedFromGlobalRegion "iam")
  , ("aws:iam:OpenIdConnectProvider", ReachableWhenTaggedFromGlobalRegion "iam")
  , ("aws:route53:Zone", ReachableWhenTaggedFromGlobalRegion "route53")
  ,
    ( "aws:ec2:RouteTableAssociation"
    , UntaggableByTaggingApi "a route-table association accepts no tags"
    )
  ,
    ( "aws:iam:RolePolicyAttachment"
    , UntaggableByTaggingApi "a role-policy attachment accepts no tags"
    )
  ,
    ( "aws:s3:BucketPolicy"
    , UntaggableByTaggingApi "a bucket policy is a bucket subresource"
    )
  ,
    ( "aws:s3:BucketObjectv2"
    , UntaggableByTaggingApi "the Tagging API does not enumerate S3 objects"
    )
  ,
    ( "aws:route53:Record"
    , UntaggableByTaggingApi "a Route 53 record accepts no tags"
    )
  ,
    ( "aws:ses:DomainIdentity"
    , UntaggableByTaggingApi "a classic SES identity accepts no tags"
    )
  ,
    ( "aws:ses:DomainDkim"
    , UntaggableByTaggingApi "SES DKIM settings are an identity subresource"
    )
  ,
    ( "aws:ses:ReceiptRuleSet"
    , UntaggableByTaggingApi "a classic SES receipt rule set accepts no tags"
    )
  ,
    ( "aws:ses:ReceiptRule"
    , UntaggableByTaggingApi "a classic SES receipt rule accepts no tags"
    )
  ,
    ( "aws:ses:ActiveReceiptRuleSet"
    , UntaggableByTaggingApi "the active rule-set pointer accepts no tags"
    )
  ,
    ( "pulumi:providers:aws"
    , NotAnAwsResource "an explicit provider declaration, not a resource"
    )
  ,
    ( "tls:PrivateKey"
    , NotAnAwsResource "a locally generated key, held in stack state"
    )
  ]

-- | Classify one provider type token.
--
-- 'Nothing' is the deliberate refusal: an unrecognized type is not assumed
-- unreachable (which would silently excuse it) nor assumed reachable (which
-- would demand a tag AWS may not accept).  The caller fails the build and the
-- type is classified by hand, which is the only point at which anyone knows
-- whether AWS tags it.
classifyTaggingApiReach :: Text -> Maybe TaggingApiReach
classifyTaggingApiReach resourceType = lookup resourceType taggingApiReachTable

-- | Every global service this repository provisions taggable resources in,
-- derived from 'taggingApiReachTable'.
--
-- A query issued outside 'globalServiceTaggingRegion' asks about none of these,
-- so an audit taken there has a blind spot exactly this wide.
globalServicesRequiringGlobalRegion :: [Text]
globalServicesRequiringGlobalRegion =
  sort
    ( nub
        [ service
        | (_, ReachableWhenTaggedFromGlobalRegion service) <- taggingApiReachTable
        ]
    )

-- | The global service a query issued in this region cannot return, if any.
--
-- Total over the reach universe: the untaggable and non-AWS arms are outside
-- the field of view for reasons the region cannot change, so naming a region
-- for them would misattribute the exclusion.
unreachedGlobalService :: AwsRegion -> TaggingApiReach -> Maybe Text
unreachedGlobalService region reach = case reach of
  ReachableWhenTaggedFromGlobalRegion service
    | isGlobalServiceTaggingRegion region -> Nothing
    | otherwise -> Just service
  ReachableWhenTagged -> Nothing
  UntaggableByTaggingApi _ -> Nothing
  NotAnAwsResource _ -> Nothing

-- | Every global service an audit issuing its queries in this region did not
-- ask about.  Empty exactly when the audited region is the global-service
-- region.
unreachedGlobalServicesFrom :: AwsRegion -> [Text]
unreachedGlobalServicesFrom region
  | isGlobalServiceTaggingRegion region = []
  | otherwise = globalServicesRequiringGlobalRegion
