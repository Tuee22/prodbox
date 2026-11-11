{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.ControlPlane.RpcAdmissionBirthConfig
  ( RpcBirthConfig (..)
  , RpcBirthConfigPin (..)
  , RpcBirthConfigError (..)
  , validateRpcBirthConfig
  , renderRpcBirthConfigDhall
  )
where

import Control.Monad (unless)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import Dhall.Core qualified as Core
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RpcAdmissionBirth
  ( RpcBirthServingMode
  , legacyRpcBirthServingMode
  , registeredRpcBirthServingMode
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data RpcBirthConfigPin = RpcBirthConfigPin
  { authority_scope :: !Text
  , generation :: !Natural
  , descriptor_digest :: !Text
  }
  deriving (Eq, Generic, Show)

instance Dhall.FromDhall RpcBirthConfigPin

instance Dhall.ToDhall RpcBirthConfigPin

data RpcBirthConfig
  = RpcBirthConfigLegacy
  | RpcBirthConfigRegistered !RpcBirthConfigPin
  deriving (Eq, Generic, Show)

instance Dhall.FromDhall RpcBirthConfig where
  autoWith _ = Dhall.genericAutoWith rpcBirthInterpretOptions

instance Dhall.ToDhall RpcBirthConfig where
  injectWith _ = Dhall.genericToDhallWith rpcBirthInterpretOptions

rpcBirthInterpretOptions :: Dhall.InterpretOptions
rpcBirthInterpretOptions =
  Dhall.defaultInterpretOptions
    { Dhall.constructorModifier = \value -> Text.copy (maybe value id (Text.stripPrefix "RpcBirthConfig" value))
    }

data RpcBirthConfigError
  = RpcBirthConfigRoleUnsupported
  | RpcBirthConfigScopeInvalid
  | RpcBirthConfigScopeMismatch
  | RpcBirthConfigPinInvalid
  deriving (Eq, Show)

validateRpcBirthConfig
  :: RuntimeRole -> AuthorityScope -> RpcBirthConfig -> Either RpcBirthConfigError RpcBirthServingMode
validateRpcBirthConfig role scope config = case config of
  RpcBirthConfigLegacy -> Right legacyRpcBirthServingMode
  RpcBirthConfigRegistered pin -> do
    unless (role == LifecycleAuthorityRuntime) (Left RpcBirthConfigRoleUnsupported)
    actual <-
      either (const (Left RpcBirthConfigScopeInvalid)) Right (mkAuthorityScope (authority_scope pin))
    unless (actual == scope) (Left RpcBirthConfigScopeMismatch)
    either
      (const (Left RpcBirthConfigPinInvalid))
      Right
      (registeredRpcBirthServingMode scope (generation pin) (descriptor_digest pin))

-- Config data are rendered as Dhall text literals; interpolations and control
-- characters never become executable imports or expressions.
renderRpcBirthConfigDhall :: RpcBirthConfig -> String
renderRpcBirthConfigDhall = Text.unpack . Core.pretty . Core.denote . Dhall.embed Dhall.inject
