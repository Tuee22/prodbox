{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The closed endpoint/filter plan and retained catalog of one ordinary run.
-- Public names are retained in its scope before any validation effect.
module Prodbox.Lifecycle.Teardown.PerRunTerminalAuditPlan
  ( PerRunTerminalAuditPlan
  , PerRunAuditQuery (..)
  , AuditQueryEndpoint (..)
  , mkPerRunTerminalAuditPlan
  , perRunAuditPlanScope
  , perRunAuditPlanCatalog
  , perRunAuditPlanQueries
  , perRunAuditQueryProviderIntent
  , perRunAuditQueryAwsScope
  , maximumPerRunTerminalAuditQueries
  , terminalAuditEndpointQueriesFor
  , terminalAuditEndpointQueryIdentity
  )
where

import Codec.Serialise (serialise)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderOwnedTagQuery (..)
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Lifecycle.Teardown.RetainedInventory
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForTerminalAudit)

data AuditQueryEndpoint = RunRegionTaggingEndpoint | GlobalRegionTaggingEndpoint
  deriving (Eq, Ord, Show)

data PerRunAuditQuery = PerRunAuditQuery !AuditQueryEndpoint !TerminalAuditQuery
  deriving (Eq, Ord, Show)

data PerRunTerminalAuditPlan = PerRunTerminalAuditPlan
  { perRunAuditPlanScope :: !(TerminalAuditScope 'ExplicitPerRun)
  , perRunAuditPlanCatalog :: !(RetainedCatalog 'ExplicitPerRun)
  , perRunAuditPlanQueries :: ![PerRunAuditQuery]
  }

maximumPerRunTerminalAuditQueries :: Int
maximumPerRunTerminalAuditQueries = 1 + 2 * terminalAuditQueryCatalogMaximumCardinality

mkPerRunTerminalAuditPlan :: ObservationEvidenceScope -> Either Text PerRunTerminalAuditPlan
mkPerRunTerminalAuditPlan scope = do
  aws <-
    maybe (Left "per-run terminal audit has no retained AWS scope") Right (evidenceAwsScope scope)
  names <-
    maybe
      (Left "per-run terminal audit has no retained catalog names")
      Right
      (evidenceResourceScopeBindings scope >>= resourceScopeAuditRetainedNames)
  let queries = terminalAuditEndpointQueriesFor aws names
      regions = [awsScopeRegion (perRunAuditQueryAwsScope aws query) | query <- queries]
      digest =
        TerminalAuditQueryDigest
          ( TextEncoding.decodeUtf8
              ( hexSha256
                  ( LazyByteString.toStrict
                      ( serialise
                          ( "per-run-terminal-audit-plan/v1/provider-scope-read" :: Text
                          , [terminalAuditEndpointQueryIdentity aws query | query <- queries]
                          , "GetResources excludes IAM users and roles" :: Text
                          )
                      )
                  )
              )
          )
  catalog <-
    first
      (const "per-run terminal audit retained catalog is invalid")
      (retainedCatalogForQueryRegions ExplicitPerRunSurface aws names regions)
  auditScope <-
    first
      (const "per-run terminal audit scope is invalid")
      ( mkTerminalAuditScope
          ExplicitPerRunSurface
          (scopeForTerminalAudit scope)
          digest
          (retainedSetDigestFor catalog)
      )
  Right (PerRunTerminalAuditPlan auditScope catalog queries)

-- | The shared regional/global endpoint universe. A run in the global
-- service region needs one endpoint; other runs include both explicitly.
terminalAuditEndpointQueriesFor :: AwsScope -> RetainedNameBinding -> [PerRunAuditQuery]
terminalAuditEndpointQueriesFor aws names =
  [PerRunAuditQuery endpoint query | endpoint <- endpoints, query <- terminalAuditQueryCatalog names]
 where
  endpoints
    | awsScopeRegion aws == AwsRegion awsGlobalServiceRegion = [RunRegionTaggingEndpoint]
    | otherwise = [RunRegionTaggingEndpoint, GlobalRegionTaggingEndpoint]

terminalAuditEndpointQueryIdentity :: AwsScope -> PerRunAuditQuery -> (Text, Text, Text)
terminalAuditEndpointQueryIdentity aws query@(PerRunAuditQuery _ selector) =
  let AwsRegion region = awsScopeRegion (perRunAuditQueryAwsScope aws query)
   in case selector of
        AuditQueryTagKey key -> (region, key, "key-only")
        AuditQueryTagPair key value -> (region, key, "pair/" <> value)

perRunAuditQueryProviderIntent :: PerRunAuditQuery -> ProviderIntent
perRunAuditQueryProviderIntent (PerRunAuditQuery endpoint selector) =
  let query = case selector of
        AuditQueryTagKey key -> ProviderOwnedTagKeyQuery key
        AuditQueryTagPair key value -> ProviderOwnedTagPairQuery key value
   in case endpoint of
        RunRegionTaggingEndpoint -> ObserveOwnedResourceTags query
        GlobalRegionTaggingEndpoint -> ObserveGlobalOwnedResourceTags query

perRunAuditQueryAwsScope :: AwsScope -> PerRunAuditQuery -> AwsScope
perRunAuditQueryAwsScope scope (PerRunAuditQuery endpoint _) = case endpoint of
  RunRegionTaggingEndpoint -> scope
  GlobalRegionTaggingEndpoint -> scope {awsScopeRegion = AwsRegion awsGlobalServiceRegion}
