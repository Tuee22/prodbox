-- | Sprint 3.47: Keycloak is started with its public URL, not only its public
-- host, so no request can change the issuer of a token it issues.
--
-- Envoy validates a bearer token against the issuer
-- @https://\<host\>/auth/realms/prodbox@. A bare @--hostname=\<host\>@ takes the
-- scheme and port from the request, and a request over the in-cluster backchannel
-- carries no forwarded headers, so the token the harness issues inside the Pod
-- (and the one the websocket workload exchanges) was issued under
-- @http://\<host\>:8080/auth/realms/prodbox@ and refused with @Jwt issuer is not
-- configured@. Measured against the pinned @keycloak:26.0.0@ on 2026-10-12: the
-- full URL with the path makes the issuer @https://\<host\>/auth/realms/\<realm\>@
-- for every request, and the same URL without the path drops @/auth@.
module KeycloakPublicIssuer (keycloakPublicIssuerSuite) where

import Data.List (isInfixOf)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

keycloakPublicIssuerSuite :: SuiteBuilder ()
keycloakPublicIssuerSuite =
  describe "Sprint 3.47 Keycloak issues every token under the public issuer" $ do
    it "starts with the full public URL, path included, so no request can change the issuer" $ do
      deployment <- keycloakDeploymentTemplate
      deployment
        `shouldSatisfy` carries
          "--hostname=https://{{ .Values.keycloak.publicHost }}{{ .Values.keycloak.httpRelativePath }}"
      -- The path the URL carries is the path Keycloak serves under, and the proxy
      -- headers still describe browser requests that arrive through the edge.
      deployment `shouldSatisfy` carries "--http-relative-path={{ .Values.keycloak.httpRelativePath }}"
      deployment `shouldSatisfy` carries "--proxy-headers=xforwarded"

    it "no longer passes the bare host, which took its scheme and port from the request" $ do
      deployment <- keycloakDeploymentTemplate
      deployment `shouldSatisfy` (not . carries "--hostname={{ .Values.keycloak.publicHost }} ")

-- | Whether the template carries the argument. A failure names the case and not
-- the whole template.
carries :: String -> String -> Bool
carries = isInfixOf

keycloakDeploymentTemplate :: IO String
keycloakDeploymentTemplate = do
  repoRoot <- getCurrentDirectory
  readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "deployment.yaml")
