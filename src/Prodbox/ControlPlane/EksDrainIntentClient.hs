{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed client over the Lifecycle Authority EKS drain-intent repository.
-- Every commit, including an exact replay or an ambiguous response, is
-- followed by an independent read-back.  Only the pure intent module can turn
-- that positive canonical observation into the opaque committed proof.
module Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClient (..)
  , EksDrainIntentClientError (..)
  , lifecycleAuthorityEksDrainIntentClient
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  , EksDrainIntentAuthorityReadBackObservation (..)
  , EksDrainIntentCommitRequestError
  , EksDrainIntentCommitResult
  , EksDrainIntentRepository (..)
  , eksDrainIntentAuthorityIdentity
  , eksDrainIntentCommitRequestIdentity
  , prepareEksDrainIntentCommitRequest
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( CommittedEksDrainIntent
  , EksDrainIntent
  , EksDrainIntentError
  , EksDrainIntentReadBackObservation (..)
  , confirmEksDrainIntentCommitted
  , decodeEksDrainIntent
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))

data EksDrainIntentClient m = EksDrainIntentClient
  { commitAndReadBackEksDrainIntent
      :: EksDrainIntent
      -> m (Either EksDrainIntentClientError CommittedEksDrainIntent)
  , readBackCommittedEksDrainIntent
      :: EksDrainIntent
      -> m (Either EksDrainIntentClientError CommittedEksDrainIntent)
  , recoverCommittedEksDrainIntent
      :: EksDrainIntentAuthorityIdentity
      -> m (Either EksDrainIntentClientError CommittedEksDrainIntent)
  }

data EksDrainIntentClientError
  = EksDrainIntentClientRequestInvalid !EksDrainIntentCommitRequestError
  | EksDrainIntentClientCommitUnconfirmed
      !EksDrainIntentCommitResult
      !EksDrainIntentError
  | EksDrainIntentClientReadBackInvalid !EksDrainIntentError
  | EksDrainIntentClientRecoveryMissing
  | EksDrainIntentClientRecoveryUnobservable !ObservationFailure
  | EksDrainIntentClientRecoveryUnbounded !Int !Int
  | EksDrainIntentClientRecoveryCorrupt !EksDrainIntentError
  | EksDrainIntentClientRecoveryStoreCorrupt !Text
  | EksDrainIntentClientRecoveryIdentityMismatch
      !EksDrainIntentAuthorityIdentity
      !EksDrainIntentAuthorityIdentity
  | EksDrainIntentClientRecoveryProofInvalid !EksDrainIntentError
  | EksDrainIntentClientTransportFailed !AuthenticatedClientError
  | EksDrainIntentClientResponseInvalid !ControlPlaneResponseCodecError
  | EksDrainIntentClientHttpStatusMismatch !Int !Int
  | EksDrainIntentClientRemoteRefused !Text
  | EksDrainIntentClientRemoteUnavailable !Text
  | EksDrainIntentClientRemoteProofInvalid !Text
  deriving stock (Eq, Show)

lifecycleAuthorityEksDrainIntentClient
  :: (Monad m)
  => EksDrainIntentRepository m
  -> EksDrainIntentClient m
lifecycleAuthorityEksDrainIntentClient repository =
  EksDrainIntentClient
    { commitAndReadBackEksDrainIntent = commitAndReadBack
    , readBackCommittedEksDrainIntent = readBackOnly
    , recoverCommittedEksDrainIntent = recoverOnly
    }
 where
  commitAndReadBack intent = case prepareEksDrainIntentCommitRequest intent of
    Left err -> pure (Left (EksDrainIntentClientRequestInvalid err))
    Right request -> do
      commitResult <- createOrReplayAuthorityEksDrainIntent repository request
      observation <-
        independentlyReadBackAuthorityEksDrainIntent
          repository
          (eksDrainIntentCommitRequestIdentity request)
      pure $ case confirmEksDrainIntentCommitted intent (intentObservation observation) of
        Left err ->
          Left (EksDrainIntentClientCommitUnconfirmed commitResult err)
        Right committed -> Right committed

  readBackOnly intent = do
    case prepareEksDrainIntentCommitRequest intent of
      Left err -> pure (Left (EksDrainIntentClientRequestInvalid err))
      Right request -> do
        observation <-
          independentlyReadBackAuthorityEksDrainIntent
            repository
            (eksDrainIntentCommitRequestIdentity request)
        pure $ case confirmEksDrainIntentCommitted intent (intentObservation observation) of
          Left err -> Left (EksDrainIntentClientReadBackInvalid err)
          Right committed -> Right committed

  recoverOnly expectedIdentity = do
    observation <-
      independentlyReadBackAuthorityEksDrainIntent
        repository
        expectedIdentity
    pure $ case observation of
      EksDrainIntentAuthorityReadBackMissing ->
        Left EksDrainIntentClientRecoveryMissing
      EksDrainIntentAuthorityReadBackUnobservable failure ->
        Left (EksDrainIntentClientRecoveryUnobservable failure)
      EksDrainIntentAuthorityReadBackUnbounded actual maximumAllowed ->
        Left
          ( EksDrainIntentClientRecoveryUnbounded
              actual
              maximumAllowed
          )
      EksDrainIntentAuthorityReadBackCorrupt detail ->
        Left (EksDrainIntentClientRecoveryStoreCorrupt detail)
      EksDrainIntentAuthorityReadBackPresent bytes -> case decodeEksDrainIntent bytes of
        Left err -> Left (EksDrainIntentClientRecoveryCorrupt err)
        Right observedIntent ->
          let observedIdentity = eksDrainIntentAuthorityIdentity observedIntent
           in if observedIdentity /= expectedIdentity
                then
                  Left
                    ( EksDrainIntentClientRecoveryIdentityMismatch
                        expectedIdentity
                        observedIdentity
                    )
                else case
                  confirmEksDrainIntentCommitted
                    observedIntent
                    (EksDrainIntentReadBackPresent bytes)
                of
                  Left err ->
                    Left (EksDrainIntentClientRecoveryProofInvalid err)
                  Right committed -> Right committed

  intentObservation observation = case observation of
    EksDrainIntentAuthorityReadBackPresent bytes ->
      EksDrainIntentReadBackPresent bytes
    EksDrainIntentAuthorityReadBackMissing ->
      EksDrainIntentReadBackMissing
    EksDrainIntentAuthorityReadBackCorrupt detail ->
      EksDrainIntentReadBackUnobservable
        (ObservationFailure ("Authority retained EKS drain intent corrupt: " <> detail))
    EksDrainIntentAuthorityReadBackUnobservable failure ->
      EksDrainIntentReadBackUnobservable failure
    EksDrainIntentAuthorityReadBackUnbounded actual maximumAllowed ->
      EksDrainIntentReadBackUnbounded actual maximumAllowed
