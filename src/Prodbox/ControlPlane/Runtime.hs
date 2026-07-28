{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Fail-closed executable boundary for the physically separated control-plane
-- roles. Liveness means the role process is serving; readiness remains false
-- until the role's production interpreter is installed.
module Prodbox.ControlPlane.Runtime
  ( ControlPlaneConfigError (..)
  , validateControlPlaneConfig
  , runControlPlaneRole
  )
where

import Control.Concurrent (forkFinally)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forever, void)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import GHC.Generics (Generic)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import Numeric.Natural (Natural)
import Prodbox.CLI.Command
  ( ControlPlaneLaunchOptions (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.ControlPlane.Route (routesForRole)
import Prodbox.ControlPlane.Server
  ( failClosedInterpreter
  , renderHttpResponse
  , serveControlPlaneRequest
  )
import Prodbox.ControlPlane.VaultSession
  ( mkControlPlaneVaultConfig
  , newControlPlaneVaultSession
  )
import Prodbox.Runtime.Role (RuntimeRole, runtimeRoleName)
import Prodbox.Vault.Session (VaultSession)
import System.Exit (ExitCode (..))

data ControlPlaneConfig = ControlPlaneConfig
  { schema_version :: !Natural
  , runtime_role :: !Text
  , vault_address :: !Text
  , vault_auth_path :: !Text
  , vault_role :: !Text
  , service_account_token_file :: !Text
  }
  deriving (Generic, Show)

instance Dhall.FromDhall ControlPlaneConfig

data ControlPlaneConfigError
  = ControlPlaneConfigVersionUnsupported
  | ControlPlaneConfigRoleMismatch
  deriving (Eq, Show)

validateControlPlaneConfig
  :: RuntimeRole
  -> Natural
  -> Text
  -> Either ControlPlaneConfigError ()
validateControlPlaneConfig role version configuredRole
  | version /= 2 = Left ControlPlaneConfigVersionUnsupported
  | configuredRole /= Text.pack (runtimeRoleName role) =
      Left ControlPlaneConfigRoleMismatch
  | otherwise = Right ()

runControlPlaneRole :: RuntimeRole -> ControlPlaneLaunchOptions -> IO ExitCode
runControlPlaneRole role options = do
  decoded <- try (Dhall.inputFile Dhall.auto (controlPlaneConfigPath options))
  case decoded of
    Left (_ :: SomeException) -> pure (ExitFailure 1)
    Right config ->
      case validateControlPlaneConfig role (schema_version config) (runtime_role config) of
        Left _ -> pure (ExitFailure 1)
        Right () ->
          case mkControlPlaneVaultConfig
            role
            (vault_address config)
            (vault_auth_path config)
            (vault_role config)
            (Text.unpack (service_account_token_file config)) of
            Left _ ->
              pure (ExitFailure 1)
            Right vaultConfig -> do
              vaultSession <- newControlPlaneVaultSession vaultConfig
              runRolePlan role options vaultSession

runRolePlan
  :: RuntimeRole
  -> ControlPlaneLaunchOptions
  -> VaultSession
  -> IO ExitCode
runRolePlan role options vaultSession =
  runPlanWithOptions
    (controlPlanePlanOptions options)
    ( buildPlan
        ( \() ->
            unlines
              [ "CONTROL_PLANE_ROLE_START_PLAN"
              , "RUNTIME_ROLE=" ++ runtimeRoleName role
              , "CONFIG_PATH=" ++ controlPlaneConfigPath options
              , "CONFIG_SCHEMA_VERSION=2"
              , "CONFIG_RUNTIME_ROLE=" ++ runtimeRoleName role
              , "LISTENER=0.0.0.0:8600"
              , "ROLE_ROUTE_COUNT=" ++ show (length (routesForRole role))
              , "READINESS=fail-closed-until-interpreter-bound"
              ]
        )
        ()
    )
    (const (runFailClosedServer role vaultSession))

runFailClosedServer
  :: RuntimeRole
  -> VaultSession
  -> IO ExitCode
runFailClosedServer role _vaultSession =
  withSocketsDo $
    bracket open close $ \listener ->
      forever $ do
        (client, _) <- accept listener
        void $ forkFinally (serve role client) (const (close client))
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet 8600 (tupleToHostAddress (0, 0, 0, 0)))
    listen listener 32
    pure listener
  -- The role's production interpreter is not yet bound, so the shared
  -- fail-closed interpreter serves: liveness answers, readiness and every owned
  -- route fail closed. The classification/dispatch/response are the pure
  -- 'Prodbox.ControlPlane.Server' seam.
  serve activeRole client = do
    request <- recv client 4096
    (status, body) <- serveControlPlaneRequest failClosedInterpreter activeRole request
    sendAll client (renderHttpResponse status body)
