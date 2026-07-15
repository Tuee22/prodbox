{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.34 conformance suite: the compiled gateway chart-statics source of
-- truth. Proves the deployed helm values equal the compiled projection, the
-- @values.yaml@ generated block matches the renderer, and the hand-written
-- ServiceAccount templates flow from @.Values@ rather than raw literals.
module GatewayChartStatics
  ( gatewayChartStaticsSuite
  )
where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.CheckCode
  ( gatewayChartStaticViolations
  , gatewayChartStaticsConformanceViolations
  )
import Prodbox.Gateway.ChartStatics
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

gatewayChartStaticsSuite :: SuiteBuilder ()
gatewayChartStaticsSuite =
  describe "Sprint 2.34 compiled gateway chart statics" $ do
    it "unifies the ServiceAccount name with the Vault role identity" $ do
      gatewayStaticServiceAccount gatewayChartStatics
        `shouldBe` gatewayStaticVaultRole gatewayChartStatics
      gatewayStaticRestPort gatewayChartStatics `shouldBe` 8443
      gatewayStaticEventsPort gatewayChartStatics `shouldBe` 8444
      gatewayStaticNodePort gatewayChartStatics `shouldBe` 30443

    it "renders the generated values block from the typed statics" $ do
      renderGatewayChartStaticsYaml
        `shouldBe` unlines
          [ "ports:"
          , "  rest: 8443"
          , "  events: 8444"
          , "nodePort:"
          , "  rest: 30443"
          , "serviceAccount:"
          , "  name: prodbox-gateway-daemon"
          ]

    it "certifies the committed values.yaml equals the compiled projection" $ do
      repoRoot <- getCurrentDirectory
      valuesContents <- readFile (repoRoot </> "charts" </> "gateway" </> "values.yaml")
      gatewayChartStaticsConformanceViolations valuesContents `shouldBe` []

    it "rejects a values.yaml whose static default has drifted from the compiled projection" $ do
      let drifted =
            "ports:\n  rest: 9999\n  events: 8444\nnodePort:\n  rest: 30443\n"
              ++ "serviceAccount:\n  name: prodbox-gateway-daemon\nvault:\n  role: prodbox-gateway-daemon\n"
      gatewayChartStaticsConformanceViolations drifted
        `shouldSatisfy` any ("ports.rest" `isInfixOf`)

    it "accepts the values-backed hand-written ServiceAccount templates" $ do
      repoRoot <- getCurrentDirectory
      let templates = repoRoot </> "charts" </> "gateway" </> "templates"
      serviceAccountContents <- readFile (templates </> "serviceaccount.yaml")
      deploymentContents <- readFile (templates </> "deployments.yaml")
      valuesContents <- readFile (repoRoot </> "charts" </> "gateway" </> "values.yaml")
      gatewayChartStaticViolations serviceAccountContents deploymentContents valuesContents
        `shouldBe` []

    it "rejects a hand-written ServiceAccount name hard-coded to the raw role literal" $ do
      let rawServiceAccount = "metadata:\n  name: prodbox-gateway-daemon\n"
          rawDeployment = "spec:\n  serviceAccountName: prodbox-gateway-daemon\n"
      gatewayChartStaticViolations rawServiceAccount rawDeployment renderGatewayChartStaticsYaml
        `shouldSatisfy` (\violations -> length violations >= 2)

    it "flags a values.yaml missing the generated statics block" $ do
      let saName = Text.unpack (gatewayStaticServiceAccount gatewayChartStatics)
          valuesBackedServiceAccount = "metadata:\n  name: {{ .Values.serviceAccount.name }}\n"
          valuesBackedDeployment = "spec:\n  serviceAccountName: {{ .Values.serviceAccount.name }}\n"
      -- Templates are clean, but the values.yaml lacks the generated block.
      saName `shouldBe` "prodbox-gateway-daemon"
      gatewayChartStaticViolations
        valuesBackedServiceAccount
        valuesBackedDeployment
        "ports:\n  rest: 8443\n"
        `shouldSatisfy` any ("generated GatewayChartStatics defaults" `isInfixOf`)
