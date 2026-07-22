{-# LANGUAGE OverloadedStrings #-}

-- | Native in-cluster @coordination.k8s.io/v1 Lease@ client for the emitter
-- fence. It uses only the projected ServiceAccount token and CA, performs no
-- @kubectl@ subprocess, and preserves HTTP 404/409 as typed absence/conflict.
module Prodbox.Gateway.Emitter.KubernetesLease
  ( inClusterEmitterLeaseClient
  , leaseApiPath
  , maximumLeaseResponseBytes
  , validateProjectedToken
  , projectedTokenSupplierAt
  , boundLeaseResponseBody
  , collectLeaseResponseBody
  , runLeaseRequestWithinDeadline
  , leaseObservationFromResponse
  , leaseMutationFromResponse
  )
where

import Control.Exception
  ( IOException
  , SomeAsyncException
  , SomeException
  , fromException
  , try
  , tryJust
  )
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAscii, isControl, isSpace)
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime)
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (..)
  , Manager
  , Request (..)
  , RequestBody (RequestBodyLBS)
  , brReadSome
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  , withResponse
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS
  ( ClientParams (..)
  , Shared (..)
  , defaultParamsClient
  )
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineObservation
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.Gateway.Emitter.Lease
  ( EmitterLeaseClient (..)
  , LeaseMutationResult (..)
  , LeaseName
  , LeaseObservation (..)
  , LeaseRecord (..)
  , leaseDurationSeconds
  , leaseNameText
  , mkLeaseDuration
  , mkLeaseName
  )
import Prodbox.K8s.InCluster
  ( InClusterCredentials (..)
  , inClusterTokenPath
  , secretApiBaseUrl
  )
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Timeout (timeout)

leaseApiPath :: Text -> LeaseName -> String
leaseApiPath namespace name =
  "/apis/coordination.k8s.io/v1/namespaces/"
    ++ Text.unpack namespace
    ++ "/leases/"
    ++ Text.unpack (leaseNameText name)

leaseCollectionPath :: Text -> String
leaseCollectionPath namespace =
  "/apis/coordination.k8s.io/v1/namespaces/"
    ++ Text.unpack namespace
    ++ "/leases"

inClusterEmitterLeaseClient
  :: InClusterCredentials
  -> IO (Either String EmitterLeaseClient)
inClusterEmitterLeaseClient credentials = do
  managerResult <- inClusterManager credentials
  pure $ do
    manager <- managerResult
    namespaceName <-
      either
        (Left . show)
        Right
        (mkLeaseName (inClusterCredentialsNamespace credentials))
    let namespace = leaseNameText namespaceName
    if namespace /= inClusterCredentialsNamespace credentials
      then Left "in-pod namespace is not in canonical DNS-label form"
      else Right ()
    let tokenSupplier = projectedTokenSupplierAt inClusterTokenPath
    Right
      EmitterLeaseClient
        { leaseClientObserve = observeLease manager tokenSupplier namespace
        , leaseClientCreate = mutateLease manager tokenSupplier namespace "POST"
        , leaseClientReplace = mutateLease manager tokenSupplier namespace "PUT"
        }

type ProjectedTokenSupplier = IO (Either Text Text)

maximumProjectedTokenBytes :: Int
maximumProjectedTokenBytes = 16 * 1024

maximumLeaseResponseBytes :: Int
maximumLeaseResponseBytes = 64 * 1024

-- | Validate one freshly read projected ServiceAccount token. Tokens are
-- bounded and must be a single non-empty UTF-8 token. Projected files may have
-- surrounding line whitespace, which is removed; whitespace/control bytes
-- inside the canonical token are rejected as ambiguous header material.
validateProjectedToken :: BS.ByteString -> Either Text Text
validateProjectedToken bytes
  | BS.length bytes > maximumProjectedTokenBytes =
      Left "projected ServiceAccount token exceeds the 16 KiB bound"
  | otherwise = do
      token <-
        either
          (Left . Text.pack . ("projected ServiceAccount token is not UTF-8: " ++) . show)
          Right
          (TextEncoding.decodeUtf8' bytes)
      let canonical = Text.strip token
      if Text.null canonical
        then Left "projected ServiceAccount token is empty"
        else
          if Text.any
            (\character -> not (isAscii character) || isSpace character || isControl character)
            canonical
            then Left "projected ServiceAccount token contains non-ASCII, whitespace, or control characters"
            else Right canonical

-- | Read the projected token for every request so kubelet token rotation takes
-- effect without restarting the daemon. The read itself is bounded before a
-- token-sized allocation is accepted.
projectedTokenSupplierAt :: FilePath -> ProjectedTokenSupplier
projectedTokenSupplierAt path = do
  result <-
    ( try
        ( withBinaryFile path ReadMode $ \handle ->
            BS.hGet handle (maximumProjectedTokenBytes + 1)
        )
        :: IO (Either IOException BS.ByteString)
    )
  pure $ case result of
    Left err ->
      Left (Text.pack ("failed to read projected ServiceAccount token: " ++ show err))
    Right bytes -> validateProjectedToken bytes

inClusterManager :: InClusterCredentials -> IO (Either String Manager)
inClusterManager credentials = do
  caStore <- readCertificateStore (inClusterCredentialsCaCertPath credentials)
  case caStore of
    Nothing ->
      pure
        ( Left
            ( "failed to read in-pod CA certificate at "
                ++ inClusterCredentialsCaCertPath credentials
            )
        )
    Just store -> do
      let host = "kubernetes.default.svc.cluster.local"
          baseParams = defaultParamsClient host ""
          clientParams =
            baseParams {clientShared = (clientShared baseParams) {sharedCAStore = store}}
      Right <$> newManager (mkManagerSettings (TLSSettings clientParams) Nothing)

observeLease
  :: Manager
  -> ProjectedTokenSupplier
  -> Text
  -> Deadline
  -> LeaseName
  -> IO LeaseObservation
observeLease manager tokenSupplier namespace deadline name = do
  result <- requestLease manager tokenSupplier deadline "GET" (objectUrl namespace name) Nothing
  pure $ case result of
    Left detail -> LeaseUnobservable detail
    Right (code, body) -> leaseObservationFromResponse name code body

mutateLease
  :: Manager
  -> ProjectedTokenSupplier
  -> Text
  -> BL.ByteString
  -> Deadline
  -> LeaseRecord
  -> IO LeaseMutationResult
mutateLease manager tokenSupplier namespace httpMethod deadline record = do
  let url =
        if httpMethod == "POST"
          then secretApiBaseUrl ++ leaseCollectionPath namespace
          else objectUrl namespace (leaseRecordName record)
  result <-
    requestLease
      manager
      tokenSupplier
      deadline
      httpMethod
      url
      (Just (encode (recordToManifest namespace record)))
  pure $ case result of
    Left detail -> LeaseMutationUnobservable detail
    Right (code, body) -> leaseMutationFromResponse record code body

objectUrl :: Text -> LeaseName -> String
objectUrl namespace name = secretApiBaseUrl ++ leaseApiPath namespace name

requestLease
  :: Manager
  -> ProjectedTokenSupplier
  -> Deadline
  -> BL.ByteString
  -> String
  -> Maybe BL.ByteString
  -> IO (Either Text (Int, BL.ByteString))
requestLease manager tokenSupplier deadline httpMethod url maybeBody = do
  now <- realMonotonicNow
  case deadlineObservation now deadline of
    DeadlineExpired -> pure (Left "Kubernetes Lease deadline expired before dispatch")
    DeadlineOpen _ -> do
      tokenResult <- tokenSupplier
      case tokenResult of
        Left detail -> pure (Left detail)
        Right token -> do
          parsed <- tryJust catchSynchronousHttp (parseRequest url)
          case parsed of
            Left err -> pure (Left (Text.pack ("Kubernetes Lease URL error: " ++ show err)))
            Right baseRequest -> do
              response <-
                runLeaseRequestWithinDeadline realMonotonicNow deadline $ \remainingMicros -> do
                  let requestTimeoutMicros = min remainingMicros (5 * 1000 * 1000)
                      request =
                        baseRequest
                          { method = BL.toStrict httpMethod
                          , requestHeaders =
                              catMaybes
                                [ Just ("Authorization", TextEncoding.encodeUtf8 ("Bearer " <> token))
                                , Just ("Accept", "application/json")
                                , (\_ -> ("Content-Type", "application/json")) <$> maybeBody
                                ]
                          , requestBody = maybe (requestBody baseRequest) RequestBodyLBS maybeBody
                          , responseTimeout = responseTimeoutMicro requestTimeoutMicros
                          }
                  tryJust catchSynchronousHttp $
                    withResponse request manager $ \value -> do
                      bodyResult <-
                        collectLeaseResponseBody
                          realMonotonicNow
                          deadline
                          (brReadSome (responseBody value))
                      pure $ do
                        body <- bodyResult
                        Right (statusCode (responseStatus value), body)
              pure $ case response of
                Left detail -> Left detail
                Right (Left err) -> Left (Text.pack ("Kubernetes Lease HTTP error: " ++ show err))
                Right (Right bounded) -> bounded

catchSynchronousHttp :: HttpException -> Maybe HttpException
catchSynchronousHttp err
  | httpExceptionContainsAsync err = Nothing
  | otherwise = Just err

httpExceptionContainsAsync :: HttpException -> Bool
httpExceptionContainsAsync err = case err of
  InvalidUrlException {} -> False
  HttpExceptionRequest _ content -> case content of
    ConnectionFailure nested -> exceptionIsAsync nested
    InternalException nested -> exceptionIsAsync nested
    _ -> False

exceptionIsAsync :: SomeException -> Bool
exceptionIsAsync = isJust . (fromException :: SomeException -> Maybe SomeAsyncException)

boundLeaseResponseBody :: BL.ByteString -> Either Text BL.ByteString
boundLeaseResponseBody body
  | BL.length body > fromIntegral maximumLeaseResponseBytes =
      Left "Kubernetes Lease response exceeds the 64 KiB bound"
  | otherwise = Right body

-- | Consume one HTTP response body through EOF under the caller's original
-- absolute deadline. A single 'brReadSome' is not a complete-body read: the
-- network may fragment valid JSON arbitrarily. The collector asks for at most
-- the remaining bound plus one byte, rejects as soon as that sentinel byte is
-- observed, and never returns a partial prefix as a successful body.
--
-- 'timeout' cancels the blocked body read with its private asynchronous
-- exception and catches only that exception; unrelated asynchronous
-- cancellation continues to propagate to the daemon's structured-concurrency
-- scope.
collectLeaseResponseBody
  :: IO MonotonicInstant
  -> Deadline
  -> (Int -> IO BL.ByteString)
  -> IO (Either Text BL.ByteString)
collectLeaseResponseBody observeNow deadline readChunk = do
  now <- observeNow
  case deadlineObservation now deadline of
    DeadlineExpired -> pure (Left leaseResponseDeadlineError)
    DeadlineOpen (RemainingDuration remainingMicros) -> do
      completed <-
        timeout
          (naturalToTimeoutMicros remainingMicros)
          (collectChunks 0 [])
      case completed of
        Nothing -> pure (Left leaseResponseDeadlineError)
        Just result -> do
          after <- observeNow
          pure $ case deadlineObservation after deadline of
            DeadlineExpired -> Left leaseResponseDeadlineError
            DeadlineOpen _ -> result
 where
  collectChunks total reversed = do
    let requested = maximumLeaseResponseBytes + 1 - total
    chunk <- readChunk requested
    if BL.null chunk
      then pure (Right (BL.concat (reverse reversed)))
      else
        if BL.length chunk > fromIntegral requested
          then pure (Left leaseResponseBoundError)
          else do
            let totalAfter = total + fromIntegral (BL.length chunk)
            if totalAfter > maximumLeaseResponseBytes
              then pure (Left leaseResponseBoundError)
              else collectChunks totalAfter (chunk : reversed)

naturalToTimeoutMicros :: Natural -> Int
naturalToTimeoutMicros value =
  fromIntegral (min value (fromIntegral (maxBound :: Int)))

leaseResponseBoundError :: Text
leaseResponseBoundError = "Kubernetes Lease response exceeds the 64 KiB bound"

leaseResponseDeadlineError :: Text
leaseResponseDeadlineError = "Kubernetes Lease response deadline expired before EOF"

-- | Re-observe the caller's original absolute deadline immediately before an
-- HTTP dispatch and cancel the entire request/response scope at that fresh
-- remaining budget. Token rotation reads and URL parsing happen before this
-- boundary, so neither may consume time and then dispatch with a stale timeout.
runLeaseRequestWithinDeadline
  :: IO MonotonicInstant
  -> Deadline
  -> (Int -> IO value)
  -> IO (Either Text value)
runLeaseRequestWithinDeadline observeNow deadline action = do
  now <- observeNow
  case deadlineObservation now deadline of
    DeadlineExpired -> pure (Left leaseRequestDeadlineError)
    DeadlineOpen (RemainingDuration remainingMicros) -> do
      let boundedRemaining = naturalToTimeoutMicros remainingMicros
      completed <- timeout boundedRemaining (action boundedRemaining)
      case completed of
        Nothing -> pure (Left leaseRequestDeadlineError)
        Just result -> do
          after <- observeNow
          pure $ case deadlineObservation after deadline of
            DeadlineExpired -> Left leaseRequestDeadlineError
            DeadlineOpen _ -> Right result

leaseRequestDeadlineError :: Text
leaseRequestDeadlineError = "Kubernetes Lease deadline expired before request completion"

leaseObservationFromResponse :: LeaseName -> Int -> BL.ByteString -> LeaseObservation
leaseObservationFromResponse expectedName code body = case code of
  404 -> LeaseMissing
  200 ->
    case eitherDecode body >>= wireToRecord of
      Left detail -> LeaseUnobservable (Text.pack detail)
      Right record
        | leaseRecordName record /= expectedName ->
            LeaseUnobservable "Kubernetes Lease GET returned a different Lease coordinate"
        | otherwise -> LeaseObserved record
  _ ->
    LeaseUnobservable
      ( Text.pack
          ("Kubernetes Lease GET returned " ++ show code ++ ": " ++ truncateBody body)
      )

leaseMutationFromResponse :: LeaseRecord -> Int -> BL.ByteString -> LeaseMutationResult
leaseMutationFromResponse desired code body
  | code == 409 = LeaseMutationConflict
  | code == 200 || code == 201 =
      case eitherDecode body >>= wireToRecord of
        Left detail -> LeaseMutationUnobservable (Text.pack detail)
        Right applied
          | leaseRecordName applied /= leaseRecordName desired -> mismatch
          | leaseRecordHolderIdentity applied /= leaseRecordHolderIdentity desired -> mismatch
          | leaseRecordDuration applied /= leaseRecordDuration desired -> mismatch
          | Text.null (leaseRecordResourceVersion applied) -> mismatch
          | otherwise -> LeaseMutationApplied applied
  | otherwise =
      LeaseMutationUnobservable
        ( Text.pack
            ( "Kubernetes Lease mutation returned "
                ++ show code
                ++ ": "
                ++ truncateBody body
            )
        )
 where
  mismatch = LeaseMutationUnobservable "Kubernetes Lease mutation returned mismatching coordinates"

data LeaseWire = LeaseWire
  { wireName :: !Text
  , wireResourceVersion :: !Text
  , wireHolderIdentity :: !Text
  , wireDurationSeconds :: !Natural
  , wireAcquireTime :: !UTCTime
  , wireRenewTime :: !UTCTime
  , wireTransitions :: !Natural
  }

instance FromJSON LeaseWire where
  parseJSON = withObject "Kubernetes Lease" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    LeaseWire
      <$> metadata .: "name"
      <*> metadata .: "resourceVersion"
      <*> spec .: "holderIdentity"
      <*> spec .: "leaseDurationSeconds"
      <*> spec .: "acquireTime"
      <*> spec .: "renewTime"
      <*> (spec .:? "leaseTransitions" .!= 0)

wireToRecord :: LeaseWire -> Either String LeaseRecord
wireToRecord wire = do
  name <- either (Left . show) Right (mkLeaseName (wireName wire))
  if wireName wire /= leaseNameText name
    then Left "Kubernetes Lease metadata.name is not in canonical DNS-label form"
    else Right ()
  requireWireText "resourceVersion" 1024 (wireResourceVersion wire)
  requireWireText "holderIdentity" 255 (wireHolderIdentity wire)
  if wireTransitions wire > fromIntegral (maxBound :: Int)
    then Left "Kubernetes Lease leaseTransitions exceeds the platform bound"
    else Right ()
  duration <- either (Left . show) Right (mkLeaseDuration (wireDurationSeconds wire))
  Right
    LeaseRecord
      { leaseRecordName = name
      , leaseRecordResourceVersion = wireResourceVersion wire
      , leaseRecordHolderIdentity = wireHolderIdentity wire
      , leaseRecordDuration = duration
      , leaseRecordAcquireTime = wireAcquireTime wire
      , leaseRecordRenewTime = wireRenewTime wire
      , leaseRecordTransitions = wireTransitions wire
      }

requireWireText :: String -> Int -> Text -> Either String ()
requireWireText label maximumLength value
  | Text.null value = Left ("Kubernetes Lease " ++ label ++ " is empty")
  | Text.length value > maximumLength = Left ("Kubernetes Lease " ++ label ++ " exceeds its bound")
  | Text.any (== '\NUL') value = Left ("Kubernetes Lease " ++ label ++ " contains NUL")
  | otherwise = Right ()

recordToManifest :: Text -> LeaseRecord -> Value
recordToManifest namespace record =
  object
    [ "apiVersion" .= ("coordination.k8s.io/v1" :: Text)
    , "kind" .= ("Lease" :: Text)
    , "metadata"
        .= object
          ( [ "name" .= leaseNameText (leaseRecordName record)
            , "namespace" .= namespace
            ]
              ++ [ "resourceVersion" .= leaseRecordResourceVersion record
                 | not (Text.null (leaseRecordResourceVersion record))
                 ]
          )
    , "spec"
        .= object
          [ "holderIdentity" .= leaseRecordHolderIdentity record
          , "leaseDurationSeconds" .= leaseDurationSeconds (leaseRecordDuration record)
          , "acquireTime" .= leaseRecordAcquireTime record
          , "renewTime" .= leaseRecordRenewTime record
          , "leaseTransitions" .= leaseRecordTransitions record
          ]
    ]

truncateBody :: BL.ByteString -> String
truncateBody body =
  let rendered = BL8.unpack body
   in if length rendered > 200 then take 200 rendered ++ "…" else rendered
