{-# LANGUAGE OverloadedStrings #-}

-- | The IAM actions each AWS CLI verb a fenced Provider interpreter runs needs.
--
-- The Provider role's permissions policy and the CLI verbs its interpreters run
-- were written by hand in two places, and nothing compared them. A verb the
-- policy omits is denied only when a live run reaches it, and each earlier
-- instance was found that way, at the cost of a live cycle: the hosted-zone
-- create (2026-09-05) and the same create under the assumed role (2026-09-06).
-- The SES receipt-rule observers, the capture-bucket tagging calls and the
-- owned-resource tag listing were the same defect waiting for a run that
-- reached them.
--
-- This module is the third thing both must agree with. The table names, for
-- every verb a Provider-run module invokes, the actions AWS authorizes it
-- with. @prodbox dev check@ then fails when a Provider-run module invokes a
-- verb the table does not name, and when the policy does not grant an action
-- the table names for a verb in use.
--
-- The scope is the CLI verbs only. Pulumi programs the Provider runs, and the
-- native clients the Credential Provisioner uses under the admin credential,
-- authorize through other policies and are not described here.
module Prodbox.Lifecycle.CredentialProvisioner.ProviderCliActions
  ( ProviderCliEntry (..)
  , providerCliActionTable
  , providerCliEntryFor
  , providerCliRunModules
  , ProviderCliDynamicSite (..)
  , providerCliDynamicVerbSites
  , policyGrantsAction
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text

-- | One CLI verb and the IAM actions it is authorized by.
--
-- A verb of @"*"@ stands for every verb of a service the policy grants with a
-- service-wide wildcard, and its action is that wildcard.
data ProviderCliEntry = ProviderCliEntry
  { providerCliService :: !Text
  -- ^ the CLI service token, as it appears in the argument list
  , providerCliVerb :: !Text
  , providerCliActions :: ![Text]
  -- ^ empty when AWS requires no permission for the call
  }
  deriving (Eq, Show)

-- | The Provider-run modules whose AWS CLI invocations execute under the
-- Provider's assumed-role session.
providerCliRunModules :: [FilePath]
providerCliRunModules =
  [ "src/Prodbox/ControlPlane/ProviderProduction.hs"
  , "src/Prodbox/Lifecycle/AwsAuditField.hs"
  , "src/Prodbox/Lifecycle/AwsNativeStackFamily.hs"
  , "src/Prodbox/Lifecycle/EbsVolume.hs"
  , "src/Prodbox/Lifecycle/TaggedResourceQuery.hs"
  , "src/Prodbox/Lifecycle/ValidationHostedZone.hs"
  , "src/Prodbox/Ses/Capture.hs"
  , "src/Prodbox/Ses/CaptureLifecycle.hs"
  ]

-- | A place where a Provider-run module names a service and chooses the verb at
-- run time, so the scan cannot read it. The verbs it may choose are listed and
-- must each be in the table; the count makes a second such site a finding
-- rather than an unreviewed one.
data ProviderCliDynamicSite = ProviderCliDynamicSite
  { providerCliDynamicModule :: !FilePath
  , providerCliDynamicService :: !Text
  , providerCliDynamicCount :: !Int
  , providerCliDynamicVerbs :: ![Text]
  }
  deriving (Eq, Show)

providerCliDynamicVerbSites :: [ProviderCliDynamicSite]
providerCliDynamicVerbSites =
  [ ProviderCliDynamicSite
      { providerCliDynamicModule = "src/Prodbox/ControlPlane/ProviderProduction.hs"
      , providerCliDynamicService = "ses"
      , providerCliDynamicCount = 1
      , providerCliDynamicVerbs = ["create-receipt-rule", "update-receipt-rule"]
      }
  ]

-- | The entry that authorizes one CLI verb, if the table names it.
providerCliEntryFor :: Text -> Text -> Maybe ProviderCliEntry
providerCliEntryFor service verb =
  case find exact providerCliActionTable of
    Just entry -> Just entry
    Nothing -> find wildcard providerCliActionTable
 where
  exact entry = providerCliService entry == service && providerCliVerb entry == verb
  wildcard entry = providerCliService entry == service && providerCliVerb entry == "*"

-- | Whether a policy's action list authorizes a required action: the exact
-- action, or the service-wide wildcard of its service.
policyGrantsAction :: [Text] -> Text -> Bool
policyGrantsAction granted required =
  required `elem` granted
    || (fst (Text.breakOn ":" required) <> ":*") `elem` granted

providerCliActionTable :: [ProviderCliEntry]
providerCliActionTable =
  [ -- Services the policy grants with a service-wide wildcard.
    ProviderCliEntry "ec2" "*" ["ec2:*"]
  , ProviderCliEntry "eks" "*" ["eks:*"]
  , ProviderCliEntry "elbv2" "*" ["elasticloadbalancing:*"]
  , -- The classic load balancer API shares the service-wide grant; the audit reads it.
    ProviderCliEntry "elb" "*" ["elasticloadbalancing:*"]
  , ProviderCliEntry "autoscaling" "*" ["autoscaling:*"]
  , -- IAM role and policy lifecycle for the registered EKS families.
    ProviderCliEntry "iam" "delete-open-id-connect-provider" ["iam:DeleteOpenIDConnectProvider"]
  , ProviderCliEntry "iam" "delete-policy" ["iam:DeletePolicy"]
  , ProviderCliEntry "iam" "delete-policy-version" ["iam:DeletePolicyVersion"]
  , ProviderCliEntry "iam" "delete-role" ["iam:DeleteRole"]
  , ProviderCliEntry "iam" "delete-role-policy" ["iam:DeleteRolePolicy"]
  , ProviderCliEntry "iam" "detach-role-policy" ["iam:DetachRolePolicy"]
  , ProviderCliEntry "iam" "get-policy" ["iam:GetPolicy"]
  , ProviderCliEntry "iam" "get-role" ["iam:GetRole"]
  , ProviderCliEntry "iam" "list-attached-role-policies" ["iam:ListAttachedRolePolicies"]
  , ProviderCliEntry "iam" "list-instance-profiles-for-role" ["iam:ListInstanceProfilesForRole"]
  , ProviderCliEntry "iam" "list-policy-versions" ["iam:ListPolicyVersions"]
  , ProviderCliEntry "iam" "list-role-policies" ["iam:ListRolePolicies"]
  , ProviderCliEntry "iam" "remove-role-from-instance-profile" ["iam:RemoveRoleFromInstanceProfile"]
  , -- Route 53 zones and records.
    ProviderCliEntry "route53" "change-resource-record-sets" ["route53:ChangeResourceRecordSets"]
  , ProviderCliEntry "route53" "change-tags-for-resource" ["route53:ChangeTagsForResource"]
  , ProviderCliEntry "route53" "create-hosted-zone" ["route53:CreateHostedZone"]
  , ProviderCliEntry "route53" "delete-hosted-zone" ["route53:DeleteHostedZone"]
  , ProviderCliEntry "route53" "get-hosted-zone" ["route53:GetHostedZone"]
  , ProviderCliEntry "route53" "list-hosted-zones" ["route53:ListHostedZones"]
  , ProviderCliEntry "route53" "list-resource-record-sets" ["route53:ListResourceRecordSets"]
  , ProviderCliEntry "route53" "list-tags-for-resource" ["route53:ListTagsForResource"]
  , -- The SES capture bucket. @head-bucket@ and @head-object@ are authorized by
    -- the list and get actions, not by actions of their own names.
    ProviderCliEntry "s3api" "create-bucket" ["s3:CreateBucket"]
  , ProviderCliEntry "s3api" "delete-object" ["s3:DeleteObject"]
  , ProviderCliEntry "s3api" "get-bucket-lifecycle-configuration" ["s3:GetLifecycleConfiguration"]
  , ProviderCliEntry "s3api" "get-bucket-policy" ["s3:GetBucketPolicy"]
  , ProviderCliEntry "s3api" "get-bucket-tagging" ["s3:GetBucketTagging"]
  , ProviderCliEntry "s3api" "get-object" ["s3:GetObject"]
  , ProviderCliEntry "s3api" "head-bucket" ["s3:ListBucket"]
  , ProviderCliEntry "s3api" "head-object" ["s3:GetObject"]
  , ProviderCliEntry "s3api" "list-objects-v2" ["s3:ListBucket"]
  , ProviderCliEntry "s3api" "put-bucket-lifecycle-configuration" ["s3:PutLifecycleConfiguration"]
  , ProviderCliEntry "s3api" "put-bucket-policy" ["s3:PutBucketPolicy"]
  , ProviderCliEntry "s3api" "put-bucket-tagging" ["s3:PutBucketTagging"]
  , ProviderCliEntry "s3api" "put-object" ["s3:PutObject"]
  , -- SES identity, DKIM and receipt rules.
    ProviderCliEntry "ses" "create-receipt-rule" ["ses:CreateReceiptRule"]
  , ProviderCliEntry "ses" "create-receipt-rule-set" ["ses:CreateReceiptRuleSet"]
  , ProviderCliEntry "ses" "describe-active-receipt-rule-set" ["ses:DescribeActiveReceiptRuleSet"]
  , ProviderCliEntry "ses" "describe-receipt-rule" ["ses:DescribeReceiptRule"]
  , ProviderCliEntry "ses" "describe-receipt-rule-set" ["ses:DescribeReceiptRuleSet"]
  , ProviderCliEntry "ses" "get-identity-dkim-attributes" ["ses:GetIdentityDkimAttributes"]
  , ProviderCliEntry
      "ses"
      "get-identity-verification-attributes"
      ["ses:GetIdentityVerificationAttributes"]
  , ProviderCliEntry "ses" "set-active-receipt-rule-set" ["ses:SetActiveReceiptRuleSet"]
  , ProviderCliEntry "ses" "update-receipt-rule" ["ses:UpdateReceiptRule"]
  , ProviderCliEntry "ses" "verify-domain-dkim" ["ses:VerifyDomainDkim"]
  , ProviderCliEntry "ses" "verify-domain-identity" ["ses:VerifyDomainIdentity"]
  , -- STS needs no permission to report the caller.
    ProviderCliEntry "sts" "get-caller-identity" []
  , -- The owned-resource tag listing the terminal audit and the sweep share.
    ProviderCliEntry "resourcegroupstaggingapi" "get-resources" ["tag:GetResources"]
  ]
