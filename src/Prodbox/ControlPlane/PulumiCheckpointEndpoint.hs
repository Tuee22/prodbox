{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed Lifecycle Authority protocol for registered Pulumi checkpoints.
--
-- Requests name only a registry entry, never an object key, bucket, endpoint,
-- or Vault coordinate.  Publication and retirement additionally carry an
-- authority-allocated identity of an already-admitted operation plus the
-- predecessor digest observed by the caller.  The injected repository must
-- validate that identity against the retained submission and exact stack mutation and
-- perform the aggregate + primary/backup immutable-blob transaction; this HTTP
-- layer cannot be used as a generic object-store proxy.
module Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointRequest (..)
  , PulumiCheckpointMutationTicket (..)
  , PulumiCheckpointWireObservation (..)
  , PulumiCheckpointWirePublication (..)
  , PulumiCheckpointWireRetirement (..)
  , PulumiCheckpointResponse (..)
  , PulumiCheckpointObservation (..)
  , PulumiCheckpointCopyObservation (..)
  , PulumiCheckpointPairObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRestoreResult (..)
  , PulumiCheckpointRestoreReadBack (..)
  , PulumiCheckpointRetirementAttemptResult (..)
  , PulumiCheckpointRetirementReadBack (..)
  , PulumiCheckpointRetirementResult (..)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointHandler
  , pulumiCheckpointRequestMaximumBytes
  , pulumiCheckpointResponseMaximumBytes
  , mkPulumiCheckpointHandler
  , runPulumiCheckpointHandler
  , pulumiCheckpointResponseHttpStatus
  , pulumiCheckpointResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RequestAuthentication (VerifiedCallerSlot)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( VerifiedPulumiCheckpointRef
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , PulumiCheckpointCodecError
  , PulumiCheckpointDigest
  , PulumiCheckpointPayloadKind (PulumiFileBackendCheckpoint)
  , RegisteredPulumiCheckpoint
  , canonicalPulumiCheckpointBytes
  , canonicalPulumiCheckpointDigest
  , decodeCanonicalPulumiCheckpoint
  , pulumiCheckpointMaximumBytes
  , registeredPulumiCheckpointByName
  , registeredPulumiCheckpointName
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CustodyDispositionRecord
  )

data PulumiCheckpointRequest
  = ObservePulumiCheckpoint !Text
  | ObservePulumiCheckpointPair !Text
  | PublishPulumiCheckpoint
      !Text
      !PulumiCheckpointMutationTicket
      !ByteString
  | -- | Sprint 4.89: a retirement carries the disposition its caller consumed.
    --
    -- The Lifecycle Authority cannot observe AWS and so cannot check the proof;
    -- what it refuses is a retirement for which no disposition was ever stated,
    -- which is the failure that stranded two AWS resources.
    RetirePulumiCheckpoint
      !Text
      !PulumiCheckpointMutationTicket
      !CustodyDispositionRecord
  | RestorePulumiCheckpointPrimary
      !Text
      !PulumiCheckpointMutationTicket
      !VerifiedPulumiCheckpointRef
  | ReadBackPulumiCheckpointRestore
      !Text
      !OperationId
  | AttemptPulumiCheckpointRetirement
      !Text
      !PulumiCheckpointMutationTicket
      !CustodyDispositionRecord
      !(Maybe VerifiedPulumiCheckpointRef)
  | ReadBackPulumiCheckpointRetirement
      !Text
      !OperationId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The exact admitted operation plus the predecessor observed before the
-- caller submitted its mutation.  Keeping these fields together prevents an
-- endpoint or repository adapter from accidentally dropping the predecessor
-- fence while preserving a single closed mutation argument.
data PulumiCheckpointMutationTicket = PulumiCheckpointMutationTicket
  { pulumiCheckpointTicketOperation :: !OperationId
  , pulumiCheckpointTicketExpectedDigest :: !(Maybe PulumiCheckpointDigest)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointWireObservation
  = PulumiCheckpointWireMissing
  | PulumiCheckpointWireObserved !PulumiCheckpointDigest !ByteString
  | PulumiCheckpointWireCorrupt !Text
  | PulumiCheckpointWireCorruptAt !PulumiCheckpointDigest !Text
  | PulumiCheckpointWireEndpointUnready !Text
  | PulumiCheckpointWireUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointWirePublication
  = PulumiCheckpointWirePublished !PulumiCheckpointDigest
  | PulumiCheckpointWireAlreadyCurrent !PulumiCheckpointDigest
  | PulumiCheckpointWirePublicationConflict !PulumiCheckpointWireObservation
  | PulumiCheckpointWirePublicationRefused !Text
  | PulumiCheckpointWirePublicationUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointWireRetirement
  = PulumiCheckpointWireAlreadyAbsent
  | PulumiCheckpointWireRetiredAndReadBack
  | PulumiCheckpointWireRetirementRefused !PulumiCheckpointWireObservation
  | PulumiCheckpointWireRetirementUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointResponse
  = PulumiCheckpointObserved !Text !PulumiCheckpointWireObservation
  | PulumiCheckpointPairObserved !Text !PulumiCheckpointPairObservation
  | PulumiCheckpointPublication !Text !PulumiCheckpointWirePublication
  | PulumiCheckpointRetirement !Text !PulumiCheckpointWireRetirement
  | PulumiCheckpointRestoreAttempted !Text !PulumiCheckpointRestoreResult
  | PulumiCheckpointRestoreReadBackObserved
      !Text
      !PulumiCheckpointRestoreReadBack
  | PulumiCheckpointRetirementAttempted
      !Text
      !PulumiCheckpointRetirementAttemptResult
  | PulumiCheckpointRetirementReadBackObserved
      !Text
      !PulumiCheckpointRetirementReadBack
  | PulumiCheckpointBadRequest !Text
  | PulumiCheckpointRegistrationRefused !Text
  | PulumiCheckpointOperationRefRefused !Text !Text
  | PulumiCheckpointPayloadRefused !Text !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointObservation
  = PulumiCheckpointMissing
  | PulumiCheckpointCurrent !CanonicalPulumiCheckpoint
  | PulumiCheckpointCorrupt !Text
  | PulumiCheckpointCorruptAt !PulumiCheckpointDigest !Text
  | PulumiCheckpointEndpointUnready !Text
  | PulumiCheckpointUnobservable !Text
  deriving stock (Eq, Show)

-- | Each physical copy is observed independently.  A missing or unknown
-- primary never suppresses the backup request, and vice versa.
data PulumiCheckpointCopyObservation
  = PulumiCheckpointCopyMissing
  | PulumiCheckpointCopyCurrent !Text
  | PulumiCheckpointCopyCorrupt !Text
  | PulumiCheckpointCopyUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointPairObservation
  = PulumiCheckpointPairNoCurrentReference
  | PulumiCheckpointPairCurrent
      !VerifiedPulumiCheckpointRef
      !PulumiCheckpointCopyObservation
      !PulumiCheckpointCopyObservation
  | PulumiCheckpointPairUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointPublicationResult
  = PulumiCheckpointPublished !PulumiCheckpointDigest
  | PulumiCheckpointAlreadyCurrent !PulumiCheckpointDigest
  | PulumiCheckpointPublicationConflict !PulumiCheckpointObservation
  | PulumiCheckpointPublicationRefused !Text
  | PulumiCheckpointPublicationUnavailable !Text
  deriving stock (Eq, Show)

data PulumiCheckpointRetirementResult
  = PulumiCheckpointAlreadyAbsent
  | PulumiCheckpointRetiredAndReadBack
  | PulumiCheckpointRetirementRefused !PulumiCheckpointObservation
  | PulumiCheckpointRetirementUnavailable !Text
  deriving stock (Eq, Show)

data PulumiCheckpointRestoreResult
  = PulumiCheckpointRestoreApplied !VerifiedPulumiCheckpointRef
  | PulumiCheckpointRestoreAlreadyApplied !VerifiedPulumiCheckpointRef
  | PulumiCheckpointRestoreRefused !Text
  | PulumiCheckpointRestoreUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointRestoreReadBack
  = PulumiCheckpointRestorePending
  | PulumiCheckpointRestoreConfirmed
      !VerifiedPulumiCheckpointRef
      !VerifiedPulumiCheckpointRef
  | PulumiCheckpointRestoreReadBackRefused !Text
  | PulumiCheckpointRestoreReadBackUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointRetirementAttemptResult
  = PulumiCheckpointRetirementApplied
  | PulumiCheckpointRetirementAlreadyApplied
  | PulumiCheckpointRetirementAttemptRefused !Text
  | PulumiCheckpointRetirementAttemptUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PulumiCheckpointRetirementReadBack
  = PulumiCheckpointRetirementPending
  | PulumiCheckpointReferenceRetired !(Maybe VerifiedPulumiCheckpointRef)
  | PulumiCheckpointReferenceStillCurrent !(Maybe VerifiedPulumiCheckpointRef)
  | PulumiCheckpointRetirementReadBackRefused !Text
  | PulumiCheckpointRetirementReadBackUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The load-bearing Authority transaction seam.  Implementations validate
-- operation ownership and exact checkpoint registration, publish immutable
-- content-addressed bytes to both primary and backup stores, and promote or
-- retire the aggregate reference only after authoritative read-back.
data PulumiCheckpointRepository m = PulumiCheckpointRepository
  { observeRegisteredPulumiCheckpoint
      :: VerifiedCallerSlot
      -> RegisteredPulumiCheckpoint
      -> m PulumiCheckpointObservation
  , observeRegisteredPulumiCheckpointPair
      :: VerifiedCallerSlot
      -> RegisteredPulumiCheckpoint
      -> m PulumiCheckpointPairObservation
  , publishRegisteredPulumiCheckpoint
      :: VerifiedCallerSlot
      -> PulumiCheckpointMutationTicket
      -> RegisteredPulumiCheckpoint
      -> CanonicalPulumiCheckpoint
      -> m PulumiCheckpointPublicationResult
  , retireRegisteredPulumiCheckpoint
      :: VerifiedCallerSlot
      -> PulumiCheckpointMutationTicket
      -> CustodyDispositionRecord
      -> RegisteredPulumiCheckpoint
      -> m PulumiCheckpointRetirementResult
  , restoreRegisteredPulumiCheckpointPrimary
      :: VerifiedCallerSlot
      -> PulumiCheckpointMutationTicket
      -> RegisteredPulumiCheckpoint
      -> VerifiedPulumiCheckpointRef
      -> m PulumiCheckpointRestoreResult
  , readBackRegisteredPulumiCheckpointRestore
      :: VerifiedCallerSlot
      -> OperationId
      -> RegisteredPulumiCheckpoint
      -> m PulumiCheckpointRestoreReadBack
  , attemptRegisteredPulumiCheckpointRetirement
      :: VerifiedCallerSlot
      -> PulumiCheckpointMutationTicket
      -> CustodyDispositionRecord
      -> RegisteredPulumiCheckpoint
      -> Maybe VerifiedPulumiCheckpointRef
      -> m PulumiCheckpointRetirementAttemptResult
  , readBackRegisteredPulumiCheckpointRetirement
      :: VerifiedCallerSlot
      -> OperationId
      -> RegisteredPulumiCheckpoint
      -> m PulumiCheckpointRetirementReadBack
  }

newtype PulumiCheckpointHandler m = PulumiCheckpointHandler
  { runPulumiCheckpointHandler
      :: VerifiedCallerSlot
      -> LazyByteString.ByteString
      -> m PulumiCheckpointResponse
  }

pulumiCheckpointRequestMaximumBytes :: Int
pulumiCheckpointRequestMaximumBytes = pulumiCheckpointMaximumBytes + 64 * 1024

pulumiCheckpointResponseMaximumBytes :: Int
pulumiCheckpointResponseMaximumBytes = pulumiCheckpointMaximumBytes + 64 * 1024

mkPulumiCheckpointHandler
  :: (Monad m)
  => PulumiCheckpointRepository m
  -> PulumiCheckpointHandler m
mkPulumiCheckpointHandler repository =
  PulumiCheckpointHandler (handlePulumiCheckpoint repository)

handlePulumiCheckpoint
  :: (Monad m)
  => PulumiCheckpointRepository m
  -> VerifiedCallerSlot
  -> LazyByteString.ByteString
  -> m PulumiCheckpointResponse
handlePulumiCheckpoint repository callerSlot body =
  case decodeControlPlaneRequest pulumiCheckpointRequestMaximumBytes body of
    Left err -> pure (badRequest err)
    Right request -> servePulumiCheckpoint repository callerSlot request

servePulumiCheckpoint
  :: (Monad m)
  => PulumiCheckpointRepository m
  -> VerifiedCallerSlot
  -> PulumiCheckpointRequest
  -> m PulumiCheckpointResponse
servePulumiCheckpoint repository callerSlot request =
  case request of
    ObservePulumiCheckpoint rawName ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointObserved rawName . encodeObservation
          <$> observeRegisteredPulumiCheckpoint repository callerSlot registered
    ObservePulumiCheckpointPair rawName ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointPairObserved rawName
          <$> observeRegisteredPulumiCheckpointPair repository callerSlot registered
    PublishPulumiCheckpoint rawName ticket bytes ->
      withRegistration
        rawName
        (publishPulumiCheckpoint repository callerSlot rawName ticket bytes)
    RetirePulumiCheckpoint rawName ticket disposition ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointRetirement rawName . encodeRetirement
          <$> retireRegisteredPulumiCheckpoint
            repository
            callerSlot
            ticket
            disposition
            registered
    RestorePulumiCheckpointPrimary rawName ticket predecessor ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointRestoreAttempted rawName
          <$> restoreRegisteredPulumiCheckpointPrimary
            repository
            callerSlot
            ticket
            registered
            predecessor
    ReadBackPulumiCheckpointRestore rawName operation ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointRestoreReadBackObserved rawName
          <$> readBackRegisteredPulumiCheckpointRestore
            repository
            callerSlot
            operation
            registered
    AttemptPulumiCheckpointRetirement rawName ticket disposition expectedReference ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointRetirementAttempted rawName
          <$> attemptRegisteredPulumiCheckpointRetirement
            repository
            callerSlot
            ticket
            disposition
            registered
            expectedReference
    ReadBackPulumiCheckpointRetirement rawName operation ->
      withRegistration rawName $ \registered ->
        PulumiCheckpointRetirementReadBackObserved rawName
          <$> readBackRegisteredPulumiCheckpointRetirement
            repository
            callerSlot
            operation
            registered
 where
  withRegistration rawName action =
    case registeredPulumiCheckpointByName rawName of
      Left err -> pure (PulumiCheckpointRegistrationRefused (Text.pack (show err)))
      Right checkpoint
        | registeredPulumiCheckpointName checkpoint /= rawName ->
            pure (PulumiCheckpointRegistrationRefused "checkpoint registration changed during decode")
        | otherwise -> action checkpoint

publishPulumiCheckpoint
  :: (Monad m)
  => PulumiCheckpointRepository m
  -> VerifiedCallerSlot
  -> Text
  -> PulumiCheckpointMutationTicket
  -> ByteString
  -> RegisteredPulumiCheckpoint
  -> m PulumiCheckpointResponse
publishPulumiCheckpoint repository callerSlot rawName ticket bytes registered =
  case decodeCanonicalPulumiCheckpoint
    (Set.singleton PulumiFileBackendCheckpoint)
    pulumiCheckpointMaximumBytes
    bytes of
    Left err ->
      pure
        ( PulumiCheckpointPayloadRefused
            rawName
            (renderPayloadError err)
        )
    Right canonical ->
      PulumiCheckpointPublication rawName . encodePublication
        <$> publishRegisteredPulumiCheckpoint
          repository
          callerSlot
          ticket
          registered
          canonical

encodeObservation :: PulumiCheckpointObservation -> PulumiCheckpointWireObservation
encodeObservation observation = case observation of
  PulumiCheckpointMissing -> PulumiCheckpointWireMissing
  PulumiCheckpointCurrent checkpoint ->
    PulumiCheckpointWireObserved
      (canonicalPulumiCheckpointDigest checkpoint)
      (canonicalPulumiCheckpointBytes checkpoint)
  PulumiCheckpointCorrupt detail -> PulumiCheckpointWireCorrupt detail
  PulumiCheckpointCorruptAt digest detail ->
    PulumiCheckpointWireCorruptAt digest detail
  PulumiCheckpointEndpointUnready detail -> PulumiCheckpointWireEndpointUnready detail
  PulumiCheckpointUnobservable detail -> PulumiCheckpointWireUnobservable detail

encodePublication
  :: PulumiCheckpointPublicationResult
  -> PulumiCheckpointWirePublication
encodePublication result = case result of
  PulumiCheckpointPublished digest -> PulumiCheckpointWirePublished digest
  PulumiCheckpointAlreadyCurrent digest -> PulumiCheckpointWireAlreadyCurrent digest
  PulumiCheckpointPublicationConflict observation ->
    PulumiCheckpointWirePublicationConflict (encodeObservation observation)
  PulumiCheckpointPublicationRefused detail ->
    PulumiCheckpointWirePublicationRefused detail
  PulumiCheckpointPublicationUnavailable detail ->
    PulumiCheckpointWirePublicationUnavailable detail

encodeRetirement
  :: PulumiCheckpointRetirementResult
  -> PulumiCheckpointWireRetirement
encodeRetirement result = case result of
  PulumiCheckpointAlreadyAbsent -> PulumiCheckpointWireAlreadyAbsent
  PulumiCheckpointRetiredAndReadBack -> PulumiCheckpointWireRetiredAndReadBack
  PulumiCheckpointRetirementRefused observation ->
    PulumiCheckpointWireRetirementRefused (encodeObservation observation)
  PulumiCheckpointRetirementUnavailable detail ->
    PulumiCheckpointWireRetirementUnavailable detail

badRequest :: ControlPlaneRequestCodecError -> PulumiCheckpointResponse
badRequest = PulumiCheckpointBadRequest . controlPlaneRequestCodecToken

renderPayloadError :: PulumiCheckpointCodecError -> Text
renderPayloadError = Text.pack . show

pulumiCheckpointResponseHttpStatus :: PulumiCheckpointResponse -> ReplyStatus
pulumiCheckpointResponseHttpStatus response = case response of
  PulumiCheckpointObserved _ observation -> observationStatus observation
  PulumiCheckpointPairObserved _ observation -> pairStatus observation
  PulumiCheckpointPublication _ result -> publicationStatus result
  PulumiCheckpointRetirement _ result -> retirementStatus result
  PulumiCheckpointRestoreAttempted _ result -> restoreStatus result
  PulumiCheckpointRestoreReadBackObserved _ result -> restoreReadBackStatus result
  PulumiCheckpointRetirementAttempted _ result -> retirementAttemptStatus result
  PulumiCheckpointRetirementReadBackObserved _ result ->
    retirementReadBackStatus result
  PulumiCheckpointBadRequest _ -> ReplyBadRequest
  PulumiCheckpointRegistrationRefused _ -> ReplyBadRequest
  PulumiCheckpointOperationRefRefused _ _ -> ReplyBadRequest
  PulumiCheckpointPayloadRefused _ _ -> ReplyBadRequest
 where
  observationStatus observation = case observation of
    PulumiCheckpointWireMissing -> ReplyOk
    PulumiCheckpointWireObserved {} -> ReplyOk
    PulumiCheckpointWireCorrupt _ -> ReplyInternalError
    PulumiCheckpointWireCorruptAt {} -> ReplyInternalError
    PulumiCheckpointWireEndpointUnready _ -> ReplyServiceUnavailable
    PulumiCheckpointWireUnobservable _ -> ReplyServiceUnavailable
  pairStatus observation = case observation of
    PulumiCheckpointPairNoCurrentReference -> ReplyOk
    PulumiCheckpointPairCurrent {} -> ReplyOk
    PulumiCheckpointPairUnobservable _ -> ReplyServiceUnavailable
  publicationStatus result = case result of
    PulumiCheckpointWirePublished _ -> ReplyOk
    PulumiCheckpointWireAlreadyCurrent _ -> ReplyOk
    PulumiCheckpointWirePublicationConflict _ -> ReplyConflict
    PulumiCheckpointWirePublicationRefused _ -> ReplyConflict
    PulumiCheckpointWirePublicationUnavailable _ -> ReplyServiceUnavailable
  retirementStatus result = case result of
    PulumiCheckpointWireAlreadyAbsent -> ReplyOk
    PulumiCheckpointWireRetiredAndReadBack -> ReplyOk
    PulumiCheckpointWireRetirementRefused _ -> ReplyConflict
    PulumiCheckpointWireRetirementUnavailable _ -> ReplyServiceUnavailable
  restoreStatus result = case result of
    PulumiCheckpointRestoreApplied _ -> ReplyOk
    PulumiCheckpointRestoreAlreadyApplied _ -> ReplyOk
    PulumiCheckpointRestoreRefused _ -> ReplyConflict
    PulumiCheckpointRestoreUnavailable _ -> ReplyServiceUnavailable
  restoreReadBackStatus result = case result of
    PulumiCheckpointRestorePending -> ReplyOk
    PulumiCheckpointRestoreConfirmed {} -> ReplyOk
    PulumiCheckpointRestoreReadBackRefused _ -> ReplyConflict
    PulumiCheckpointRestoreReadBackUnavailable _ -> ReplyServiceUnavailable
  retirementAttemptStatus result = case result of
    PulumiCheckpointRetirementApplied -> ReplyOk
    PulumiCheckpointRetirementAlreadyApplied -> ReplyOk
    PulumiCheckpointRetirementAttemptRefused _ -> ReplyConflict
    PulumiCheckpointRetirementAttemptUnavailable _ -> ReplyServiceUnavailable
  retirementReadBackStatus result = case result of
    PulumiCheckpointRetirementPending -> ReplyOk
    PulumiCheckpointReferenceRetired _ -> ReplyOk
    PulumiCheckpointReferenceStillCurrent _ -> ReplyConflict
    PulumiCheckpointRetirementReadBackRefused _ -> ReplyConflict
    PulumiCheckpointRetirementReadBackUnavailable _ -> ReplyServiceUnavailable

pulumiCheckpointResponseBody :: PulumiCheckpointResponse -> ByteString
pulumiCheckpointResponseBody =
  LazyByteString.toStrict . encodeControlPlaneResponse
