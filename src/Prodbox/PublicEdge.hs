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
  , resolveSubstrateHostedZoneId
  , substrateHostedZoneId
  , substrateKubeconfigPath
  , substratePublicFqdn
  , withSubstrateKubectlEnvironment
  , vscodePathPrefix
  , websocketOidcPathPrefix
  , websocketPathPrefix
  )
where

import Control.Exception (bracket_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.StackOutputs (StackName (..))
import Prodbox.Lifecycle.LiveResidue
  ( awsEksSubzoneStackName
  , fetchPerRunStackOutputs
  )
import Prodbox.Settings
  ( AwsSubstrateSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , validatedConfig
  )
import Prodbox.Substrate (Substrate (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)
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
                \development_plan_standards.md \xc2\xa7 M (no fallback). Either \
                \set it in prodbox-config.dhall or call resolveSubstrateHostedZoneId \
                \from an IO context to consult the live aws-eks-subzone Pulumi stack \
                \snapshot."
            else stripped

-- | IO-context variant of 'substrateHostedZoneId' that, for the AWS substrate,
-- falls back to the live aws-eks-subzone Pulumi stack snapshot when the
-- operator has not populated @aws_substrate.hosted_zone_id@ in
-- @prodbox-config.dhall@. The Pulumi snapshot is written by
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
            Right outputs
              | Just subzoneId <- Map.lookup "subzone_id" outputs
              , not (Text.null subzoneId) ->
                  Right subzoneId
            _ ->
              Left
                "resolveSubstrateHostedZoneId: aws_substrate.hosted_zone_id is \
                \empty and the live aws-eks-subzone Pulumi backend has no \
                \subzone_id output. Run `prodbox pulumi aws-subzone-resources \
                \--yes` to provision the subzone, or set \
                \aws_substrate.hosted_zone_id in prodbox-config.dhall."

substrateKubeconfigPath :: FilePath -> Substrate -> Maybe FilePath
substrateKubeconfigPath repoRoot substrate =
  case substrate of
    SubstrateHomeLocal -> Nothing
    SubstrateAws ->
      Just (repoRoot </> ".prodbox-state" </> "aws-eks-test" </> "kubeconfig")

-- | Sprint 7.5.c.v follow-up: bracket an IO action with the
-- substrate-specific @KUBECONFIG@ + @AWS_*@ environment so kubectl and
-- @aws eks get-token@ subprocesses speak to the correct cluster. Returns
-- the action unchanged on the home substrate (kubectl uses the ambient
-- kubeconfig from @/etc/rancher/rke2/rke2.yaml@ or @~\/.kube\/config@,
-- and no AWS creds are needed). On the AWS substrate this mirrors the
-- @withSubstrateEnvironment@ helper in @Prodbox.CLI.Charts@ so the
-- @prodbox host public-edge --substrate aws@ diagnostic walks the
-- EKS-side @envoy-gateway-system@ / @vscode@ / @cert-manager@
-- namespaces instead of the local cluster's.
withSubstrateKubectlEnvironment
  :: FilePath -> ValidatedSettings -> Substrate -> IO a -> IO a
withSubstrateKubectlEnvironment repoRoot settings substrate action =
  case substrateKubeconfigPath repoRoot substrate of
    Nothing -> action
    Just kubeconfigPath -> do
      let awsCreds = aws (validatedConfig settings)
          envOverrides =
            [ ("KUBECONFIG", kubeconfigPath)
            , ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id awsCreds))
            , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key awsCreds))
            , ("AWS_DEFAULT_REGION", Text.unpack (region awsCreds))
            , ("AWS_REGION", Text.unpack (region awsCreds))
            ]
              ++ maybe [] (\tok -> [("AWS_SESSION_TOKEN", Text.unpack tok)]) (session_token awsCreds)
      previousValues <- mapM (lookupEnv . fst) envOverrides
      bracket_
        (mapM_ (uncurry setEnv) envOverrides)
        (mapM_ restoreOne (zip envOverrides previousValues))
        action
 where
  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value

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
