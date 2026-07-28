{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneServer (controlPlaneServerSuite) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (fromJust)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.MigrationEndpoint
  ( migrationEndpointHttpStatus
  , migrationEndpointSummary
  , serveMigrationApply
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
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
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import TestSupport

controlPlaneServerSuite :: SuiteBuilder ()
controlPlaneServerSuite =
  describe "Sprint 4.50 control-plane role server seam" $ do
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
    it "dispatches an owned migration request through a bound interpreter" $ do
      interpreter <- lifecycleAuthorityInterpreter
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

migrationRequest :: MigrationCommand -> ByteString
migrationRequest command =
  "POST /v1/migration/apply HTTP/1.1\r\n\r\n"
    <> LazyByteString.toStrict (encodeMigrationCommand command)

lifecycleAuthorityInterpreter :: IO (RoleInterpreter IO)
lifecycleAuthorityInterpreter = do
  repository <- freshMigrationRepository
  pure
    RoleInterpreter
      { interpreterReadyz = pure True
      , interpreterHandle = handleLifecycleAuthorityRoute repository
      }

handleLifecycleAuthorityRoute
  :: MigrationRepository IO Word
  -> ControlPlaneRoute
  -> ByteString
  -> IO (Maybe (Int, ByteString))
handleLifecycleAuthorityRoute repository route body = case route of
  LifecycleMigrationApply -> do
    result <- serveMigrationApply 4096 repository (LazyByteString.fromStrict body)
    pure
      ( Just
          ( migrationEndpointHttpStatus result
          , TextEncoding.encodeUtf8 (migrationEndpointSummary result)
          )
      )
  _ -> pure Nothing

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
