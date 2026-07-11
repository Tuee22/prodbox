{-# LANGUAGE ImportQualifiedPost #-}

module GatewayProbe
  ( gatewayProbeSuite
  )
where

import Control.Monad (forM_)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isInfixOf)
import Prodbox.CheckCode (gatewayProbeViolations)
import Prodbox.Gateway.Probe
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

gatewayProbeSuite :: SuiteBuilder ()
gatewayProbeSuite =
  describe "Sprint 3.25 constant-time gateway chart probes" $ do
    it "keeps the typed lifecycle endpoints and kubelet timings explicit" $ do
      gatewayProbeEndpointPath (gatewayProbeEndpoint gatewayLivenessProbe)
        `shouldBe` "/healthz"
      gatewayProbeInitialDelaySeconds gatewayLivenessProbe `shouldBe` 10
      gatewayProbePeriodSeconds gatewayLivenessProbe `shouldBe` 15
      gatewayProbeTimeoutSeconds gatewayLivenessProbe `shouldBe` 1
      gatewayProbeFailureThreshold gatewayLivenessProbe `shouldBe` 3
      gatewayProbeSuccessThreshold gatewayLivenessProbe `shouldBe` 1
      gatewayProbeEndpointPath (gatewayProbeEndpoint gatewayReadinessProbe)
        `shouldBe` "/readyz"
      gatewayProbeInitialDelaySeconds gatewayReadinessProbe `shouldBe` 5
      gatewayProbePeriodSeconds gatewayReadinessProbe `shouldBe` 10
      gatewayProbeTimeoutSeconds gatewayReadinessProbe `shouldBe` 1
      gatewayProbeFailureThreshold gatewayReadinessProbe `shouldBe` 3
      gatewayProbeSuccessThreshold gatewayReadinessProbe `shouldBe` 1

    goldenTest
      "renders the typed gateway probe defaults"
      "test/golden/charts/gateway-probes-values.yaml"
      (pure (BL8.pack renderGatewayProbeDefaultsYaml))

    it "accepts the canonical values-backed chart surface" $ do
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "deployments.yaml")
      valuesContents <- readFile (repoRoot </> "charts" </> "gateway" </> "values.yaml")
      gatewayProbeViolations deploymentTemplate valuesContents `shouldBe` []
      deploymentTemplate `shouldNotContain` "/v1/state"
      valuesContents `shouldNotContain` "/v1/state"

    it "rejects /v1/state independently in either lifecycle probe" $ do
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "deployments.yaml")
      let fixtureDirectory = repoRoot </> "test" </> "unit" </> "fixtures" </> "gateway-probes"
      forM_
        [ fixtureDirectory </> "liveness-v1-state.values.yaml"
        , fixtureDirectory </> "readiness-v1-state.values.yaml"
        ]
        (assertForbiddenFixture deploymentTemplate)

assertForbiddenFixture :: String -> FilePath -> Expectation
assertForbiddenFixture deploymentTemplate fixturePath = do
  valuesFixture <- readFile fixturePath
  gatewayProbeViolations deploymentTemplate valuesFixture
    `shouldSatisfy` any ("forbidden kubelet probe path `/v1/state`" `isInfixOf`)
