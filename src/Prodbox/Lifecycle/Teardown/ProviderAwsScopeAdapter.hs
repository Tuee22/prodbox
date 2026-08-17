{-# LANGUAGE OverloadedStrings #-}

-- | Closed lifecycle proof that the Provider Worker observed its own AWS
-- account and sealed credential region under one exact admitted operation.
-- Raw Provider results are deliberately insufficient: only an opaque
-- 'ExecutedProviderIntent' can be decoded into this proof.
module Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter
  ( providerAwsScopeIntent
  , providerAwsScopeIntentCoordinate
  , VerifiedProviderAwsScope
  , verifiedProviderAwsScopeAccountId
  , verifiedProviderAwsScopeRegion
  , verifiedProviderAwsScopeRevision
  , verifiedProviderAwsScopeOperationId
  , verifiedProviderAwsScopeCoordinate
  , decodeVerifiedProviderAwsScope
  , ProviderAwsScopeAdapterError (..)
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ExecutedProviderIntent
  , ProviderIntentExecutionResult (..)
  , executedProviderIntentAction
  , executedProviderIntentCoordinate
  , executedProviderIntentOperationId
  , executedProviderIntentResult
  , executedProviderIntentRevision
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderRevision
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal
  ( decodeProviderAwsScopeEvidence
  )

providerAwsScopeIntent :: ProviderIntent
providerAwsScopeIntent = ObserveProviderAwsScope

providerAwsScopeIntentCoordinate :: ProviderIntentCoordinate
providerAwsScopeIntentCoordinate = providerIntentCoordinate providerAwsScopeIntent

-- | Opaque, operation-bound Provider AWS scope.  There is intentionally no
-- accessor that converts these fields into an 'AwsScope': that later promotion
-- also needs Lifecycle-Authority admission and exact run/foundation scope.
data VerifiedProviderAwsScope = VerifiedProviderAwsScope
  { internalVerifiedProviderAwsScopeAccountId :: !AwsAccountId
  , internalVerifiedProviderAwsScopeRegion :: !AwsRegion
  , internalVerifiedProviderAwsScopeRevision :: !ProviderRevision
  , internalVerifiedProviderAwsScopeOperationId :: !Text
  , internalVerifiedProviderAwsScopeCoordinate :: !ProviderIntentCoordinate
  }

verifiedProviderAwsScopeAccountId
  :: VerifiedProviderAwsScope -> AwsAccountId
verifiedProviderAwsScopeAccountId = internalVerifiedProviderAwsScopeAccountId

verifiedProviderAwsScopeRegion :: VerifiedProviderAwsScope -> AwsRegion
verifiedProviderAwsScopeRegion = internalVerifiedProviderAwsScopeRegion

verifiedProviderAwsScopeRevision
  :: VerifiedProviderAwsScope -> ProviderRevision
verifiedProviderAwsScopeRevision = internalVerifiedProviderAwsScopeRevision

verifiedProviderAwsScopeOperationId :: VerifiedProviderAwsScope -> Text
verifiedProviderAwsScopeOperationId = internalVerifiedProviderAwsScopeOperationId

verifiedProviderAwsScopeCoordinate
  :: VerifiedProviderAwsScope -> ProviderIntentCoordinate
verifiedProviderAwsScopeCoordinate = internalVerifiedProviderAwsScopeCoordinate

data ProviderAwsScopeAdapterError
  = ProviderAwsScopeIntentMismatch !ProviderIntent
  | ProviderAwsScopeCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | ProviderAwsScopeResultKindMismatch
  | ProviderAwsScopeEvidenceInvalid !Text
  deriving (Eq, Show)

-- | Promote only the exact read-only scope intent and its exact observed
-- terminal result.  Admission-bound operation/revision metadata comes from
-- the opaque execution value, never from caller fields.
decodeVerifiedProviderAwsScope
  :: ExecutedProviderIntent
  -> Either ProviderAwsScopeAdapterError VerifiedProviderAwsScope
decodeVerifiedProviderAwsScope executed = do
  let action = executedProviderIntentAction executed
  if action == providerAwsScopeIntent
    then Right ()
    else Left (ProviderAwsScopeIntentMismatch action)
  let expectedCoordinate = providerAwsScopeIntentCoordinate
      actualCoordinate = executedProviderIntentCoordinate executed
  if actualCoordinate == expectedCoordinate
    then Right ()
    else
      Left
        ( ProviderAwsScopeCoordinateMismatch
            expectedCoordinate
            actualCoordinate
        )
  evidence <- case executedProviderIntentResult executed of
    ProviderIntentExecutionObserved coordinate payload
      | coordinate == expectedCoordinate -> Right payload
      | otherwise ->
          Left
            ( ProviderAwsScopeCoordinateMismatch
                expectedCoordinate
                coordinate
            )
    ProviderIntentExecutionApplied {} -> Left ProviderAwsScopeResultKindMismatch
    ProviderIntentExecutionAlreadySatisfied {} ->
      Left ProviderAwsScopeResultKindMismatch
  (accountId, region) <-
    either
      (Left . ProviderAwsScopeEvidenceInvalid . Text.pack . show)
      Right
      (decodeProviderAwsScopeEvidence evidence)
  Right
    VerifiedProviderAwsScope
      { internalVerifiedProviderAwsScopeAccountId = AwsAccountId accountId
      , internalVerifiedProviderAwsScopeRegion = AwsRegion region
      , internalVerifiedProviderAwsScopeRevision =
          executedProviderIntentRevision executed
      , internalVerifiedProviderAwsScopeOperationId =
          executedProviderIntentOperationId executed
      , internalVerifiedProviderAwsScopeCoordinate = expectedCoordinate
      }
