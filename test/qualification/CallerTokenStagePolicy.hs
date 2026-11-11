{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
import Prodbox.Subprocess
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (stderr, stdout)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["fixture", scenario, caller, stage] -> tool scenario caller stage
    _ ->
      defaultMain $
        testGroup
          "shared token stage policy"
          ( [ testCase (show caller <> "/" <> scenario) (check caller scenario)
            | caller <- [LifecycleAuthorityOperator, LifecycleAuthorityTestHarness]
            , scenario <-
                [ "ascii-limit"
                , "latin1-limit"
                , "stdout-over"
                , "stderr-limit"
                , "stderr-over"
                , "identity-mismatch"
                , "notfound"
                , "eligibility-refused"
                , "invalid-token"
                , "request-unavailable"
                ]
            ]
              <> [testCase "actual 30-second stage expiry" (check LifecycleAuthorityOperator "elapsed")]
          )

check :: ExternalLifecycleAuthorityCaller -> String -> IO ()
check caller scenario = do
  executable <- getExecutablePath
  stages <- newIORef []
  let run stage = do
        modifyIORef' stages (<> [stage])
        captureSubprocessBounded
          (externalCallerTokenStageLimits stage)
          Subprocess
            { subprocessPath = executable
            , subprocessArguments =
                [ "fixture"
                , scenario
                , if caller == LifecycleAuthorityOperator then "operator" else "harness"
                , stageName stage
                ]
            , subprocessEnvironment = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/synthetic-unused")]
            , subprocessWorkingDirectory = Nothing
            }
  result <- mintExternalCallerTokenUsing run caller
  case scenario of
    "ascii-limit" -> result @?= Right (Text.replicate 16384 "a")
    "latin1-limit" -> result @?= Right (Text.replicate 16384 "ÿ")
    "stdout-over" -> result @?= Left ExternalCallerTokenRequestSubprocessUnavailable
    "stderr-limit" -> result @?= Right "synthetic-unused"
    "stderr-over" -> result @?= Left ExternalCallerTokenRequestSubprocessUnavailable
    "identity-mismatch" -> assertBool "identity mismatch taxonomy lost" (identityMismatch result)
    "notfound" -> result @?= Left (ExternalCallerServiceAccountUnobservable ServiceAccountObservationAbsent)
    "eligibility-refused" -> result @?= Left ExternalCallerTokenEligibilityRefused
    "invalid-token" -> result @?= Left ExternalCallerTokenMalformed
    "request-unavailable" -> result @?= Left ExternalCallerTokenRequestApiUnreachable
    "elapsed" ->
      result
        @?= Left (ExternalCallerServiceAccountUnobservable ServiceAccountObservationSubprocessUnavailable)
    _ -> fail "unknown synthetic scenario"
  observed <- readIORef stages
  observed @?= take (stageCount scenario) tokenStages

tokenStages :: [ExternalCallerTokenStage]
tokenStages =
  [ ObserveExternalCallerServiceAccount
  , CheckExternalCallerTokenEligibility
  , RequestExternalCallerToken
  ]

identityMismatch :: Either ExternalCallerTokenError value -> Bool
identityMismatch result = case result of
  Left (ExternalCallerServiceAccountUnobservable ServiceAccountObservationIdentityMismatch {}) -> True
  _ -> False

stageCount :: String -> Int
stageCount scenario
  | scenario `elem` ["identity-mismatch", "notfound", "elapsed"] = 1
  | scenario == "eligibility-refused" = 2
  | otherwise = 3

stageName :: ExternalCallerTokenStage -> String
stageName stage = case stage of
  ObserveExternalCallerServiceAccount -> "service-account"
  CheckExternalCallerTokenEligibility -> "eligibility"
  RequestExternalCallerToken -> "token"

tool :: String -> String -> String -> IO ()
tool scenario caller stage = case stage of
  "service-account"
    | scenario == "elapsed" -> threadDelay 31000000
    | scenario == "notfound" -> Char8.hPutStr stderr "NotFound" >> exitWith (ExitFailure 1)
    | scenario == "identity-mismatch" -> Char8.hPutStr stdout "wrong"
    | otherwise ->
        Char8.hPutStr
          stdout
          ( if caller == "operator"
              then "bootstrap-broker\nprodbox-control-plane-operator\nfalse\n"
              else "gateway\nprodbox-control-plane-test-harness\nfalse\n"
          )
  "eligibility" -> Char8.hPutStr stdout (if scenario == "eligibility-refused" then "no" else "yes")
  "token" -> case scenario of
    "ascii-limit" -> Bytes.hPut stdout (Bytes.replicate 16384 97)
    "latin1-limit" -> Bytes.hPut stdout (Bytes.replicate 16384 255)
    "stdout-over" -> Bytes.hPut stdout (Bytes.replicate 16385 97)
    "stderr-limit" -> Char8.hPutStr stdout "synthetic-unused" >> Bytes.hPut stderr (Bytes.replicate 16384 120)
    "stderr-over" -> Char8.hPutStr stdout "synthetic-unused" >> Bytes.hPut stderr (Bytes.replicate 16385 120)
    "invalid-token" -> Char8.hPutStr stdout "invalid token"
    "request-unavailable" -> Char8.hPutStr stderr "connection refused" >> exitWith (ExitFailure 1)
    _ -> Char8.hPutStr stdout "synthetic-unused"
  _ -> fail "unknown synthetic stage"
