{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained Lifecycle-Authority persistence for Kubernetes controller owners.
--
-- A controller-owned AWS family is enabled only after its deterministic
-- descriptor and Kubernetes UID have survived an independent read-back.  AWS
-- child ARNs are then added monotonically with versioned CAS.  A response from
-- the write itself is never a receipt: every successful operation re-opens the
-- object and compares the complete canonical state.
module Prodbox.ControlPlane.ControllerOwnerRepository
  ( ControllerOwnerTransition (..)
  , ControllerOwnerRepositoryError (..)
  , controllerOwnerDescriptorOf
  , controllerOwnerStateUid
  , controllerOwnerStateChildArns
  , controllerOwnerLogicalName
  , controllerOwnerModelBCodec
  , modelBControllerOwnerRepository
  , transitionControllerOwner
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lib.AwsControlPlaneIsolation
  ( ControllerOwnerDescriptor (..)
  , ControllerOwnerRefusal
  , ControllerOwnerState (..)
  , enableControllerOwner
  , registerControllerChildArns
  , registerControllerOwnerUid
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )

data ControllerOwnerTransition
  = RegisterControllerOwnerInert !ControllerOwnerDescriptor
  | RegisterControllerOwnerUid !ControllerOwnerDescriptor !Text
  | EnableRegisteredControllerOwner !ControllerOwnerDescriptor
  | RegisterControllerOwnerChildArns !ControllerOwnerDescriptor ![Text]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ControllerOwnerRepositoryError
  = ControllerOwnerDescriptorInvalid !Text
  | ControllerOwnerStateInvalid !Text
  | ControllerOwnerStateMissing
  | ControllerOwnerDescriptorConflict
      !ControllerOwnerDescriptor
      !ControllerOwnerDescriptor
  | ControllerOwnerTransitionRefused !ControllerOwnerRefusal
  | ControllerOwnerRepositoryConflict
  | ControllerOwnerRepositoryCorrupt !Text
  | ControllerOwnerRepositoryUnobservable !Text
  | ControllerOwnerRepositoryReadBackMismatch
      !ControllerOwnerState
      !ControllerOwnerState
  | ControllerOwnerRepositoryRetryLimitExceeded !Int
  deriving (Eq, Show)

controllerOwnerDescriptorOf :: ControllerOwnerState -> ControllerOwnerDescriptor
controllerOwnerDescriptorOf state = case state of
  ControllerOwnerRegisteredInert descriptor -> descriptor
  ControllerOwnerUidRegistered descriptor _ -> descriptor
  ControllerOwnerEnabled descriptor _ -> descriptor
  ControllerChildArnsRegistered descriptor _ _ -> descriptor

controllerOwnerStateUid :: ControllerOwnerState -> Maybe Text
controllerOwnerStateUid state = case state of
  ControllerOwnerRegisteredInert {} -> Nothing
  ControllerOwnerUidRegistered _ uid -> Just uid
  ControllerOwnerEnabled _ uid -> Just uid
  ControllerChildArnsRegistered _ uid _ -> Just uid

controllerOwnerStateChildArns :: ControllerOwnerState -> [Text]
controllerOwnerStateChildArns state = case state of
  ControllerChildArnsRegistered _ _ arns -> arns
  _ -> []

controllerOwnerLogicalName
  :: ControllerOwnerDescriptor -> Either ControllerOwnerRepositoryError Text
controllerOwnerLogicalName descriptor = do
  validateDescriptor descriptor
  Right
    ( Text.intercalate
        "/"
        [ "authority/controller-owners/v1"
        , controllerOwnerAccount descriptor
        , controllerOwnerRegion descriptor
        , controllerOwnerCluster descriptor
        , controllerOwnerResourceName descriptor
        ]
    )

data ControllerOwnerStateWire = ControllerOwnerStateWire
  { controllerOwnerWireVersion :: !Int
  , controllerOwnerWireStage :: !Int
  , controllerOwnerWireAccount :: !Text
  , controllerOwnerWireRegion :: !Text
  , controllerOwnerWireCluster :: !Text
  , controllerOwnerWireResourceName :: !Text
  , controllerOwnerWireManifestDigest :: !Text
  , controllerOwnerWireTags :: ![(Text, Text)]
  , controllerOwnerWireUid :: !(Maybe Text)
  , controllerOwnerWireChildArns :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

controllerOwnerModelBCodec :: ModelBCodec ControllerOwnerState
controllerOwnerModelBCodec =
  ModelBCodec
    { encodeModelBValue = encodeControllerOwnerState
    , decodeModelBValue = decodeControllerOwnerState
    }

encodeControllerOwnerState :: ControllerOwnerState -> Either String ByteString
encodeControllerOwnerState state = do
  first (Text.unpack . renderError) (validateState state)
  Right (LazyByteString.toStrict (serialise (stateToWire state)))

decodeControllerOwnerState :: ByteString -> Either String ControllerOwnerState
decodeControllerOwnerState bytes = do
  when (ByteString.null bytes) (Left "controller-owner state was empty")
  when
    (ByteString.length bytes > maximumControllerOwnerStateBytes)
    (Left "controller-owner state exceeded the canonical byte bound")
  wire <- first show (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left "controller-owner state was not canonically encoded")
  state <- first (Text.unpack . renderError) (wireToState wire)
  first (Text.unpack . renderError) (validateState state)
  Right state

maximumControllerOwnerStateBytes :: Int
maximumControllerOwnerStateBytes = 32 * 1024

modelBControllerOwnerRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ControllerOwnerState
  -> ControllerOwnerTransition
  -> m (Either ControllerOwnerRepositoryError ControllerOwnerState)
modelBControllerOwnerRepository = transitionControllerOwner

transitionControllerOwner
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ControllerOwnerState
  -> ControllerOwnerTransition
  -> m (Either ControllerOwnerRepositoryError ControllerOwnerState)
transitionControllerOwner authority adapter transition =
  case coordinateFor authority descriptor of
    Left err -> pure (Left err)
    Right coordinate -> attempt maximumControllerOwnerCasAttempts coordinate
 where
  descriptor = transitionDescriptor transition

  attempt remaining coordinate
    | remaining <= 0 =
        pure
          (Left (ControllerOwnerRepositoryRetryLimitExceeded maximumControllerOwnerCasAttempts))
    | otherwise = do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> case transition of
            RegisterControllerOwnerInert _ ->
              applyInitialize remaining coordinate
            _ -> pure (Left ControllerOwnerStateMissing)
          ModelBObserved version current ->
            case applyTransition transition current of
              Left err -> pure (Left err)
              Right expected
                | expected == current -> confirmReadBack coordinate expected
                | otherwise -> applyReplace remaining coordinate version expected
          ModelBCorrupt detail -> pure (Left (ControllerOwnerRepositoryCorrupt detail))
          ModelBEndpointUnready detail -> pure (unobservable detail)
          ModelBUnobservable detail -> pure (unobservable detail)

  applyInitialize remaining coordinate = do
    let expected = ControllerOwnerRegisteredInert descriptor
    result <- modelBCompareAndSwap adapter (ModelBInitialize coordinate expected)
    settleCas remaining coordinate expected result

  applyReplace remaining coordinate version expected = do
    result <-
      modelBCompareAndSwap adapter (ModelBReplace coordinate version expected)
    settleCas remaining coordinate expected result

  settleCas remaining coordinate expected result = case result of
    ModelBCasApplied _ actual
      | actual == expected -> confirmReadBack coordinate expected
      | otherwise ->
          pure
            (Left (ControllerOwnerRepositoryReadBackMismatch expected actual))
    ModelBCasConflict _ -> attempt (remaining - 1) coordinate
    ModelBCasRefusedCorrupt detail ->
      pure (Left (ControllerOwnerRepositoryCorrupt detail))
    ModelBCasEndpointUnready detail -> pure (unobservable detail)
    ModelBCasUnobservable detail -> do
      -- The response may have been lost after a successful CAS.  The only
      -- safe answer comes from the same independent read-back used after an
      -- acknowledged write.
      readBack <- confirmReadBack coordinate expected
      pure $ case readBack of
        Right state -> Right state
        Left ControllerOwnerStateMissing -> unobservable detail
        Left (ControllerOwnerRepositoryReadBackMismatch _ _) -> unobservable detail
        Left err -> Left err

  confirmReadBack coordinate expected = do
    observed <- modelBObserve adapter coordinate
    pure $ case observed of
      ModelBObserved _ actual
        | actual == expected -> Right actual
        | otherwise ->
            Left (ControllerOwnerRepositoryReadBackMismatch expected actual)
      ModelBMissing -> Left ControllerOwnerStateMissing
      ModelBCorrupt detail -> Left (ControllerOwnerRepositoryCorrupt detail)
      ModelBEndpointUnready detail -> unobservable detail
      ModelBUnobservable detail -> unobservable detail

  unobservable = Left . ControllerOwnerRepositoryUnobservable . Text.take 1024

maximumControllerOwnerCasAttempts :: Int
maximumControllerOwnerCasAttempts = 8

coordinateFor
  :: LongLivedCheckpointAuthority
  -> ControllerOwnerDescriptor
  -> Either
       ControllerOwnerRepositoryError
       (ModelBObjectCoordinate 'ClusterRetained)
coordinateFor authority descriptor = do
  logicalName <- controllerOwnerLogicalName descriptor
  first
    (ControllerOwnerDescriptorInvalid . Text.pack . show)
    (mkClusterRetainedCoordinate authority logicalName)

transitionDescriptor :: ControllerOwnerTransition -> ControllerOwnerDescriptor
transitionDescriptor transition = case transition of
  RegisterControllerOwnerInert descriptor -> descriptor
  RegisterControllerOwnerUid descriptor _ -> descriptor
  EnableRegisteredControllerOwner descriptor -> descriptor
  RegisterControllerOwnerChildArns descriptor _ -> descriptor

applyTransition
  :: ControllerOwnerTransition
  -> ControllerOwnerState
  -> Either ControllerOwnerRepositoryError ControllerOwnerState
applyTransition transition current = do
  let expectedDescriptor = transitionDescriptor transition
      actualDescriptor = controllerOwnerDescriptorOf current
  unless
    (actualDescriptor == expectedDescriptor)
    (Left (ControllerOwnerDescriptorConflict expectedDescriptor actualDescriptor))
  first ControllerOwnerTransitionRefused $ case transition of
    RegisterControllerOwnerInert _ -> Right current
    RegisterControllerOwnerUid _ uid -> registerControllerOwnerUid uid current
    EnableRegisteredControllerOwner _ -> enableControllerOwner current
    RegisterControllerOwnerChildArns _ arns -> registerControllerChildArns arns current

validateState :: ControllerOwnerState -> Either ControllerOwnerRepositoryError ()
validateState state = do
  validateDescriptor (controllerOwnerDescriptorOf state)
  case controllerOwnerStateUid state of
    Nothing -> Right ()
    Just uid -> validateField "Kubernetes UID" 512 uid
  mapM_ (validateField "child ARN" 2048) (controllerOwnerStateChildArns state)
  unless
    (controllerOwnerStateChildArns state == sort (controllerOwnerStateChildArns state))
    (Left (ControllerOwnerStateInvalid "child ARNs were not canonically ordered"))

validateDescriptor
  :: ControllerOwnerDescriptor -> Either ControllerOwnerRepositoryError ()
validateDescriptor descriptor = do
  validateField "AWS account" 32 (controllerOwnerAccount descriptor)
  validateField "AWS region" 64 (controllerOwnerRegion descriptor)
  validateField "cluster" 256 (controllerOwnerCluster descriptor)
  validateField "resource name" 256 (controllerOwnerResourceName descriptor)
  validateField "manifest digest" 256 (controllerOwnerManifestDigest descriptor)
  unless
    (controllerOwnerTags descriptor == sort (controllerOwnerTags descriptor))
    (Left (ControllerOwnerDescriptorInvalid "tags were not canonically ordered"))
  mapM_ validateTag (controllerOwnerTags descriptor)
  case firstDuplicate (map fst (controllerOwnerTags descriptor)) of
    Nothing -> Right ()
    Just key ->
      Left (ControllerOwnerDescriptorInvalid ("duplicate tag key: " <> key))
 where
  validateTag (key, value) = do
    validateField "tag key" 128 key
    validateField "tag value" 256 value

validateField
  :: Text -> Int -> Text -> Either ControllerOwnerRepositoryError ()
validateField label maximumLength raw
  | Text.null value = invalid "was empty"
  | Text.length value > maximumLength = invalid "exceeded its byte-safe bound"
  | Text.any isControl value = invalid "contained a control character"
  | Text.any isSpace value = invalid "contained whitespace"
  | otherwise = Right ()
 where
  value = Text.strip raw
  invalid detail =
    Left (ControllerOwnerDescriptorInvalid (label <> " " <> detail))

firstDuplicate :: (Eq value) => [value] -> Maybe value
firstDuplicate = go []
 where
  go _ [] = Nothing
  go seen (value : remaining)
    | value `elem` seen = Just value
    | otherwise = go (value : seen) remaining

stateToWire :: ControllerOwnerState -> ControllerOwnerStateWire
stateToWire state =
  ControllerOwnerStateWire
    { controllerOwnerWireVersion = 1
    , controllerOwnerWireStage = stage
    , controllerOwnerWireAccount = controllerOwnerAccount descriptor
    , controllerOwnerWireRegion = controllerOwnerRegion descriptor
    , controllerOwnerWireCluster = controllerOwnerCluster descriptor
    , controllerOwnerWireResourceName = controllerOwnerResourceName descriptor
    , controllerOwnerWireManifestDigest = controllerOwnerManifestDigest descriptor
    , controllerOwnerWireTags = controllerOwnerTags descriptor
    , controllerOwnerWireUid = controllerOwnerStateUid state
    , controllerOwnerWireChildArns = controllerOwnerStateChildArns state
    }
 where
  descriptor = controllerOwnerDescriptorOf state
  stage = case state of
    ControllerOwnerRegisteredInert {} -> 0
    ControllerOwnerUidRegistered {} -> 1
    ControllerOwnerEnabled {} -> 2
    ControllerChildArnsRegistered {} -> 3

wireToState
  :: ControllerOwnerStateWire
  -> Either ControllerOwnerRepositoryError ControllerOwnerState
wireToState wire = do
  unless
    (controllerOwnerWireVersion wire == 1)
    (Left (ControllerOwnerStateInvalid "unsupported wire version"))
  let descriptor =
        ControllerOwnerDescriptor
          { controllerOwnerAccount = controllerOwnerWireAccount wire
          , controllerOwnerRegion = controllerOwnerWireRegion wire
          , controllerOwnerCluster = controllerOwnerWireCluster wire
          , controllerOwnerResourceName = controllerOwnerWireResourceName wire
          , controllerOwnerManifestDigest = controllerOwnerWireManifestDigest wire
          , controllerOwnerTags = controllerOwnerWireTags wire
          }
      requireUid =
        maybe
          (Left (ControllerOwnerStateInvalid "state stage requires a UID"))
          Right
          (controllerOwnerWireUid wire)
  case controllerOwnerWireStage wire of
    0
      | controllerOwnerWireUid wire == Nothing
          && null (controllerOwnerWireChildArns wire) ->
          Right (ControllerOwnerRegisteredInert descriptor)
      | otherwise -> Left (ControllerOwnerStateInvalid "inert state carried enrichment")
    1 -> do
      uid <- requireUid
      unless
        (null (controllerOwnerWireChildArns wire))
        (Left (ControllerOwnerStateInvalid "UID state carried child ARNs"))
      Right (ControllerOwnerUidRegistered descriptor uid)
    2 -> do
      uid <- requireUid
      unless
        (null (controllerOwnerWireChildArns wire))
        (Left (ControllerOwnerStateInvalid "enabled state carried child ARNs"))
      Right (ControllerOwnerEnabled descriptor uid)
    3 -> do
      uid <- requireUid
      Right
        ( ControllerChildArnsRegistered
            descriptor
            uid
            (controllerOwnerWireChildArns wire)
        )
    _ -> Left (ControllerOwnerStateInvalid "unknown state stage")

renderError :: ControllerOwnerRepositoryError -> Text
renderError = Text.pack . show
