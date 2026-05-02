{-# LANGUAGE OverloadedStrings #-}

module Prodbox.PublicEdge (
    PublicEdgeRoute (..),
    adminPublicRoutes,
    apiPathPrefix,
    authPathPrefix,
    canonicalPublicRouteCatalog,
    harborPathPrefix,
    identityIssuerUrl,
    minioPathPrefix,
    publicFqdn,
    publicRoutePathPrefix,
    publicRouteUrl,
    sharedPublicHostFqdns,
    vscodePathPrefix,
    websocketOidcPathPrefix,
    websocketPathPrefix,
)
where

import Data.Text qualified as Text
import Prodbox.Settings (
    ConfigFile (..),
    DomainSection (..),
    ValidatedSettings (..),
 )

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
