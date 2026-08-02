{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native Kubernetes TokenReview authentication for the Bootstrap Broker.
--
-- The controller receives an opaque, bounded projected ServiceAccount token
-- in the transport credential header.  This module sends that token to the
-- Kubernetes TokenReview API using the Broker Pod's own rotating projected
-- token and cluster CA.  Only the exact Broker ServiceAccount identity and
-- audience are admitted; malformed, foreign, or ambiguous responses refuse.
module Prodbox.Bootstrap.Broker.TokenReview
  ( brokerTokenReviewAudience
  , BrokerTokenReviewer (..)
  , BrokerTokenReviewResult (..)
  , BrokerTokenReviewUser (..)
  , tokenReviewRequestValue
  , decideBrokerTokenReview
  , tokenReviewBrokerAuthenticator
  , productionBrokerAuthenticator
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
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isAscii, isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( BodyReader
  , HttpException (..)
  , HttpExceptionContent (..)
  , Manager
  , Request (..)
  , RequestBody (RequestBodyLBS)
  , brRead
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
import Prodbox.Bootstrap.Broker.ChartStatics qualified as ChartStatics
import Prodbox.Bootstrap.Broker.Request
  ( BrokerServiceIdentity
  , renderBrokerServiceIdentity
  )
import Prodbox.Bootstrap.Broker.Server
  ( BrokerAuthenticationFailure (..)
  , BrokerAuthenticationRequest (..)
  , BrokerAuthenticator (..)
  , withBrokerTransportCredential
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , RemainingDuration (..)
  , deadlineObservation
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.K8s.InCluster
  ( inClusterCaCertPath
  , inClusterNamespacePath
  , inClusterTokenPath
  , secretApiBaseUrl
  )
import System.IO (IOMode (ReadMode), withBinaryFile)

brokerTokenReviewAudience :: Text
brokerTokenReviewAudience =
  ChartStatics.brokerStaticTokenAudience ChartStatics.brokerChartStatics

maximumProjectedTokenBytes :: Int
maximumProjectedTokenBytes = 16 * 1024

maximumTokenReviewResponseBytes :: Int
maximumTokenReviewResponseBytes = 64 * 1024

newtype BrokerTokenReviewer = BrokerTokenReviewer
  { reviewBrokerToken
      :: ByteString
      -> Deadline
      -> IO (Either Text BrokerTokenReviewResult)
  }

data BrokerTokenReviewUser = BrokerTokenReviewUser
  { tokenReviewUsername :: !Text
  , tokenReviewUid :: !Text
  , tokenReviewGroups :: ![Text]
  }
  deriving stock (Eq, Show)

data BrokerTokenReviewResult = BrokerTokenReviewResult
  { tokenReviewAuthenticated :: !Bool
  , tokenReviewAudiences :: ![Text]
  , tokenReviewUser :: !(Maybe BrokerTokenReviewUser)
  , tokenReviewError :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance FromJSON BrokerTokenReviewUser where
  parseJSON = withObject "TokenReview user" $ \value ->
    BrokerTokenReviewUser
      <$> value .: "username"
      <*> value .: "uid"
      <*> value .:? "groups" .!= []

newtype TokenReviewResponse = TokenReviewResponse BrokerTokenReviewResult

instance FromJSON TokenReviewResponse where
  parseJSON = withObject "TokenReview" $ \value -> do
    status <- value .: "status"
    TokenReviewResponse
      <$> withObject
        "TokenReview status"
        ( \statusValue ->
            BrokerTokenReviewResult
              <$> statusValue .:? "authenticated" .!= False
              <*> statusValue .:? "audiences" .!= []
              <*> statusValue .:? "user"
              <*> statusValue .:? "error"
        )
        status

-- | Build the exact TokenReview request. The returned value contains the
-- credential, so callers must never render or log it.
tokenReviewRequestValue :: ByteString -> Either Text Value
tokenReviewRequestValue credential = do
  canonicalCredential <- validateBearerToken credential
  credentialText <-
    either
      (const (Left "projected ServiceAccount token is not UTF-8"))
      Right
      (TextEncoding.decodeUtf8' canonicalCredential)
  pure
    ( object
        [ "apiVersion" .= ("authentication.k8s.io/v1" :: Text)
        , "kind" .= ("TokenReview" :: Text)
        , "spec"
            .= object
              [ "token" .= credentialText
              , "audiences" .= [brokerTokenReviewAudience]
              ]
        ]
    )

-- | Fail-closed projection of a Kubernetes TokenReview response. A successful
-- review must bind the one requested audience, canonical ServiceAccount
-- username, non-empty Kubernetes UID, and the standard authenticated groups.
decideBrokerTokenReview
  :: Text
  -> BrokerServiceIdentity
  -> BrokerTokenReviewResult
  -> Either BrokerAuthenticationFailure BrokerServiceIdentity
decideBrokerTokenReview namespace expectedIdentity result
  | not (tokenReviewAuthenticated result) = rejected
  | maybe False (not . Text.null . Text.strip) (tokenReviewError result) = rejected
  | tokenReviewAudiences result /= [brokerTokenReviewAudience] = rejected
  | otherwise = case tokenReviewUser result of
      Nothing -> rejected
      Just user
        | tokenReviewUsername user /= expectedUsername -> rejected
        | Text.null (Text.strip (tokenReviewUid user)) -> rejected
        | not (all (`elem` tokenReviewGroups user) requiredGroups) -> rejected
        | otherwise -> Right expectedIdentity
 where
  rejected = Left BrokerAuthenticationRejected
  serviceAccount = renderBrokerServiceIdentity expectedIdentity
  expectedUsername =
    "system:serviceaccount:" <> namespace <> ":" <> serviceAccount
  requiredGroups =
    [ "system:authenticated"
    , "system:serviceaccounts"
    , "system:serviceaccounts:" <> namespace
    ]

tokenReviewBrokerAuthenticator
  :: Text -> BrokerTokenReviewer -> BrokerAuthenticator
tokenReviewBrokerAuthenticator namespace reviewer =
  BrokerAuthenticator $ \request ->
    withBrokerTransportCredential
      (authenticationCredential request)
      (authenticateCredential request)
 where
  authenticateCredential request credential =
    case validateBearerToken credential of
      Left _ -> pure (Left BrokerAuthenticationRejected)
      Right canonicalCredential -> do
        reviewed <-
          reviewBrokerToken
            reviewer
            canonicalCredential
            (authenticationDeadline request)
        pure $ case reviewed of
          Left _ -> Left BrokerAuthenticationUnavailable
          Right result ->
            decideBrokerTokenReview
              namespace
              (authenticationExpectedServiceIdentity request)
              result

-- | Construct the real in-cluster authenticator. Missing projected
-- credentials or an unreadable cluster CA prevent process startup.
productionBrokerAuthenticator
  :: BootstrapBrokerSettings -> IO (Either String BrokerAuthenticator)
productionBrokerAuthenticator _settings = do
  namespaceResult <- readProjectedNamespace inClusterNamespacePath
  case namespaceResult of
    Left detail -> pure (Left detail)
    Right namespace -> do
      reviewerResult <- inClusterTokenReviewer
      pure
        ( tokenReviewBrokerAuthenticator
            namespace
            <$> reviewerResult
        )

inClusterTokenReviewer :: IO (Either String BrokerTokenReviewer)
inClusterTokenReviewer = do
  managerResult <- inClusterManager
  pure $ do
    manager <- managerResult
    Right
      BrokerTokenReviewer
        { reviewBrokerToken = requestTokenReview manager
        }

inClusterManager :: IO (Either String Manager)
inClusterManager = do
  caStore <- readCertificateStore inClusterCaCertPath
  case caStore of
    Nothing ->
      pure
        ( Left
            ( "failed to read in-pod CA certificate at "
                ++ inClusterCaCertPath
            )
        )
    Just store -> do
      let host = "kubernetes.default.svc.cluster.local"
          baseParams = defaultParamsClient host ""
          clientParams =
            baseParams {clientShared = (clientShared baseParams) {sharedCAStore = store}}
      Right <$> newManager (mkManagerSettings (TLSSettings clientParams) Nothing)

requestTokenReview
  :: Manager
  -> ByteString
  -> Deadline
  -> IO (Either Text BrokerTokenReviewResult)
requestTokenReview manager credential deadline = do
  now <- realMonotonicNow
  case deadlineObservation now deadline of
    DeadlineExpired -> pure (Left "TokenReview deadline expired before dispatch")
    DeadlineOpen (RemainingDuration remainingMicros) -> do
      ownTokenResult <- readProjectedToken inClusterTokenPath
      case ownTokenResult of
        Left detail -> pure (Left detail)
        Right ownToken -> do
          case tokenReviewRequestValue credential of
            Left detail -> pure (Left detail)
            Right reviewValue -> do
              parsed <- tryJust catchSynchronousHttp (parseRequest tokenReviewUrl)
              case parsed of
                Left err -> pure (Left (Text.pack ("TokenReview URL error: " ++ show err)))
                Right baseRequest -> do
                  let timeoutMicros = min remainingMicros (5 * 1000 * 1000)
                      request =
                        baseRequest
                          { method = "POST"
                          , requestHeaders =
                              [ ("Authorization", TextEncoding.encodeUtf8 ("Bearer " <> ownToken))
                              , ("Content-Type", "application/json")
                              , ("Accept", "application/json")
                              ]
                          , requestBody = RequestBodyLBS (encode reviewValue)
                          , responseTimeout = responseTimeoutMicro (naturalToInt timeoutMicros)
                          }
                  responseResult <-
                    tryJust
                      catchSynchronousHttp
                      ( withResponse request manager $ \response -> do
                          boundedBody <-
                            readBoundedBody
                              maximumTokenReviewResponseBytes
                              (responseBody response)
                          pure
                            ( statusCode (responseStatus response)
                            , boundedBody
                            )
                      )
                  pure $ case responseResult of
                    Left err -> Left (Text.pack ("TokenReview HTTP error: " ++ show err))
                    Right (responseCode, boundedBody)
                      | responseCode /= 201 ->
                          Left
                            ( "TokenReview API returned HTTP "
                                <> Text.pack (show responseCode)
                            )
                      | otherwise -> case boundedBody of
                          Left detail -> Left detail
                          Right body -> case eitherDecodeStrict' body of
                            Left detail ->
                              Left (Text.pack ("invalid TokenReview response: " ++ detail))
                            Right (TokenReviewResponse result) -> Right result
 where
  tokenReviewUrl =
    secretApiBaseUrl ++ "/apis/authentication.k8s.io/v1/tokenreviews"

readProjectedToken :: FilePath -> IO (Either Text Text)
readProjectedToken path = do
  result <-
    try
      ( withBinaryFile path ReadMode $ \handle ->
          ByteString.hGet handle (maximumProjectedTokenBytes + 1)
      )
      :: IO (Either IOException ByteString)
  pure $ case result of
    Left err -> Left (Text.pack ("failed to read projected ServiceAccount token: " ++ show err))
    Right bytes -> do
      canonical <- validateBearerToken bytes
      Right (TextEncoding.decodeUtf8 canonical)

readProjectedNamespace :: FilePath -> IO (Either String Text)
readProjectedNamespace path = do
  result <-
    try
      ( withBinaryFile path ReadMode $ \handle ->
          ByteString.hGet handle 254
      )
      :: IO (Either IOException ByteString)
  pure $ case result of
    Left _ -> Left "failed to read projected ServiceAccount namespace"
    Right bytes
      | ByteString.length bytes > 253 ->
          Left "projected ServiceAccount namespace exceeds 253 bytes"
      | otherwise -> case TextEncoding.decodeUtf8' bytes of
          Left _ -> Left "projected ServiceAccount namespace is not UTF-8"
          Right decoded ->
            let namespace = Text.strip decoded
             in if Text.null namespace
                  || Text.any
                    (\character -> isSpace character || isControl character)
                    namespace
                  then Left "projected ServiceAccount namespace is invalid"
                  else Right namespace

readBoundedBody :: Int -> BodyReader -> IO (Either Text ByteString)
readBoundedBody maximumBytes = go maximumBytes []
 where
  go remaining chunks reader = do
    chunk <- brRead reader
    if ByteString.null chunk
      then pure (Right (ByteString.concat (reverse chunks)))
      else
        if ByteString.length chunk > remaining
          then pure (Left "TokenReview response exceeds the 64 KiB bound")
          else go (remaining - ByteString.length chunk) (chunk : chunks) reader

validateBearerToken :: ByteString -> Either Text ByteString
validateBearerToken bytes
  | ByteString.length bytes > maximumProjectedTokenBytes =
      Left "projected ServiceAccount token exceeds the 16 KiB bound"
  | otherwise = do
      decoded <-
        either
          (Left . Text.pack . ("projected ServiceAccount token is not UTF-8: " ++) . show)
          Right
          (TextEncoding.decodeUtf8' bytes)
      let canonical = Text.strip decoded
      if Text.null canonical
        then Left "projected ServiceAccount token is empty"
        else
          if Text.any
            (\character -> not (isAscii character) || isSpace character || isControl character)
            canonical
            then Left "projected ServiceAccount token contains invalid characters"
            else Right (TextEncoding.encodeUtf8 canonical)

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
exceptionIsAsync = maybe False (const True) . (fromException :: SomeException -> Maybe SomeAsyncException)

naturalToInt :: (Integral value) => value -> Int
naturalToInt value
  | value > fromIntegral (maxBound :: Int) = maxBound
  | otherwise = fromIntegral value
