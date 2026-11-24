{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Interactive authoring of a new, non-secret bootstrap document. This can
-- enroll a fresh test root; it does not install artifacts or authorize a cluster.
module Prodbox.Config.BootstrapSetup (runSelectedBootstrapSetup, runSelectedFreshTestBootstrapSetup) where

import Control.Exception (IOException, try)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.CLI.Command (PlanOptions (..))
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutput, writeOutputLine)
import Prodbox.Config.BootstrapProjection
  ( BootstrapDraft (..)
  , BootstrapDraftPublicationError (..)
  , BootstrapDraftRecovery (..)
  , prepareBootstrapRoot
  , publishBootstrapDraft
  , recoverBootstrapDraft
  )
import Prodbox.Config.DeploymentScope (FreshScopeResult (..))
import Prodbox.Config.SelectedDhall (SelectedDhallPublication (..))
import System.Exit (ExitCode (..))
import System.IO (hFlush, isEOF, stdout)
import Text.Read (readMaybe)

-- | The test harness may create a new test identity, but it must never adopt
-- an existing or incomplete root, even if that root matches its draft.
runSelectedFreshTestBootstrapSetup :: FilePath -> PlanOptions -> IO ExitCode
runSelectedFreshTestBootstrapSetup selected options
  | dryRun options || planFile options /= Nothing =
      refuse "Fresh test setup does not support plan options."
  | otherwise = do
      attempted <- try readDraft
      case attempted of
        Left (_ :: IOException) -> refuse "Fresh test bootstrap input ended or could not be read."
        Right (Left failure) -> refuse failure
        Right (Right draft)
          | draftEnvironment draft /= "test" -> refuse "Fresh test setup accepts only a test identity."
          | otherwise -> do
              enrolled <- prepareBootstrapRoot selected draft
              case enrolled of
                Right FreshScopePrepared -> do
                  published <- publishBootstrapDraft selected draft
                  case published of
                    Right () -> writeOutputLine "Fresh test root and bootstrap configuration published." >> pure ExitSuccess
                    Left failure -> refuse ("Fresh test root retained after publication failure: " ++ show failure)
                Right other -> refuse ("Fresh test root was not created: " ++ show other)
                Left failure -> refuse ("Fresh test root was not created: " ++ show failure)
 where
  refuse message = writeDiagnosticLine message >> pure (ExitFailure 1)

runSelectedBootstrapSetup :: FilePath -> PlanOptions -> IO ExitCode
runSelectedBootstrapSetup selected options
  | dryRun options || planFile options /= Nothing =
      refuse "Selected bootstrap setup does not support --dry-run or --plan-file yet."
  | otherwise = do
      attempted <- try readDraft
      case attempted of
        Left (_ :: IOException) -> refuse "Bootstrap input ended or could not be read."
        Right (Left failure) -> refuse failure
        Right (Right draft) -> do
          result <- publishBootstrapDraft selected draft
          final <- case result of
            Left BootstrapDraftRootUnavailable -> do
              choice <-
                try (prompt "Selected root unavailable; enroll a fresh root (yes/no)")
                  :: IO (Either IOException String)
              case choice of
                Right "yes" -> do
                  enrolled <- prepareBootstrapRoot selected draft
                  case enrolled of
                    Right FreshScopePrepared -> do
                      writeOutputLine "Fresh selected root enrolled. If publication fails, retain the root for recovery."
                      publishBootstrapDraft selected draft
                    Right other -> refuseEnrollment (show other)
                    Left failure -> pure (Left failure)
                _ -> pure result
            _ -> pure result
          case final of
            Left (BootstrapDraftPublication SelectedDhallPendingExists) ->
              offerRecovery
                selected
                draft
                "A pending publication exists; recover matching v2 document (yes/no)"
                final
            Left (BootstrapDraftPublication SelectedDhallDestinationExists) ->
              offerRecovery selected draft "A destination exists; verify it matches the draft (yes/no)" final
            _ -> finishPublication final
 where
  refuse message = writeDiagnosticLine message >> pure (ExitFailure 1)
  refuseEnrollment detail = do
    writeDiagnosticLine ("Fresh test root was not confirmed: " ++ detail)
    pure (Left BootstrapDraftRootUnavailable)
  finishPublication :: Either BootstrapDraftPublicationError () -> IO ExitCode
  finishPublication result = case result of
    Left failure -> refuse ("Bootstrap configuration was not confirmed: " ++ show failure)
    Right () -> do
      writeOutputLine
        "Bootstrap configuration published. Artifact bytes and runtime were not checked; no cluster was created."
      pure ExitSuccess
  offerRecovery path draft question original = do
    choice <- try (prompt question) :: IO (Either IOException String)
    case choice of
      Right "yes" -> do
        recovered <- recoverBootstrapDraft path draft
        case recovered of
          Left failure -> finishPublication (Left failure)
          Right BootstrapRecoveryPublished -> finishPublication (Right ())
          Right BootstrapRecoveryAlreadyMatches -> do
            writeOutputLine
              "Existing bootstrap configuration matches the draft; publication origin, artifact bytes and runtime remain unverified."
            pure ExitSuccess
      _ -> finishPublication original

readDraft :: IO (Either String BootstrapDraft)
readDraft = do
  values <- traverse prompt prompts
  case values of
    [ anchor
      , socket
      , environment
      , deployment
      , generation
      , api
      , image
      , httpHost
      , httpNode
      , httpsHost
      , httpsNode
      , address
      , nodePath
      , nodeDigest
      , nodeLimit
      , kindPath
      , kindDigest
      , kindLimit
      ] -> pure $ do
        apiPort <- natural "API port" api
        httpHostPort <- natural "HTTP host port" httpHost
        httpNodePort <- natural "HTTP node port" httpNode
        httpsHostPort <- natural "HTTPS host port" httpsHost
        httpsNodePort <- natural "HTTPS node port" httpsNode
        nodeBytes <- natural "node artifact maximum" nodeLimit
        kindBytes <- natural "kind tool maximum" kindLimit
        Right
          BootstrapDraft
            { draftProjectAnchor = Text.pack anchor
            , draftRuntimeSocket = Text.pack socket
            , draftEnvironment = Text.pack environment
            , draftDeploymentId = Text.pack deployment
            , draftRootGeneration = Text.pack generation
            , draftApiPort = apiPort
            , draftNodeImage = Text.pack image
            , draftHttpHostPort = httpHostPort
            , draftHttpNodePort = httpNodePort
            , draftHttpsHostPort = httpsHostPort
            , draftHttpsNodePort = httpsNodePort
            , draftListenAddress = Text.pack address
            , draftNodePath = Text.pack nodePath
            , draftNodeDigest = Text.pack nodeDigest
            , draftNodeMaximumBytes = nodeBytes
            , draftKindPath = Text.pack kindPath
            , draftKindDigest = Text.pack kindDigest
            , draftKindMaximumBytes = kindBytes
            }
    _ -> pure (Left "Bootstrap input was incomplete.")
 where
  natural label value = maybe (Left (label ++ " must be a Natural number.")) Right (readMaybe value :: Maybe Natural)

prompts :: [String]
prompts =
  [ "Absolute project anchor"
  , "Absolute Docker socket"
  , "Environment (production or test)"
  , "Deployment or run ID"
  , "Existing root generation (32 lowercase hexadecimal characters)"
  , "Kubernetes API host port"
  , "Digest-pinned kind node image"
  , "HTTP host port"
  , "HTTP node port"
  , "HTTPS host port"
  , "HTTPS node port"
  , "Publication listen IP"
  , "Node archive path relative to the deployment root"
  , "Node archive SHA-256 digest"
  , "Node archive maximum bytes"
  , "Kind executable path relative to the deployment root"
  , "Kind executable SHA-256 digest"
  , "Kind executable maximum bytes"
  ]

prompt :: String -> IO String
prompt label = do
  writeOutput (label ++ ": ")
  hFlush stdout
  readLineBounded 4096 []

readLineBounded :: Int -> String -> IO String
readLineBounded remaining reversed = do
  eof <- isEOF
  if eof
    then ioError (userError "input ended")
    else do
      character <- getChar
      if character == '\n'
        then pure (reverse reversed)
        else
          if remaining <= 0 || character == '\r' || character == '\0'
            then ioError (userError "invalid input line")
            else readLineBounded (remaining - 1) (character : reversed)
