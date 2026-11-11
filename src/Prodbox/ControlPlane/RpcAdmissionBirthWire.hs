{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Data-only request families and response bounds shared by the RPC birth
-- producer and client. Prefix recognition grants no authentication or read policy.
module Prodbox.ControlPlane.RpcAdmissionBirthWire
  ( RpcBirthWireFamily (..)
  , classifyRpcBirthWireFamily
  , rpcBirthResponseMaximumForBody
  , rpcBirthRequestPrefix
  , rpcBirthDescriptorRequest
  , rpcBirthRegistryRequest
  , rpcBirthSignedDescriptorRequest
  , rpcBirthSignedRegistryRequest
  , isRpcBirthRequest
  , isRpcBirthDescriptorRequest
  , isRpcBirthRegistryRequest
  , rpcKeyRegistryMaximumBytes
  , rpcBirthObservationMaximumBytes
  , rpcBirthRegistryObservationMaximumBytes
  , rpcBirthRegistryResponseMaximumBytes
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Prodbox.Capacity.ControlPlaneReplayBudget (authorityMetadataResponseMaximumBytes)

data RpcBirthWireFamily = RpcBirthCommandFamily | RpcBirthDescriptorFamily | RpcBirthRegistryFamily
  deriving (Eq, Show)

rpcBirthRequestPrefix, rpcBirthDescriptorRequest, rpcBirthRegistryRequest :: ByteString
rpcBirthRequestPrefix = "prodbox-rpc-birth-request/v1\NUL"
rpcBirthDescriptorRequest = "prodbox-rpc-birth-descriptor/v1\NUL"
rpcBirthRegistryRequest = "prodbox-rpc-birth-registry/v1\NUL"

rpcBirthSignedDescriptorRequest, rpcBirthSignedRegistryRequest :: ByteString
rpcBirthSignedDescriptorRequest = rpcBirthDescriptorRequest <> "signed/v1"
rpcBirthSignedRegistryRequest = rpcBirthRegistryRequest <> "signed/v1"

isRpcBirthRequest, isRpcBirthDescriptorRequest, isRpcBirthRegistryRequest :: ByteString -> Bool
isRpcBirthRequest = BS.isPrefixOf rpcBirthRequestPrefix
isRpcBirthDescriptorRequest = BS.isPrefixOf rpcBirthDescriptorRequest
isRpcBirthRegistryRequest = BS.isPrefixOf rpcBirthRegistryRequest

classifyRpcBirthWireFamily :: ByteString -> Maybe RpcBirthWireFamily
classifyRpcBirthWireFamily bytes
  | isRpcBirthRegistryRequest bytes = Just RpcBirthRegistryFamily
  | isRpcBirthDescriptorRequest bytes = Just RpcBirthDescriptorFamily
  | isRpcBirthRequest bytes = Just RpcBirthCommandFamily
  | otherwise = Nothing

rpcBirthResponseMaximumForBody :: ByteString -> Maybe Int
rpcBirthResponseMaximumForBody bytes = limit <$> classifyRpcBirthWireFamily bytes
 where
  limit family = case family of
    RpcBirthCommandFamily -> authorityMetadataResponseMaximumBytes
    RpcBirthDescriptorFamily -> authorityMetadataResponseMaximumBytes
    RpcBirthRegistryFamily -> rpcBirthRegistryResponseMaximumBytes

rpcKeyRegistryMaximumBytes :: Int
rpcKeyRegistryMaximumBytes = 128 * 1024

rpcBirthObservationMaximumBytes :: Int
rpcBirthObservationMaximumBytes = 8192

rpcBirthRegistryObservationMaximumBytes :: Int
rpcBirthRegistryObservationMaximumBytes = rpcBirthObservationMaximumBytes + rpcKeyRegistryMaximumBytes + 128

rpcBirthRegistryResponseMaximumBytes :: Int
rpcBirthRegistryResponseMaximumBytes = rpcBirthRegistryObservationMaximumBytes + 128
