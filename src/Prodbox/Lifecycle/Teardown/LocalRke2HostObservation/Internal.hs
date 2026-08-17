{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private admission and canonical identity for the host-observed
-- local RKE2 Healthy fact.  A candidate can be produced only after the exact
-- descriptor-bound recovery Establish node has begun and the production host
-- observer has returned its opaque Healthy state.
module Prodbox.Lifecycle.Teardown.LocalRke2HostObservation.Internal
  ( LocalRke2HostObservationIdentity
  , localRke2HostObservationRunId
  , localRke2HostObservationDescriptorDigest
  , localRke2HostObservationGraphDigest
  , localRke2HostObservationScope
  , localRke2HostObservationFoundation
  , localRke2HostObservationEstablishOperationId
  , localRke2HostObservationEstablishAttemptId
  , localRke2HostObservationIdentityDigest
  , LocalRke2HostObservationCandidate
  , localRke2HostObservationCandidateIdentityInternal
  , localRke2HostObservationIdentityFromBindingInternal
  , encodeLocalRke2HostObservationIdentityInternal
  , encodeLocalRke2HostObservationCandidateInternal
  , validateCanonicalLocalRke2HostObservationBytesInternal
  , validateLocalRke2HostObservationCandidateBytesInternal
  , admitObservedLocalRke2HealthyInternal
  , LocalRke2HostObservationError (..)
  , maximumLocalRke2HostObservationBytes
  , fixedLocalRke2HostObservationCandidateInternal
  , fixedStaleLocalRke2HostObservationCandidateInternal
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryState
  )
import Prodbox.Config.LocalRke2RecoveryState.Internal
  ( withObservedLocalRke2RecoveryHealthyInternal
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupOperationIdText
  , mkCleanupAttemptId
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , LinuxRke2FoundationId
  , ObservationEvidenceScope
  , evidenceLinuxRke2Foundation
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneIdentity
  , recoveryPlaneIdentityDescriptorDigest
  , recoveryPlaneIdentityEstablishOperationId
  , recoveryPlaneIdentityGraphDigest
  , recoveryPlaneIdentityObservationScope
  , recoveryPlaneIdentityRunId
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( RecoveryPlaneAttemptBinding (RecoveryPlaneAttemptBindingInternal)
  , decodeRecoveryPlaneIdentityWireInternal
  , encodeRecoveryPlaneIdentityWireInternal
  , fixedRecoveryPlaneEstablishAttemptIdInternal
  , fixedRecoveryPlaneIdentityInternal
  , recoveryPlaneAttemptBindingInternal
  )

data LocalRke2HostObservationIdentity (surface :: CleanupSurface)
  = LocalRke2HostObservationIdentityInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupAttemptId

instance Eq (LocalRke2HostObservationIdentity surface) where
  left == right =
    encodeLocalRke2HostObservationIdentityInternal left
      == encodeLocalRke2HostObservationIdentityInternal right

instance Show (LocalRke2HostObservationIdentity surface) where
  show identity =
    "<local-rke2-host-observation:"
      <> Text.unpack (cleanupAttemptIdText (localRke2HostObservationEstablishAttemptId identity))
      <> ">"

-- | Deliberately constructor-private: existence means the production host
-- observation was Healthy after the exact Establish Begin was validated.
newtype LocalRke2HostObservationCandidate (surface :: CleanupSurface)
  = LocalRke2HostObservationCandidateInternal
      (LocalRke2HostObservationIdentity surface)

data LocalRke2HostObservationError
  = LocalRke2HostObservationNotHealthy
  | LocalRke2HostObservationBindingIdentityMismatch
  | LocalRke2HostObservationBindingOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | LocalRke2HostObservationEncodedEmpty
  | LocalRke2HostObservationEncodedUnbounded !Int !Int
  | LocalRke2HostObservationEncodedCorrupt !Text
  | LocalRke2HostObservationEncodedIdentityMismatch
  | LocalRke2HostObservationEncodedOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | LocalRke2HostObservationEncodedAttemptMismatch
      !CleanupAttemptId
      !CleanupAttemptId
  deriving stock (Eq, Show)

data LocalRke2HostObservationWire = LocalRke2HostObservationWire
  { hostObservationWireVersion :: !Int
  , hostObservationWireIdentity :: !ByteString
  , hostObservationWireEstablishOperation :: !Text
  , hostObservationWireEstablishAttempt :: !Text
  , hostObservationWireHealthyFact :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumLocalRke2HostObservationBytes :: Int
maximumLocalRke2HostObservationBytes = 20 * 1024

localRke2HostObservationWireVersion :: Int
localRke2HostObservationWireVersion = 1

localRke2HostObservationHealthyFactTag :: Int
localRke2HostObservationHealthyFactTag = 1

localRke2HostObservationRunId
  :: LocalRke2HostObservationIdentity surface -> CleanupRunId
localRke2HostObservationRunId
  (LocalRke2HostObservationIdentityInternal identity _) =
    recoveryPlaneIdentityRunId identity

localRke2HostObservationDescriptorDigest
  :: LocalRke2HostObservationIdentity surface -> CleanupDigest
localRke2HostObservationDescriptorDigest
  (LocalRke2HostObservationIdentityInternal identity _) =
    recoveryPlaneIdentityDescriptorDigest identity

localRke2HostObservationGraphDigest
  :: LocalRke2HostObservationIdentity surface -> CleanupDigest
localRke2HostObservationGraphDigest
  (LocalRke2HostObservationIdentityInternal identity _) =
    recoveryPlaneIdentityGraphDigest identity

localRke2HostObservationScope
  :: LocalRke2HostObservationIdentity surface -> ObservationEvidenceScope
localRke2HostObservationScope
  (LocalRke2HostObservationIdentityInternal identity _) =
    recoveryPlaneIdentityObservationScope identity

localRke2HostObservationFoundation
  :: LocalRke2HostObservationIdentity surface -> LinuxRke2FoundationId
localRke2HostObservationFoundation =
  evidenceLinuxRke2Foundation . localRke2HostObservationScope

localRke2HostObservationEstablishOperationId
  :: LocalRke2HostObservationIdentity surface -> CleanupOperationId
localRke2HostObservationEstablishOperationId
  (LocalRke2HostObservationIdentityInternal identity _) =
    recoveryPlaneIdentityEstablishOperationId identity

localRke2HostObservationEstablishAttemptId
  :: LocalRke2HostObservationIdentity surface -> CleanupAttemptId
localRke2HostObservationEstablishAttemptId
  (LocalRke2HostObservationIdentityInternal _ attempt) = attempt

localRke2HostObservationIdentityDigest
  :: LocalRke2HostObservationIdentity surface -> Text
localRke2HostObservationIdentityDigest identity =
  TextEncoding.decodeUtf8
    ( hexSha256
        ( lengthFrameBytes
            [ "local-rke2-host-observation-identity/v1"
            , encodeLocalRke2HostObservationIdentityInternal identity
            ]
        )
    )

localRke2HostObservationCandidateIdentityInternal
  :: LocalRke2HostObservationCandidate surface
  -> LocalRke2HostObservationIdentity surface
localRke2HostObservationCandidateIdentityInternal
  (LocalRke2HostObservationCandidateInternal identity) = identity

-- | Package-private positive admission.  Its only production caller first
-- validates the descriptor-bound Establish Begin and only then invokes the
-- canonical host observer; source-ownership tests keep that sequencing
-- boundary closed.
admitObservedLocalRke2HealthyInternal
  :: RecoveryPlaneIdentity surface
  -> RecoveryPlaneAttemptBinding surface
  -> LocalRke2RecoveryState
  -> Either
       LocalRke2HostObservationError
       (LocalRke2HostObservationCandidate surface)
admitObservedLocalRke2HealthyInternal identity binding state =
  case withObservedLocalRke2RecoveryHealthyInternal state () of
    Nothing -> Left LocalRke2HostObservationNotHealthy
    Just () ->
      LocalRke2HostObservationCandidateInternal
        <$> localRke2HostObservationIdentityFromBindingInternal identity binding

localRke2HostObservationIdentityFromBindingInternal
  :: RecoveryPlaneIdentity surface
  -> RecoveryPlaneAttemptBinding surface
  -> Either
       LocalRke2HostObservationError
       (LocalRke2HostObservationIdentity surface)
localRke2HostObservationIdentityFromBindingInternal
  expectedIdentity
  ( RecoveryPlaneAttemptBindingInternal
      actualIdentity
      actualOperation
      actualAttempt
    ) = do
    unless
      (actualIdentity == expectedIdentity)
      (Left LocalRke2HostObservationBindingIdentityMismatch)
    let expectedOperation =
          recoveryPlaneIdentityEstablishOperationId expectedIdentity
    unless
      (actualOperation == expectedOperation)
      ( Left
          ( LocalRke2HostObservationBindingOperationMismatch
              expectedOperation
              actualOperation
          )
      )
    pure (LocalRke2HostObservationIdentityInternal expectedIdentity actualAttempt)

encodeLocalRke2HostObservationCandidateInternal
  :: LocalRke2HostObservationCandidate surface -> ByteString
encodeLocalRke2HostObservationCandidateInternal candidate =
  LazyByteString.toStrict (serialise (candidateToWire candidate))

encodeLocalRke2HostObservationIdentityInternal
  :: LocalRke2HostObservationIdentity surface -> ByteString
encodeLocalRke2HostObservationIdentityInternal identity =
  encodeLocalRke2HostObservationCandidateInternal
    (LocalRke2HostObservationCandidateInternal identity)

candidateToWire
  :: LocalRke2HostObservationCandidate surface -> LocalRke2HostObservationWire
candidateToWire candidate =
  LocalRke2HostObservationWire
    { hostObservationWireVersion = localRke2HostObservationWireVersion
    , hostObservationWireIdentity =
        encodeRecoveryPlaneIdentityWireInternal recoveryIdentity
    , hostObservationWireEstablishOperation =
        cleanupOperationIdText
          (localRke2HostObservationEstablishOperationId identity)
    , hostObservationWireEstablishAttempt =
        cleanupAttemptIdText
          (localRke2HostObservationEstablishAttemptId identity)
    , hostObservationWireHealthyFact =
        localRke2HostObservationHealthyFactTag
    }
 where
  identity = localRke2HostObservationCandidateIdentityInternal candidate
  LocalRke2HostObservationIdentityInternal recoveryIdentity _ = identity

validateLocalRke2HostObservationCandidateBytesInternal
  :: LocalRke2HostObservationIdentity surface
  -> ByteString
  -> Either LocalRke2HostObservationError ()
validateLocalRke2HostObservationCandidateBytesInternal expected bytes = do
  wire <- validateCanonicalLocalRke2HostObservationWireInternal bytes
  let expectedWire =
        candidateToWire (LocalRke2HostObservationCandidateInternal expected)
  unless
    ( hostObservationWireIdentity wire
        == hostObservationWireIdentity expectedWire
    )
    (Left LocalRke2HostObservationEncodedIdentityMismatch)
  actualOperation <-
    first
      LocalRke2HostObservationEncodedCorrupt
      (mkCleanupOperationId (hostObservationWireEstablishOperation wire))
  let expectedOperation =
        localRke2HostObservationEstablishOperationId
          expected
  unless
    (actualOperation == expectedOperation)
    ( Left
        ( LocalRke2HostObservationEncodedOperationMismatch
            expectedOperation
            actualOperation
        )
    )
  actualAttempt <-
    first
      LocalRke2HostObservationEncodedCorrupt
      (mkCleanupAttemptId (hostObservationWireEstablishAttempt wire))
  let expectedAttempt =
        localRke2HostObservationEstablishAttemptId
          expected
  unless
    (actualAttempt == expectedAttempt)
    ( Left
        ( LocalRke2HostObservationEncodedAttemptMismatch
            expectedAttempt
            actualAttempt
        )
    )

-- | Validate stored bytes without manufacturing an identity.  The Runtime
-- codec uses this to reject unbounded or non-canonical values before they can
-- enter retained Authority storage; exact identity admission remains above.
validateCanonicalLocalRke2HostObservationBytesInternal
  :: ByteString
  -> Either LocalRke2HostObservationError ByteString
validateCanonicalLocalRke2HostObservationBytesInternal bytes =
  bytes <$ validateCanonicalLocalRke2HostObservationWireInternal bytes

validateCanonicalLocalRke2HostObservationWireInternal
  :: ByteString
  -> Either LocalRke2HostObservationError LocalRke2HostObservationWire
validateCanonicalLocalRke2HostObservationWireInternal bytes = do
  when
    (ByteString.null bytes)
    (Left LocalRke2HostObservationEncodedEmpty)
  when
    (ByteString.length bytes > maximumLocalRke2HostObservationBytes)
    ( Left
        ( LocalRke2HostObservationEncodedUnbounded
            (ByteString.length bytes)
            maximumLocalRke2HostObservationBytes
        )
    )
  wire <-
    first
      (LocalRke2HostObservationEncodedCorrupt . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    ( Left
        ( LocalRke2HostObservationEncodedCorrupt
            "host observation is non-canonical"
        )
    )
  unless
    (hostObservationWireVersion wire == localRke2HostObservationWireVersion)
    ( Left
        ( LocalRke2HostObservationEncodedCorrupt
            "unsupported host-observation version"
        )
    )
  unless
    (hostObservationWireHealthyFact wire == localRke2HostObservationHealthyFactTag)
    ( Left
        ( LocalRke2HostObservationEncodedCorrupt
            "host observation does not contain the closed Healthy fact"
        )
    )
  _ <-
    first
      LocalRke2HostObservationEncodedCorrupt
      (decodeRecoveryPlaneIdentityWireInternal (hostObservationWireIdentity wire))
  _ <-
    first
      LocalRke2HostObservationEncodedCorrupt
      (mkCleanupOperationId (hostObservationWireEstablishOperation wire))
  _ <-
    first
      LocalRke2HostObservationEncodedCorrupt
      (mkCleanupAttemptId (hostObservationWireEstablishAttempt wire))
  pure wire

fixedLocalRke2HostObservationCandidateInternal
  :: LocalRke2HostObservationCandidate 'Cascade
fixedLocalRke2HostObservationCandidateInternal =
  fixedCandidate fixedRecoveryPlaneEstablishAttemptIdInternal

fixedStaleLocalRke2HostObservationCandidateInternal
  :: LocalRke2HostObservationCandidate 'Cascade
fixedStaleLocalRke2HostObservationCandidateInternal =
  fixedCandidate (mustRight (mkCleanupAttemptId "recovery-establish-attempt-stale"))

fixedCandidate
  :: CleanupAttemptId -> LocalRke2HostObservationCandidate 'Cascade
fixedCandidate attempt =
  LocalRke2HostObservationCandidateInternal
    ( mustRight
        ( localRke2HostObservationIdentityFromBindingInternal
            fixedRecoveryPlaneIdentityInternal
            ( recoveryPlaneAttemptBindingInternal
                fixedRecoveryPlaneIdentityInternal
                ( recoveryPlaneIdentityEstablishOperationId
                    fixedRecoveryPlaneIdentityInternal
                )
                attempt
            )
        )
    )

lengthFrameBytes :: [ByteString] -> ByteString
lengthFrameBytes = ByteString.concat . map frame
 where
  frame bytes =
    TextEncoding.encodeUtf8 (Text.pack (show (ByteString.length bytes)) <> ":")
      <> bytes

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
