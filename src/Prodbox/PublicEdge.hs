{-# LANGUAGE OverloadedStrings #-}

module Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , adminPublicRoutes
  , apiPathPrefix
  , authPathPrefix
  , canonicalPublicRouteCatalog
  , harborPathPrefix
  , identityIssuerUrl
  , minioPathPrefix
  , publicFqdn
  , publicRoutePathPrefix
  , publicRouteUrl
  , renderHelmRouteInventory
  , sharedPublicHostFqdns
  , substrateHostedZoneId
  , substrateKubeconfigPath
  , substratePublicFqdn
  , vscodePathPrefix
  , websocketOidcPathPrefix
  , websocketPathPrefix
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Settings
  ( AwsSubstrateSection (..)
  , ConfigFile (..)
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  )
import Prodbox.Substrate (Substrate (..))
import System.FilePath ((</>))

data PublicEdgeRoute
  = PublicRouteAuth
  | PublicRouteVscode
  | PublicRouteApi
  | PublicRouteWebsocket
  | PublicRouteHarbor
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

harborPathPrefix :: String
harborPathPrefix = "/harbor"

minioPathPrefix :: String
minioPathPrefix = "/minio"

canonicalPublicRouteCatalog :: [PublicEdgeRoute]
canonicalPublicRouteCatalog =
  [ PublicRouteAuth
  , PublicRouteVscode
  , PublicRouteApi
  , PublicRouteWebsocket
  , PublicRouteHarbor
  , PublicRouteMinio
  ]

adminPublicRoutes :: [PublicEdgeRoute]
adminPublicRoutes = [PublicRouteHarbor, PublicRouteMinio]

publicRoutePathPrefix :: PublicEdgeRoute -> String
publicRoutePathPrefix route =
  case route of
    PublicRouteAuth -> authPathPrefix
    PublicRouteVscode -> vscodePathPrefix
    PublicRouteApi -> apiPathPrefix
    PublicRouteWebsocket -> websocketPathPrefix
    PublicRouteHarbor -> harborPathPrefix
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
                \development_plan_standards.md \xc2\xa7 M (no fallback)"
            else stripped

substrateKubeconfigPath :: FilePath -> Substrate -> Maybe FilePath
substrateKubeconfigPath repoRoot substrate =
  case substrate of
    SubstrateHomeLocal -> Nothing
    SubstrateAws ->
      Just (repoRoot </> ".prodbox-state" </> "aws-eks-test" </> "kubeconfig")

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
    PublicRouteHarbor -> "harbor"
    PublicRouteMinio -> "minio"
