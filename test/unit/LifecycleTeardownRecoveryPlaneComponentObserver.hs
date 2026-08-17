module LifecycleTeardownRecoveryPlaneComponentObserver
  ( lifecycleTeardownRecoveryPlaneComponentObserverSuite
  )
where

import Control.Monad (filterM, forM_)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (..)
  , ordinaryTeardownRecovery
  , ordinaryTeardownRecoveryChartNames
  )
import Prodbox.Lib.ChartPlatform (recoveryObserverRbacChartNames)
import Prodbox.Lifecycle.Teardown.RecoveryPlaneComponentObserver
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownRecoveryPlaneComponentObserverSuite :: SuiteBuilder ()
lifecycleTeardownRecoveryPlaneComponentObserverSuite =
  describe "production recovery-plane component observer" $ do
    it "accepts only the closed exact ready inventory" $ do
      let regression = fixedRecoveryPlaneComponentObserverRegression
      recoveryPlaneComponentObserverClosedInventory regression `shouldBe` True
      recoveryPlaneComponentObserverReadyRowsExact regression `shouldBe` True
      recoveryPlaneComponentObserverExternalCallerExact regression `shouldBe` True

    it "keeps missing, malformed, unauthorized, partial, and unknown observations non-ready" $ do
      let regression = fixedRecoveryPlaneComponentObserverRegression
      recoveryPlaneComponentObserverMissingRefused regression `shouldBe` True
      recoveryPlaneComponentObserverMalformedRefused regression `shouldBe` True
      recoveryPlaneComponentObserverUnauthorizedRefused regression `shouldBe` True
      recoveryPlaneComponentObserverPartialRolloutRefused regression `shouldBe` True
      recoveryPlaneComponentObserverInvalidUidRefused regression `shouldBe` True
      recoveryPlaneComponentObserverGenerationMismatchRefused regression `shouldBe` True
      recoveryPlaneComponentObserverConditionMismatchRefused regression `shouldBe` True
      recoveryPlaneComponentObserverVaultSealedRefused regression `shouldBe` True
      recoveryPlaneComponentObserverNetworkUnknownRefused regression `shouldBe` True

    it "grants the Authority exact-name GET only in recovery-profile namespaces" $ do
      recoveryObserverRbacChartNames
        `shouldBe` [ "minio"
                   , "vault"
                   , "bootstrap-broker"
                   , "lifecycle-authority"
                   , "authority-backup"
                   , "provider-worker"
                   , "target-secret-agent"
                   ]
      forM_ recoveryObserverRbacChartNames $ \chartName -> do
        template <-
          readFile
            ( "charts/"
                ++ chartName
                ++ "/templates/recovery-observer-rbac.yaml"
            )
        template `shouldContain` "resourceNames:"
        template `shouldContain` "verbs: [\"get\"]"
        template
          `shouldContain` ".Values.recoveryObserver.serviceAccountName"
        template
          `shouldContain` ".Values.recoveryObserver.serviceAccountNamespace"
        template `shouldNotContain` "verbs: [\"list\"]"
        template `shouldNotContain` "verbs: [\"watch\"]"
        template `shouldNotContain` "resources: [\"secrets\"]"

    it "keeps the bootstrap caller and API egress tied to their existing owners" $ do
      brokerRbac <-
        readFile
          "charts/bootstrap-broker/templates/recovery-observer-rbac.yaml"
      brokerRbac
        `shouldContain` ".Values.cleanupCaller.serviceAccountName"
      brokerRbac `shouldContain` "resources: [\"serviceaccounts\"]"
      brokerRbac `shouldContain` "resources: [\"roles\", \"rolebindings\"]"
      authorityPolicy <-
        readFile
          "charts/lifecycle-authority/templates/networkpolicy.yaml"
      authorityPolicy
        `shouldContain` "range .Values.kubernetesApiEgress.addresses"
      authorityPolicy `shouldContain` ".Values.kubernetesApiEgress.port"
      chartPlatform <- readFile "src/Prodbox/Lib/ChartPlatform.hs"
      chartPlatform `shouldContain` "lifecycleAuthorityRecoveryObserverValue"
      chartPlatform `shouldContain` "attachRecoveryObserverValues"
      checkCode <- readFile "src/Prodbox/CheckCode.hs"
      checkCode `shouldContain` "recoveryObserverRbacChartViolations"

    it "derives only the recovery closure and excludes Gateway/app charts" $ do
      withoutTarget <-
        either
          (\err -> expectationFailure (show err) >> fail "invalid recovery profile")
          pure
          (ordinaryTeardownRecovery OrdinaryTeardownWithoutTargetAgent)
      withTarget <-
        either
          (\err -> expectationFailure (show err) >> fail "invalid recovery profile")
          pure
          (ordinaryTeardownRecovery OrdinaryTeardownWithTargetAgent)
      ordinaryTeardownRecoveryChartNames withoutTarget
        `shouldBe` [ "bootstrap-broker"
                   , "lifecycle-authority"
                   , "authority-backup"
                   , "provider-worker"
                   ]
      ordinaryTeardownRecoveryChartNames withTarget
        `shouldBe` [ "bootstrap-broker"
                   , "target-secret-agent"
                   , "lifecycle-authority"
                   , "authority-backup"
                   , "provider-worker"
                   ]
      recoveryObserverRbacChartNames `shouldNotContain` ["gateway"]

    it "keeps raw rows, effects, clients, and the production factory hidden" $ do
      let regression = fixedRecoveryPlaneComponentObserverRegression
      recoveryPlaneComponentObserverOpacityClosed regression `shouldBe` True
      facade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneComponentObserver.hs"
      let header = moduleHeader facade
      mapM_
        (header `shouldNotContain`)
        [ "productionRecoveryPlaneComponentObserverInternal"
        , "RecoveryPlaneComponentObserverEffects"
        , "RecoveryPlaneKubernetesResult"
        , "RecoveryPlaneRawComponentResult"
        , "LocalRke2HostObservationRepositoryClient"
        , "ByteString"
        ]
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.RecoveryPlaneComponentObserver.Internal"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/Runtime.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneComponentObserver.hs"
                   ]

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (importNeedle `isInfixOf` contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | ".hs" `isSuffixOf` path]
