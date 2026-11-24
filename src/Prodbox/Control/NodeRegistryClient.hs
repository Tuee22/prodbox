{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Anonymous, bounded reads of a pinned public kind-node manifest. No Docker
-- operation, credential discovery, or artifact publication occurs here.
module Prodbox.Control.NodeRegistryClient
  ( NodeRegistryReadError (..)
  , NodeRegistryDocument (..)
  , fetchNodeRegistryManifest
  , fetchNodeRegistryBlob
  , fetchPinnedKindTool
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Prodbox.Control.NodeRegistryManifest
  ( NodeRegistryBlob (..)
  , NodeRegistryManifestError
  , NodeRegistryPlan
  , parseNodeRegistryManifest
  , validNodeRegistryDigest
  )
import System.IO (Handle)
import System.Info qualified as SystemInfo
import System.Timeout (timeout)

data NodeRegistryReadError
  = NodeRegistryReadInvalidDigest
  | NodeRegistryReadTimedOut
  | NodeRegistryReadUnavailable
  | NodeRegistryReadBadResponse
  | NodeRegistryReadManifestRefused !NodeRegistryManifestError
  | NodeRegistryReadBlobMismatch
  deriving (Eq, Show)

-- The original bytes are needed to construct an OCI layout whose descriptor
-- continues to identify the exact manifest retrieved from the registry.
data NodeRegistryDocument = NodeRegistryDocument
  { nodeRegistryManifestBytes :: !ByteString.ByteString
  , nodeRegistryManifestPlan :: !NodeRegistryPlan
  }
  deriving (Eq, Show)

-- | Both hosts and repository are fixed. A selected manifest digest is checked
-- before a request and again against the exact response bytes. Tokens remain in
-- memory and neither token nor response bodies appear in returned errors.
fetchNodeRegistryManifest :: Text -> IO (Either NodeRegistryReadError NodeRegistryDocument)
fetchNodeRegistryManifest selected
  | not (validNodeRegistryDigest selected) = pure (Left NodeRegistryReadInvalidDigest)
  | otherwise = do
      bounded <- timeout 45000000 (tryHttp (fetch selected))
      pure $ case bounded of
        Nothing -> Left NodeRegistryReadTimedOut
        Just (Left _) -> Left NodeRegistryReadUnavailable
        Just (Right result) -> result

tryHttp :: IO a -> IO (Either HTTP.HttpException a)
tryHttp = try

fetch :: Text -> IO (Either NodeRegistryReadError NodeRegistryDocument)
fetch selected = do
  manager <- HTTP.newManager (HTTP.managerSetProxy HTTP.noProxy tlsManagerSettings)
  tokenResponse <- fetchToken manager
  case tokenResponse of
    Left failure -> pure (Left failure)
    Right token -> do
      base <-
        HTTP.parseRequest
          ("https://registry-1.docker.io/v2/kindest/node/manifests/" ++ Text.unpack selected)
      let request =
            base
              { HTTP.requestHeaders =
                  [ ("Authorization", "Bearer " <> token)
                  ,
                    ( "Accept"
                    , "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
                    )
                  ]
              , HTTP.redirectCount = 0
              }
      response <- readBounded manager request 1048576
      pure $ do
        bytes <- response
        plan <-
          either (Left . NodeRegistryReadManifestRefused) Right (parseNodeRegistryManifest selected bytes)
        Right (NodeRegistryDocument bytes plan)

fetchToken :: HTTP.Manager -> IO (Either NodeRegistryReadError ByteString.ByteString)
fetchToken manager = do
  tokenRequest <-
    HTTP.parseRequest
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository:kindest/node:pull"
  tokenResponse <- readBounded manager tokenRequest 65536
  pure (tokenResponse >>= parseToken)

-- | The destination is an unpublished temporary file owned by the caller.
-- On any failure its partial contents must be discarded. Redirects are
-- restricted to the observed Docker Hub CDN and never receive the bearer token.
fetchNodeRegistryBlob :: NodeRegistryBlob -> Handle -> IO (Either NodeRegistryReadError ())
fetchNodeRegistryBlob descriptor destination
  | not (validNodeRegistryDigest (nodeRegistryBlobDigest descriptor)) =
      pure (Left NodeRegistryReadInvalidDigest)
  | expected <= 0 || expected > 2147483648 = pure (Left NodeRegistryReadBadResponse)
  | otherwise = do
      bounded <- timeout 540000000 (tryHttp (tryIO download))
      pure $ case bounded of
        Nothing -> Left NodeRegistryReadTimedOut
        Just (Left _) -> Left NodeRegistryReadUnavailable
        Just (Right (Left _)) -> Left NodeRegistryReadUnavailable
        Just (Right (Right result)) -> result
 where
  expected = nodeRegistryBlobSize descriptor
  tryIO :: IO a -> IO (Either IOException a)
  tryIO = try
  download = do
    manager <- HTTP.newManager (HTTP.managerSetProxy HTTP.noProxy tlsManagerSettings)
    token <- fetchToken manager
    case token of
      Left failure -> pure (Left failure)
      Right value -> do
        base <-
          HTTP.parseRequest
            ( "https://registry-1.docker.io/v2/kindest/node/blobs/"
                ++ Text.unpack (nodeRegistryBlobDigest descriptor)
            )
        let request =
              base
                { HTTP.requestHeaders = [("Authorization", "Bearer " <> value)]
                , HTTP.redirectCount = 0
                , HTTP.responseTimeout = HTTP.responseTimeoutMicro 15000000
                }
        HTTP.withResponse request manager (handleResponse manager)
  handleResponse manager response = case statusCode (HTTP.responseStatus response) of
    200 -> consume (HTTP.responseBody response) 0 (hashInit :: Context SHA256)
    307 -> case lookup "Location" (HTTP.responseHeaders response) of
      Just location | "https://production.cloudfront.docker.com/" `ByteString.isPrefixOf` location -> do
        redirect <-
          HTTP.parseRequest (Text.unpack (TextEncoding.decodeUtf8With (\_ _ -> Just '\xfffd') location))
        let safe =
              redirect
                { HTTP.requestHeaders = []
                , HTTP.redirectCount = 0
                , HTTP.responseTimeout = HTTP.responseTimeoutMicro 15000000
                }
        HTTP.withResponse safe manager $ \cdn ->
          if statusCode (HTTP.responseStatus cdn) == 200
            then consume (HTTP.responseBody cdn) 0 (hashInit :: Context SHA256)
            else pure (Left NodeRegistryReadBadResponse)
      _ -> pure (Left NodeRegistryReadBadResponse)
    _ -> pure (Left NodeRegistryReadBadResponse)
  consume reader !count !context = do
    chunk <- HTTP.brRead reader
    let next = count + fromIntegral (ByteString.length chunk)
    if ByteString.null chunk
      then
        pure $
          if count == expected
            && "sha256:" <> Text.pack (show (hashFinalize context :: Digest SHA256))
              == nodeRegistryBlobDigest descriptor
            then Right ()
            else Left NodeRegistryReadBlobMismatch
      else
        if next > expected
          then pure (Left NodeRegistryReadBlobMismatch)
          else ByteString.hPut destination chunk >> consume reader next (hashUpdate context chunk)

-- | Fetch the one provider executable whose invocation is modelled by the
-- kind adapter. The destination is unpublished and must be discarded on any
-- failure. A release redirect receives no credentials and is never rendered.
fetchPinnedKindTool :: Text -> Integer -> Handle -> IO (Either NodeRegistryReadError ())
fetchPinnedKindTool expected limit destination
  | expected /= pinnedKindDigest || SystemInfo.arch /= "x86_64" =
      pure (Left NodeRegistryReadInvalidDigest)
  | limit <= 0 || limit > 104857600 = pure (Left NodeRegistryReadBadResponse)
  | otherwise = do
      bounded <- timeout 180000000 (tryHttp (tryIO download))
      pure $ case bounded of
        Nothing -> Left NodeRegistryReadTimedOut
        Just (Left _) -> Left NodeRegistryReadUnavailable
        Just (Right (Left _)) -> Left NodeRegistryReadUnavailable
        Just (Right (Right result)) -> result
 where
  pinnedKindDigest = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
  tryIO :: IO a -> IO (Either IOException a)
  tryIO = try
  download = do
    manager <- HTTP.newManager (HTTP.managerSetProxy HTTP.noProxy tlsManagerSettings)
    base <-
      HTTP.parseRequest
        "https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-linux-amd64"
    let request = base {HTTP.redirectCount = 0, HTTP.responseTimeout = HTTP.responseTimeoutMicro 15000000}
    HTTP.withResponse request manager (handleResponse manager)
  handleResponse manager response = case statusCode (HTTP.responseStatus response) of
    200 -> consume (HTTP.responseBody response) 0 (hashInit :: Context SHA256)
    302 -> case lookup "Location" (HTTP.responseHeaders response) of
      Just location | "https://release-assets.githubusercontent.com/" `ByteString.isPrefixOf` location -> do
        redirect <-
          HTTP.parseRequest (Text.unpack (TextEncoding.decodeUtf8With (\_ _ -> Just '\xfffd') location))
        let safe =
              redirect
                { HTTP.requestHeaders = []
                , HTTP.redirectCount = 0
                , HTTP.responseTimeout = HTTP.responseTimeoutMicro 15000000
                }
        HTTP.withResponse safe manager readAsset
      _ -> pure (Left NodeRegistryReadBadResponse)
    _ -> pure (Left NodeRegistryReadBadResponse)
  readAsset response =
    if statusCode (HTTP.responseStatus response) == 200
      then consume (HTTP.responseBody response) 0 (hashInit :: Context SHA256)
      else pure (Left NodeRegistryReadBadResponse)
  consume reader !count !context = do
    chunk <- HTTP.brRead reader
    let next = count + fromIntegral (ByteString.length chunk)
    if ByteString.null chunk
      then
        pure $
          if count > 0 && "sha256:" <> Text.pack (show (hashFinalize context :: Digest SHA256)) == expected
            then Right ()
            else Left NodeRegistryReadBlobMismatch
      else
        if next > limit
          then pure (Left NodeRegistryReadBlobMismatch)
          else ByteString.hPut destination chunk >> consume reader next (hashUpdate context chunk)

parseToken :: ByteString.ByteString -> Either NodeRegistryReadError ByteString.ByteString
parseToken bytes = case Aeson.decodeStrict bytes >>= AesonTypes.parseMaybe tokenField of
  Just token
    | not (Text.null token)
        && Text.length token <= 8192
        && Text.all (\c -> c > ' ' && c < '\DEL') token ->
        Right (TextEncoding.encodeUtf8 token)
  _ -> Left NodeRegistryReadBadResponse
 where
  tokenField = Aeson.withObject "anonymous token" (.: "token")

readBounded
  :: HTTP.Manager -> HTTP.Request -> Int -> IO (Either NodeRegistryReadError ByteString.ByteString)
readBounded manager request maximumBytes = do
  outcome <-
    try
      ( HTTP.withResponse
          request {HTTP.responseTimeout = HTTP.responseTimeoutMicro 15000000, HTTP.redirectCount = 0}
          manager
          readResponse
      )
  pure $ case outcome of
    Left (_ :: IOException) -> Left NodeRegistryReadUnavailable
    Right result -> result
 where
  readResponse response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left NodeRegistryReadBadResponse)
    | otherwise = collect (HTTP.responseBody response) [] 0
  collect reader chunks size = do
    chunk <- HTTP.brRead reader
    let nextSize = size + ByteString.length chunk
    if ByteString.null chunk
      then pure (Right (ByteString.concat (reverse chunks)))
      else
        if nextSize > maximumBytes
          then pure (Left NodeRegistryReadBadResponse)
          else collect reader (chunk : chunks) nextSize
