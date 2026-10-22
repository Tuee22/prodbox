{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Registered ordinary audit interpreter. Every query is a journalled,
-- cleanup-owned Provider read. It neither freezes the shared Provider epoch nor
-- borrows the cascade's pre-uninstall/revocation lane.
module Prodbox.Lifecycle.Teardown.PerRunTerminalAudit (observePerRunTerminalAudit) where

import Data.Bifunctor (first)
import Data.Either (lefts, rights)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityProviderEndpoint (providerExecutionOutcome)
import Prodbox.Lifecycle.AwsInventory (AwsTagRow (..), normalizeAwsTagRows)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent (ObserveProviderAwsScope))
import Prodbox.Lifecycle.Teardown.CascadeTerminalAuditAdapter
  ( decodeTerminalAuditQueryObservationForIntent
  )
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.PerRunTerminalAuditPlan
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter (decodeProviderAwsScopeResponse)
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.RetainedInventory (terminalAuditResultFor)

observePerRunTerminalAudit
  :: (Monad m)
  => TeardownProviderBoundary m
  -> TeardownExecutionContext 'ExplicitPerRun
  -> m (Either Text (TerminalAuditObservation 'ExplicitPerRun))
observePerRunTerminalAudit boundary context = case mkPerRunTerminalAuditPlan scope of
  Left detail -> pure (Left detail)
  Right plan -> case evidenceAwsScope scope of
    Nothing -> pure (Left "per-run terminal audit has no AWS scope")
    Just aws -> do
      identity <- observeActor aws
      case identity of
        Left detail -> pure (Left detail)
        Right () -> observeField aws plan
 where
  observeField aws plan = do
    answers <- traverse (issue aws) (perRunAuditPlanQueries plan)
    pure $ do
      inventory <-
        first (const "terminal audit responses conflict") (normalizeAwsTagRows (concat (rights answers)))
      let result = case terminalAuditResultFor (perRunAuditPlanCatalog plan) inventory of
            escaped@TerminalAuditFoundEscapes {} -> escaped
            TerminalAuditUnobservable observed failures -> TerminalAuditUnobservable observed (NonEmpty.prependList (lefts answers) failures)
            clean@TerminalAuditConfirmedClean {} -> case NonEmpty.nonEmpty (lefts answers) of
              Nothing -> clean
              Just failures -> TerminalAuditUnobservable inventory failures
      revision <-
        first
          (Text.pack . show)
          ( observationRevisionForProviderDispatchKey
              <$> mkProviderDispatchKey operationId ProviderTerminalAudit
          )
      Right (TerminalAuditObservation (perRunAuditPlanScope plan) revision result)
  scope = teardownExecutionObservationScope context
  operationId = teardownExecutionOperationId context
  issue aws query@(PerRunAuditQuery _ selector) =
    let intent = perRunAuditQueryProviderIntent query
     in case mkTerminalAuditProviderDispatchKey operationId intent of
          Left err -> pure (Left (ObservationFailure (Text.pack (show err))))
          Right key -> do
            result <- dispatchRegisteredProviderObservation boundary key intent
            -- Each endpoint validates its actual ARN region. The normalized
            -- inventory then carries the one audited field's owning AWS scope;
            -- the ARN still identifies the regional/global resource exactly.
            pure $
              fmap
                (map (\row -> row {awsTagRowScope = aws}))
                ( decodeTerminalAuditQueryObservationForIntent
                    (perRunAuditQueryAwsScope aws query)
                    selector
                    intent
                    (first (Text.pack . show) result)
                )

  observeActor aws = case mkTerminalAuditProviderDispatchKey operationId ObserveProviderAwsScope of
    Left err -> pure (Left (Text.pack (show err)))
    Right key -> do
      observed <- dispatchRegisteredProviderObservation boundary key ObserveProviderAwsScope
      pure $ do
        result <- first (Text.pack . show) observed
        (account, region) <- decodeProviderAwsScopeResponse (providerExecutionOutcome result)
        let AwsAccountId expectedAccount = awsScopeAccountId aws
            AwsRegion expectedRegion = awsScopeRegion aws
        if account == expectedAccount && region == expectedRegion
          then Right ()
          else Left "terminal audit Provider account/region differs from the retained run"
