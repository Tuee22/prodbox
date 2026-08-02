{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Role-separated effect interpretation for the SES aggregate.
module Prodbox.Ses.Workflow.Interpreter
  ( ProviderWorkflowInterpreter (..)
  , OperatorMaterialWorkflowInterpreter (..)
  , CustodyWorkflowInterpreter (..)
  , AdminTeardownWorkflowInterpreter (..)
  , SesWorkflowInterpreters (..)
  , SesWorkflowEffectResult (..)
  , runSesWorkflowEffect
  )
where

import Data.Text (Text)
import Prodbox.Ses.Workflow.Model
  ( AdminTeardownEffect
  , CustodyEffect
  , OperatorMaterialEffect
  , ProviderEffect
  , SesWorkflowEffect (..)
  , SesWorkflowEvent
  )

-- Each interpreter accepts only its own closed effect family. This is the
-- static mutation fence: Provider code cannot receive credential work and the
-- Credential Provisioner cannot receive provider inventory work.
data ProviderWorkflowInterpreter m = ProviderWorkflowInterpreter
  { observeProviderWorkflowEffect :: ProviderEffect -> m (Either Text (Maybe SesWorkflowEvent))
  , applyProviderWorkflowEffect :: ProviderEffect -> m (Either Text ())
  }

data OperatorMaterialWorkflowInterpreter m = OperatorMaterialWorkflowInterpreter
  { observeOperatorMaterialWorkflowEffect
      :: OperatorMaterialEffect -> m (Either Text (Maybe SesWorkflowEvent))
  , applyOperatorMaterialWorkflowEffect :: OperatorMaterialEffect -> m (Either Text ())
  }

data CustodyWorkflowInterpreter m = CustodyWorkflowInterpreter
  { observeCustodyWorkflowEffect :: CustodyEffect -> m (Either Text (Maybe SesWorkflowEvent))
  , applyCustodyWorkflowEffect :: CustodyEffect -> m (Either Text ())
  }

data AdminTeardownWorkflowInterpreter m = AdminTeardownWorkflowInterpreter
  { observeAdminTeardownWorkflowEffect :: AdminTeardownEffect -> m (Either Text (Maybe Text))
  , applyAdminTeardownWorkflowEffect :: AdminTeardownEffect -> m (Either Text ())
  }

data SesWorkflowInterpreters m = SesWorkflowInterpreters
  { sesProviderWorkflowInterpreter :: !(ProviderWorkflowInterpreter m)
  , sesOperatorMaterialWorkflowInterpreter :: !(OperatorMaterialWorkflowInterpreter m)
  , sesCustodyWorkflowInterpreter :: !(CustodyWorkflowInterpreter m)
  , sesAdminTeardownWorkflowInterpreter :: !(AdminTeardownWorkflowInterpreter m)
  }

data SesWorkflowEffectResult
  = SesWorkflowEventResult !SesWorkflowEvent
  | SesWorkflowDestroyResult !Text
  deriving stock (Eq, Show)

runSesWorkflowEffect
  :: (Monad m)
  => SesWorkflowInterpreters m
  -> SesWorkflowEffect
  -> m (Either Text SesWorkflowEffectResult)
runSesWorkflowEffect interpreters effect = case effect of
  ProviderWork provider ->
    converge
      SesWorkflowEventResult
      (observeProviderWorkflowEffect interpreter provider)
      (applyProviderWorkflowEffect interpreter provider)
   where
    interpreter = sesProviderWorkflowInterpreter interpreters
  OperatorMaterialWork material ->
    converge
      SesWorkflowEventResult
      (observeOperatorMaterialWorkflowEffect interpreter material)
      (applyOperatorMaterialWorkflowEffect interpreter material)
   where
    interpreter = sesOperatorMaterialWorkflowInterpreter interpreters
  CustodyWork custody ->
    converge
      SesWorkflowEventResult
      (observeCustodyWorkflowEffect interpreter custody)
      (applyCustodyWorkflowEffect interpreter custody)
   where
    interpreter = sesCustodyWorkflowInterpreter interpreters
  AdminTeardownWork teardown ->
    converge
      SesWorkflowDestroyResult
      (observeAdminTeardownWorkflowEffect interpreter teardown)
      (applyAdminTeardownWorkflowEffect interpreter teardown)
   where
    interpreter = sesAdminTeardownWorkflowInterpreter interpreters

converge
  :: (Monad m)
  => (result -> SesWorkflowEffectResult)
  -> m (Either Text (Maybe result))
  -> m (Either Text ())
  -> m (Either Text SesWorkflowEffectResult)
converge wrap observe apply = do
  before <- observe
  case before of
    Left detail -> pure (Left detail)
    Right (Just result) -> pure (Right (wrap result))
    Right Nothing -> do
      applied <- apply
      case applied of
        Left _responseLostOrFailed -> confirm
        Right () -> confirm
 where
  confirm = do
    after <- observe
    pure $ case after of
      Left detail -> Left detail
      Right Nothing -> Left "SES workflow effect did not converge after apply"
      Right (Just result) -> Right (wrap result)
