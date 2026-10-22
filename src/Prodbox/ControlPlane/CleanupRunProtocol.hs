{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pure cleanup request DTOs; constructor order preserves existing wire bytes.
module Prodbox.ControlPlane.CleanupRunProtocol
  ( CleanupRunCommand (..)
  , CleanupRunDescriptorCommand (..)
  , isCleanupRunObservationRequest
  , cleanupRunMaximumBytes
  ) where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest)
import Prodbox.Lifecycle.CleanupRun.Outcome (CleanupNodeOutcome, CleanupPrimaryOutcome)

data CleanupRunCommand
  = CleanupRunCreate !Text !ByteString
  | CleanupRunObserve !Text
  | CleanupRunClaim !Text !Text !Natural !Natural
  | CleanupRunRecordPrimary !Text !Text !Natural !CleanupPrimaryOutcome
  | CleanupRunBeginNode !Text !Text !Natural !Text !Text
  | CleanupRunCompleteNode !Text !Text !Natural !Text !Text !CleanupNodeOutcome
  | CleanupRunScan
  | CleanupRunCompact !Text !Natural !Natural
  | CleanupRunDescriptorBound !CleanupRunDescriptorCommand
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupRunDescriptorCommand
  = CleanupRunDescriptorCreate !Text !ByteString
  | CleanupRunDescriptorObserve !Text
  | CleanupRunDescriptorClaim !Text !Text !Text !Natural !Natural
  | CleanupRunDescriptorRecordPrimary
      !Text
      !Text
      !Text
      !Natural
      !CleanupPrimaryOutcome
  | CleanupRunDescriptorBeginNode
      !Text
      !Text
      !Text
      !Natural
      !Text
      !Text
  | CleanupRunDescriptorCompleteNode
      !Text
      !Text
      !Text
      !Natural
      !Text
      !Text
      !CleanupNodeOutcome
  | CleanupRunDescriptorScan
  | CleanupRunDescriptorCompact !Text !Text !Natural !Natural
  | CleanupRunDescriptorReadBackProgram !Text
  | CleanupRunDescriptorObserveCompletion !Text !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cleanupRunMaximumBytes :: Int
cleanupRunMaximumBytes = 3 * 1024 * 1024

isCleanupRunObservationRequest :: ByteString -> Bool
isCleanupRunObservationRequest bytes =
  case decodeControlPlaneRequest cleanupRunMaximumBytes (LazyByteString.fromStrict bytes) of
    Right (CleanupRunDescriptorBound command) -> case command of
      CleanupRunDescriptorObserve _ -> True
      CleanupRunDescriptorObserveCompletion {} -> True
      CleanupRunDescriptorReadBackProgram _ -> True
      CleanupRunDescriptorCreate {} -> False
      CleanupRunDescriptorClaim {} -> False
      CleanupRunDescriptorRecordPrimary {} -> False
      CleanupRunDescriptorBeginNode {} -> False
      CleanupRunDescriptorCompleteNode {} -> False
      CleanupRunDescriptorScan -> False
      CleanupRunDescriptorCompact {} -> False
    _ -> False
