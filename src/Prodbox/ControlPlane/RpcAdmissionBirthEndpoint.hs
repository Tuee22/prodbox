{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
  ( rpcBirthVerifiedHandler
  , rpcBirthOwnBindingInterpreter
  , rpcBirthOwnBindingReadMaximumMicros
  , isRpcBirthObservationForRole
  , RpcBirthClientError (..)
  , requestRpcBirthWithin
  , requestRpcBirthDescriptorWithin
  , requestRpcBirthRegistryWithin
  , rpcBirthRegistryResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Control.Exception (evaluate)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Capacity.ControlPlaneReplayBudget qualified as ReplayBudget
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , authenticatedClientTransportAtEpoch
  , callAuthenticatedClientTransport
  , resolveAuthenticatedClientTransportDeadline
  )
import Prodbox.ControlPlane.AuthorityPeerContext (peerContextEpoch)
import Prodbox.ControlPlane.AuthorityPeerContextClient
  ( AuthorityPeerContextClientError
  , requestAuthorityPeerContextWithin
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleMigrationApplyRoute)
  )
import Prodbox.ControlPlane.Codec (decodeControlPlaneResponse, encodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedControlPlaneRequest
  , verifiedRequestBody
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
import Prodbox.ControlPlane.RpcAdmissionBirthNative
import Prodbox.ControlPlane.RpcAdmissionBirthWire (rpcBirthRegistryResponseMaximumBytes)
import Prodbox.ControlPlane.RpcOwnBindingHint
  ( decodeRpcOwnBindingQuery
  , encodeRpcOwnBindingHint
  , isRpcOwnBindingQuery
  )
import Prodbox.ControlPlane.Server (RoleInterpreter (..))
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import System.Timeout (timeout)

-- A caller cannot extend this server-owned read window. This is public hint
-- data only: ordinary frames still reach the complete authenticated handler.
rpcBirthOwnBindingReadMaximumMicros :: Natural
rpcBirthOwnBindingReadMaximumMicros = 2000000

rpcBirthOwnBindingInterpreter
  :: AuthorityScope
  -> RpcBirthServingMode
  -> RpcBirthReadInterpreter IO
  -> RoleInterpreter IO
  -> RoleInterpreter IO
rpcBirthOwnBindingInterpreter scope mode reader inner =
  inner {interpreterHandle = handle}
 where
  handle route body
    | route /= LifecycleMigrationApply || not (isRpcOwnBindingQuery body) =
        interpreterHandle inner route body
    | otherwise = Just <$> hint body
  hint body = case decodeRpcOwnBindingQuery scope body of
    Left _ -> pure (ReplyBadRequest, "rpc-own-binding-query-refused\n")
    Right query -> do
      now <- rpcBirthSystemTime
      let deadline = authorityTimeFromMicros (authorityTimeMicros now + rpcBirthOwnBindingReadMaximumMicros)
      result <- runRpcBirthWithin deadline $ do
        selected <- executeRpcBirthOwnBindingHint reader scope mode deadline query
        case selected of
          Left cause -> pure (Left cause)
          Right value -> do
            let bytes = encodeRpcOwnBindingHint value
            _ <- evaluate (BS.length bytes)
            pure (Right bytes)
      pure $ case result of
        Right bytes -> (ReplyOk, bytes)
        Left _ -> (ReplyServiceUnavailable, "rpc-own-binding-unavailable\n")

rpcBirthVerifiedHandler
  :: AuthorityScope
  -> RpcBirthServingMode
  -> RpcBirthNativeBackend
  -> VerifiedControlPlaneRequest
  -> IO (Maybe (ReplyStatus, ByteString))
rpcBirthVerifiedHandler scope mode backend request
  | verifiedRequestRoute request /= LifecycleMigrationApply = pure Nothing
  | isRpcBirthRegistryRequest (verifiedRequestBody request) = do
      result <- case mkRpcBirthRegistryContext scope mode request of
        Left cause -> pure (Left cause)
        Right context ->
          runRpcBirthWithin
            (rpcBirthRegistryContextDeadline context)
            ( do
                observed <-
                  executeRpcBirthRegistryObservation
                    (rpcBirthReadInterpreter (rpcBirthNativeInterpreter backend))
                    context
                pure (observed >>= encodeRpcBirthRegistryObservation)
            )
      pure (Just (rpcBirthResponse result))
  | isRpcBirthDescriptorRequest (verifiedRequestBody request) = do
      result <- case mkRpcBirthDescriptorContext scope mode request of
        Left cause -> pure (Left cause)
        Right context ->
          runRpcBirthWithin
            (rpcBirthDescriptorContextDeadline context)
            ( do
                observed <-
                  executeRpcBirthDescriptorObservation
                    (rpcBirthReadInterpreter (rpcBirthNativeInterpreter backend))
                    context
                pure (observed >>= encodeRpcBirthDescriptorObservation)
            )
      pure (Just (rpcBirthResponse result))
  | not (isRpcBirthRequest (verifiedRequestBody request)) = pure Nothing
  | otherwise = do
      result <- case mkRpcBirthContext scope mode request of
        Left cause -> pure (Left cause)
        Right context ->
          runRpcBirthWithin
            (rpcBirthContextDeadline context)
            (executeRpcBirth (rpcBirthNativeInterpreter backend) context)
      pure (Just (rpcBirthResponse result))

runRpcBirthWithin
  :: AuthorityTime -> IO (Either RpcBirthError value) -> IO (Either RpcBirthError value)
runRpcBirthWithin deadline effect = do
  now <- rpcBirthSystemTime
  if now >= deadline
    then pure (Left RpcBirthDeadlineReached)
    else do
      let remaining = authorityTimeMicros deadline - authorityTimeMicros now
          limit = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
      attempted <- timeout limit (effect >>= evaluate)
      closing <- rpcBirthSystemTime
      pure $
        if closing >= deadline
          then Left RpcBirthDeadlineReached
          else maybe (Left RpcBirthEffectTimedOut) id attempted

rpcBirthResponse :: (Serialise value) => Either RpcBirthError value -> (ReplyStatus, ByteString)
rpcBirthResponse result = (status result, Lazy.toStrict (encodeControlPlaneResponse result))
 where
  status response = case response of
    Right _ -> ReplyOk
    Left RpcBirthRequestInvalid -> ReplyBadRequest
    Left RpcBirthRequestContextInvalid -> ReplyBadRequest
    Left RpcBirthObservationUnavailable -> ReplyServiceUnavailable
    Left RpcBirthNativeSourceUnavailable -> ReplyServiceUnavailable
    Left RpcBirthClockUnavailable -> ReplyServiceUnavailable
    Left RpcBirthEffectTimedOut -> ReplyServiceUnavailable
    Left RpcBirthWriteUnconfirmed -> ReplyServiceUnavailable
    Left _ -> ReplyConflict

isRpcBirthObservationForRole :: RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isRpcBirthObservationForRole role route body =
  role == LifecycleAuthorityRuntime
    && route == LifecycleMigrationApply
    && (isRpcBirthObservation body || body == rpcBirthDescriptorRequest || body == rpcBirthRegistryRequest)

data RpcBirthClientError
  = RpcBirthClientTransport !AuthenticatedClientError
  | RpcBirthClientPeer !AuthorityPeerContextClientError
  | RpcBirthClientClockUnavailable
  | RpcBirthClientDeadlineReached
  | RpcBirthClientTimedOut
  | RpcBirthClientResponseInvalid
  | RpcBirthClientRejected !RpcBirthError
  | RpcBirthClientHttpStatus !Int
  deriving (Eq, Show)

-- Refresh uses the fixed read-only metadata route and never needs ordinary
-- operation admission, so pending registration remains recoverable on restart.
requestRpcBirthWithin
  :: IO (Either Text AuthorityTime)
  -> AuthorityTime
  -> AuthorityScope
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RpcBirthCommand
  -> IO (Either RpcBirthClientError RpcBirthStatus)
requestRpcBirthWithin readTime parent scope transport command =
  requestRpcBirthPayloadWithin
    readTime
    parent
    scope
    transport
    (encodeRpcBirthCommand command)
    decodeRpcBirthClientResponse

requestRpcBirthDescriptorWithin
  :: IO (Either Text AuthorityTime)
  -> AuthorityTime
  -> AuthorityScope
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either RpcBirthClientError RpcBirthDescriptorObservation)
requestRpcBirthDescriptorWithin readTime parent scope transport =
  requestRpcBirthPayloadWithin
    readTime
    parent
    scope
    transport
    rpcBirthDescriptorRequest
    decodeDescriptor
 where
  decodeDescriptor response = do
    bytes <- decodeRpcBirthClientResponse response
    first (const RpcBirthClientResponseInvalid) (decodeRpcBirthDescriptorObservation scope bytes)

-- The registry has its own existing 128-KiB encoding ceiling. Callers must
-- select a client HTTP read bound that covers this enclosing response; ordinary
-- status/descriptor metadata retain their narrower limit.
requestRpcBirthRegistryWithin
  :: IO (Either Text AuthorityTime)
  -> AuthorityTime
  -> AuthorityScope
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either RpcBirthClientError RpcBirthRegistryObservation)
requestRpcBirthRegistryWithin readTime parent scope transport =
  requestRpcBirthPayloadWithin
    readTime
    parent
    scope
    transport
    rpcBirthRegistryRequest
    decodeRegistry
 where
  decodeRegistry response = do
    bytes <- decodeRpcBirthClientResponseWithMaximum rpcBirthRegistryResponseMaximumBytes response
    first (const RpcBirthClientResponseInvalid) (decodeRpcBirthRegistryObservation scope bytes)

-- The parent covers provider resolution, peer refresh, signing, HTTP and the
-- canonical decode. A coordinator can resolve its transport once before using
-- either operation, preserving the original deadline across all later steps.
requestRpcBirthPayloadWithin
  :: IO (Either Text AuthorityTime)
  -> AuthorityTime
  -> AuthorityScope
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ByteString
  -> (ControlPlaneResponse -> Either RpcBirthClientError result)
  -> IO (Either RpcBirthClientError result)
requestRpcBirthPayloadWithin readTime parent scope transport body decode = before parent $ do
  resolved <- resolveAuthenticatedClientTransportDeadline parent transport
  case resolved of
    Left cause -> pure (Left (RpcBirthClientTransport cause))
    Right (deadline, boundedTransport) -> before deadline $ do
      refreshed <- requestAuthorityPeerContextWithin readTime deadline scope boundedTransport
      case refreshed of
        Left cause -> pure (Left (RpcBirthClientPeer cause))
        Right peer -> do
          response <-
            callAuthenticatedClientTransport
              (authenticatedClientTransportAtEpoch (peerContextEpoch peer) boundedTransport)
              LifecycleMigrationApplyRoute
              body
          pure (first RpcBirthClientTransport response >>= decode)
 where
  before deadline effect = do
    observed <- readTime
    case observed of
      Left _ -> pure (Left RpcBirthClientClockUnavailable)
      Right now
        | now >= deadline -> pure (Left RpcBirthClientDeadlineReached)
        | otherwise -> do
            let remaining = authorityTimeMicros deadline - authorityTimeMicros now
                limit = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
            attempted <- timeout limit (effect >>= evaluate)
            closing <- readTime
            pure $ case closing of
              Left _ -> Left RpcBirthClientClockUnavailable
              Right after
                | after >= deadline -> Left RpcBirthClientDeadlineReached
                | otherwise -> maybe (Left RpcBirthClientTimedOut) id attempted

-- The old status path and the new descriptor path share the outer envelope;
-- each then decodes only its own payload type. Neither infers success from HTTP
-- status without a canonical successful body.
decodeRpcBirthClientResponse
  :: (Serialise result) => ControlPlaneResponse -> Either RpcBirthClientError result
decodeRpcBirthClientResponse =
  decodeRpcBirthClientResponseWithMaximum ReplayBudget.authorityMetadataResponseMaximumBytes

decodeRpcBirthClientResponseWithMaximum
  :: (Serialise result) => Int -> ControlPlaneResponse -> Either RpcBirthClientError result
decodeRpcBirthClientResponseWithMaximum maximumBytes (ControlPlaneResponse status body) = do
  decoded <-
    first
      (const RpcBirthClientResponseInvalid)
      (decodeControlPlaneResponse maximumBytes (Lazy.fromStrict body))
  case decoded of
    Left cause -> Left (RpcBirthClientRejected cause)
    Right value
      | status == 200 -> Right value
      | otherwise -> Left (RpcBirthClientHttpStatus status)
