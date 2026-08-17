{-# LANGUAGE DerivingStrategies #-}

-- | Closed client facade over the Authority-owned EKS drain read-back
-- receipt repository.  Host executors depend on this algebra, never on the
-- retained Model-B adapter.  An authenticated transport can implement the
-- same record without exposing repository storage.
module Prodbox.ControlPlane.EksDrainReadBackReceiptClient
  ( EksDrainReadBackReceiptClient (..)
  , EksDrainReadBackReceiptClientError (..)
  , lifecycleAuthorityEksDrainReadBackReceiptClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientError)
import Prodbox.ControlPlane.Codec (ControlPlaneResponseCodecError)
import Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClient (..)
  , EksDrainIntentClientError (..)
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
  ( CommittedEksDrainReadBackReceipt
  , EksDrainReadBackReceiptError
  , EksDrainReadBackReceiptRepository
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository qualified as Repository
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( CommittedEksDrainIntent
  , EksDrainAttemptEvidence
  , EksDrainTargetReadBackObservation
  )

data EksDrainReadBackReceiptClient m = EksDrainReadBackReceiptClient
  { commitAndReadBackEksDrainReceipt
      :: CommittedEksDrainIntent
      -> EksDrainAttemptEvidence
      -> EksDrainTargetReadBackObservation
      -> m
           ( Either
               EksDrainReadBackReceiptClientError
               CommittedEksDrainReadBackReceipt
           )
  , readBackEksDrainReceipt
      :: CommittedEksDrainIntent
      -> m
           ( Either
               EksDrainReadBackReceiptClientError
               CommittedEksDrainReadBackReceipt
           )
  , commitCanonicalEksDrainReceiptFromIntentIdentity
      :: EksDrainIntentAuthorityIdentity
      -> ByteString
      -> m
           ( Either
               EksDrainReadBackReceiptClientError
               CommittedEksDrainReadBackReceipt
           )
  , recoverEksDrainReceiptFromIntentIdentity
      :: EksDrainIntentAuthorityIdentity
      -> m
           ( Either
               EksDrainReadBackReceiptClientError
               CommittedEksDrainReadBackReceipt
           )
  }

data EksDrainReadBackReceiptClientError
  = EksDrainReadBackReceiptClientRecoveryMissing
  | EksDrainReadBackReceiptClientIntentRecoveryFailed
      !EksDrainIntentClientError
  | EksDrainReadBackReceiptClientReceiptFailed
      !EksDrainReadBackReceiptError
  | EksDrainReadBackReceiptClientTransportFailed !AuthenticatedClientError
  | EksDrainReadBackReceiptClientResponseInvalid
      !ControlPlaneResponseCodecError
  | EksDrainReadBackReceiptClientHttpStatusMismatch !Int !Int
  | EksDrainReadBackReceiptClientRemoteRefused !Text
  | EksDrainReadBackReceiptClientRemoteUnavailable !Text
  | EksDrainReadBackReceiptClientRemoteProofInvalid !Text
  deriving stock (Eq, Show)

-- | Authority-local implementation.  Identity-only recovery first obtains
-- the committed intent from its retained Authority object, then locates the
-- receipt through the stable identity derived from that proof.  No attempt
-- ID, in-process evidence value, or side map is needed for lookup.
lifecycleAuthorityEksDrainReadBackReceiptClient
  :: (Monad m)
  => EksDrainIntentClient m
  -> EksDrainReadBackReceiptRepository m
  -> EksDrainReadBackReceiptClient m
lifecycleAuthorityEksDrainReadBackReceiptClient intentClient repository =
  EksDrainReadBackReceiptClient
    { commitAndReadBackEksDrainReceipt = \committed attempt observation ->
        fmap
          (first EksDrainReadBackReceiptClientReceiptFailed)
          ( Repository.commitAndReadBackEksDrainTargetsAbsentReceipt
              repository
              committed
              attempt
              observation
          )
    , readBackEksDrainReceipt = \committed ->
        fmap
          (first receiptRecoveryError)
          ( Repository.readBackCommittedEksDrainTargetsAbsentReceipt
              repository
              committed
          )
    , commitCanonicalEksDrainReceiptFromIntentIdentity =
        \identity bytes -> do
          recovered <- recoverCommittedEksDrainIntent intentClient identity
          case recovered of
            Left err ->
              pure
                (Left (intentRecoveryError err))
            Right committed ->
              case Repository.recoverEksDrainReadBackReceiptCommitRequest
                committed
                bytes of
                Left err ->
                  pure
                    (Left (EksDrainReadBackReceiptClientReceiptFailed err))
                Right request ->
                  fmap
                    (first EksDrainReadBackReceiptClientReceiptFailed)
                    ( Repository.commitPreparedAndReadBackEksDrainTargetsAbsentReceipt
                        repository
                        committed
                        request
                    )
    , recoverEksDrainReceiptFromIntentIdentity = \identity -> do
        recovered <- recoverCommittedEksDrainIntent intentClient identity
        case recovered of
          Left err ->
            pure
              (Left (intentRecoveryError err))
          Right committed ->
            fmap
              (first receiptRecoveryError)
              ( Repository.readBackCommittedEksDrainTargetsAbsentReceipt
                  repository
                  committed
              )
    }

intentRecoveryError
  :: EksDrainIntentClientError -> EksDrainReadBackReceiptClientError
intentRecoveryError err = case err of
  EksDrainIntentClientRecoveryMissing ->
    EksDrainReadBackReceiptClientRecoveryMissing
  _ -> EksDrainReadBackReceiptClientIntentRecoveryFailed err

receiptRecoveryError
  :: EksDrainReadBackReceiptError -> EksDrainReadBackReceiptClientError
receiptRecoveryError err = case err of
  Repository.EksDrainReadBackReceiptReadBackMissing ->
    EksDrainReadBackReceiptClientRecoveryMissing
  _ -> EksDrainReadBackReceiptClientReceiptFailed err
