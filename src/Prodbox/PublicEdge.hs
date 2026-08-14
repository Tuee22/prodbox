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
  , substrateIdentityIssuerUrl
  , substratePublicRouteUrl
  , substrateServedHostMissing
  , requireSubstratePublicFqdn
  , requireSubstrateCertScopeSet
  , requireSubstrateServedHost
  , servedHostString
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
  ( ValidatedCoordinates (..)
  , ValidatedPublicEdge (..)
  , ValidatedServedHost (..)
  , ValidatedSettings (..)
  , substrateServedHost
  , validatedCoordinates
  , validatedPublicEdge
  )
import Prodbox.Settings.Coordinate (route53ZoneIdText)
import Prodbox.Substrate (Substrate (..), substrateId)
import Prodbox.Tls.CertScope (CertScopeSet, fqdnText, renderCertScopeSet)

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

-- | The home substrate's served host.
--
-- Sprint 1.89: this read @domain.demo_fqdn@ and stripped it, which re-derived a
-- value 'validatedPublicEdge' already carried in parsed form — the exact
-- re-derivation Sprint 1.83 created that field to end, left behind because the
-- string here looked too small to be worth routing. It is the same value: the
-- 'Fqdn' is minted from this field by the one validation.
publicFqdn :: ValidatedSettings -> String
publicFqdn = servedHostString . validatedHomeServedHost . validatedPublicEdge

publicRouteUrl :: ValidatedSettings -> PublicEdgeRoute -> String
publicRouteUrl settings route =
  "https://" ++ publicFqdn settings ++ publicRoutePathPrefix route

identityIssuerUrl :: ValidatedSettings -> String
identityIssuerUrl settings = publicRouteUrl settings PublicRouteAuth ++ "/realms/prodbox"

sharedPublicHostFqdns :: ValidatedSettings -> [String]
sharedPublicHostFqdns settings = [publicFqdn settings]

-- | The served host as the string the renderers below want.
servedHostString :: ValidatedServedHost -> String
servedHostString = Text.unpack . fqdnText . servedHostFqdn

-- | The substrate's served host for a caller that has an error channel: the
-- substrate either has a served host or the config does not declare one, and
-- the second case is a refusal rather than an empty hostname.
--
-- Sprint 1.83 introduced the string-projecting 'requireSubstratePublicFqdn'
-- below and converted the callers that already sat in an @Either@. Sprint 1.84
-- converted the six direct consumers of the former empty-string accessor and
-- made that accessor module-private. Sprint 1.87 removes it outright and makes
-- this the __only__ way to obtain a substrate's served host: the renderers
-- below take a 'ValidatedServedHost' rather than a @ValidatedSettings@ and a
-- 'Substrate', so \"this config declares no served host for that substrate\" is
-- no longer one of their inputs and @https:\/\/\/path@ is not a string any of
-- them can produce.
--
-- The state itself is real and unchanged: @aws_substrate.subzone_name@ is
-- required by 'Prodbox.Settings.validateAwsBootstrapConfig', the AWS config
-- tier, and deliberately not by the local one, because declaring no AWS served
-- host is the correct state for a home-only host. What Sprints 1.81–1.87
-- removed is representing that state as a served hostname.
requireSubstrateServedHost
  :: ValidatedSettings -> Substrate -> Either String ValidatedServedHost
requireSubstrateServedHost settings substrate =
  maybe
    (Left (substrateServedHostMissing substrate))
    Right
    (substrateServedHost settings substrate)

-- | The served hostname a substrate declares, for a caller that wants the bare
-- string rather than the parsed host.
requireSubstratePublicFqdn :: ValidatedSettings -> Substrate -> Either String String
requireSubstratePublicFqdn settings substrate =
  servedHostString <$> requireSubstrateServedHost settings substrate

-- | The certificate scope set the substrate's served host projects, read from
-- the parse config validation performed rather than re-derived from raw text.
requireSubstrateCertScopeSet :: ValidatedSettings -> Substrate -> Either String CertScopeSet
requireSubstrateCertScopeSet settings substrate =
  servedHostCertScopes <$> requireSubstrateServedHost settings substrate

-- | The one wording for \"this config declares no served host for that
-- substrate\", so the same state does not get three different messages.
substrateServedHostMissing :: Substrate -> String
substrateServedHostMissing substrate =
  substrateId substrate
    ++ " public FQDN is not configured: aws_substrate.subzone_name is required by "
    ++ "the AWS config tier and this config was validated only locally"

-- | The canonical HTTPS URL of a public-edge route on a substrate's served
-- host.
--
-- Sprint 1.87: the host argument is a 'ValidatedServedHost', which carries a
-- 'Prodbox.Tls.CertScope.Fqdn' — a hidden-constructor newtype minted only by
-- 'Prodbox.Tls.CertScope.mkFqdn', which rejects the empty string. The former
-- @https:\/\/\/path@ rendering is therefore not merely refused here, it is
-- unconstructible: there is no inhabitant of this argument that produces it.
-- Callers resolve through 'requireSubstrateServedHost' at whichever boundary
-- has an error channel.
substratePublicRouteUrl :: ValidatedServedHost -> PublicEdgeRoute -> String
substratePublicRouteUrl servedHost route =
  "https://" ++ servedHostString servedHost ++ publicRoutePathPrefix route

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

substrateIdentityIssuerUrl :: ValidatedServedHost -> String
substrateIdentityIssuerUrl servedHost =
  substratePublicRouteUrl servedHost PublicRouteAuth ++ "/realms/prodbox"

-- | IO-context resolver for the hosted zone. For the AWS substrate this
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
      -- Sprint 1.89: the home zone id is the parsed coordinate rather than the
      -- raw field. It stays `Maybe` here because an unset home zone is the
      -- correct state for a host that never touches AWS; what changed is that a
      -- SET value has been through 'mkRoute53ZoneId', so this can no longer
      -- return a string that is not a zone id.
      pure $ case coordinateHomeZoneId (validatedCoordinates settings) of
        Just zoneId -> Right (route53ZoneIdText zoneId)
        Nothing ->
          Left
            "resolveSubstrateHostedZoneId: route53.zone_id is empty. Set it in \
            \prodbox.dhall to name the home substrate's Route 53 hosted zone."
    SubstrateAws -> do
      let configured =
            fmap route53ZoneIdText (coordinateAwsSubstrateZoneId (validatedCoordinates settings))
      case configured of
        Just zoneId -> pure (Right zoneId)
        Nothing -> do
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
