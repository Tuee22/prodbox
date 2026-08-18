{-# LANGUAGE OverloadedStrings #-}

-- | The prodbox-owned tag families a production writer authors onto a retained
-- AWS resource.
--
-- These values exist in one place because three separate surfaces need to agree
-- about them and previously did not: the writer that authors the tags, the
-- read-back that certifies them, and the terminal escape audit, whose field of
-- view is exactly the set of tag families it queries for.  A resource carrying
-- none of those families is returned by no query, so a clean audit verdict says
-- nothing about it while reading like a statement that it is gone.
--
-- The module is a leaf on purpose — it depends on nothing but 'Text' — so the
-- native S3 client, the Provider Worker's SES mutation, and the pure retained
-- catalog can each hold the same value rather than three restatements of it.
module Prodbox.Lifecycle.OwnedResourceTags
  ( OwnedResourceTag
  , prodboxManagedByTag
  , longLivedPulumiStateBucketTags
  , sesCaptureBucketTags
  )
where

import Data.Text (Text)

-- | One authored tag: key and exact value.
type OwnedResourceTag = (Text, Text)

-- | The ownership tag every prodbox-authored AWS resource carries.  It is the
-- one family the terminal audit queries as an exact pair rather than by key, so
-- a resource carrying the key with another value is not covered by it.
prodboxManagedByTag :: OwnedResourceTag
prodboxManagedByTag = ("prodbox.io/managed-by", "prodbox")

-- | The retained Pulumi state backend bucket.  The native client both writes
-- this set and certifies it on read-back; they were two hand-authored copies of
-- one fact until this became their single source.
longLivedPulumiStateBucketTags :: [OwnedResourceTag]
longLivedPulumiStateBucketTags =
  [ prodboxManagedByTag
  , ("prodbox.io/role", "long-lived-pulumi-state")
  ]

-- | The retained SES capture bucket.
--
-- Its supported writer is the Provider Worker's @ReconcileSesCaptureBucket@
-- intent, which created the bucket carrying no tag at all while the retained
-- catalog declared the family discoverable by the audit's queries — so the
-- audit could neither have found it escaped nor confirmed it present.  The
-- @substrate@ and @purpose@ families match what the frozen @aws-ses@
-- provisioning program declares, so the two writers do not disagree about the
-- prodbox-owned families during migration.
sesCaptureBucketTags :: [OwnedResourceTag]
sesCaptureBucketTags =
  [ prodboxManagedByTag
  , ("prodbox.io/substrate", "shared")
  , ("prodbox.io/purpose", "ses-capture")
  ]
