{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module HttpClientBodyBuffer (httpClientBodyBufferCases) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception
  ( AsyncException (ThreadKilled)
  , IOException
  , SomeException
  , bracket
  , catch
  , fromException
  )
import Control.Monad (forM_, forever, replicateM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as Bytes8
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Net
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline (RemainingDuration (..), deadlineAtOffset)
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.RequestReplay
  ( encodeRequestReplayProjection
  , initialRequestReplayProjection
  , mkRequestReplayLimits
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( TargetReplayMigrationResult (..)
  , migrateTargetReplayStaged
  )
import Prodbox.Http.Client
import Prodbox.Lifecycle.Lease (authorityDurationFromMicros)
import Prodbox.Minio.ObjectStoreNative (deleteIfVersionObservedBefore, putIfAbsentObservedBefore)
import Prodbox.Minio.ObjectStoreTypes
  ( ConditionalDeleteResult (..)
  , ConditionalPutResult (..)
  , ObjectStoreConfig (..)
  , ObjectVersion (..)
  )
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2ExactVersionSecret (..)
  , KvV2SecretMetadata (..)
  , KvV2VersionedSecret (..)
  , SealStatus
  , VaultAddress (..)
  , VaultCasOutcome (..)
  , VaultToken (..)
  , VaultTokenSelfObservation (..)
  , classifyVaultCasOutcome
  , vaultKvCasWriteV2Bounded
  , vaultKvReadMetadataV2WithLimit
  , vaultKvReadVersionedV2WithLimit
  , vaultLookupSelfTokenWith
  , vaultRotateTransitKeyWith
  , vaultSealStatusWith
  , vaultSubmitUnsealWith
  )
import Prodbox.Vault.Session (LoginLease (..), SessionClock (..), newVaultSession)
import System.Timeout (timeout)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, (@?=))

httpClientBodyBufferCases :: [(String, Assertion)]
httpClientBodyBufferCases =
  [
    ( "Vault token self lookup reads the hard cap and redacts provider errors"
    , do
        let readSelf address = vaultLookupSelfTokenWith (HttpConfig 1000000) address (VaultToken "fixture-token")
            path = "/v1/auth/token/lookup-self"
        observed <-
          vaultFixtureResponse
            200
            "{\"data\":{\"accessor\":\"fixture-accessor\",\"type\":\"service\",\"ttl\":299,\"explicit_max_ttl\":300,\"renewable\":true,\"id\":\"sensitive-bearer\"}}"
            path
            readSelf
        observed @?= Right (VaultTokenSelfObservation "fixture-accessor" "service" 299 300 True)
        malformed <- vaultFixtureResponse 200 "{\"data\":{\"id\":\"sensitive-bearer\"}}" path readSelf
        refused <- vaultFixtureResponse 400 "sensitive-bearer" path readSelf
        assertBool "missing fields fail closed" (isLeft malformed)
        assertBool "provider errors fail closed" (isLeft refused)
        assertBool
          "missing-field error omits bearer"
          (not ("sensitive-bearer" `Text.isInfixOf` Text.pack (show malformed)))
        assertBool
          "provider error omits bearer"
          (not ("sensitive-bearer" `Text.isInfixOf` Text.pack (show refused)))
        oversized <- vaultFixtureResponse 200 (Bytes.replicate 140000 120) path readSelf
        assertBool "oversized token metadata is refused" (isLeft oversized)
        delayedHeaders <- vaultSelfTimedResponse 500000 0
        delayedBody <- vaultSelfTimedResponse 0 500000
        let assertTimedOut result = case result of
              Left (HttpTimeout _) -> pure ()
              other -> assertFailure (show other)
        forM_ [delayedHeaders, delayedBody] assertTimedOut
        noBudget <-
          vaultLookupSelfTokenWith
            (HttpConfig 0)
            (VaultAddress "http://127.0.0.1:1")
            (VaultToken "fixture-token")
        case noBudget of
          Left (HttpTimeout _) -> pure ()
          other -> assertFailure (show other)
    )
  ,
    ( "native object-store cancellation propagates while synchronous failures remain structured"
    , do
        cancelled <- nativeObjectStoreCancellation
        case cancelled of
          Just (Left failure) | Just ThreadKilled <- fromException failure -> pure ()
          other -> assertFailure ("expected ThreadKilled, got " ++ show other)
        timed <- nativeObjectStoreOuterTimeout
        case timed of
          Just Nothing -> pure ()
          other -> assertFailure ("expected outer timeout, got " ++ show other)
        (cancelledAfterPut, fakeWriteObserved) <- nativeObjectStoreCancelAfterPut
        case cancelledAfterPut of
          Just (Left failure) | Just ThreadKilled <- fromException failure -> pure ()
          other -> assertFailure ("expected ThreadKilled after PUT, got " ++ show other)
        assertBool "fake conditional write was observed before cancellation" fakeWriteObserved
        now <- realMonotonicNow
        let config = ObjectStoreConfig "http://127.0.0.1:0" "fixture-bucket" "fixture-user" "fixture-password"
        failed <-
          putIfAbsentObservedBefore
            (deadlineAtOffset now (RemainingDuration 2000000))
            config
            "fixture-key"
            "fixture-value"
        assertBool "synchronous connection failure stays structured" (isLeft failed)
    )
  ,
    ( "conditional object PUT refuses after delayed bucket preflight"
    , do
        (timely, timelyPuts) <- conditionalPutResponse 0 2000000
        (late, latePuts) <- conditionalPutResponse 300000 100000
        case timely of
          Right (ConditionalPutApplied _) -> pure ()
          other -> assertFailure (show other)
        assertBool "timely conditional PUT reached the fixture" (timelyPuts == 1)
        assertBool "late preflight refuses" (isLeft late)
        assertBool "no conditional PUT followed the late preflight" (latePuts == 0)
    )
  ,
    ( "native conditional DELETE refuses an expired deadline and preserves the version condition"
    , conditionalDeleteDeadline
    )
  ,
    ( "Vault Transit rotation applies the supplied HTTP timeout"
    , do
        (timely, timelySeen) <- vaultTransitRotationResponse 0 1000000
        (delayed, delayedSeen) <- vaultTransitRotationResponse 500000 100000
        assertBool "timely rotation reached the fixture" timelySeen
        assertBool "delayed rotation reached the fixture" delayedSeen
        case timely of
          Right () -> pure ()
          Left failure -> assertFailure (show failure)
        case delayed of
          Left (HttpTimeout _) -> pure ()
          other -> assertFailure (show other)
    )
  ,
    ( "Vault unseal timeout preserves an unconfirmed dispatched outcome"
    , do
        (timely, timelySeen) <- vaultUnsealResponse 0 1000000
        (delayed, delayedSeen) <- vaultUnsealResponse 500000 100000
        assertBool "timely request reached the fixture" timelySeen
        assertBool "delayed request reached the fixture before the timeout" delayedSeen
        case timely of
          Right _ -> pure ()
          Left failure -> assertFailure (show failure)
        case delayed of
          Left (HttpTimeout _) -> pure ()
          other -> assertFailure (show other)
    )
  ,
    ( "Vault seal status bounds delayed headers and response bodies"
    , do
        timely <- vaultStatusResponse 0 0 1000000
        delayedHeaders <- vaultStatusResponse 500000 0 100000
        delayedBody <- vaultStatusResponse 0 500000 100000
        noBudget <- vaultSealStatusWith (HttpConfig 0) (VaultAddress "http://127.0.0.1:1")
        negativeBudget <- vaultSealStatusWith (HttpConfig (-1)) (VaultAddress "http://127.0.0.1:1")
        case timely of
          Right _ -> pure ()
          Left failure -> assertFailure (show failure)
        case delayedHeaders of
          Left (HttpTimeout _) -> pure ()
          other -> assertFailure (show other)
        case delayedBody of
          Left (HttpTimeout _) -> pure ()
          other -> assertFailure (show other)
        case (noBudget, negativeBudget) of
          (Left (HttpTimeout _), Left (HttpTimeout _)) -> pure ()
          other -> assertFailure (show other)
    )
  ,
    ( "full two-MiB body with one-byte transfer chunks"
    , do
        observed <- fragmentedResponse
        case observed of
          Left cause -> assertFailure (show cause)
          Right (status, bytes) -> do
            status @?= 200
            Bytes.length bytes @?= 2 * 1048576
            assertBool "every decoded byte retained" (Bytes.all (== 120) bytes)
    )
  ,
    ( "bounded Vault KV read retains exact data and version"
    , vaultResponse
        200
        "{\"data\":{\"data\":{\"projection_base64\":\"AQ==\"},\"metadata\":{\"version\":7}}}"
        128
        >>= (@?= Right (KvV2VersionedSecret (Map.singleton "projection_base64" "AQ==") 7))
    )
  ,
    ( "bounded Vault KV read accepts only uint64 versions"
    , do
        vaultResponse
          200
          "{\"data\":{\"data\":{\"journal\":\"value\"},\"metadata\":{\"version\":18446744073709551615}}}"
          256
          >>= (@?= Right (KvV2VersionedSecret (Map.singleton "journal" "value") 18446744073709551615))
        vaultResponse
          200
          "{\"data\":{\"data\":{\"journal\":\"value\"},\"metadata\":{\"version\":18446744073709551616}}}"
          256
          >>= (@?= Left (HttpDecode "Vault KV response is not valid JSON"))
        let longVersion =
              "{\"data\":{\"data\":{\"journal\":\"value\"},\"metadata\":{\"version\":"
                <> Bytes.replicate 300000 57
                <> "}}}"
        vaultResponse 200 longVersion (Bytes.length longVersion)
          >>= (@?= Left (HttpDecode "Vault KV response is not valid JSON"))
    )
  ,
    ( "Vault KV exact-read, metadata and CAS responses use the same uint64 domain"
    , do
        let exact version =
              "{\"data\":{\"data\":{\"journal\":\"value\"},\"metadata\":{\"version\":"
                <> version
                <> ",\"destroyed\":false}}}"
            maxVersion = "18446744073709551615"
            overflow = "18446744073709551616"
        (Aeson.eitherDecodeStrict' (exact maxVersion) :: Either String KvV2ExactVersionSecret)
          @?= Right (KvV2ExactVersionSecret (Just (Map.singleton "journal" "value")) 18446744073709551615 False)
        assertBool "exact-read overflow rejected" $
          isLeft (Aeson.eitherDecodeStrict' (exact overflow) :: Either String KvV2ExactVersionSecret)
        metadataResponse 200 "{\"data\":{\"current_version\":18446744073709551615}}" 128
          >>= (@?= Right (KvV2SecretMetadata 18446744073709551615 Map.empty))
        metadataResponse 200 "{\"data\":{\"current_version\":18446744073709551616}}" 128
          >>= (@?= Left (HttpDecode "Vault KV response is not valid JSON"))
        vaultWriteResponse 200 "{\"data\":{\"version\":18446744073709551615}}"
          >>= (@?= Right 18446744073709551615)
        vaultWriteResponse 200 "{\"data\":{\"version\":18446744073709551616}}"
          >>= assertVaultCasUnobservable
    )
  ,
    ( "bounded Vault KV read refuses oversized body"
    , vaultResponse 200 (Bytes.replicate 129 120) 128
        >>= (@?= Left (HttpDecode "Vault KV response exceeded its body bound"))
    )
  ,
    ( "bounded Vault KV read preserves missing status"
    , vaultResponse 404 "{}" 128
        >>= (@?= Left (HttpStatus 404 "Vault KV request failed"))
    )
  ,
    ( "bounded Vault KV read refuses malformed JSON"
    , vaultResponse 200 "{" 128
        >>= (@?= Left (HttpDecode "Vault KV response is not valid JSON"))
    )
  ,
    ( "bounded Vault metadata distinguishes missing from oversized and malformed"
    , do
        metadataResponse
          200
          "{\"data\":{\"current_version\":2,\"custom_metadata\":{\"kind\":\"receipt\"}}}"
          128
          >>= (@?= Right (KvV2SecretMetadata 2 (Map.singleton "kind" "receipt")))
        metadataResponse 404 "{}" 128
          >>= (@?= Left (HttpStatus 404 "Vault KV request failed"))
        metadataResponse 404 (Bytes.replicate 129 120) 128
          >>= (@?= Left (HttpDecode "Vault KV response exceeded its body bound"))
        metadataResponse 200 "{" 128
          >>= (@?= Left (HttpDecode "Vault KV response is not valid JSON"))
    )
  ,
    ( "bounded Vault CAS preserves its applied version"
    , vaultWriteResponse 200 "{\"data\":{\"version\":8}}"
        >>= (@?= VaultCasApplied 8) . classifyVaultCasOutcome
    )
  ,
    ( "bounded Vault CAS distinguishes version conflict and request refusal"
    , do
        conflict <-
          classifyVaultCasOutcome
            <$> vaultWriteResponse 400 "check-and-set parameter did not match the current version"
        conflict @?= VaultCasConflict "check-and-set parameter did not match the current version"
        refusal <- classifyVaultCasOutcome <$> vaultWriteResponse 400 "check-and-set parameter required"
        refusal @?= VaultCasRefused 400 "check-and-set parameter required"
        forbidden <- classifyVaultCasOutcome <$> vaultWriteResponse 403 "forbidden"
        forbidden @?= VaultCasRefused 403 "forbidden"
    )
  ,
    ( "bounded Vault CAS leaves uncertain responses unobservable"
    , do
        results <-
          traverse
            (uncurry vaultWriteResponse)
            [ (200, Bytes.replicate (128 * 1024 + 1) 120)
            , (200, "{")
            , (500, "failure")
            , (400, Bytes.pack [255])
            ]
        forM_ results assertVaultCasUnobservable
    )
  ,
    ( "Target migration never retries a forbidden CAS through the shared session"
    , targetMigrationForbidden
    )
  ]
    <> [ ( show (size, width, limit)
         , do
             observed <- response size width limit
             if size > limit
               then case observed of
                 Left (HttpBoundedResponseTooLarge actual actualLimit) -> do
                   actualLimit @?= limit
                   assertBool
                     "crossing is exact and remains within delivered body"
                     (actual > fromIntegral limit && actual <= fromIntegral size)
                 other -> assertFailure ("wrong crossing result: " <> show other)
               else case observed of
                 Left cause -> assertFailure (show cause)
                 Right (status, bytes) -> do
                   status @?= 200
                   Bytes.length bytes @?= size
                   assertBool "every byte retained" (Bytes.all (== 120) bytes)
         )
       | (size, width, limit) <-
           [ (0, 1, 0)
           , (1, 1, 0)
           , (1, 1, 1)
           , (1, 1, 2097152)
           , (32767, 1, 32767)
           , (32768, 4096, 32768)
           , (32769, 1, 32769)
           , (65537, 4096, 65537)
           , (65538, 1, 65537)
           , (65537, 65537, 65537)
           ]
       ]

fragmentedResponse :: IO (Either HttpBoundedError (Int, Bytes.ByteString))
fragmentedResponse = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "fragment fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        receive connection Bytes.empty
        let send bytes = Net.sendAll connection bytes `catch` ignoreClosed
            block = Bytes.concat (replicate 8192 "1\r\nx\r\n")
        send "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        replicateM_ 256 (send block)
        send "0\r\n\r\n"
  Async.withAsync serve $ \worker -> do
    Async.link worker
    httpRequestRawBounded
      (HttpConfig 30000000)
      (2 * 1048576)
      "GET"
      []
      ("http://127.0.0.1:" <> show port <> "/fragments")
      Nothing
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

receive :: Socket.Socket -> Bytes.ByteString -> IO ()
receive connection accumulated
  | Bytes.length accumulated > 4096 = assertFailure "fixture request too large"
  | "\r\n\r\n" `Bytes.isInfixOf` accumulated = pure ()
  | otherwise = do
      chunk <- Net.recv connection 4096
      if Bytes.null chunk then assertFailure "fixture EOF" else receive connection (accumulated <> chunk)

response :: Int -> Int -> Int -> IO (Either HttpBoundedError (Int, Bytes.ByteString))
response size width limit = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "compatibility fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        receive connection Bytes.empty
        let send bytes = Net.sendAll connection bytes `catch` ignoreClosed
        send "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        forM_ (chunks width (Bytes.replicate size 120)) $ \piece ->
          send (Bytes8.pack (showHex (Bytes.length piece) "") <> "\r\n" <> piece <> "\r\n")
        send "0\r\n\r\n"
  Async.withAsync serve $ \worker -> do
    Async.link worker
    httpRequestRawBounded
      (HttpConfig 30000000)
      limit
      "GET"
      []
      ("http://127.0.0.1:" <> show port <> "/body")
      Nothing
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

chunks :: Int -> Bytes.ByteString -> [Bytes.ByteString]
chunks width bytes
  | Bytes.null bytes = []
  | otherwise = let (prefix, suffix) = Bytes.splitAt width bytes in prefix : chunks width suffix

assertVaultCasUnobservable :: Either HttpError Natural -> Assertion
assertVaultCasUnobservable result = case classifyVaultCasOutcome result of
  VaultCasUnobservable _ -> pure ()
  other -> assertFailure ("expected unobservable, got " <> show other)

vaultResponse :: Int -> Bytes.ByteString -> Int -> IO (Either HttpError KvV2VersionedSecret)
vaultResponse status body maximumBytes =
  vaultFixtureResponse status body "/v1/secret/data/control-plane/request-replay/target-secret-agent" $ \address ->
    vaultKvReadVersionedV2WithLimit
      maximumBytes
      address
      (VaultToken "fixture-token")
      "secret"
      "control-plane/request-replay/target-secret-agent"

metadataResponse :: Int -> Bytes.ByteString -> Int -> IO (Either HttpError KvV2SecretMetadata)
metadataResponse status body maximumBytes =
  vaultFixtureResponse status body "/v1/secret/metadata/aws/lifecycle-provider" $ \address ->
    vaultKvReadMetadataV2WithLimit
      maximumBytes
      address
      (VaultToken "fixture-token")
      "secret"
      "aws/lifecycle-provider"

nativeObjectStoreCancelAfterPut
  :: IO (Maybe (Either SomeException (Either String ConditionalPutResult)), Bool)
nativeObjectStoreCancelAfterPut = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "object-store fixture requires IPv4"
  seen <- newEmptyMVar
  applied <- newIORef False
  let serveOne = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        if "HEAD " `Bytes.isPrefixOf` request
          then Net.sendAll connection "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          else
            if "GET " `Bytes.isPrefixOf` request
              then
                Net.sendAll
                  connection
                  "HTTP/1.1 200 OK\r\nContent-Length: 19\r\nConnection: close\r\n\r\n<ListBucketResult/>"
              else
                if "PUT " `Bytes.isPrefixOf` request
                  then do
                    let (_, afterHeaders) = Bytes.breakSubstring "\r\n\r\n" request
                    body <- receiveBody connection (Bytes.drop 4 afterHeaders)
                    assertBool "fixture received the complete conditional value" (body == "fixture-value")
                    modifyIORef' applied (const True)
                    putMVar seen ()
                    threadDelay 3000000
                  else assertFailure "unexpected object-store method"
      receiveBody connection body
        | Bytes.length body >= 13 = pure body
        | otherwise = do
            chunk <- Net.recv connection 4096
            if Bytes.null chunk
              then assertFailure "fixture EOF before PUT body"
              else receiveBody connection (body <> chunk)
      config =
        ObjectStoreConfig
          ("http://127.0.0.1:" ++ show port)
          "fixture-bucket"
          "fixture-user"
          "fixture-password"
  Async.withAsync (forever serveOne) $ \server -> do
    Async.link server
    now <- realMonotonicNow
    Async.withAsync
      ( putIfAbsentObservedBefore
          (deadlineAtOffset now (RemainingDuration 5000000))
          config
          "fixture-key"
          "fixture-value"
      )
      $ \client -> do
        result <- timeout 2000000 $ do
          takeMVar seen
          Async.cancelWith client ThreadKilled
          Async.waitCatch client
        wasApplied <- readIORef applied
        pure (result, wasApplied)
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 4
    pure listener

nativeObjectStoreOuterTimeout :: IO (Maybe (Maybe (Either String ConditionalPutResult)))
nativeObjectStoreOuterTimeout = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "object-store fixture requires IPv4"
  seen <- newEmptyMVar
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "bucket HEAD reached fixture" ("HEAD " `Bytes.isPrefixOf` request)
        putMVar seen ()
        threadDelay 3000000
      config =
        ObjectStoreConfig
          ("http://127.0.0.1:" ++ show port)
          "fixture-bucket"
          "fixture-user"
          "fixture-password"
  Async.withAsync serve $ \server -> do
    Async.link server
    now <- realMonotonicNow
    Async.withAsync
      ( timeout
          1000000
          ( putIfAbsentObservedBefore
              (deadlineAtOffset now (RemainingDuration 5000000))
              config
              "fixture-key"
              "fixture-value"
          )
      )
      $ \client ->
        timeout 3000000 $ do
          takeMVar seen
          Async.wait client
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener

nativeObjectStoreCancellation
  :: IO (Maybe (Either SomeException (Either String ConditionalPutResult)))
nativeObjectStoreCancellation = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "object-store fixture requires IPv4"
  seen <- newEmptyMVar
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "bucket HEAD reached fixture" ("HEAD " `Bytes.isPrefixOf` request)
        putMVar seen ()
        threadDelay 3000000
      config =
        ObjectStoreConfig
          ("http://127.0.0.1:" ++ show port)
          "fixture-bucket"
          "fixture-user"
          "fixture-password"
  Async.withAsync serve $ \server -> do
    Async.link server
    now <- realMonotonicNow
    Async.withAsync
      ( putIfAbsentObservedBefore
          (deadlineAtOffset now (RemainingDuration 5000000))
          config
          "fixture-key"
          "fixture-value"
      )
      $ \client ->
        timeout 2000000 $ do
          takeMVar seen
          Async.cancelWith client ThreadKilled
          Async.waitCatch client
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener

conditionalDeleteDeadline :: Assertion
conditionalDeleteDeadline = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "object-store fixture requires IPv4"
  deletes <- newIORef (0 :: Int)
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "exact DELETE path" ("DELETE /fixture-bucket/fixture-key " `Bytes.isPrefixOf` request)
        assertBool "observed ETag is sent" ("\"fixture-etag\"" `Bytes.isInfixOf` request)
        modifyIORef' deletes (+ 1)
        Net.sendAll connection "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      config =
        ObjectStoreConfig
          ("http://127.0.0.1:" ++ show port)
          "fixture-bucket"
          "fixture-user"
          "fixture-password"
      delete deadline = deleteIfVersionObservedBefore deadline config "fixture-key" (ObjectVersion "fixture-etag")
  Async.withAsync (forever serve) $ \worker -> do
    Async.link worker
    now <- realMonotonicNow
    expired <- delete (deadlineAtOffset now (RemainingDuration 0))
    assertBool "expired deadline is unavailable" (isLeft expired)
    readIORef deletes >>= (@?= 0)
    fresh <- realMonotonicNow
    timely <- delete (deadlineAtOffset fresh (RemainingDuration 2000000))
    timely @?= Right ConditionalDeleteApplied
    readIORef deletes >>= (@?= 1)
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 4
    pure listener

conditionalPutResponse :: Int -> Natural -> IO (Either String ConditionalPutResult, Int)
conditionalPutResponse headDelay budget = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "object-store fixture requires IPv4"
  puts <- newIORef (0 :: Int)
  let serveOne = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        if "HEAD " `Bytes.isPrefixOf` request
          then
            threadDelay headDelay
              >> Net.sendAll connection "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          else
            if "GET " `Bytes.isPrefixOf` request
              then
                Net.sendAll
                  connection
                  "HTTP/1.1 200 OK\r\nContent-Length: 19\r\nConnection: close\r\n\r\n<ListBucketResult/>"
              else
                if "PUT " `Bytes.isPrefixOf` request
                  then do
                    modifyIORef' puts (+ 1)
                    Net.sendAll
                      connection
                      "HTTP/1.1 200 OK\r\nETag: \"fixture-etag\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                  else assertFailure "unexpected object-store method"
      config =
        ObjectStoreConfig
          ("http://127.0.0.1:" ++ show port)
          "fixture-bucket"
          "fixture-user"
          "fixture-password"
  Async.withAsync (forever serveOne) $ \worker -> do
    Async.link worker
    now <- realMonotonicNow
    result <-
      putIfAbsentObservedBefore
        (deadlineAtOffset now (RemainingDuration budget))
        config
        "fixture-key"
        "fixture-value"
    count <- readIORef puts
    pure (result, count)
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 4
    pure listener

vaultTransitRotationResponse :: Int -> Int -> IO (Either HttpError (), Bool)
vaultTransitRotationResponse responseDelay timeoutMicros = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  seen <- newIORef False
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool
          "exact rotation path"
          ("POST /v1/transit/keys/fixture-key/rotate " `Bytes.isPrefixOf` request)
        modifyIORef' seen (const True)
        threadDelay responseDelay
        Net.sendAll connection "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          `catch` ignoreClosed
  Async.withAsync serve $ \worker -> do
    Async.link worker
    result <-
      vaultRotateTransitKeyWith
        (HttpConfig timeoutMicros)
        (VaultAddress (Text.pack ("http://127.0.0.1:" ++ show port)))
        (VaultToken "fixture-token")
        "fixture-key"
    observed <- readIORef seen
    pure (result, observed)
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

vaultUnsealResponse :: Int -> Int -> IO (Either HttpError SealStatus, Bool)
vaultUnsealResponse bodyDelay timeoutMicros = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  seen <- newIORef False
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "exact unseal path" ("POST /v1/sys/unseal " `Bytes.isPrefixOf` request)
        modifyIORef' seen (const True)
        let body = "{\"initialized\":true,\"sealed\":true,\"t\":2,\"n\":3,\"progress\":1}"
            header =
              Bytes8.pack
                ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (Bytes.length body) ++ "\r\nConnection: close\r\n\r\n")
        Net.sendAll connection header `catch` ignoreClosed
        threadDelay bodyDelay
        Net.sendAll connection body `catch` ignoreClosed
  Async.withAsync serve $ \worker -> do
    Async.link worker
    result <-
      vaultSubmitUnsealWith
        (HttpConfig timeoutMicros)
        (VaultAddress (Text.pack ("http://127.0.0.1:" ++ show port)))
        "fixture-share"
    observed <- readIORef seen
    pure (result, observed)
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

vaultSelfTimedResponse :: Int -> Int -> IO (Either HttpError VaultTokenSelfObservation)
vaultSelfTimedResponse headerDelay bodyDelay = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "exact token lookup path" ("GET /v1/auth/token/lookup-self " `Bytes.isPrefixOf` request)
        threadDelay headerDelay
        let body =
              "{\"data\":{\"accessor\":\"fixture-accessor\",\"type\":\"service\",\"ttl\":299,\"explicit_max_ttl\":300,\"renewable\":true}}"
            header =
              Bytes8.pack
                ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (Bytes.length body) ++ "\r\nConnection: close\r\n\r\n")
        Net.sendAll connection header `catch` ignoreClosed
        threadDelay bodyDelay
        Net.sendAll connection body `catch` ignoreClosed
  Async.withAsync serve $ \worker -> do
    Async.link worker
    vaultLookupSelfTokenWith
      (HttpConfig 100000)
      (VaultAddress (Text.pack ("http://127.0.0.1:" ++ show port)))
      (VaultToken "fixture-token")
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

vaultStatusResponse :: Int -> Int -> Int -> IO (Either HttpError SealStatus)
vaultStatusResponse headerDelay bodyDelay timeoutMicros = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "exact seal-status path" ("GET /v1/sys/seal-status " `Bytes.isPrefixOf` request)
        threadDelay headerDelay
        let body = "{\"initialized\":true,\"sealed\":false,\"t\":1,\"n\":1,\"progress\":0}"
            header =
              Bytes8.pack
                ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (Bytes.length body) ++ "\r\nConnection: close\r\n\r\n")
        Net.sendAll connection header `catch` ignoreClosed
        threadDelay bodyDelay
        Net.sendAll connection body `catch` ignoreClosed
  Async.withAsync serve $ \worker -> do
    Async.link worker
    vaultSealStatusWith
      (HttpConfig timeoutMicros)
      (VaultAddress (Text.pack ("http://127.0.0.1:" ++ show port)))
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 1
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

vaultFixtureResponse
  :: Int -> Bytes.ByteString -> Bytes.ByteString -> (VaultAddress -> IO result) -> IO result
vaultFixtureResponse status body expectedPath action = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultHeaders connection Bytes.empty
        assertBool "exact Vault request path" (("GET " <> expectedPath <> " ") `Bytes.isPrefixOf` request)
        assertBool "Vault token header" ("X-Vault-Token: fixture-token" `Bytes.isInfixOf` request)
        let header =
              Bytes8.pack
                ( "HTTP/1.1 "
                    <> show status
                    <> " test\r\nContent-Length: "
                    <> show (Bytes.length body)
                    <> "\r\nConnection: close\r\n\r\n"
                )
        Net.sendAll connection (header <> body) `catch` ignoreClosed
  Async.withAsync serve $ \worker -> do
    Async.link worker
    action (VaultAddress (Text.pack ("http://127.0.0.1:" <> show port)))
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

receiveVaultHeaders :: Socket.Socket -> Bytes.ByteString -> IO Bytes.ByteString
receiveVaultHeaders connection accumulated
  | Bytes.length accumulated > 4096 = assertFailure "fixture request too large"
  | "\r\n\r\n" `Bytes.isInfixOf` accumulated = pure accumulated
  | otherwise = do
      chunk <- Net.recv connection 4096
      if Bytes.null chunk
        then assertFailure "fixture EOF"
        else receiveVaultHeaders connection (accumulated <> chunk)

vaultWriteResponse :: Int -> Bytes.ByteString -> IO (Either HttpError Natural)
vaultWriteResponse status body = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  let serve = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        request <- receiveVaultWrite connection Bytes.empty
        assertBool
          "CAS targets the exact Target replay path"
          ("POST /v1/secret/data/control-plane/request-replay/target-secret-agent " `Bytes.isInfixOf` request)
        let header =
              Bytes8.pack
                ( "HTTP/1.1 "
                    <> show status
                    <> " test\r\nContent-Length: "
                    <> show (Bytes.length body)
                    <> "\r\nConnection: close\r\n\r\n"
                )
        Net.sendAll connection (header <> body) `catch` ignoreClosed
  Async.withAsync serve $ \worker -> do
    Async.link worker
    vaultKvCasWriteV2Bounded
      (VaultAddress (Text.pack ("http://127.0.0.1:" <> show port)))
      (VaultToken "fixture-token")
      "secret"
      "control-plane/request-replay/target-secret-agent"
      (KvV2Cas 7)
      (Map.singleton "projection_base64" "AQ==")
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener
  ignoreClosed :: IOException -> IO ()
  ignoreClosed _ = pure ()

receiveVaultWrite :: Socket.Socket -> Bytes.ByteString -> IO Bytes.ByteString
receiveVaultWrite connection accumulated
  | Bytes.length accumulated > 4096 = assertFailure "fixture request too large"
  | "\"cas\":7" `Bytes.isInfixOf` accumulated
      && "\"projection_base64\":\"AQ==\"" `Bytes.isInfixOf` accumulated =
      pure accumulated
  | otherwise = do
      chunk <- Net.recv connection 4096
      if Bytes.null chunk
        then assertFailure "fixture EOF before expected CAS body"
        else receiveVaultWrite connection (accumulated <> chunk)

targetMigrationForbidden :: Assertion
targetMigrationForbidden = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
  skew <- either (assertFailure . show) pure (authorityDurationFromMicros 100)
  oldLimits <- either (assertFailure . show) pure (mkRequestReplayLimits 1 64 skew)
  nextLimits <- either (assertFailure . show) pure (mkRequestReplayLimits 2 64 skew)
  projection <-
    either
      (assertFailure . show)
      pure
      (encodeRequestReplayProjection 65536 oldLimits (initialRequestReplayProjection oldLimits))
  address <- Socket.getSocketName listener
  port <- case address of
    Socket.SockAddrInet value _ -> pure (fromIntegral value :: Int)
    _ -> assertFailure "Vault fixture requires IPv4"
  logins <- newIORef (0 :: Int)
  let login = do
        modifyIORef' logins (+ 1)
        pure (Right (LoginLease (VaultToken "fixture-token") 60 True))
      base64 = Base64.encode projection
      getBody = "{\"data\":{\"data\":{\"projection_base64\":\"" <> base64 <> "\"},\"metadata\":{\"version\":7}}}"
      respond status body connection = do
        let header =
              Bytes8.pack
                ( "HTTP/1.1 "
                    <> show (status :: Int)
                    <> " test\r\nContent-Length: "
                    <> show (Bytes.length body)
                    <> "\r\nConnection: close\r\n\r\n"
                )
        Net.sendAll connection (header <> body)
      serve = do
        bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
          receive connection Bytes.empty
          respond 200 getBody connection
        bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
          receiveMigrationWrite connection Bytes.empty
          respond 403 "forbidden" connection
  session <-
    newVaultSession
      (VaultAddress (Text.pack ("http://127.0.0.1:" <> show port)))
      (SessionClock (pure 0))
      login
  Async.withAsync serve $ \worker -> do
    Async.link worker
    migrateTargetReplayStaged session 65536 oldLimits nextLimits >>= (@?= TargetReplayWriteRefused)
    Async.wait worker
  readIORef logins >>= (@?= 1)
 where
  open = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 2
    pure listener

receiveMigrationWrite :: Socket.Socket -> Bytes.ByteString -> IO ()
receiveMigrationWrite connection accumulated
  | Bytes.length accumulated > 4096 = assertFailure "fixture request too large"
  | "\"cas\":7" `Bytes.isInfixOf` accumulated
      && "\"projection_base64\"" `Bytes.isInfixOf` accumulated =
      pure ()
  | otherwise = do
      chunk <- Net.recv connection 4096
      if Bytes.null chunk
        then assertFailure "fixture EOF before migration CAS"
        else receiveMigrationWrite connection (accumulated <> chunk)
