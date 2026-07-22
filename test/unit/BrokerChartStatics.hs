{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26 (increment A) conformance suite: the physically separate
-- Bootstrap Broker workload has its own compiled identity. Proves the broker
-- ServiceAccount/Vault-role is distinct from the Gateway Runtime's (the
-- anti-shared-identity invariant), the ServiceAccount and Vault role are the
-- same bootstrap-only identity, no two roles in the closed 'VaultRoleId'
-- inventory share a name, and the liveness/readiness probe paths are exact
-- projections of the closed 'BrokerRoute' registry.
module BrokerChartStatics
  ( brokerChartStaticsSuite
  )
where

import Data.List (isInfixOf, nub, sort)
import Prodbox.Bootstrap.Broker.ChartStatics
import Prodbox.Bootstrap.Broker.Routes qualified as Routes
import Prodbox.CheckCode
  ( bootstrapBrokerChartStaticViolations
  , bootstrapBrokerChartStaticsConformanceViolations
  )
import Prodbox.Gateway.ChartStatics (gatewayChartStatics, gatewayStaticVaultRole)
import Prodbox.Vault.RoleId
  ( VaultRoleId (VaultRoleBootstrapBroker, VaultRoleGatewayDaemon)
  , allVaultRoleIds
  , vaultRoleIdText
  )
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

brokerChartStaticsSuite :: SuiteBuilder ()
brokerChartStaticsSuite =
  describe "Sprint 3.26 compiled Bootstrap Broker chart statics" $ do
    it "unifies the ServiceAccount name with the bootstrap-only Vault role" $ do
      brokerStaticServiceAccount brokerChartStatics
        `shouldBe` brokerStaticVaultRole brokerChartStatics
      brokerStaticVaultRole brokerChartStatics
        `shouldBe` vaultRoleIdText VaultRoleBootstrapBroker
      brokerStaticServiceAccount brokerChartStatics `shouldBe` "prodbox-bootstrap-broker"

    it "gives the broker a distinct identity from the Gateway Runtime" $ do
      -- The physically separate workloads must never share a ServiceAccount or
      -- Vault role: this is the anti-shared-identity invariant of Sprint 3.26.
      brokerStaticVaultRole brokerChartStatics
        `shouldNotBe` gatewayStaticVaultRole gatewayChartStatics
      vaultRoleIdText VaultRoleBootstrapBroker
        `shouldNotBe` vaultRoleIdText VaultRoleGatewayDaemon

    it "keeps every Vault role name in the closed inventory distinct" $ do
      let names = map vaultRoleIdText allVaultRoleIds
      sort (nub names) `shouldBe` sort names
      length names `shouldBe` 2

    it "projects the liveness and readiness paths from the closed route registry" $ do
      brokerStaticLivenessPath brokerChartStatics
        `shouldBe` "/healthz"
      brokerStaticReadinessPath brokerChartStatics
        `shouldBe` "/readyz"
      -- The projection is the registry, not a hand-written duplicate.
      map (Routes.brokerRoutePath) [Routes.BrokerHealth, Routes.BrokerReadiness]
        `shouldBe` ["/healthz", "/readyz"]

    it "renders the generated values block from the typed statics" $ do
      renderBrokerChartStaticsYaml
        `shouldBe` unlines
          [ "serviceAccount:"
          , "  name: prodbox-bootstrap-broker"
          , "vault:"
          , "  role: prodbox-bootstrap-broker"
          , "probes:"
          , "  liveness: /healthz"
          , "  readiness: /readyz"
          ]

    it "certifies the committed values.yaml equals the compiled projection" $ do
      repoRoot <- getCurrentDirectory
      valuesContents <- readFile (repoRoot </> "charts" </> "bootstrap-broker" </> "values.yaml")
      bootstrapBrokerChartStaticsConformanceViolations valuesContents `shouldBe` []

    it "rejects a values.yaml whose static default has drifted from the compiled projection" $ do
      let drifted =
            "serviceAccount:\n  name: prodbox-wrong-broker\nvault:\n  role: prodbox-bootstrap-broker\n"
              ++ "probes:\n  liveness: /healthz\n  readiness: /readyz\n"
      bootstrapBrokerChartStaticsConformanceViolations drifted
        `shouldSatisfy` any ("serviceAccount.name" `isInfixOf`)

    it "accepts the values-backed hand-written broker templates" $ do
      repoRoot <- getCurrentDirectory
      let templates = repoRoot </> "charts" </> "bootstrap-broker" </> "templates"
      serviceAccountContents <- readFile (templates </> "serviceaccount.yaml")
      deploymentContents <- readFile (templates </> "deployment.yaml")
      valuesContents <- readFile (repoRoot </> "charts" </> "bootstrap-broker" </> "values.yaml")
      bootstrapBrokerChartStaticViolations serviceAccountContents deploymentContents valuesContents
        `shouldBe` []

    it "rejects a hand-written ServiceAccount name hard-coded to the raw role literal" $ do
      let rawServiceAccount = "metadata:\n  name: prodbox-bootstrap-broker\n"
          rawDeployment = "spec:\n  serviceAccountName: prodbox-bootstrap-broker\n"
      bootstrapBrokerChartStaticViolations rawServiceAccount rawDeployment renderBrokerChartStaticsYaml
        `shouldSatisfy` (\violations -> length violations >= 2)

    it "rejects a deployment probe path hard-coded to the raw route literal" $ do
      let rawDeployment =
            "          livenessProbe:\n            httpGet:\n              path: /healthz\n"
      bootstrapBrokerChartStaticViolations "" rawDeployment renderBrokerChartStaticsYaml
        `shouldSatisfy` any ("probe path" `isInfixOf`)

    it "flags a values.yaml missing the generated statics block" $ do
      let valuesBackedServiceAccount = "metadata:\n  name: {{ .Values.serviceAccount.name }}\n"
          valuesBackedDeployment =
            "spec:\n  serviceAccountName: {{ .Values.serviceAccount.name }}\n"
              ++ "          livenessProbe:\n            httpGet:\n              path: {{ .Values.probes.liveness | quote }}\n"
      bootstrapBrokerChartStaticViolations
        valuesBackedServiceAccount
        valuesBackedDeployment
        "serviceAccount:\n  name: prodbox-bootstrap-broker\n"
        `shouldSatisfy` any ("generated BrokerChartStatics defaults" `isInfixOf`)
