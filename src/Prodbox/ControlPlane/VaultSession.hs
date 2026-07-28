{-# LANGUAGE OverloadedStrings #-}

-- | Cached Kubernetes-auth Vault session for a standing control-plane role.
--
-- The configuration is validated against the executable role before any token
-- file is read. The login callback re-reads the projected ServiceAccount JWT on
-- renewal, so Kubernetes token rotation is honored without a per-request login.
module Prodbox.ControlPlane.VaultSession
  ( ControlPlaneVaultConfig
  , ControlPlaneVaultConfigError (..)
  , mkControlPlaneVaultConfig
  , controlPlaneVaultAddress
  , controlPlaneVaultAuthPath
  , controlPlaneVaultRole
  , controlPlaneVaultTokenFile
  , newControlPlaneVaultSession
  )
where

import Control.Exception (IOException, displayException, try)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Prodbox.Runtime.Role
  ( RuntimeRole
      ( AuthorityBackupRuntime
      , LifecycleAuthorityRuntime
      , ProviderWorkerRuntime
      , TargetSecretAgentRuntime
      , TlsRetentionRuntime
      )
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , vaultKubernetesLoginWithLease
  , vaultLoginLeaseSeconds
  , vaultLoginRenewable
  , vaultLoginToken
  )
import Prodbox.Vault.RoleId
  ( VaultRoleId
      ( VaultRoleAuthorityBackup
      , VaultRoleLifecycleAuthority
      , VaultRoleProviderWorker
      , VaultRoleTargetSecretAgent
      , VaultRoleTlsRetention
      )
  , vaultRoleIdText
  )
import Prodbox.Vault.Session
  ( LoginLease (..)
  , VaultSession
  , VaultSessionError (VaultSessionUnavailable)
  , httpErrorToSessionError
  , newVaultSession
  , realSessionClock
  )

data ControlPlaneVaultConfig = ControlPlaneVaultConfig
  { internalControlPlaneVaultAddress :: !VaultAddress
  , internalControlPlaneVaultAuthPath :: !Text
  , internalControlPlaneVaultRole :: !Text
  , internalControlPlaneVaultTokenFile :: !FilePath
  }

data ControlPlaneVaultConfigError
  = ControlPlaneVaultRoleUnsupported
  | ControlPlaneVaultAddressEmpty
  | ControlPlaneVaultAuthPathEmpty
  | ControlPlaneVaultRoleMismatch !Text !Text
  | ControlPlaneVaultTokenFileEmpty
  deriving (Eq, Show)

mkControlPlaneVaultConfig
  :: RuntimeRole
  -> Text
  -> Text
  -> Text
  -> FilePath
  -> Either ControlPlaneVaultConfigError ControlPlaneVaultConfig
mkControlPlaneVaultConfig runtimeRole address authPath configuredRole tokenFile = do
  expectedRole <-
    maybe
      (Left ControlPlaneVaultRoleUnsupported)
      Right
      (expectedVaultRole runtimeRole)
  let normalizedAddress = Text.strip address
      normalizedAuthPath = Text.strip authPath
      normalizedRole = Text.strip configuredRole
  if Text.null normalizedAddress
    then Left ControlPlaneVaultAddressEmpty
    else
      if Text.null normalizedAuthPath
        then Left ControlPlaneVaultAuthPathEmpty
        else
          if normalizedRole /= expectedRole
            then Left (ControlPlaneVaultRoleMismatch expectedRole normalizedRole)
            else
              if null tokenFile
                then Left ControlPlaneVaultTokenFileEmpty
                else
                  Right
                    ControlPlaneVaultConfig
                      { internalControlPlaneVaultAddress =
                          VaultAddress normalizedAddress
                      , internalControlPlaneVaultAuthPath = normalizedAuthPath
                      , internalControlPlaneVaultRole = normalizedRole
                      , internalControlPlaneVaultTokenFile = tokenFile
                      }

controlPlaneVaultAddress :: ControlPlaneVaultConfig -> VaultAddress
controlPlaneVaultAddress = internalControlPlaneVaultAddress

controlPlaneVaultAuthPath :: ControlPlaneVaultConfig -> Text
controlPlaneVaultAuthPath = internalControlPlaneVaultAuthPath

controlPlaneVaultRole :: ControlPlaneVaultConfig -> Text
controlPlaneVaultRole = internalControlPlaneVaultRole

controlPlaneVaultTokenFile :: ControlPlaneVaultConfig -> FilePath
controlPlaneVaultTokenFile = internalControlPlaneVaultTokenFile

newControlPlaneVaultSession
  :: ControlPlaneVaultConfig -> IO VaultSession
newControlPlaneVaultSession config =
  newVaultSession
    (controlPlaneVaultAddress config)
    realSessionClock
    login
 where
  login = do
    jwtResult <- readProjectedJwt (controlPlaneVaultTokenFile config)
    case jwtResult of
      Left detail -> pure (Left (VaultSessionUnavailable detail))
      Right jwt -> do
        result <-
          vaultKubernetesLoginWithLease
            (controlPlaneVaultAddress config)
            (controlPlaneVaultAuthPath config)
            (controlPlaneVaultRole config)
            jwt
        pure $ case result of
          Left err -> Left (httpErrorToSessionError err)
          Right lease ->
            Right
              LoginLease
                { loginLeaseToken = vaultLoginToken lease
                , loginLeaseSeconds = vaultLoginLeaseSeconds lease
                , loginLeaseRenewable = vaultLoginRenewable lease
                }

readProjectedJwt :: FilePath -> IO (Either String Text)
readProjectedJwt tokenFile = do
  result <- try (TextIO.readFile tokenFile) :: IO (Either IOException Text)
  pure $ case result of
    Left err ->
      Left
        ( "failed to read projected ServiceAccount token: "
            ++ displayException err
        )
    Right raw ->
      let token = Text.strip raw
       in if Text.null token
            then Left "projected ServiceAccount token is empty"
            else Right token

expectedVaultRole :: RuntimeRole -> Maybe Text
expectedVaultRole role = case role of
  LifecycleAuthorityRuntime ->
    Just (vaultRoleIdText VaultRoleLifecycleAuthority)
  ProviderWorkerRuntime -> Just (vaultRoleIdText VaultRoleProviderWorker)
  AuthorityBackupRuntime -> Just (vaultRoleIdText VaultRoleAuthorityBackup)
  TlsRetentionRuntime -> Just (vaultRoleIdText VaultRoleTlsRetention)
  TargetSecretAgentRuntime ->
    Just (vaultRoleIdText VaultRoleTargetSecretAgent)
  _ -> Nothing
