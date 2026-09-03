{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed Lifecycle-Authority client for read-only retained-home custody
-- recovery. It can request only one schema, operation, generation, and bounded
-- deadline and receives only the Target Agent's secret-free source metadata.
module Prodbox.ControlPlane.TargetRetainedMaterialSourceClient
  ( TargetRetainedMaterialSourceClientError (..)
  , TargetRetainedMaterialSourceResult (..)
  , observeTargetRetainedMaterialSource
  , renderTargetRetainedMaterialSourceClientCause
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetRetainedMaterialRewrapRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( TargetRetainedMaterialRewrapRequest (..)
  , TargetRetainedMaterialRewrapResponse (..)
  , TargetRetainedMaterialSourceObservation
  , targetRetainedMaterialRewrapResponseMaximumBytes
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

data TargetRetainedMaterialSourceClientError
  = TargetRetainedMaterialSourceClientTransportFailed !AuthenticatedClientError
  | TargetRetainedMaterialSourceClientResponseInvalid !ControlPlaneResponseCodecError
  | TargetRetainedMaterialSourceClientHttpStatus !Int
  | TargetRetainedMaterialSourceClientRefused !Text
  | TargetRetainedMaterialSourceClientUnavailable !Text
  | TargetRetainedMaterialSourceClientUnexpectedResponse
  deriving stock (Eq, Show)

data TargetRetainedMaterialSourceResult
  = TargetRetainedMaterialSourcePresent !TargetRetainedMaterialSourceObservation
  | TargetRetainedMaterialSourcePositivelyAbsent !TargetSecretId
  deriving stock (Eq, Show)

-- | Closed, payload-free diagnostic cause. Authenticated response details are
-- retained privately for control flow but never written to the role log.
renderTargetRetainedMaterialSourceClientCause
  :: TargetRetainedMaterialSourceClientError -> Text
renderTargetRetainedMaterialSourceClientCause err = case err of
  TargetRetainedMaterialSourceClientTransportFailed _ -> "transport-failed"
  TargetRetainedMaterialSourceClientResponseInvalid _ -> "response-invalid"
  TargetRetainedMaterialSourceClientHttpStatus _ -> "http-status"
  TargetRetainedMaterialSourceClientRefused detail -> case detail of
    "retained-material observation deadline elapsed" -> "deadline-elapsed"
    "retained source operation mismatch" -> "operation-mismatch"
    "retained source generation mismatch" -> "generation-mismatch"
    "retained source is absent" -> "source-absent"
    _ -> "refused-other"
  TargetRetainedMaterialSourceClientUnavailable detail -> case detail of
    "retained source digest mismatches metadata" -> "digest-mismatch"
    "retained source is corrupt" -> "source-corrupt"
    "retained source is unobservable" -> "source-unobservable"
    _ -> "unavailable-other"
  TargetRetainedMaterialSourceClientUnexpectedResponse -> "unexpected-response"

observeTargetRetainedMaterialSource
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetSecretId
  -> Text
  -> Natural
  -> Natural
  -> IO
       ( Either
           TargetRetainedMaterialSourceClientError
           TargetRetainedMaterialSourceResult
       )
observeTargetRetainedMaterialSource transport target operationId generation deadline = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      TargetRetainedMaterialRewrapRoute
      ( LazyByteString.toStrict
          ( encodeControlPlaneRequest
              ObserveTargetRetainedMaterialSource
                { targetRetainedRewrapTarget = target
                , targetRetainedSourceExpectedOperationId = operationId
                , targetRetainedSourceExpectedGeneration = generation
                , targetRetainedSourceObservationDeadlineMicros = deadline
                }
          )
      )
  pure $ do
    ControlPlaneResponse status body <-
      first TargetRetainedMaterialSourceClientTransportFailed attempted
    response <-
      first
        TargetRetainedMaterialSourceClientResponseInvalid
        ( decodeControlPlaneResponse
            targetRetainedMaterialRewrapResponseMaximumBytes
            (LazyByteString.fromStrict body)
        )
    case response of
      TargetRetainedMaterialSourceObserved observation
        | status == 200 -> Right (TargetRetainedMaterialSourcePresent observation)
        | otherwise -> Left (TargetRetainedMaterialSourceClientHttpStatus status)
      TargetRetainedMaterialSourceAbsent absentTarget
        | status == 200 -> Right (TargetRetainedMaterialSourcePositivelyAbsent absentTarget)
        | otherwise -> Left (TargetRetainedMaterialSourceClientHttpStatus status)
      TargetRetainedMaterialRewrapRefused detail ->
        Left (TargetRetainedMaterialSourceClientRefused detail)
      TargetRetainedMaterialRewrapUnavailable detail ->
        Left (TargetRetainedMaterialSourceClientUnavailable detail)
      _ -> Left TargetRetainedMaterialSourceClientUnexpectedResponse
