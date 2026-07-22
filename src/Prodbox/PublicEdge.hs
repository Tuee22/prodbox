{-# LANGUAGE OverloadedStrings #-}

module Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , adminPublicRoutes
  , apiPathPrefix
  , authPathPrefix
  , canonicalPublicRouteCatalog
  , identityIssuerUrl
  , minioPathPrefix
  , publicEdgeClusterIssuerName
  , publicEdgeTlsRetentionKey
  , publicFqdn
  , publicRoutePathPrefix
  , publicRouteUrl
  , renderHelmRouteInventory
  , sharedPublicHostFqdns
  , resolveSubstrateHostedZoneId
  , substrateHostedZoneId
  , substrateIdentityIssuerUrl
  , substratePublicFqdn
  , substratePublicRouteUrl
  , vscodePathPrefix
  , websocketOidcPathPrefix
  , websocketPathPrefix
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.AwsEksSubzoneStack
  ( AwsEksSubzoneStackSnapshot (..)
  , parseAwsEksSubzoneStackFromOutputs
  )
import Prodbox.Infra.StackOutputs (StackName (..))
import Prodbox.Lifecycle.LiveResidue
  ( awsEksSubzoneStackName
  , fetchPerRunStackOutputs
  , publicEdgeTlsRetentionPrefix
  )
import Prodbox.Settings
  ( AwsSubstrateSection (..)
  , ConfigFile (..)
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , validatedConfig
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import Prodbox.Tls.CertScope (CertScopeSet, renderCertScopeSet)

data PublicEdgeRoute
  = PublicRouteAuth
  | PublicRouteVscode
  | PublicRouteApi
  | PublicRouteWebsocket
  | PublicRouteMinio
  deriving (Eq, Show)

authPathPrefix :: String
authPathPrefix = "/auth"

apiPathPrefix :: String
apiPathPrefix = "/api"

vscodePathPrefix :: String
vscodePathPrefix = "/vscode"

websocketPathPrefix :: String
websocketPathPrefix = "/ws"

websocketOidcPathPrefix :: String
websocketOidcPathPrefix = websocketPathPrefix ++ "/oidc"

minioPathPrefix :: String
minioPathPrefix = "/minio"

canonicalPublicRouteCatalog :: [PublicEdgeRoute]
canonicalPublicRouteCatalog =
  [ PublicRouteAuth
  , PublicRouteVscode
  , PublicRouteApi
  , PublicRouteWebsocket
  , PublicRouteMinio
  ]

adminPublicRoutes :: [PublicEdgeRoute]
adminPublicRoutes = [PublicRouteMinio]

publicRoutePathPrefix :: PublicEdgeRoute -> String
publicRoutePathPrefix route =
  case route of
    PublicRouteAuth -> authPathPrefix
    PublicRouteVscode -> vscodePathPrefix
    PublicRouteApi -> apiPathPrefix
    PublicRouteWebsocket -> websocketPathPrefix
    PublicRouteMinio -> minioPathPrefix

publicFqdn :: ValidatedSettings -> String
publicFqdn settings =
  Text.unpack (Text.strip (demo_fqdn (domain (validatedConfig settings))))

publicRouteUrl :: ValidatedSettings -> PublicEdgeRoute -> String
publicRouteUrl settings route =
  "https://" ++ publicFqdn settings ++ publicRoutePathPrefix route

identityIssuerUrl :: ValidatedSettings -> String
identityIssuerUrl settings = publicRouteUrl settings PublicRouteAuth ++ "/realms/prodbox"

sharedPublicHostFqdns :: ValidatedSettings -> [String]
sharedPublicHostFqdns settings = [publicFqdn settings]

substratePublicFqdn :: ValidatedSettings -> Substrate -> String
substratePublicFqdn settings substrate =
  case substrate of
    SubstrateHomeLocal -> publicFqdn settings
    SubstrateAws ->
      let stripped = Text.strip (subzone_name (aws_substrate (validatedConfig settings)))
       in if Text.null stripped
            then
              error
                "substratePublicFqdn: aws_substrate.subzone_name is empty; \
                \--substrate aws runs require aws_substrate.subzone_name per \
                \development_plan_standards.md \xc2\xa7 M (no fallback)"
            else Text.unpack stripped

substratePublicRouteUrl :: ValidatedSettings -> Substrate -> PublicEdgeRoute -> String
substratePublicRouteUrl settings substrate route =
  "https://" ++ substratePublicFqdn settings substrate ++ publicRoutePathPrefix route

-- | The single cert-manager ACME @ClusterIssuer@ that the public-edge
-- @Certificate@ references at chart deploy time. prodbox uses ZeroSSL as
-- its sole ACME provider, so there is one issuer for every substrate and
-- every deploy. The name is @zerossl-dns01@: a DNS-01-honest name that
-- matches the issuer's actual @acmeRoute53Solver@ (DNS-01 via Route 53),
-- not the historically-inaccurate HTTP-01-claiming name it replaced
-- (Sprint @7.13@). Must match the issuer name rendered by
-- @Prodbox.CLI.Rke2.acmeRuntimeManifestWith@. Rebuild cycles avoid
-- re-ordering the certificate through the S3-backed retention store
-- ('publicEdgeTlsRetentionKey') — keyed on substrate + the exact canonical
-- certificate scope set, not on the issuer name — so an exact-scope retained
-- cert restores without re-ordering from ZeroSSL.
publicEdgeClusterIssuerName :: String
publicEdgeClusterIssuerName = "zerossl-dns01"

-- | Sprints 7.11 / 2.35: the substrate-scoped S3 retention key for the
-- public-edge **production** TLS certificate material in the long-lived
-- @pulumi_state_backend@ bucket:
-- @public-edge-tls/\<substrate\>/\<canonical-scope-key\>@. The key consumes a
-- 'CertScopeSet', not caller text, so retention cannot drift from the canonical
-- deduped/ordered scope projection. The exact single-host default deliberately
-- preserves its historical key byte-for-byte. Wildcard and multi-scope syntax
-- is percent-escaped in the path segment so a literal certificate wildcard is
-- never interpreted as an IAM resource-pattern wildcard by the later
-- TLS-retention identity. Restore is exact-scope only: a different configured
-- scope lets cert-manager issue once and is retained under its own canonical
-- key. Every object remains grouped under the @public-edge-tls/@ prefix that
-- the Sprint 4.24 managed-resource @discover@ / @destroy@ operate over.
publicEdgeTlsRetentionKey :: Substrate -> CertScopeSet -> String
publicEdgeTlsRetentionKey substrate scopeSet =
  publicEdgeTlsRetentionPrefix
    ++ substrateId substrate
    ++ "/"
    ++ Text.unpack (renderRetentionScopePathSegment scopeSet)

renderRetentionScopePathSegment :: CertScopeSet -> Text
renderRetentionScopePathSegment =
  Text.replace "," "%2C"
    . Text.replace "*" "%2A"
    . renderCertScopeSet

substrateIdentityIssuerUrl :: ValidatedSettings -> Substrate -> String
substrateIdentityIssuerUrl settings substrate =
  substratePublicRouteUrl settings substrate PublicRouteAuth ++ "/realms/prodbox"

substrateHostedZoneId :: ValidatedSettings -> Substrate -> Text
substrateHostedZoneId settings substrate =
  case substrate of
    SubstrateHomeLocal -> zone_id (route53 (validatedConfig settings))
    SubstrateAws ->
      let stripped = Text.strip (hosted_zone_id (aws_substrate (validatedConfig settings)))
       in if Text.null stripped
            then
              error
                "substrateHostedZoneId: aws_substrate.hosted_zone_id is empty; \
                \--substrate aws runs require aws_substrate.hosted_zone_id per \
                \development_plan_standards.md \xc2\xa7 M (no fallback). Either \
                \set it in prodbox.dhall or call resolveSubstrateHostedZoneId \
                \from an IO context to consult the live aws-eks-subzone Pulumi stack \
                \snapshot."
            else stripped

-- | IO-context variant of 'substrateHostedZoneId' that, for the AWS substrate,
-- falls back to the live aws-eks-subzone Pulumi stack snapshot when the
-- operator has not populated @aws_substrate.hosted_zone_id@ in
-- @prodbox.dhall@. The Pulumi snapshot is written by
-- 'Prodbox.Infra.AwsEksSubzoneStack.ensureAwsEksSubzoneStackResources' as
-- part of the substrate-platform install, so by the time any AWS-substrate
-- canonical validation runs the snapshot is guaranteed to exist.
--
-- This is doctrine-compliant per
-- [development_plan_standards.md § M "Substrate coverage and independence
-- (no fallback)"](../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback):
-- a substrate may consume its own /operator-supplied config/ AND its own
-- /provisioned infrastructure/. The subzone Pulumi stack output IS the
-- AWS substrate's provisioned infrastructure, so reading it does not
-- silently substitute home-substrate values.
--
-- Sprint @7.13@: the hosted-zone id is sourced from settings
-- (@aws_substrate.hosted_zone_id@) and, failing that, the live
-- aws-eks-subzone Pulumi stack output — never from a
-- @PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID@ environment variable. The Dhall
-- @--config <path>@ is the sole source of binary configuration per
-- @documents/engineering/config_doctrine.md § 10@, and this module is
-- scoped by @checkEnvVarConfigReads@ so no @PRODBOX_*@ env read can
-- reappear here.
--
-- Returns 'Left' when both the config block and the Pulumi snapshot are
-- absent — the caller renders that as the canonical fail-fast error.
resolveSubstrateHostedZoneId
  :: FilePath -> ValidatedSettings -> Substrate -> IO (Either String Text)
resolveSubstrateHostedZoneId repoRoot settings substrate =
  case substrate of
    SubstrateHomeLocal ->
      pure (Right (zone_id (route53 (validatedConfig settings))))
    SubstrateAws -> do
      let configured =
            Text.strip (hosted_zone_id (aws_substrate (validatedConfig settings)))
      if not (Text.null configured)
        then pure (Right configured)
        else do
          -- Sprint 4.18: read the hosted zone ID from the live
          -- aws-eks-subzone Pulumi outputs rather than the legacy
          -- `.prodbox-state/aws-eks-subzone/stack-snapshot.json` file.
          outputsResult <-
            fetchPerRunStackOutputs repoRoot (StackName (Text.pack awsEksSubzoneStackName))
          pure $ case outputsResult of
            Left err ->
              Left
                ( "resolveSubstrateHostedZoneId: aws_substrate.hosted_zone_id is \
                  \empty and the live aws-eks-subzone Pulumi outputs could not \
                  \be read: "
                    ++ err
                    ++ ". Run `prodbox aws stack aws-subzone reconcile` to provision \
                       \the subzone, or set aws_substrate.hosted_zone_id in \
                       \prodbox.dhall."
                )
            Right outputs ->
              case parseAwsEksSubzoneStackFromOutputs outputs of
                Right snapshot ->
                  Right (Text.pack (subzoneSnapshotSubzoneId snapshot))
                Left err ->
                  Left
                    ( "resolveSubstrateHostedZoneId: aws_substrate.hosted_zone_id is \
                      \empty and the live aws-eks-subzone Pulumi outputs are \
                      \incomplete: "
                        ++ err
                        ++ ". Run `prodbox aws stack aws-subzone reconcile` to provision \
                           \the subzone, or set aws_substrate.hosted_zone_id in \
                           \prodbox.dhall."
                    )

renderHelmRouteInventory :: String
renderHelmRouteInventory =
  unlines $
    [ "{{/* Canonical public-edge route inventory generated from `src/Prodbox/PublicEdge.hs`. */}}"
    , "{{/* PUBLIC_FQDN=test.resolvefintech.com */}}"
    ]
      ++ map renderRouteComment canonicalPublicRouteCatalog
      ++ map renderAdminRouteComment adminPublicRoutes
 where
  renderRouteComment route =
    "{{/* ROUTE "
      ++ renderRouteName route
      ++ "="
      ++ publicRoutePathPrefix route
      ++ " */}}"
  renderAdminRouteComment route =
    "{{/* ADMIN_ROUTE "
      ++ renderRouteName route
      ++ "="
      ++ publicRoutePathPrefix route
      ++ " */}}"

renderRouteName :: PublicEdgeRoute -> String
renderRouteName route =
  case route of
    PublicRouteAuth -> "auth"
    PublicRouteVscode -> "vscode"
    PublicRouteApi -> "api"
    PublicRouteWebsocket -> "websocket"
    PublicRouteMinio -> "minio"
