{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact-revision retained repository for the Lifecycle Authority's TLS
-- current-reference fold.  The TLS Retention Adapter owns immutable envelope
-- bytes; this repository owns only the monotone, per-substrate/scope current
-- reference which selects one of those versions.
module Prodbox.ControlPlane.TlsRetentionAuthority
  ( TlsRetentionSlot
  , TlsRetentionSlotError (..)
  , mkTlsRetentionSlot
  , tlsRetentionSlotSubstrate
  , tlsRetentionSlotScopeDigest
  , tlsRetentionAuthorityCoordinate
  , TlsRetentionAuthorityRepository (..)
  , StoredTlsRetentionState (..)
  , TlsRetentionAuthorityError (..)
  , TlsRetentionPromotionResult (..)
  , tlsRetentionStateMaximumBytes
  , tlsRetentionStateCodec
  , modelBTlsRetentionAuthorityRepository
  , observeTlsRetentionAuthority
  , promoteTlsRetentionAuthority
  )
where

import Codec.Serialise (deserialiseOrFail, serialise)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval
  , PromotionEvidence
  , RetainedTlsRef
  , TlsPromotionDecision (TlsPromoted)
  , TlsRetentionState
  , applyTlsPromotion
  , decideTlsPromotion
  , initialTlsRetentionState
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )

-- | One closed public-edge aggregate slot.  The scope itself is not placed in
-- object names: only its SHA-256 digest is retained, keeping wildcard/SAN
-- syntax out of the physical coordinate while preventing two scopes aliasing.
data TlsRetentionSlot = TlsRetentionSlot
  { internalTlsRetentionSlotSubstrate :: !Text
  , internalTlsRetentionSlotScopeDigest :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data TlsRetentionSlotError
  = TlsRetentionSlotSubstrateInvalid
  | TlsRetentionSlotScopeEmpty
  | TlsRetentionSlotScopeContainsControl
  | TlsRetentionSlotScopeContainsWhitespace
  | TlsRetentionSlotScopeTooLong !Int !Int
  deriving stock (Eq, Show)

mkTlsRetentionSlot :: Text -> Text -> Either TlsRetentionSlotError TlsRetentionSlot
mkTlsRetentionSlot rawSubstrate rawScope
  | substrate /= "home-local" && substrate /= "aws" =
      Left TlsRetentionSlotSubstrateInvalid
  | Text.null scope = Left TlsRetentionSlotScopeEmpty
  | Text.any isControl scope = Left TlsRetentionSlotScopeContainsControl
  | Text.any isSpace scope = Left TlsRetentionSlotScopeContainsWhitespace
  | Text.length scope > maximumScopeBytes =
      Left (TlsRetentionSlotScopeTooLong (Text.length scope) maximumScopeBytes)
  | otherwise =
      Right
        TlsRetentionSlot
          { internalTlsRetentionSlotSubstrate = substrate
          , internalTlsRetentionSlotScopeDigest =
              TextEncoding.decodeUtf8 (hexSha256 (TextEncoding.encodeUtf8 scope))
          }
 where
  substrate = Text.strip rawSubstrate
  scope = Text.strip rawScope
  maximumScopeBytes = 2048

tlsRetentionSlotSubstrate :: TlsRetentionSlot -> Text
tlsRetentionSlotSubstrate = internalTlsRetentionSlotSubstrate

tlsRetentionSlotScopeDigest :: TlsRetentionSlot -> Text
tlsRetentionSlotScopeDigest = internalTlsRetentionSlotScopeDigest

tlsRetentionAuthorityCoordinate
  :: LongLivedCheckpointAuthority
  -> TlsRetentionSlot
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
tlsRetentionAuthorityCoordinate authority slot =
  mapLeft (Text.pack . show) $
    mkClusterRetainedCoordinate
      authority
      ( Text.intercalate
          "/"
          [ "authority/tls-retention"
          , tlsRetentionSlotSubstrate slot
          , tlsRetentionSlotScopeDigest slot
          ]
      )

data StoredTlsRetentionState revision = StoredTlsRetentionState
  { storedTlsRetentionRevision :: !revision
  , storedTlsRetentionState :: !TlsRetentionState
  }
  deriving stock (Eq, Show)

data TlsRetentionAuthorityRepository m revision = TlsRetentionAuthorityRepository
  { readTlsRetentionState
      :: m (Either Text (Maybe (StoredTlsRetentionState revision)))
  , compareAndSwapTlsRetentionState
      :: Maybe revision
      -> TlsRetentionState
      -> m (Either Text Bool)
  }

data TlsRetentionAuthorityError
  = TlsRetentionAuthorityReadFailed !Text
  | TlsRetentionAuthorityWriteFailed !Text
  | TlsRetentionAuthorityConcurrentWrite
  deriving stock (Eq, Show)

data TlsRetentionPromotionResult = TlsRetentionPromotionResult
  { tlsRetentionPromotionState :: !TlsRetentionState
  , tlsRetentionPromotionDecision :: !TlsPromotionDecision
  }
  deriving stock (Eq, Show)

tlsRetentionStateMaximumBytes :: Int
tlsRetentionStateMaximumBytes = 64 * 1024

tlsRetentionStateCodec :: ModelBCodec TlsRetentionState
tlsRetentionStateCodec =
  ModelBCodec
    { encodeModelBValue = \state -> do
        let encoded = LazyByteString.toStrict (serialise state)
        if ByteString.length encoded > tlsRetentionStateMaximumBytes
          then Left "TLS retention state exceeds the compiled bound"
          else Right encoded
    , decodeModelBValue = \bytes -> do
        if ByteString.length bytes > tlsRetentionStateMaximumBytes
          then Left "TLS retention state exceeds the compiled bound"
          else do
            state <-
              mapLeft
                (const "TLS retention state is not canonical CBOR")
                (deserialiseOrFail (LazyByteString.fromStrict bytes))
            if LazyByteString.toStrict (serialise state) == bytes
              then Right state
              else Left "TLS retention state is not canonical CBOR"
    }

modelBTlsRetentionAuthorityRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m TlsRetentionState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> TlsRetentionAuthorityRepository m ModelBObjectVersion
modelBTlsRetentionAuthorityRepository adapter coordinate =
  TlsRetentionAuthorityRepository
    { readTlsRetentionState = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right Nothing
          ModelBObserved revision state ->
            Right (Just (StoredTlsRetentionState revision state))
          ModelBCorrupt detail -> Left ("TLS retention state is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("TLS retention state is unavailable: " <> detail)
          ModelBUnobservable detail -> Left ("TLS retention state is unobservable: " <> detail)
    , compareAndSwapTlsRetentionState = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right True
          ModelBCasConflict _ -> Right False
          ModelBCasRefusedCorrupt detail -> Left ("TLS retention CAS refused corrupt state: " <> detail)
          ModelBCasEndpointUnready detail -> Left ("TLS retention CAS endpoint is unavailable: " <> detail)
          ModelBCasUnobservable detail -> Left ("TLS retention CAS is unobservable: " <> detail)
    }

observeTlsRetentionAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> m (Either TlsRetentionAuthorityError TlsRetentionState)
observeTlsRetentionAuthority repository = do
  observed <- readTlsRetentionState repository
  pure $ case observed of
    Left detail -> Left (TlsRetentionAuthorityReadFailed detail)
    Right Nothing -> Right initialTlsRetentionState
    Right (Just stored) -> Right (storedTlsRetentionState stored)

promoteTlsRetentionAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> KeyRotationApproval
  -> PromotionEvidence
  -> RetainedTlsRef
  -> m (Either TlsRetentionAuthorityError TlsRetentionPromotionResult)
promoteTlsRetentionAuthority repository approval evidence candidate = do
  observed <- readTlsRetentionState repository
  case observed of
    Left detail -> pure (Left (TlsRetentionAuthorityReadFailed detail))
    Right maybeStored -> do
      let current = maybe initialTlsRetentionState storedTlsRetentionState maybeStored
          expected = storedTlsRetentionRevision <$> maybeStored
          decision = decideTlsPromotion approval evidence current candidate
          next = applyTlsPromotion decision current
          result = TlsRetentionPromotionResult next decision
      case decision of
        TlsPromoted _ -> do
          written <- compareAndSwapTlsRetentionState repository expected next
          pure $ case written of
            Left detail -> Left (TlsRetentionAuthorityWriteFailed detail)
            Right False -> Left TlsRetentionAuthorityConcurrentWrite
            Right True -> Right result
        _ -> pure (Right result)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f = either (Left . f) Right
