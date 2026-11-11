{-# LANGUAGE ImportQualifiedPost #-}

-- | One retained pair of SDK codec roots for the closed settings envelope.
-- Construction, function environments and runtime admission keep their own
-- funding obligations; sharing these roots grants no admission capability.
module Prodbox.ControlPlane.RpcBirthSettingsCodec
  ( rpcBirthSettingsDecoder
  , rpcBirthSettingsEncoder
  ) where

import Dhall qualified
import Prodbox.ControlPlane.RpcBirthSettingsEnvelope (SettingsEnvelope)

{-# NOINLINE rpcBirthSettingsDecoder #-}
rpcBirthSettingsDecoder :: Dhall.Decoder SettingsEnvelope
rpcBirthSettingsDecoder = Dhall.auto

{-# NOINLINE rpcBirthSettingsEncoder #-}
rpcBirthSettingsEncoder :: Dhall.Encoder SettingsEnvelope
rpcBirthSettingsEncoder = Dhall.inject
