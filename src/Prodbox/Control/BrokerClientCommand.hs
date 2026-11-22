{-# LANGUAGE OverloadedStrings #-}

-- | Call the real Bootstrap Broker through its authenticated host path: mint a
-- custom-audience TokenRequest for the secret-free client ServiceAccount, open
-- the bracketed loopback port-forward, prove the Broker answers, and make one
-- closed read-only route request. The cluster is selected explicitly by pinning
-- @KUBECONFIG@ to the environment's installed credential; nothing ambient is
-- consulted. The call context is valid only inside the bracket.
module Prodbox.Control.BrokerClientCommand
  ( brokerVaultStatus
  ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.Client (queryVaultStatus, renderBrokerError)
import Prodbox.Bootstrap.Broker.PortForward
  ( BrokerHostConnection (..)
  , renderBrokerHostConnectionError
  , withBrokerHostConnection
  )
import Prodbox.Bootstrap.Broker.Request (mkIdempotencyKey)
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | Vault's state as the Broker reports it, rendered without secrets.
brokerVaultStatus :: FilePath -> IO (Either String String)
brokerVaultStatus kubeconfig = do
  random <-
    try (withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 12))
      :: IO (Either IOException ByteString.ByteString)
  case random of
    Left failure -> pure (Left ("no entropy for the idempotency key: " ++ show failure))
    Right bytes -> case mkIdempotencyKey (Text.pack ("status-" ++ concatMap hex (ByteString.unpack bytes))) of
      Left detail -> pure (Left detail)
      Right key -> do
        let connection =
              BrokerHostConnection
                { brokerHostEnvironment =
                    Just [("KUBECONFIG", kubeconfig), ("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                , brokerHostWorkingDirectory = "."
                }
        result <- withBrokerHostConnection connection key queryVaultStatus
        pure $ case result of
          Left failure -> Left (renderBrokerHostConnectionError failure)
          Right (Left failure) -> Left (renderBrokerError failure)
          Right (Right value) -> Right (ByteString8.unpack (LazyByteString.toStrict (Aeson.encode value)))
 where
  hex byte = [digits !! fromIntegral (byte `div` 16), digits !! fromIntegral (byte `mod` 16)]
  digits = "0123456789abcdef" :: String
