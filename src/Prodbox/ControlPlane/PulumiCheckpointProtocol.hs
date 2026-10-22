{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pure checkpoint request DTOs and exact immutable-read replay classification.
-- Constructor order is the existing endpoint wire order.
module Prodbox.ControlPlane.PulumiCheckpointProtocol
  ( PulumiCheckpointRequest (..)
  , PulumiCheckpointMutationTicket (..)
  , isPulumiCheckpointObservationRequest
  , pulumiCheckpointRequestMaximumBytes
  ) where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest)
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry (VerifiedPulumiCheckpointRef)
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.PulumiCheckpoint (PulumiCheckpointDigest, pulumiCheckpointMaximumBytes)
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe (CustodyDispositionRecord)

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

isPulumiCheckpointObservationRequest :: ByteString -> Bool
isPulumiCheckpointObservationRequest bytes =
  case decodeControlPlaneRequest
    pulumiCheckpointRequestMaximumBytes
    (LazyByteString.fromStrict bytes) of
    Left _ -> False
    Right request -> case request of
      ObservePulumiCheckpoint _ -> True
      ObservePulumiCheckpointPair _ -> True
      PublishPulumiCheckpoint {} -> False
      RetirePulumiCheckpoint {} -> False
      RestorePulumiCheckpointPrimary {} -> False
      ReadBackPulumiCheckpointRestore {} -> False
      AttemptPulumiCheckpointRetirement {} -> False
      ReadBackPulumiCheckpointRetirement {} -> False

pulumiCheckpointRequestMaximumBytes :: Int
pulumiCheckpointRequestMaximumBytes = pulumiCheckpointMaximumBytes + 64 * 1024
