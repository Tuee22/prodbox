{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The coordinator's source-file boundary delegates every operation to the
-- canonical descriptor-opened Tier-0 lock/validation/fsync/readback owner.
module Prodbox.ControlPlane.RpcAdmissionBirthPublication
  ( tier0RpcBirthPublicationAtPath
  ) where

import Data.Text (Text)
import Prodbox.Config.Tier0
  ( compareAndSwapTier0RpcRegistrationAtPath
  , observeTier0RpcRegistrationAtPath
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RpcAdmissionBirth (RpcBirthDescriptor)
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator (RpcBirthPublicationEffects (..))
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import System.Timeout (timeout)

-- | The supplied rollout remains a separate physical interpreter: it must own
-- and bound its subprocess tree. This factory does not mint rollout evidence.
tier0RpcBirthPublicationAtPath
  :: AuthorityScope
  -> FilePath
  -> (AuthorityTime -> RpcBirthDescriptor -> IO (Either Text ()))
  -> RpcBirthPublicationEffects IO
tier0RpcBirthPublicationAtPath scope path reconcile =
  RpcBirthPublicationEffects
    { coordinationReadSource = \deadline -> within deadline readSource
    , coordinationPublishSource = publishSource
    , coordinationReconcileRuntime = reconcile
    }
 where
  publishSource deadline expected desired = case (expected, desired) of
    (RpcBirthConfigLegacy, registered@(RpcBirthConfigRegistered _)) ->
      case validateRpcBirthConfig LifecycleAuthorityRuntime scope registered of
        Left _ -> pure (Left "registration publication pin does not match the requested Authority")
        Right _ -> within deadline $ do
          observed <- readSource
          case observed of
            Left cause -> pure (Left cause)
            Right actual
              | actual /= expected && actual /= desired ->
                  pure (Left "registration source changed before publication")
              | otherwise -> do
                  written <- compareAndSwapTier0RpcRegistrationAtPath path expected desired
                  -- The canonical writer already confirms durability/readback;
                  -- the coordinator independently observes the source again.
                  pure (either (const (Left "canonical registration publication was not confirmed")) Right written)
    _ -> pure (Left "registration publication cannot remove or replace a pin")

  readSource = do
    observed <- observeTier0RpcRegistrationAtPath path
    pure $ case observed of
      Left _ -> Left "canonical registration source is unavailable or invalid"
      Right (actualScope, pin)
        | actualScope == scope -> Right pin
        | otherwise -> Left "registration source belongs to a different Authority"

  within deadline action = do
    before <- rpcBirthSystemTime
    if before >= deadline
      then pure (Left "registration source deadline reached")
      else do
        let remaining = authorityTimeMicros deadline - authorityTimeMicros before
            micros = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
        attempted <- timeout micros action
        after <- rpcBirthSystemTime
        pure $
          if after >= deadline
            then Left "registration source deadline reached"
            else maybe (Left "registration source observation timed out") id attempted
