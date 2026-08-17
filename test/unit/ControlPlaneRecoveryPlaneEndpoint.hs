{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRecoveryPlaneEndpoint
  ( controlPlaneRecoveryPlaneEndpointSuite
  )
where

import Control.Monad (filterM, forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( callerMayCallRoute
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService, CallerTestHarness)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneRouteFor (LifecycleRecoveryPlaneRoute)
  , controlPlaneClientWithTransport
  , controlPlaneRouteForValue
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RecoveryPlaneEndpoint
import Prodbox.ControlPlane.RecoveryPlaneHostRuntime
import Prodbox.ControlPlane.RecoveryPlaneTransportClient
  ( RecoveryPlaneAuthorityClient
  , executeRecoveryPlaneFinalDispositionRemote
  , executeRecoveryPlaneInitialReadBackRemote
  , lifecycleAuthorityRecoveryPlaneAuthenticatedClient
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.Server
  ( controlPlaneMaximumLifecycleInputBodyBytes
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupNodeOutcome (CleanupNodeSucceeded)
  , CleanupOperationId
  , CleanupRunId
  , mkCleanupAttemptId
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Runtime.Role
  ( RuntimeRole
      ( LifecycleAuthorityRuntime
      , ProviderWorkerRuntime
      )
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

controlPlaneRecoveryPlaneEndpointSuite :: SuiteBuilder ()
controlPlaneRecoveryPlaneEndpointSuite =
  describe "authenticated recovery-plane Authority endpoint" $ do
    it "executes an exact canonical request once" $ do
      regression <- fixedRecoveryPlaneEndpointRegression
      shouldBe (recoveryPlaneEndpointValidExact regression) True

    it "refuses malformed and oversized requests before execution" $ do
      regression <- fixedRecoveryPlaneEndpointRegression
      shouldBe (recoveryPlaneEndpointMalformedNoExecution regression) True
      shouldBe (recoveryPlaneEndpointOversizeNoExecution regression) True

    it "refuses invalid identities and unsupported versions before execution" $ do
      regression <- fixedRecoveryPlaneEndpointRegression
      shouldBe (recoveryPlaneEndpointInvalidIdentityNoExecution regression) True
      shouldBe (recoveryPlaneEndpointUnsupportedVersionNoExecution regression) True

    it "validates version and request digest on every response arm" $ do
      regression <- fixedRecoveryPlaneEndpointRegression
      shouldBe (recoveryPlaneEndpointAllArmsValidateVersion regression) True
      shouldBe (recoveryPlaneEndpointAllArmsValidateRequestDigest regression) True

    it "executes both phases through the authenticated route-56 transport" $ do
      forM_
        [
          ( recoveryPlaneInitialReadBackWireRequest fixtureRunId fixtureOperationId fixtureAttemptId
          , executeRecoveryPlaneInitialReadBackRemote
          )
        ,
          ( recoveryPlaneFinalDispositionWireRequest fixtureRunId fixtureOperationId fixtureAttemptId
          , executeRecoveryPlaneFinalDispositionRemote
          )
        ]
        $ \(request, execute) -> do
          client <- authenticatedRecoveryPlaneClientFor request
          observed <- execute client fixtureRunId fixtureOperationId fixtureAttemptId
          shouldBe observed (Right CleanupNodeSucceeded)

    it "closes the host runtime over exactly Establish and both read-back phases" $ do
      let regression = fixedRecoveryPlaneHostRuntimeRegression
      recoveryPlaneHostRuntimeClosedOperationsExact regression `shouldBe` True
      recoveryPlaneHostRuntimeRemoteAmbiguityUnconfirmed regression `shouldBe` True
      recoveryPlaneHostRuntimeDefiniteRefusalFailed regression `shouldBe` True
      recoveryPlaneHostRuntimeOpacityClosed regression `shouldBe` True

    it "owns additive route 56 only at Lifecycle Authority" $ do
      shouldBe
        (controlPlaneRouteForValue LifecycleRecoveryPlaneRoute)
        LifecycleRecoveryPlane
      shouldBe (controlPlaneRouteMethod LifecycleRecoveryPlane) ControlPlanePost
      shouldBe
        (controlPlaneRoutePath LifecycleRecoveryPlane)
        "/v1/authority/recovery-plane"
      shouldBe
        ( decodeRoleRoute
            LifecycleAuthorityRuntime
            ControlPlanePost
            "/v1/authority/recovery-plane"
        )
        (Just LifecycleRecoveryPlane)
      shouldBe
        ( decodeRoleRoute
            ProviderWorkerRuntime
            ControlPlanePost
            "/v1/authority/recovery-plane"
        )
        Nothing
      authSource <- readFile "src/Prodbox/ControlPlane/RequestAuthentication.hs"
      shouldContain authSource "LifecycleRecoveryPlane -> 56"
      shouldContain authSource "56 -> Just LifecycleRecoveryPlane"

    it "admits only operator, test-harness, and Authority callers" $ do
      shouldBe
        (trustedCallersForRoute LifecycleRecoveryPlane)
        [ CallerOperatorCli
        , CallerTestHarness
        , CallerService LifecycleAuthorityRuntime
        ]
      shouldBe
        (callerMayCallRoute CallerOperatorCli LifecycleRecoveryPlane)
        True
      shouldBe
        (callerMayCallRoute CallerTestHarness LifecycleRecoveryPlane)
        True
      shouldBe
        ( callerMayCallRoute
            (CallerService LifecycleAuthorityRuntime)
            LifecycleRecoveryPlane
        )
        True
      shouldBe
        ( callerMayCallRoute
            (CallerService ProviderWorkerRuntime)
            LifecycleRecoveryPlane
        )
        False

    it "uses a tight endpoint bound beneath the lifecycle-input preflight" $ do
      shouldSatisfy
        recoveryPlaneEndpointMaximumBytes
        (< controlPlaneMaximumLifecycleInputBodyBytes)
      shouldSatisfy
        recoveryPlaneEndpointResponseMaximumBytes
        (< controlPlaneMaximumLifecycleInputBodyBytes)
      serverSource <- readFile "src/Prodbox/ControlPlane/Server.hs"
      shouldContain
        serverSource
        "LifecycleRecoveryPlane -> controlPlaneMaximumLifecycleInputBodyBytes"

    it "keeps the handle loader and handler factory package-private" $ do
      facade <- readFile "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint.hs"
      transport <-
        readFile "src/Prodbox/ControlPlane/RecoveryPlaneTransportClient.hs"
      let facadeHeader = moduleHeader facade
          transportHeader = moduleHeader transport
          forbiddenPublic =
            [ "lifecycleAuthorityRecoveryPlaneEndpointHandlerInternal"
            , "CleanupRunRepositoryProvider"
            , "DescriptorBoundCleanupRun"
            , "RecoveryPlaneComponentObservation"
            , "RecoveryPlaneRawComponent"
            , "RecoveryPlaneEndpointHandler (.."
            ]
      mapM_ (shouldNotContain facadeHeader) forbiddenPublic
      mapM_ (shouldNotContain transportHeader) forbiddenPublic
      shouldContain transportHeader "RecoveryPlaneAuthorityClient"
      shouldContain transportHeader "executeRecoveryPlaneInitialReadBackRemote"
      shouldContain transportHeader "executeRecoveryPlaneFinalDispositionRemote"

      endpointImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.RecoveryPlaneEndpoint.Internal"
      shouldBe
        endpointImporters
        [ "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint/Internal.hs"
        , "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint.hs"
        , "src/Prodbox/ControlPlane/Runtime.hs"
        ]
      handleImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.CleanupRunClient.Internal"
      shouldBe
        handleImporters
        [ "src/Prodbox/ControlPlane/CleanupRunClient.hs"
        , "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint/Internal.hs"
        ]

      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      shouldContain
        cabal
        "Prodbox.ControlPlane.CleanupRunClient.Internal"
      shouldContain
        cabal
        "Prodbox.ControlPlane.RecoveryPlaneEndpoint.Internal"
      shouldNotContain
        exposedLibrary
        "Prodbox.ControlPlane.CleanupRunClient.Internal"
      shouldNotContain
        exposedLibrary
        "Prodbox.ControlPlane.RecoveryPlaneEndpoint.Internal"
      shouldContain
        cabal
        "Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal"
      shouldNotContain
        exposedLibrary
        "Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal"

      hostRuntimeImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal"
      shouldBe
        hostRuntimeImporters
        ["src/Prodbox/ControlPlane/RecoveryPlaneHostRuntime.hs"]

      hostRuntimeFacade <-
        readFile "src/Prodbox/ControlPlane/RecoveryPlaneHostRuntime.hs"
      let hostRuntimeHeader = moduleHeader hostRuntimeFacade
      hostRuntimeHeader
        `shouldNotContain` "recoveryPlaneHostDescriptorBoundNodeActionInternal"
      hostRuntimeHeader `shouldNotContain` "AuthenticatedClientTransport"
      hostRuntimeHeader `shouldNotContain` "DescriptorBoundCleanupRun"
      hostRuntimeHeader `shouldNotContain` "RecoveryPlaneAuthorityClient"

    it "has no raw component observation or establish phase on the wire" $ do
      internal <-
        readFile "src/Prodbox/ControlPlane/RecoveryPlaneEndpoint/Internal.hs"
      let requestDefinition =
            takeThrough
              "deriving anyclass (Serialise)"
              (dropThrough "data RecoveryPlaneWireRequest" internal)
      shouldContain requestDefinition "recoveryPlaneWireRequestRunId"
      shouldContain requestDefinition "recoveryPlaneWireRequestOperationId"
      shouldContain requestDefinition "recoveryPlaneWireRequestAttemptId"
      shouldNotContain requestDefinition "Observation"
      shouldNotContain requestDefinition "Descriptor"
      shouldNotContain requestDefinition "Graph"
      shouldNotContain internal "RecoveryPlaneWireEstablish"

    it "constructs one fresh-fact observer per Authority Runtime and installs route 56" $ do
      runtime <- readFile "src/Prodbox/ControlPlane/Runtime.hs"
      runtime `shouldContain` "recoveryPlaneObserverResult <-"
      runtime
        `shouldContain` "productionRecoveryPlaneComponentObserverInternal"
      length
        ( filter
            (isInfixOf "productionRecoveryPlaneComponentObserverInternal")
            (lines runtime)
        )
        `shouldBe` 2
      runtime `shouldContain` "recoveryPlaneModelBCodecInternal"
      runtime
        `shouldContain` "recoveryPlaneAuthorityReadBackInterpreterInternal"
      runtime
        `shouldContain` "lifecycleAuthorityRecoveryPlaneEndpointHandlerInternal"
      runtime
        `shouldContain` "lifecycleAuthorityRecoveryPlaneAuthenticatedHandler"

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

dropThrough :: String -> String -> String
dropThrough needle contents =
  case dropWhile (not . isInfixOf needle) (lines contents) of
    [] -> ""
    _header : rest -> unlines rest

takeThrough :: String -> String -> String
takeThrough needle contents =
  unlines (go (lines contents))
 where
  go remaining = case remaining of
    [] -> []
    line : rest
      | isInfixOf needle line -> [line]
      | otherwise -> line : go rest

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (isInfixOf importNeedle contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | isSuffixOf ".hs" path]

authenticatedRecoveryPlaneClientFor
  :: RecoveryPlaneWireRequest
  -> IO (RecoveryPlaneAuthorityClient IO)
authenticatedRecoveryPlaneClientFor request = do
  endpoint <-
    mustRightIO
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  let response =
        RecoveryPlaneWireCompleted
          recoveryPlaneEndpointFormatVersion
          ( hexSha256
              ( LazyByteString.toStrict
                  (encodeControlPlaneRequest request)
              )
          )
          RecoveryPlaneWireSucceeded
  rawClient <-
    mustRightIO
      ( controlPlaneClientWithTransport
          recoveryPlaneEndpointResponseMaximumBytes
          endpoint
          ( \method _ url _ -> do
              method `shouldBe` "POST"
              url
                `shouldBe` "http://lifecycle-authority:8600/v1/authority/recovery-plane"
              pure
                ( Right
                    ( replyStatusCode
                        (recoveryPlaneWireResponseStatus response)
                    , LazyByteString.toStrict
                        (encodeControlPlaneResponse response)
                    )
                )
          )
      )
  pure
    ( lifecycleAuthorityRecoveryPlaneAuthenticatedClient
        ( mkAuthenticatedClientTransport
            recoveryPlaneTransportBounds
            recoveryPlaneClientProviders
            rawClient
        )
    )

recoveryPlaneTransportBounds :: AuthenticatedTransportBounds
recoveryPlaneTransportBounds =
  mustRight (mkAuthenticatedTransportBounds (256 * 1024) 256 (250 * 1024))

recoveryPlaneClientProviders :: AuthenticatedClientProviders IO
recoveryPlaneClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability recoveryPlaneRequestSigner))
    , provideAuthenticatedClientScope = pure (Right recoveryPlaneAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right recoveryPlaneDeadline)
    , provideAuthenticatedClientNonce = pure (Right recoveryPlaneRequestNonce)
    }

recoveryPlaneRequestSigner :: RequestSigner
recoveryPlaneRequestSigner =
  mustRight
    ( mkRequestSigner
        (CallerService LifecycleAuthorityRuntime)
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

recoveryPlaneRequestNonce :: RequestNonce
recoveryPlaneRequestNonce = mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

recoveryPlaneAuthorityScope :: AuthorityScope
recoveryPlaneAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

recoveryPlaneDeadline :: AuthorityTime
recoveryPlaneDeadline = authorityTimeFromMicros 2000

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "recovery-plane-transport-run")

fixtureOperationId :: CleanupOperationId
fixtureOperationId =
  mustRight (mkCleanupOperationId "recovery-plane-transport-operation")

fixtureAttemptId :: CleanupAttemptId
fixtureAttemptId =
  mustRight (mkCleanupAttemptId "recovery-plane-transport-attempt")

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
