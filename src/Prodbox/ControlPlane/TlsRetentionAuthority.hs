{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact-revision retained repository for the Lifecycle Authority's TLS
-- retention fold. The TLS Retention Adapter owns immutable envelope objects;
-- this repository owns the monotone, per-substrate/scope current reference or
-- the exact ciphertext-only pending outbox that must precede the object write.
module Prodbox.ControlPlane.TlsRetentionAuthority
  ( TlsRetentionSlot
  , TlsRetentionSlotError (..)
  , mkTlsRetentionSlot
  , tlsRetentionSlotSubstrate
  , tlsRetentionSlotScopeDigest
  , tlsRetentionAuthorityCoordinate
  , TlsRetentionAuthorityRepository (..)
  , StoredTlsRetentionState (..)
  , TlsRetentionAuthorityReadFailure (..)
  , TlsRetentionAuthorityWriteFailure (..)
  , TlsRetentionAuthorityError (..)
  , diagnoseTlsRetentionAuthorityRepository
  , TlsRetentionStagingResult (..)
  , TlsPendingCollisionStagingResult (..)
  , TlsLegacyRecoveryStagingResult (..)
  , TlsUnopenableSuccessorStagingResult (..)
  , TlsTerminalReplacementStagingResult (..)
  , TlsRetentionPromotionResult (..)
  , tlsRetentionStateMaximumBytes
  , tlsRetentionStateCodec
  , modelBTlsRetentionAuthorityRepository
  , observeTlsRetentionAuthority
  , stageTlsRetentionAuthority
  , stageTlsPendingCollisionAuthority
  , stageTlsLegacyRecoveryAuthority
  , stageTlsUnopenableSuccessorAuthority
  , stageTlsTerminalReplacementAuthority
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
  , TlsLegacyRecoveryCollisionEvidence
  , TlsLegacyRecoveryEvidence
  , TlsLegacyRecoveryStagingDecision
    ( TlsLegacyRecoveryCollisionRebased
    , TlsLegacyRecoveryCollisionSuccessorStaged
    , TlsLegacyRecoveryStaged
    )
  , TlsPendingCollisionRecovery
  , TlsPendingCollisionStagingDecision
    ( TlsPendingCollisionBoundedSuccessorRebased
    , TlsPendingCollisionLegacyRecoverySuccessorRebased
    , TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased
    , TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged
    , TlsPendingCollisionRebased
    , TlsPendingCollisionSuccessorStaged
    , TlsPendingCollisionUnopenableSuccessorRebased
    )
  , TlsPromotionDecision (TlsPromoted)
  , TlsRetentionState
  , TlsSealedEnvelope
  , TlsStagingDecision (TlsStaged)
  , TlsTerminalReplacementEvidence
  , TlsTerminalReplacementStagingDecision (TlsTerminalReplacementStaged)
  , TlsUnopenableSuccessorStagingDecision (TlsUnopenableSuccessorStaged)
  , TlsUnopenableVersionEvidence
  , applyTlsLegacyRecoveryStaging
  , applyTlsPendingCollisionStaging
  , applyTlsPromotion
  , applyTlsStaging
  , applyTlsTerminalReplacementStaging
  , applyTlsUnopenableSuccessorStaging
  , decideTlsLegacyRecoveryStaging
  , decideTlsPendingCollisionStaging
  , decideTlsPromotion
  , decideTlsStaging
  , decideTlsTerminalReplacementStaging
  , decideTlsUnopenableSuccessorStaging
  , initialTlsRetentionState
  , validateTlsRetentionState
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
      :: m
           ( Either
               TlsRetentionAuthorityReadFailure
               (Maybe (StoredTlsRetentionState revision))
           )
  , compareAndSwapTlsRetentionState
      :: Maybe revision
      -> TlsRetentionState
      -> m (Either TlsRetentionAuthorityWriteFailure Bool)
  }

data TlsRetentionAuthorityReadFailure
  = TlsRetentionAuthorityReadCorrupt
  | TlsRetentionAuthorityReadEndpointUnready
  | TlsRetentionAuthorityReadUnobservable
  deriving stock (Bounded, Enum, Eq, Show)

data TlsRetentionAuthorityWriteFailure
  = TlsRetentionAuthorityWriteRefusedCorrupt
  | TlsRetentionAuthorityWriteEndpointUnready
  | TlsRetentionAuthorityWriteUnobservable
  deriving stock (Bounded, Enum, Eq, Show)

data TlsRetentionAuthorityError
  = TlsRetentionAuthorityReadFailed !TlsRetentionAuthorityReadFailure
  | TlsRetentionAuthorityWriteFailed !TlsRetentionAuthorityWriteFailure
  | TlsRetentionAuthorityConcurrentWrite
  deriving stock (Eq, Show)

-- | Add a protected diagnostic at the exact repository boundary without
-- changing the read/CAS result. The failure algebras deliberately discard the
-- provider, codec, object-name, and credential detail before this reporter can
-- observe it.
diagnoseTlsRetentionAuthorityRepository
  :: (Monad m)
  => (Text -> m ())
  -> TlsRetentionAuthorityRepository m revision
  -> TlsRetentionAuthorityRepository m revision
diagnoseTlsRetentionAuthorityRepository report repository =
  repository
    { readTlsRetentionState = do
        result <- readTlsRetentionState repository
        reportFailure result
        pure result
    , compareAndSwapTlsRetentionState = \expected state -> do
        result <- compareAndSwapTlsRetentionState repository expected state
        reportFailure result
        pure result
    }
 where
  reportFailure result = case result of
    Left failure -> report (renderTlsRetentionAuthorityFailure failure)
    Right _ -> pure ()

class TlsRetentionAuthorityFailure failure where
  renderTlsRetentionAuthorityFailure :: failure -> Text

instance TlsRetentionAuthorityFailure TlsRetentionAuthorityReadFailure where
  renderTlsRetentionAuthorityFailure failure = case failure of
    TlsRetentionAuthorityReadCorrupt -> "read/corrupt"
    TlsRetentionAuthorityReadEndpointUnready -> "read/endpoint-unready"
    TlsRetentionAuthorityReadUnobservable -> "read/unobservable"

instance TlsRetentionAuthorityFailure TlsRetentionAuthorityWriteFailure where
  renderTlsRetentionAuthorityFailure failure = case failure of
    TlsRetentionAuthorityWriteRefusedCorrupt -> "write/refused-corrupt"
    TlsRetentionAuthorityWriteEndpointUnready -> "write/endpoint-unready"
    TlsRetentionAuthorityWriteUnobservable -> "write/unobservable"

data TlsRetentionPromotionResult = TlsRetentionPromotionResult
  { tlsRetentionPromotionState :: !TlsRetentionState
  , tlsRetentionPromotionDecision :: !TlsPromotionDecision
  }
  deriving stock (Eq, Show)

data TlsRetentionStagingResult = TlsRetentionStagingResult
  { tlsRetentionStagingState :: !TlsRetentionState
  , tlsRetentionStagingDecision :: !TlsStagingDecision
  }
  deriving stock (Eq, Show)

data TlsPendingCollisionStagingResult = TlsPendingCollisionStagingResult
  { tlsPendingCollisionStagingState :: !TlsRetentionState
  , tlsPendingCollisionStagingDecision :: !TlsPendingCollisionStagingDecision
  }
  deriving stock (Eq, Show)

data TlsLegacyRecoveryStagingResult = TlsLegacyRecoveryStagingResult
  { tlsLegacyRecoveryStagingState :: !TlsRetentionState
  , tlsLegacyRecoveryStagingDecision :: !TlsLegacyRecoveryStagingDecision
  }
  deriving stock (Eq, Show)

data TlsUnopenableSuccessorStagingResult = TlsUnopenableSuccessorStagingResult
  { tlsUnopenableSuccessorStagingState :: !TlsRetentionState
  , tlsUnopenableSuccessorStagingDecision :: !TlsUnopenableSuccessorStagingDecision
  }
  deriving stock (Eq, Show)

data TlsTerminalReplacementStagingResult = TlsTerminalReplacementStagingResult
  { tlsTerminalReplacementStagingState :: !TlsRetentionState
  , tlsTerminalReplacementStagingDecision :: !TlsTerminalReplacementStagingDecision
  }
  deriving stock (Eq, Show)

tlsRetentionStateMaximumBytes :: Int
tlsRetentionStateMaximumBytes = 960 * 1024

tlsRetentionStateCodec :: ModelBCodec TlsRetentionState
tlsRetentionStateCodec =
  ModelBCodec
    { encodeModelBValue = \state -> do
        mapLeft Text.unpack (validateTlsRetentionState state)
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
              then mapLeft Text.unpack (validateTlsRetentionState state) >> Right state
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
          ModelBCorrupt _ -> Left TlsRetentionAuthorityReadCorrupt
          ModelBEndpointUnready _ -> Left TlsRetentionAuthorityReadEndpointUnready
          ModelBUnobservable _ -> Left TlsRetentionAuthorityReadUnobservable
    , compareAndSwapTlsRetentionState = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right True
          ModelBCasConflict _ -> Right False
          ModelBCasRefusedCorrupt _ -> Left TlsRetentionAuthorityWriteRefusedCorrupt
          ModelBCasEndpointUnready _ -> Left TlsRetentionAuthorityWriteEndpointUnready
          ModelBCasUnobservable _ -> Left TlsRetentionAuthorityWriteUnobservable
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

stageTlsRetentionAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> KeyRotationApproval
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> m (Either TlsRetentionAuthorityError TlsRetentionStagingResult)
stageTlsRetentionAuthority repository approval candidate envelope = do
  observed <- readTlsRetentionState repository
  case observed of
    Left detail -> pure (Left (TlsRetentionAuthorityReadFailed detail))
    Right maybeStored -> do
      let current = maybe initialTlsRetentionState storedTlsRetentionState maybeStored
          expected = storedTlsRetentionRevision <$> maybeStored
          decision = decideTlsStaging approval current candidate envelope
          next = applyTlsStaging decision current
          result = TlsRetentionStagingResult next decision
      case decision of
        TlsStaged _ -> do
          written <- compareAndSwapTlsRetentionState repository expected next
          pure $ case written of
            Left detail -> Left (TlsRetentionAuthorityWriteFailed detail)
            Right False -> Left TlsRetentionAuthorityConcurrentWrite
            Right True -> Right result
        _ -> pure (Right result)

stageTlsPendingCollisionAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> KeyRotationApproval
  -> TlsPendingCollisionRecovery
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> m (Either TlsRetentionAuthorityError TlsPendingCollisionStagingResult)
stageTlsPendingCollisionAuthority repository approval recovery candidate envelope = do
  observed <- readTlsRetentionState repository
  case observed of
    Left detail -> pure (Left (TlsRetentionAuthorityReadFailed detail))
    Right maybeStored -> do
      let current = maybe initialTlsRetentionState storedTlsRetentionState maybeStored
          expected = storedTlsRetentionRevision <$> maybeStored
          decision =
            decideTlsPendingCollisionStaging
              approval
              current
              recovery
              candidate
              envelope
          next = applyTlsPendingCollisionStaging decision current
          result = TlsPendingCollisionStagingResult next decision
      case decision of
        TlsPendingCollisionRebased {} -> commit expected next result
        TlsPendingCollisionSuccessorStaged {} -> commit expected next result
        TlsPendingCollisionUnopenableSuccessorRebased {} -> commit expected next result
        TlsPendingCollisionLegacyRecoverySuccessorRebased {} -> commit expected next result
        TlsPendingCollisionBoundedSuccessorRebased {} -> commit expected next result
        TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged {} -> commit expected next result
        TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased {} -> commit expected next result
        _ -> pure (Right result)
 where
  commit expected next result = do
    written <- compareAndSwapTlsRetentionState repository expected next
    pure $ case written of
      Left detail -> Left (TlsRetentionAuthorityWriteFailed detail)
      Right False -> Left TlsRetentionAuthorityConcurrentWrite
      Right True -> Right result

stageTlsTerminalReplacementAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> KeyRotationApproval
  -> TlsPendingCollisionRecovery
  -> TlsTerminalReplacementEvidence
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> m (Either TlsRetentionAuthorityError TlsTerminalReplacementStagingResult)
stageTlsTerminalReplacementAuthority
  repository
  approval
  recovery
  terminalEvidence
  candidate
  envelope = do
    observed <- readTlsRetentionState repository
    case observed of
      Left detail -> pure (Left (TlsRetentionAuthorityReadFailed detail))
      Right maybeStored -> do
        let current = maybe initialTlsRetentionState storedTlsRetentionState maybeStored
            expected = storedTlsRetentionRevision <$> maybeStored
            decision =
              decideTlsTerminalReplacementStaging
                approval
                current
                recovery
                terminalEvidence
                candidate
                envelope
            next = applyTlsTerminalReplacementStaging decision current
            result = TlsTerminalReplacementStagingResult next decision
        case decision of
          TlsTerminalReplacementStaged {} -> do
            written <- compareAndSwapTlsRetentionState repository expected next
            pure $ case written of
              Left detail -> Left (TlsRetentionAuthorityWriteFailed detail)
              Right False -> Left TlsRetentionAuthorityConcurrentWrite
              Right True -> Right result
          _ -> pure (Right result)

stageTlsLegacyRecoveryAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> KeyRotationApproval
  -> TlsLegacyRecoveryEvidence
  -> Maybe TlsLegacyRecoveryCollisionEvidence
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> m (Either TlsRetentionAuthorityError TlsLegacyRecoveryStagingResult)
stageTlsLegacyRecoveryAuthority repository approval evidence collision candidate envelope = do
  observed <- readTlsRetentionState repository
  case observed of
    Left detail -> pure (Left (TlsRetentionAuthorityReadFailed detail))
    Right maybeStored -> do
      let current = maybe initialTlsRetentionState storedTlsRetentionState maybeStored
          expected = storedTlsRetentionRevision <$> maybeStored
          decision =
            decideTlsLegacyRecoveryStaging
              approval
              current
              evidence
              collision
              candidate
              envelope
          next = applyTlsLegacyRecoveryStaging evidence decision current
          result = TlsLegacyRecoveryStagingResult next decision
      case decision of
        TlsLegacyRecoveryStaged _ -> commit expected next result
        TlsLegacyRecoveryCollisionRebased _ _ -> commit expected next result
        TlsLegacyRecoveryCollisionSuccessorStaged _ _ -> commit expected next result
        _ -> pure (Right result)
 where
  commit expected next result = do
    written <- compareAndSwapTlsRetentionState repository expected next
    pure $ case written of
      Left detail -> Left (TlsRetentionAuthorityWriteFailed detail)
      Right False -> Left TlsRetentionAuthorityConcurrentWrite
      Right True -> Right result

-- | One CAS that durably records the proven-unopenable version and the
-- complete successor outbox before any Adapter write can occupy the successor
-- slot. Only the staged decision commits; a replay and every refusal leave the
-- retained state byte-identical.
stageTlsUnopenableSuccessorAuthority
  :: (Monad m)
  => TlsRetentionAuthorityRepository m revision
  -> KeyRotationApproval
  -> TlsUnopenableVersionEvidence
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> m (Either TlsRetentionAuthorityError TlsUnopenableSuccessorStagingResult)
stageTlsUnopenableSuccessorAuthority repository approval evidence candidate envelope = do
  observed <- readTlsRetentionState repository
  case observed of
    Left detail -> pure (Left (TlsRetentionAuthorityReadFailed detail))
    Right maybeStored -> do
      let current = maybe initialTlsRetentionState storedTlsRetentionState maybeStored
          expected = storedTlsRetentionRevision <$> maybeStored
          decision =
            decideTlsUnopenableSuccessorStaging
              approval
              current
              evidence
              candidate
              envelope
          next = applyTlsUnopenableSuccessorStaging evidence decision current
          result = TlsUnopenableSuccessorStagingResult next decision
      case decision of
        TlsUnopenableSuccessorStaged _ -> do
          written <- compareAndSwapTlsRetentionState repository expected next
          pure $ case written of
            Left detail -> Left (TlsRetentionAuthorityWriteFailed detail)
            Right False -> Left TlsRetentionAuthorityConcurrentWrite
            Right True -> Right result
        _ -> pure (Right result)

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
