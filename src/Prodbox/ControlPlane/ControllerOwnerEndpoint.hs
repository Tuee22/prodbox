{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded authenticated endpoint for retained controller-owner transitions.
-- A successful response carries the state produced by the repository's
-- independent read-back, never the immediate return value of its CAS write.
module Prodbox.ControlPlane.ControllerOwnerEndpoint
  ( ControllerOwnerWireResponse (..)
  , ControllerOwnerEndpointResult
  , controllerOwnerEndpointMaximumBytes
  , controllerOwnerEndpointResponseMaximumBytes
  , serveControllerOwnerEndpointRequest
  , controllerOwnerEndpointStatus
  , controllerOwnerWireResponseStatus
  , controllerOwnerEndpointBody
  , decodeControllerOwnerEndpointResponse
  , ControllerOwnerEndpointResponseError (..)
  , confirmControllerOwnerEndpointResponse
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.ControllerOwnerRepository
  ( ControllerOwnerRepositoryError (..)
  , ControllerOwnerTransition (..)
  , controllerOwnerDescriptorOf
  , controllerOwnerStateChildArns
  , controllerOwnerStateUid
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lib.AwsControlPlaneIsolation
  ( ControllerOwnerDescriptor
  , ControllerOwnerState (..)
  )

data ControllerOwnerWireResponse
  = ControllerOwnerWireConfirmed !ControllerOwnerState
  | ControllerOwnerWireRefused !Text
  | ControllerOwnerWireUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype ControllerOwnerEndpointResult = ControllerOwnerEndpointResult
  { controllerOwnerEndpointResponse :: ControllerOwnerWireResponse
  }

controllerOwnerEndpointMaximumBytes :: Int
controllerOwnerEndpointMaximumBytes = 64 * 1024

controllerOwnerEndpointResponseMaximumBytes :: Int
controllerOwnerEndpointResponseMaximumBytes = 64 * 1024

serveControllerOwnerEndpointRequest
  :: (Monad m)
  => (ControllerOwnerTransition -> m (Either ControllerOwnerRepositoryError ControllerOwnerState))
  -> LazyByteString.ByteString
  -> m ControllerOwnerEndpointResult
serveControllerOwnerEndpointRequest repository body =
  case decodeControlPlaneRequest controllerOwnerEndpointMaximumBytes body of
    Left err -> pure (result (ControllerOwnerWireRefused (Text.pack (show err))))
    Right transition -> do
      transitioned <- repository transition
      pure $ result $ case transitioned of
        Right state -> ControllerOwnerWireConfirmed state
        Left err
          | repositoryUnavailable err ->
              ControllerOwnerWireUnavailable (bounded (Text.pack (show err)))
          | otherwise ->
              ControllerOwnerWireRefused (bounded (Text.pack (show err)))
 where
  result = ControllerOwnerEndpointResult
  bounded = Text.take 2048

repositoryUnavailable :: ControllerOwnerRepositoryError -> Bool
repositoryUnavailable err = case err of
  ControllerOwnerRepositoryCorrupt {} -> True
  ControllerOwnerRepositoryUnobservable {} -> True
  ControllerOwnerRepositoryReadBackMismatch {} -> True
  ControllerOwnerRepositoryRetryLimitExceeded {} -> True
  _ -> False

controllerOwnerEndpointStatus :: ControllerOwnerEndpointResult -> ReplyStatus
controllerOwnerEndpointStatus =
  controllerOwnerWireResponseStatus . controllerOwnerEndpointResponse

controllerOwnerWireResponseStatus :: ControllerOwnerWireResponse -> ReplyStatus
controllerOwnerWireResponseStatus response = case response of
  ControllerOwnerWireConfirmed {} -> ReplyOk
  ControllerOwnerWireRefused {} -> ReplyConflict
  ControllerOwnerWireUnavailable {} -> ReplyServiceUnavailable

controllerOwnerEndpointBody :: ControllerOwnerEndpointResult -> ByteString
controllerOwnerEndpointBody =
  LazyByteString.toStrict
    . encodeControlPlaneResponse
    . controllerOwnerEndpointResponse

decodeControllerOwnerEndpointResponse
  :: ByteString
  -> Either ControlPlaneResponseCodecError ControllerOwnerWireResponse
decodeControllerOwnerEndpointResponse =
  decodeControlPlaneResponse controllerOwnerEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data ControllerOwnerEndpointResponseError
  = ControllerOwnerEndpointResponseRefused !Text
  | ControllerOwnerEndpointResponseUnavailable !Text
  | ControllerOwnerEndpointResponseDescriptorMismatch
      !ControllerOwnerDescriptor
      !ControllerOwnerDescriptor
  | ControllerOwnerEndpointResponseTransitionUnsatisfied
  deriving (Eq, Show)

confirmControllerOwnerEndpointResponse
  :: ControllerOwnerTransition
  -> ControllerOwnerWireResponse
  -> Either ControllerOwnerEndpointResponseError ControllerOwnerState
confirmControllerOwnerEndpointResponse transition response = case response of
  ControllerOwnerWireRefused detail ->
    Left (ControllerOwnerEndpointResponseRefused detail)
  ControllerOwnerWireUnavailable detail ->
    Left (ControllerOwnerEndpointResponseUnavailable detail)
  ControllerOwnerWireConfirmed state -> do
    let expected = transitionDescriptor transition
        actual = controllerOwnerDescriptorOf state
    if actual == expected
      then Right ()
      else
        Left
          (ControllerOwnerEndpointResponseDescriptorMismatch expected actual)
    if transitionSatisfied transition state
      then Right state
      else Left ControllerOwnerEndpointResponseTransitionUnsatisfied

transitionDescriptor :: ControllerOwnerTransition -> ControllerOwnerDescriptor
transitionDescriptor transition = case transition of
  RegisterControllerOwnerInert descriptor -> descriptor
  RegisterControllerOwnerUid descriptor _ -> descriptor
  EnableRegisteredControllerOwner descriptor -> descriptor
  RegisterControllerOwnerChildArns descriptor _ -> descriptor

transitionSatisfied :: ControllerOwnerTransition -> ControllerOwnerState -> Bool
transitionSatisfied transition state = case transition of
  RegisterControllerOwnerInert _ -> True
  RegisterControllerOwnerUid _ uid -> controllerOwnerStateUid state == Just uid
  EnableRegisteredControllerOwner _ -> case state of
    ControllerOwnerEnabled {} -> True
    ControllerChildArnsRegistered {} -> True
    _ -> False
  RegisterControllerOwnerChildArns _ arns ->
    all (`elem` controllerOwnerStateChildArns state) (sort arns)
