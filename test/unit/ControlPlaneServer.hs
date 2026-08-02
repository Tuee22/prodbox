{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneServer (controlPlaneServerSuite) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (bracket)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (fromJust)
import Network.Socket
  ( Family (AF_UNIX)
  , ShutdownCmd (ShutdownSend)
  , Socket
  , SocketType (Stream)
  , close
  , defaultProtocol
  , shutdown
  , socketPair
  , withSocketsDo
  )
import Network.Socket.ByteString (sendAll)
import Prodbox.ControlPlane.ProjectionImportEndpoint (mkProjectionImportHandler)
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointHandler
  , PulumiCheckpointObservation (PulumiCheckpointMissing)
  , PulumiCheckpointPublicationResult (PulumiCheckpointPublicationUnavailable)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointRetirementResult (PulumiCheckpointRetirementUnavailable)
  , mkPulumiCheckpointHandler
  )
import Prodbox.ControlPlane.RoleInterpreters (lifecycleAuthorityInterpreter)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
import Prodbox.ControlPlane.Runtime (receiveControlPlaneRequest)
import Prodbox.ControlPlane.Server
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCommand (RequestLegacyRollback, VerifyShadow)
  , encodeMigrationCommand
  , mkMigrationDigest
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (..)
  , StoredMigration (..)
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( LegacyProjectionObservation (LegacyProjectionMissing)
  , LegacyProjectionSource (LegacyProjectionSource)
  , ProjectionImportTarget (..)
  , ProjectionTargetObservation (ProjectionTargetMissing)
  , ProjectionTargetWriteResult (ProjectionTargetWriteUnobservable)
  , mkProjectionImportCodecConfig
  )
import Prodbox.Lifecycle.CheckpointAuthority (mkTargetClusterSecretSink)
import Prodbox.Lifecycle.Lease (defaultSesLeasePolicy)
import Prodbox.Lifecycle.TargetCommitIntent (mkRegisteredTargetSet)
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import TestSupport

controlPlaneServerSuite :: SuiteBuilder ()
controlPlaneServerSuite =
  describe "Sprint 4.50 control-plane role server seam" $ do
    it "frames a request only after its fragmented header and exact body arrive" $ do
      inspectControlPlaneRequestFraming "POST /v1/migration/apply HTTP/1.1\r\nContent-Len"
        `shouldBe` Right ControlPlaneFramingIncomplete
      inspectControlPlaneRequestFraming "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nx"
        `shouldBe` Right ControlPlaneFramingIncomplete
      let complete = "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz"
      inspectControlPlaneRequestFraming complete
        `shouldBe` Right (ControlPlaneFramingComplete complete)
    it "reads fragmented headers and bodies from a socket pair without a fixed port" $
      withSocketsDo $
        bracket (socketPair AF_UNIX Stream defaultProtocol) closeSocketPair $ \(writer, reader) -> do
          let headerFragment = "POST /v1/migration/apply HTTP/1.1\r\nContent-Len"
              bodyFragment = "gth: 3\r\n\r\nxyz"
              complete = headerFragment <> bodyFragment
          void $
            forkIO $ do
              sendAll writer headerFragment
              threadDelay 10000
              sendAll writer bodyFragment
              shutdown writer ShutdownSend
          receiveControlPlaneRequest reader `shouldReturn` Right complete
    it "frames a header-only GET after the header terminator" $ do
      let request = "GET /healthz HTTP/1.1\r\nHost: lifecycle-authority\r\n\r\n"
      inspectControlPlaneRequestFraming request
        `shouldBe` Right (ControlPlaneFramingComplete request)
    it "accepts case-insensitive framing headers and optional whitespace" $ do
      let request = "POST /v1/migration/apply HTTP/1.1\r\ncOnTeNt-LeNgTh:\t 3 \t\r\n\r\nxyz"
      inspectControlPlaneRequestFraming request
        `shouldBe` Right (ControlPlaneFramingComplete request)
    it "rejects duplicate and invalid content lengths before dispatch" $ do
      inspectControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\ncontent-length: 3\r\n\r\nxyz"
        `shouldBe` Left ControlPlaneDuplicateContentLength
      fmap
        inspectControlPlaneRequestFraming
        [ "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        , "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 1x\r\n\r\n"
        , "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 1, 1\r\n\r\n"
        ]
        `shouldBe` replicate 3 (Left ControlPlaneInvalidContentLength)
    it "rejects an oversized declared body during header preflight" $
      inspectControlPlaneRequestFraming
        (declaredRequest "POST" "/v1/migration/apply" (controlPlaneMaximumBodyBytes + 1))
        `shouldBe` Left ControlPlaneBodyTooLarge
    it "admits the large ceiling only for the two typed checkpoint-bearing routes" $ do
      fmap
        inspectControlPlaneRequestFraming
        [ declaredRequest "POST" "/v1/authority/pulumi-checkpoint" controlPlaneMaximumLargeBodyBytes
        , declaredRequest "POST" "/v1/authority-backup/copy" controlPlaneMaximumLargeBodyBytes
        ]
        `shouldBe` replicate 2 (Right ControlPlaneFramingIncomplete)
      controlPlaneMaximumLargeBodyBytes `shouldSatisfy` (> 96 * 1024 * 1024)
    it "refuses oversized large-route declarations from the header alone" $ do
      fmap
        inspectControlPlaneRequestFraming
        [ declaredRequest
            "POST"
            "/v1/authority/pulumi-checkpoint"
            (controlPlaneMaximumLargeBodyBytes + 1)
        , declaredRequest
            "POST"
            "/v1/authority-backup/copy"
            (controlPlaneMaximumLargeBodyBytes + 1)
        ]
        `shouldBe` replicate 2 (Left ControlPlaneBodyTooLarge)
    it "keeps ordinary, wrong-method, observe, and unknown routes at one MiB" $ do
      fmap
        inspectControlPlaneRequestFraming
        [ declaredRequest "POST" "/v1/migration/apply" (controlPlaneMaximumBodyBytes + 1)
        , declaredRequest "GET" "/v1/authority/pulumi-checkpoint" (controlPlaneMaximumBodyBytes + 1)
        , declaredRequest "GET" "/v1/authority-backup/observe" (controlPlaneMaximumBodyBytes + 1)
        , declaredRequest "POST" "/v1/not-a-registered-route" (controlPlaneMaximumBodyBytes + 1)
        ]
        `shouldBe` replicate 4 (Left ControlPlaneBodyTooLarge)
    it "rejects a header beyond the 16 KiB framing bound" $
      inspectControlPlaneRequestFraming
        ( "GET /healthz HTTP/1.1\r\nX-Fill: "
            <> ByteString.replicate controlPlaneMaximumHeaderBytes 97
            <> "\r\n\r\n"
        )
        `shouldBe` Left ControlPlaneHeaderTooLarge
    it "rejects bytes past the declared body" $
      inspectControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz-extra"
        `shouldBe` Left ControlPlaneBodyPastDeclaredLength
    it "rejects unsupported or missing POST framing" $ do
      inspectControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nxyz\r\n0\r\n\r\n"
        `shouldBe` Left ControlPlaneUnsupportedTransferEncoding
      inspectControlPlaneRequestFraming "POST /v1/migration/apply HTTP/1.1\r\n\r\n"
        `shouldBe` Left ControlPlaneContentLengthRequired
    it "rejects connection close before a header or declared body completes" $ do
      finishControlPlaneRequestFraming "GET /healthz HTTP/1.1\r\nHost: authority"
        `shouldBe` Left ControlPlaneConnectionClosedBeforeComplete
      finishControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxy"
        `shouldBe` Left ControlPlaneConnectionClosedBeforeComplete
    it "parses method, request target, and body from a raw request" $ do
      let parsed = parseControlPlaneRequest "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz"
      fmap parsedRequestPath parsed `shouldBe` Just "/v1/migration/apply"
      fmap parsedRequestBody parsed `shouldBe` Just "xyz"
    it "treats a header-only probe as an empty-body request" $ do
      let parsed = parseControlPlaneRequest "GET /healthz HTTP/1.1"
      fmap parsedRequestPath parsed `shouldBe` Just "/healthz"
      fmap parsedRequestBody parsed `shouldBe` Just ""
    it "classifies liveness, readiness, owned, and unowned dispositions" $ do
      classifyControlPlaneRequest LifecycleAuthorityRuntime "GET /healthz HTTP/1.1\r\n\r\n"
        `shouldBe` DispositionLive
      classifyControlPlaneRequest LifecycleAuthorityRuntime "GET /readyz HTTP/1.1\r\n\r\n"
        `shouldBe` DispositionNotReady
      classifyControlPlaneRequest
        LifecycleAuthorityRuntime
        "POST /v1/migration/apply HTTP/1.1\r\n\r\nbody"
        `shouldBe` DispositionOwnedRoute LifecycleMigrationApply "body"
      classifyControlPlaneRequest LifecycleAuthorityRuntime "GET /nope HTTP/1.1\r\n\r\n"
        `shouldBe` DispositionNotOwned
    it "refuses a route owned by a different role" $
      classifyControlPlaneRequest ProviderWorkerRuntime "POST /v1/migration/apply HTTP/1.1\r\n\r\nbody"
        `shouldBe` DispositionNotOwned
    it "serves every disposition fail-closed until an interpreter is bound" $ do
      let serve = serveControlPlaneRequest (failClosedInterpreter :: RoleInterpreter IO) LifecycleAuthorityRuntime
      serve "GET /healthz HTTP/1.1\r\n\r\n" `shouldReturn` (200, "live\n")
      serve "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (503, "not-ready\n")
      serve "POST /v1/migration/apply HTTP/1.1\r\n\r\nbody"
        `shouldReturn` (503, "interpreter-unavailable\n")
      serve "GET /nope HTTP/1.1\r\n\r\n" `shouldReturn` (404, "route-not-owned\n")
    it "dispatches an owned migration request through the library-built interpreter" $ do
      interpreter <- boundLifecycleAuthorityInterpreter
      let serve = serveControlPlaneRequest interpreter LifecycleAuthorityRuntime
      serve "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (200, "ready\n")
      accepted <- serve (migrationRequest (VerifyShadow digest))
      accepted `shouldBe` (200, "migration-accepted")
      refused <- serve (migrationRequest RequestLegacyRollback)
      refused `shouldBe` (409, "migration-refused:legacy-rollback-forbidden")
    it "renders a bounded connection-close HTTP response" $
      renderHttpResponse 200 "live\n"
        `shouldBe` "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\nlive\n"
    it "maps every emitted status code to a reason phrase" $
      fmap httpReasonPhrase [200, 400, 404, 409, 500, 503]
        `shouldBe` ["OK", "Bad Request", "Not Found", "Conflict", "Internal Server Error", "Service Unavailable"]
 where
  digest = fromJust (mkMigrationDigest "server-v1")

declaredRequest :: ByteString -> ByteString -> Int -> ByteString
declaredRequest method path bodyBytes =
  method
    <> " "
    <> path
    <> " HTTP/1.1\r\nContent-Length: "
    <> Char8.pack (show bodyBytes)
    <> "\r\n\r\n"

closeSocketPair :: (Socket, Socket) -> IO ()
closeSocketPair (left, right) = close left >> close right

migrationRequest :: MigrationCommand -> ByteString
migrationRequest command =
  "POST /v1/migration/apply HTTP/1.1\r\n\r\n"
    <> LazyByteString.toStrict (encodeMigrationCommand command)

-- | Build a Lifecycle Authority interpreter through the library builder
-- ('Prodbox.ControlPlane.RoleInterpreters.lifecycleAuthorityInterpreter') over
-- an in-memory migration repository.  Caller-selected operation identities are
-- not composed on this legacy context-free builder.
boundLifecycleAuthorityInterpreter :: IO (RoleInterpreter IO)
boundLifecycleAuthorityInterpreter = do
  migrationRepository <- freshMigrationRepository
  let projectionConfig =
        either (error . show) id $
          mkProjectionImportCodecConfig
            defaultSesLeasePolicy
            ( either (error . show) id $
                mkRegisteredTargetSet
                  1
                  [ either (error . show) id $
                      mkTargetClusterSecretSink
                        "home"
                        "secret"
                        "keycloak/smtp"
                  ]
            )
            4096
      projectionSource :: LegacyProjectionSource IO Word
      projectionSource =
        LegacyProjectionSource (\_ -> pure LegacyProjectionMissing)
      projectionTarget :: ProjectionImportTarget IO Word
      projectionTarget =
        ProjectionImportTarget
          { observeImportedProjection = \_ -> pure ProjectionTargetMissing
          , initializeImportedProjection = \_ _ ->
              pure (ProjectionTargetWriteUnobservable "unexpected initialize")
          }
      projectionHandler =
        mkProjectionImportHandler
          4096
          4096
          projectionConfig
          migrationRepository
          projectionSource
          projectionTarget
  pure
    ( lifecycleAuthorityInterpreter
        4096
        (pure True)
        "cluster-a"
        (pure (Right 123456))
        migrationRepository
        projectionHandler
        fixturePulumiCheckpointHandler
    )

fixturePulumiCheckpointHandler :: PulumiCheckpointHandler IO
fixturePulumiCheckpointHandler =
  mkPulumiCheckpointHandler
    PulumiCheckpointRepository
      { observeRegisteredPulumiCheckpoint = \_callerSlot _ -> pure PulumiCheckpointMissing
      , publishRegisteredPulumiCheckpoint = \_callerSlot _ _ _ ->
          pure (PulumiCheckpointPublicationUnavailable "fixture unavailable")
      , retireRegisteredPulumiCheckpoint = \_callerSlot _ _ ->
          pure (PulumiCheckpointRetirementUnavailable "fixture unavailable")
      }

freshMigrationRepository :: IO (MigrationRepository IO Word)
freshMigrationRepository = do
  stateRef <- newIORef Nothing
  revisionRef <- newIORef (0 :: Word)
  pure
    MigrationRepository
      { readMigrationState = Right <$> readIORef stateRef
      , compareAndSwapMigrationState = \expected bytes -> do
          observed <- readIORef stateRef
          if (storedMigrationRevision <$> observed) /= expected
            then pure (Right False)
            else do
              next <- atomicModifyIORef' revisionRef (\value -> (value + 1, value + 1))
              writeIORef stateRef (Just (StoredMigration next bytes))
              pure (Right True)
      }
