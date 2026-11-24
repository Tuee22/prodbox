{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded streaming verification of a manifest-declared blob. The caller
-- owns the handle and its lifetime; this function neither publishes nor loads.
module Prodbox.Control.NodeRegistryBlob
  ( NodeBlobVerification (..)
  , verifyNodeRegistryBlob
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Prodbox.Control.NodeRegistryManifest
  ( NodeRegistryBlob (..)
  , validNodeRegistryDigest
  )
import System.IO (Handle)
import System.Timeout (timeout)

data NodeBlobVerification
  = NodeBlobVerified
  | NodeBlobInvalidDescriptor
  | NodeBlobSizeMismatch
  | NodeBlobDigestMismatch
  | NodeBlobReadUnavailable
  | NodeBlobReadTimedOut
  deriving (Eq, Show)

-- | Read at most the declared byte count plus one bounded chunk, with an
-- absolute time bound. An error or timeout never becomes a verified result.
verifyNodeRegistryBlob :: NodeRegistryBlob -> Handle -> IO NodeBlobVerification
verifyNodeRegistryBlob descriptor handle
  | not (validNodeRegistryDigest (nodeRegistryBlobDigest descriptor)) = pure NodeBlobInvalidDescriptor
  | expected <= 0 || expected > 2147483648 = pure NodeBlobInvalidDescriptor
  | otherwise = do
      observed <- timeout 540000000 (try (consume 0 (hashInit :: Context SHA256)))
      pure $ case observed of
        Nothing -> NodeBlobReadTimedOut
        Just (Left (_ :: IOException)) -> NodeBlobReadUnavailable
        Just (Right result) -> result
 where
  expected = nodeRegistryBlobSize descriptor
  consume !count !context = do
    chunk <- ByteString.hGetSome handle 65536
    if ByteString.null chunk
      then
        pure $
          if count /= expected
            then NodeBlobSizeMismatch
            else
              if "sha256:" <> Text.pack (show (hashFinalize context :: Digest SHA256))
                == nodeRegistryBlobDigest descriptor
                then NodeBlobVerified
                else NodeBlobDigestMismatch
      else do
        let nextCount = count + fromIntegral (ByteString.length chunk)
        if nextCount > expected
          then pure NodeBlobSizeMismatch
          else consume nextCount (hashUpdate context chunk)
