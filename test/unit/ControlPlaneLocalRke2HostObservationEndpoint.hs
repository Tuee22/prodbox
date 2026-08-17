module ControlPlaneLocalRke2HostObservationEndpoint
  ( controlPlaneLocalRke2HostObservationEndpointSuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( callerMayCallRoute
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService, CallerTestHarness)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneRouteFor (LifecycleLocalRke2HostObservationRoute)
  , controlPlaneRouteForValue
  )
import Prodbox.ControlPlane.LocalRke2HostObservationEndpoint
import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlanePost)
  , ControlPlaneRoute (LifecycleLocalRke2HostObservation)
  , controlPlaneRouteMethod
  , controlPlaneRoutePath
  , controlPlaneRouteRole
  )
import Prodbox.ControlPlane.Server
  ( controlPlaneMaximumLifecycleInputBodyBytes
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

controlPlaneLocalRke2HostObservationEndpointSuite :: SuiteBuilder ()
controlPlaneLocalRke2HostObservationEndpointSuite =
  describe "host-only local RKE2 observation Authority endpoint" $ do
    it "accepts one canonical commit request and returns no proof" $ do
      regression <- fixedLocalRke2HostObservationEndpointRegression
      localRke2HostObservationEndpointValidExact regression `shouldBe` True

    it "refuses malformed, oversized, and invalid requests before execution" $ do
      regression <- fixedLocalRke2HostObservationEndpointRegression
      localRke2HostObservationEndpointMalformedNoExecution regression `shouldBe` True
      localRke2HostObservationEndpointOversizeNoExecution regression `shouldBe` True
      localRke2HostObservationEndpointInvalidIdentityNoExecution regression `shouldBe` True
      localRke2HostObservationEndpointUnsupportedVersionNoExecution regression `shouldBe` True
      localRke2HostObservationEndpointCandidateBoundNoExecution regression `shouldBe` True

    it "checks protocol version and exact request digest on every response arm" $ do
      regression <- fixedLocalRke2HostObservationEndpointRegression
      localRke2HostObservationEndpointAllArmsValidateVersion regression `shouldBe` True
      localRke2HostObservationEndpointAllArmsValidateRequestDigest regression `shouldBe` True

    it "uses the additive host-only route 57 topology" $ do
      controlPlaneRouteForValue LifecycleLocalRke2HostObservationRoute
        `shouldBe` LifecycleLocalRke2HostObservation
      controlPlaneRouteMethod LifecycleLocalRke2HostObservation
        `shouldBe` ControlPlanePost
      controlPlaneRoutePath LifecycleLocalRke2HostObservation
        `shouldBe` "/v1/authority/local-rke2-host-observation"
      controlPlaneRouteRole LifecycleLocalRke2HostObservation
        `shouldBe` LifecycleAuthorityRuntime
      trustedCallersForRoute LifecycleLocalRke2HostObservation
        `shouldBe` [CallerOperatorCli]
      callerMayCallRoute CallerOperatorCli LifecycleLocalRke2HostObservation
        `shouldBe` True
      callerMayCallRoute CallerTestHarness LifecycleLocalRke2HostObservation
        `shouldBe` False
      callerMayCallRoute
        (CallerService LifecycleAuthorityRuntime)
        LifecycleLocalRke2HostObservation
        `shouldBe` False
      localRke2HostObservationEndpointMaximumBytes
        `shouldSatisfy` (<= controlPlaneMaximumLifecycleInputBodyBytes)

      authentication <-
        readFile "src/Prodbox/ControlPlane/RequestAuthentication.hs"
      authentication `shouldContain` "LifecycleLocalRke2HostObservation -> 57"
      authentication `shouldContain` "57 -> Just LifecycleLocalRke2HostObservation"
      registry <-
        readFile "src/Prodbox/ControlPlane/AuthenticationRegistry.hs"
      registry
        `shouldContain` "(LifecycleLocalRke2HostObservation, [CallerOperatorCli])"
      registry
        `shouldNotContain` "row LifecycleLocalRke2HostObservation"

    it "keeps candidate construction, transport, repository, and read-back private" $ do
      facade <-
        readFile "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint.hs"
      let header = moduleHeader facade
      mapM_
        (header `shouldNotContain`)
        [ "LocalRke2HostObservationWire"
        , "LocalRke2HostObservationCandidate"
        , "LocalRke2HostObservationRepositoryClient"
        , "lifecycleAuthorityLocalRke2HostObservationEndpointHandlerInternal"
        , "confirmLocalRke2HostObservationResponseInternal"
        , "commitEncodedLocalRke2HostObservationAttemptInternal"
        ]
      transport <-
        readFile
          "src/Prodbox/ControlPlane/LocalRke2HostObservationTransport/Internal.hs"
      transport `shouldNotContain` "independentlyReadBack"
      transport `shouldNotContain` "ReadBackLocalRke2HostObservation"
      transport `shouldContain` "LifecycleLocalRke2HostObservationRoute"

      endpointImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.LocalRke2HostObservationEndpoint.Internal"
      endpointImporters
        `shouldBe` [ "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint.hs"
                   , "src/Prodbox/ControlPlane/LocalRke2HostObservationTransport/Internal.hs"
                   , "src/Prodbox/ControlPlane/Runtime.hs"
                   ]
      transportImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.LocalRke2HostObservationTransport.Internal"
      transportImporters
        `shouldBe` ["src/Prodbox/ControlPlane/RecoveryPlaneHostRuntime/Internal.hs"]

      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.ControlPlane.LocalRke2HostObservationEndpoint.Internal"
      cabal
        `shouldContain` "Prodbox.ControlPlane.LocalRke2HostObservationTransport.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.LocalRke2HostObservationEndpoint.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.LocalRke2HostObservationTransport.Internal"

    it "installs the commit handler beside Authority-executed route 56" $ do
      runtime <- readFile "src/Prodbox/ControlPlane/Runtime.hs"
      runtime
        `shouldContain` "localRke2HostObservationModelBCodecInternal"
      runtime
        `shouldContain` "lifecycleAuthorityLocalRke2HostObservationEndpointHandlerInternal"
      runtime
        `shouldContain` "lifecycleAuthorityLocalRke2HostObservationAuthenticatedHandler"
      runtime
        `shouldContain` "lifecycleAuthorityRecoveryPlaneAuthenticatedHandler"
      repository <-
        readFile
          "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository/Internal.hs"
      repository
        `shouldContain` "authority/local-rke2-host-observation/"

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
