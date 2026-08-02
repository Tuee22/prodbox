{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-free, Target-Agent-owned discovery for total decommission.
--
-- The request carries no target coordinate.  The Agent observes its one trusted
-- sink and projects only its fixed identity and current positive credential
-- generation.  Lifecycle Authority uses this result to construct the signed
-- manifest; it cannot guess a generation or authorize a caller-selected sink.
module Prodbox.Lifecycle.Decommission.TargetInventory
  ( TargetDecommissionInventoryBoundary
  , targetDecommissionInventoryBoundary
  , TargetDecommissionInventoryRequest (..)
  , TargetDecommissionInventory (..)
  , TargetDecommissionInventoryError (..)
  , TargetDecommissionInventoryResult (..)
  , TargetDecommissionInventoryResponse (..)
  , observeTargetDecommissionInventory
  , serveTargetDecommissionInventoryRequest
  , targetDecommissionInventoryHttpStatus
  , targetDecommissionInventoryResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.TrustedTargetSink
  ( TrustedTargetSink
  , observeTrustedTargetSink
  , trustedTargetSinkCoordinate
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( targetSecretSinkIdentity
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionTargetGeneration
  , mkDecommissionTargetGeneration
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetSinkObservation (..)
  , TargetSinkRecord (targetSinkRecordGeneration)
  , credentialGenerationValue
  )

data TargetDecommissionInventoryBoundary m payload
  = TargetDecommissionInventoryBoundary
      !Text
      !(m (TargetSinkObservation payload))

targetDecommissionInventoryBoundary
  :: TrustedTargetSink m payload
  -> TargetDecommissionInventoryBoundary m payload
targetDecommissionInventoryBoundary trusted =
  TargetDecommissionInventoryBoundary
    (targetSecretSinkIdentity (trustedTargetSinkCoordinate trusted))
    (observeTrustedTargetSink trusted)

data TargetDecommissionInventoryRequest
  = ObserveTargetDecommissionInventory
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetDecommissionInventory = TargetDecommissionInventory
  { targetDecommissionInventoryReference :: !Text
  , targetDecommissionInventoryGeneration :: !(Maybe DecommissionTargetGeneration)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetDecommissionInventoryError
  = TargetDecommissionInventoryBadRequest !ControlPlaneRequestCodecError
  | TargetDecommissionInventoryUnavailable !Text
  | TargetDecommissionInventoryGenerationInvalid
  deriving stock (Eq, Show)

data TargetDecommissionInventoryResult
  = TargetDecommissionInventoryObserved !TargetDecommissionInventory
  | TargetDecommissionInventoryRefused !TargetDecommissionInventoryError
  deriving stock (Eq, Show)

data TargetDecommissionInventoryResponse
  = TargetDecommissionInventoryResponseObserved !TargetDecommissionInventory
  | TargetDecommissionInventoryResponseRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

observeTargetDecommissionInventory
  :: (Monad m)
  => TargetDecommissionInventoryBoundary m payload
  -> m TargetDecommissionInventoryResult
observeTargetDecommissionInventory
  (TargetDecommissionInventoryBoundary reference observe) = do
    observed <- observe
    pure $ case observed of
      TargetSinkMissing -> success Nothing
      TargetSinkObserved _ record ->
        case mkDecommissionTargetGeneration
          (credentialGenerationValue (targetSinkRecordGeneration record)) of
          Left _ ->
            TargetDecommissionInventoryRefused
              TargetDecommissionInventoryGenerationInvalid
          Right generation -> success (Just generation)
      TargetSinkRetired -> unavailable "target sink is logically retired, not physically absent"
      TargetSinkUnobservable detail -> unavailable detail
      TargetSinkChanging detail -> unavailable detail
      TargetSinkUnbounded observedBytes maximumBytes ->
        unavailable
          ( "target observation exceeded bound: "
              <> Text.pack (show observedBytes)
              <> "/"
              <> Text.pack (show maximumBytes)
          )
   where
    success generation =
      TargetDecommissionInventoryObserved
        TargetDecommissionInventory
          { targetDecommissionInventoryReference = reference
          , targetDecommissionInventoryGeneration = generation
          }
    unavailable =
      TargetDecommissionInventoryRefused
        . TargetDecommissionInventoryUnavailable

serveTargetDecommissionInventoryRequest
  :: (Monad m)
  => Int
  -> TargetDecommissionInventoryBoundary m payload
  -> LazyByteString.ByteString
  -> m TargetDecommissionInventoryResult
serveTargetDecommissionInventoryRequest maximumBytes boundary body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err ->
      pure
        ( TargetDecommissionInventoryRefused
            (TargetDecommissionInventoryBadRequest err)
        )
    Right ObserveTargetDecommissionInventory ->
      observeTargetDecommissionInventory boundary

targetDecommissionInventoryHttpStatus :: TargetDecommissionInventoryResult -> Int
targetDecommissionInventoryHttpStatus result = case result of
  TargetDecommissionInventoryObserved _ -> 200
  TargetDecommissionInventoryRefused err -> case err of
    TargetDecommissionInventoryBadRequest _ -> 400
    TargetDecommissionInventoryUnavailable _ -> 503
    TargetDecommissionInventoryGenerationInvalid -> 500

targetDecommissionInventoryResponseBody
  :: TargetDecommissionInventoryResult
  -> ByteString
targetDecommissionInventoryResponseBody result =
  LazyByteString.toStrict
    ( encodeControlPlaneResponse $ case result of
        TargetDecommissionInventoryObserved inventory ->
          TargetDecommissionInventoryResponseObserved inventory
        TargetDecommissionInventoryRefused err ->
          TargetDecommissionInventoryResponseRefused (summary err)
    )
 where
  summary err = case err of
    TargetDecommissionInventoryBadRequest _ -> "target-inventory-bad-request"
    TargetDecommissionInventoryUnavailable _ -> "target-inventory-unavailable"
    TargetDecommissionInventoryGenerationInvalid -> "target-inventory-generation-invalid"
