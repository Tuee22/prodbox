{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36's effectful half of bounded legacy adoption.
--
-- The planner remains pure in 'LegacyAdoptionPlan'.  This module supplies its
-- observations only through the closed read-only Provider intent vocabulary.
-- It never accepts a discovered key: the requested family is derived from the
-- registry first, then every member is observed independently.  Transport,
-- coordinate, result-kind, and evidence failures become an exact
-- @Unobservable@ row for that member, so the planner refuses the whole family
-- instead of silently adopting a shorter one.
module Prodbox.Lifecycle.Teardown.LegacyAdoptionObserver
  ( LegacyAdoptionProviderObserver (..)
  , LegacyAdoptionObservationError (..)
  , observeAndPlanLegacyAdoption
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent
  , ProviderStackConfig
  )
import Prodbox.Lifecycle.Teardown.AwsEbsAdapter
  ( AwsEbsAdapterError
  , awsEbsObservationRequestProviderIntent
  , decodeExactAwsEbsObservation
  , mkExactAwsEbsObservationRequest
  )
import Prodbox.Lifecycle.Teardown.AwsIamRoleFamilyAdapter
  ( AwsIamRoleFamilyAdapterError
  , awsIamRoleFamilyObservationRequestProviderIntent
  , decodeExactAwsIamRoleFamilyObservation
  , mkExactAwsIamRoleFamilyObservationRequest
  )
import Prodbox.Lifecycle.Teardown.AwsLoadBalancerControllerFamilyAdapter
  ( AwsLoadBalancerControllerFamilyAdapterError
  , awsLoadBalancerControllerFamilyObservationRequestProviderIntent
  , decodeExactAwsLoadBalancerControllerFamilyObservation
  , mkExactAwsLoadBalancerControllerFamilyObservationRequest
  )
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( AwsNativeStackFamilyAdapterError
  , awsNativeStackFamilyObservationRequestIntent
  , decodeAwsNativeStackFamilyObservation
  , mkAwsNativeStackFamilyObservationRequest
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( LegacyAdoptionPlan
  , LegacyAdoptionRefusal
  , legacyAdoptionExpectedFamily
  , planLegacyAdoption
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

newtype LegacyAdoptionProviderObserver m = LegacyAdoptionProviderObserver
  { runLegacyAdoptionProviderObservation
      :: ProviderIntent
      -> m (Either Text ProviderIntentExecutionResult)
  }

data LegacyAdoptionObservationError
  = LegacyAdoptionStackRequestInvalid
      !RegisteredResourceKey
      !AwsNativeStackFamilyAdapterError
  | LegacyAdoptionEbsRequestInvalid !AwsEbsAdapterError
  | LegacyAdoptionIamRoleFamilyRequestInvalid !AwsIamRoleFamilyAdapterError
  | LegacyAdoptionLoadBalancerControllerFamilyRequestInvalid
      !AwsLoadBalancerControllerFamilyAdapterError
  | LegacyAdoptionObservationKeyUnsupported !RegisteredResourceKey
  | LegacyAdoptionPlanRefused !LegacyAdoptionRefusal
  deriving (Eq, Show)

observeAndPlanLegacyAdoption
  :: (Monad m)
  => CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationRevision
  -> ProviderStackConfig
  -> LegacyAdoptionProviderObserver m
  -> m (Either LegacyAdoptionObservationError (LegacyAdoptionPlan surface))
observeAndPlanLegacyAdoption surface stackKey scope revision config observer = do
  case lookupRegisteredIdentity stackKey of
    Just identity | registeredIdentityKind identity == Stack -> do
      observed <- traverse observeOne (legacyAdoptionExpectedFamily stackKey)
      pure $ do
        rows <- sequence observed
        either
          (Left . LegacyAdoptionPlanRefused)
          Right
          (planLegacyAdoption surface stackKey scope rows)
    _ -> pure (Left (LegacyAdoptionObservationKeyUnsupported stackKey))
 where
  dispatch = runLegacyAdoptionProviderObservation observer

  observeOne key = case lookupRegisteredIdentity key of
    Just identity | registeredIdentityKind identity == Stack -> do
      case mkAwsNativeStackFamilyObservationRequest key scope revision config of
        Left err -> pure (Left (LegacyAdoptionStackRequestInvalid key err))
        Right request -> do
          result <- dispatch (awsNativeStackFamilyObservationRequestIntent request)
          pure
            ( Right
                ( case decodeAwsNativeStackFamilyObservation request result of
                    Left err -> unobservableFor identity (Text.pack (show err))
                    Right exact -> exact
                )
            )
    Just identity
      | registeredIdentityKind identity == VolumeFamily
      , key == AwsEbsPerRunTestKey ->
          case mkExactAwsEbsObservationRequest surface revision scope of
            Left err -> pure (Left (LegacyAdoptionEbsRequestInvalid err))
            Right request -> do
              result <- dispatch (awsEbsObservationRequestProviderIntent request)
              pure
                ( Right
                    ( case decodeExactAwsEbsObservation request result of
                        Right exact -> exact
                        Left err -> unobservableFor identity (Text.pack (show err))
                    )
                )
    Just identity
      | registeredIdentityKind identity == ControllerFamily
      , key == AwsEksIamRoleFamilyKey ->
          case mkExactAwsIamRoleFamilyObservationRequest surface revision scope of
            Left err ->
              pure (Left (LegacyAdoptionIamRoleFamilyRequestInvalid err))
            Right request -> do
              result <-
                dispatch (awsIamRoleFamilyObservationRequestProviderIntent request)
              pure
                ( Right
                    ( case decodeExactAwsIamRoleFamilyObservation request result of
                        Right exact -> exact
                        Left err -> unobservableFor identity (Text.pack (show err))
                    )
                )
    Just identity
      | registeredIdentityKind identity == ControllerFamily
      , key == AwsEksLoadBalancerControllerFamilyKey ->
          case mkExactAwsLoadBalancerControllerFamilyObservationRequest
            surface
            revision
            scope of
            Left err ->
              pure
                ( Left
                    ( LegacyAdoptionLoadBalancerControllerFamilyRequestInvalid
                        err
                    )
                )
            Right request -> do
              result <-
                dispatch
                  ( awsLoadBalancerControllerFamilyObservationRequestProviderIntent
                      request
                  )
              pure
                ( Right
                    ( case decodeExactAwsLoadBalancerControllerFamilyObservation
                        request
                        result of
                        Right exact -> exact
                        Left err -> unobservableFor identity (Text.pack (show err))
                    )
                )
    _ -> pure (Left (LegacyAdoptionObservationKeyUnsupported key))

  unobservableFor identity detail =
    exactResourceObservationFor
      identity
      revision
      scope
      (ExactResourceUnobservable (ObservationFailure detail :| []))
