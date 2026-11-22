{-# LANGUAGE OverloadedStrings #-}

-- | Protected unlock: the operator supplies Vault's unseal key at a hidden
-- prompt (or one line of standard input), and nothing else holds it. This path
-- never reads the environment's MinIO or its unlock object, so it works while
-- MinIO is down and cannot be satisfied by the test-only self-unseal material.
-- Absent input is a distinct 'ProtectedNeedsInput' result that changes
-- nothing: the Vault state is read first, so a prompt appears only when Vault
-- is initialized and sealed, and an empty answer never reaches Vault. The key
-- is only bytes in memory and the standard input of the command that sends it;
-- it is never printed, logged or placed in an argument vector or an error.
module Prodbox.Control.ProtectedUnlock
  ( ProtectedOutcome (..)
  , protectedUnlock
  , renderProtectedOutcome
  ) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapScope)
import Prodbox.Config.DeploymentScope (scopeRoot)
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.Control.OperatorInput (readSecretLine)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data ProtectedOutcome
  = ProtectedUnsealed String
  | ProtectedAlreadyUnsealed
  | ProtectedNeedsInput String
  | ProtectedRefused String
  deriving (Eq, Show)

renderProtectedOutcome :: ProtectedOutcome -> (Bool, String)
renderProtectedOutcome outcome = case outcome of
  ProtectedUnsealed detail -> (True, "Vault unsealed with the operator-supplied key. " ++ detail ++ "\n")
  ProtectedAlreadyUnsealed -> (True, "Vault was already unsealed; no key was requested.\n")
  ProtectedNeedsInput detail -> (False, "Needs input: " ++ detail ++ "\n")
  ProtectedRefused detail -> (False, "Refused: " ++ detail ++ "\n")

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits (64 * 1024) (256 * 1024) (64 * 1024) 60000000

protectedUnlock :: BootstrapProjection -> IO ProtectedOutcome
protectedUnlock bootstrap = do
  let kubeconfig = scopeRoot (bootstrapScope bootstrap) </> "control" </> "kubeconfig"
      kubectl arguments input = do
        result <-
          captureSubprocessWithInputBounded
            limits
            input
            ( Subprocess
                "/usr/bin/kubectl"
                (["--kubeconfig", kubeconfig, "--request-timeout=30s"] ++ arguments)
                (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                Nothing
            )
        pure $ case result of
          Right output ->
            Right
              ( case processExitCode output of
                  ExitSuccess -> 0 :: Int
                  ExitFailure code -> code
              , ByteString8.pack (processStdout output)
              , processStderr output
              )
          Left failure -> Left (show failure)
  present <- doesFileExist kubeconfig
  if not present
    then
      pure
        ( ProtectedRefused
            "no installed cluster credential; run `control reconcile` and `control services` first"
        )
    else do
      health <-
        kubectl
          [ "get"
          , "--raw"
          , "/api/v1/namespaces/"
              ++ managementNamespace
              ++ "/pods/vault:8200/proxy/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
          ]
          ByteString.empty
      case health of
        Right (0, out, _) -> case Aeson.decodeStrict out of
          Just (Aeson.Object fields) -> case ( KeyMap.lookup (Key.fromString "initialized") fields
                                             , KeyMap.lookup (Key.fromString "sealed") fields
                                             ) of
            (Just (Aeson.Bool False), _) -> pure (ProtectedRefused "Vault is not initialized; protected unlock does not initialize it")
            (Just (Aeson.Bool True), Just (Aeson.Bool False)) -> pure ProtectedAlreadyUnsealed
            (Just (Aeson.Bool True), Just (Aeson.Bool True)) -> sealed kubectl
            _ -> pure (ProtectedRefused "Vault's health answer did not state initialized and sealed")
          _ -> pure (ProtectedRefused "Vault's health answer was not JSON")
        Right (code, _, err) ->
          pure (ProtectedRefused ("Vault is not reachable (read exit " ++ show code ++ "): " ++ take 120 err))
        Left failure -> pure (ProtectedRefused failure)
 where
  sealed kubectl = do
    supplied <- readSecretLine "Vault unseal key: "
    case supplied of
      Nothing ->
        pure
          ( ProtectedNeedsInput
              "Vault is initialized and sealed; provide the unseal key at the prompt or on standard input. Nothing was changed."
          )
      Just key -> do
        result <-
          kubectl
            [ "-n"
            , managementNamespace
            , "exec"
            , "-i"
            , "vault"
            , "--"
            , "env"
            , "VAULT_ADDR=http://127.0.0.1:8200"
            , "vault"
            , "write"
            , "sys/unseal"
            , "key=-"
            ]
            key
        pure $ case result of
          Right (0, _, _) -> ProtectedUnsealed "MinIO and its unlock object were not consulted."
          Right (code, _, err) ->
            ProtectedRefused
              ("Vault refused the supplied key (exit " ++ show code ++ "): " ++ take 120 (filter (/= '\n') err))
          Left failure -> ProtectedRefused failure
