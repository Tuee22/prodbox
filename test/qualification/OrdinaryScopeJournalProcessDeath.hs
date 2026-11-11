{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli))
import Prodbox.ControlPlane.RequestAuthentication (mkSigningKeyGeneration)
import Prodbox.Lifecycle.Authority.Config (ConfigDigest (ConfigDigest))
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CleanupRun (mkCleanupRunId)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.Teardown.OrdinaryScopeJournal
import Prodbox.Subprocess.SystemdIdentity
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [mode, root, digest, sequenceLabel]
      | mode `elem` ["observe", "bind"]
          && digest `elem` ["a", "b"]
          && sequenceLabel `elem` ["1", "2"] ->
          run mode root digest sequenceLabel
    _ -> fail "expected mode, owned synthetic root, public digest, operation sequence"

run :: String -> FilePath -> String -> String -> IO ()
run mode root digest sequenceLabel = do
  binding <- fixture
  let program = Bytes.replicate 64 (if digest == "a" then 97 else 98)
      operation =
        OperationId
          authorityEpochGenesis
          (ClientId "synthetic-journal-client")
          (ClientSequence (if sequenceLabel == "1" then 1 else 2))
          (RequestDigest (Text.replicate 64 "c"))
  result <- withOrdinaryScopeJournal root $ \journal -> do
    prepared <- prepareBoundOrdinaryScopeSubmission journal binding program
    case prepared of
      Left cause -> pure (Left cause)
      Right prior -> case mode of
        "observe" -> pure (Right prior)
        "bind" -> do
          bound <- bindOrdinaryScopeOperation journal binding operation
          case bound of
            Left cause -> pure (Left cause)
            Right () -> prepareBoundOrdinaryScopeSubmission journal binding program
        _ -> fail "unknown synthetic journal mode"
  case result of
    Left cause -> refused cause
    Right (Left cause) -> refused cause
    Right (Right Nothing) -> putStrLn "none"
    Right (Right (Just observed)) -> putStrLn ("operation:" <> show (operationIdSequence observed))

refused :: OrdinaryScopeJournalError -> IO value
refused cause = do
  print cause
  exitWith
    ( ExitFailure
        (case cause of ScopeJournalProgramConflict -> 4; ScopeJournalOperationConflict -> 5; _ -> 6)
    )

fixture :: IO OrdinaryScopeBinding
fixture = do
  runId <- right (mkCleanupRunId "synthetic-journal-crash")
  key <- present (hostExecutionKeyFromText (replicate 64 'a'))
  window <- present (hostExecutionWindow 20000000000 15000000000 16000000000 17000000000 18000000000)
  domain <-
    present
      ( hostManagerDomain
          "12345678-1234-1234-1234-123456789abc"
          "123456789abcdef0123456789abcdef0"
          ":1.2"
          1000
          42
          11
      )
  generation <- right (mkSigningKeyGeneration 1)
  right
    ( mkOrdinaryScopeBinding
        runId
        key
        window
        domain
        (authorityTimeFromMicros 9000000000)
        (ConfigDigest (Text.replicate 64 "a"))
        (Bytes.replicate 32 7)
        CallerOperatorCli
        generation
        (Bytes.replicate 32 9)
    )

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

present :: Maybe value -> IO value
present = maybe (fail "invalid synthetic fixture") pure
