{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.46: a registry readiness probe runs from the vantage its
-- substrate's registry is reached from. The home registry is asked through its
-- NodePort from the host; the EKS registry cannot be reached from the host, so
-- it is asked from inside its own pod. An AWS step that took the host's loopback
-- answered for the HOME registry, which is a false witness rather than a failure
-- that hides.
module RegistryProbe (registryProbeSuite) where

import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.CLI.Rke2
  ( RegistryProbeRunner
  , observeRegistryBackendRoundTripOnceWith
  , probeRegistryStorageBackendEdgeWith
  )
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Lib.RegistryProbe
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ReadinessObservation (BackendRoundTripResult (..))
import Prodbox.Subprocess (ProcessOutput (..))
import Prodbox.Substrate (Substrate (..))
import System.Exit (ExitCode (..))
import TestSupport

registryProbeSuite :: SuiteBuilder ()
registryProbeSuite =
  describe "Sprint 7.46 registry probes run from the vantage their registry is reached from" $ do
    it "probes the home registry from the host and the EKS registry from inside its pod" $ do
      registryProbeVantageFor SubstrateHomeLocal `shouldBe` RegistryProbeFromHost
      registryProbeVantageFor SubstrateAws `shouldBe` RegistryProbeFromRegistryPod

    it "keeps the home probes byte-identical to the curl invocations the home reconcile has always run" $ do
      registryProbeCommand target RegistryProbeFromHost (RegistryProbeStatus "/v2/")
        `shouldBe` ( "curl"
                   , ["-sS", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:30080/v2/"]
                   )
      registryProbeCommand target RegistryProbeFromHost (RegistryProbeUploadSession "probe-repo")
        `shouldBe` ( "curl"
                   ,
                     [ "-sS"
                     , "--max-time"
                     , "10"
                     , "-X"
                     , "POST"
                     , "-o"
                     , "/dev/null"
                     , "-D"
                     , "-"
                     , "-w"
                     , "\n%{http_code}"
                     , "http://127.0.0.1:30080/v2/probe-repo/blobs/uploads/"
                     ]
                   )

    it "asks the EKS registry from inside its container and never names the host's registry endpoint" $ do
      forM_ [RegistryProbeStatus "/v2/", RegistryProbeUploadSession "probe-repo"] $ \request -> do
        let (tool, arguments) = registryProbeCommand target RegistryProbeFromRegistryPod request
        tool `shouldBe` "kubectl"
        take 7 arguments
          `shouldBe` ["exec", "--namespace", "harbor", "deployment/registry", "--container", "registry", "--"]
        -- The host's loopback NodePort is the home registry: it must not appear in
        -- anything an AWS probe sends.
        concat arguments `shouldSatisfy` (not . isInfixOf ContainerImage.harborRegistryEndpoint)
        tool `shouldNotBe` "curl"
      let (_, statusArguments) = registryProbeCommand target RegistryProbeFromRegistryPod (RegistryProbeStatus "/v2/")
          (_, uploadArguments) =
            registryProbeCommand target RegistryProbeFromRegistryPod (RegistryProbeUploadSession "probe-repo")
      -- A raw HTTP/1.0 request over the container's own loopback, so the response
      -- arrives as the registry wrote it. These two scripts were run against the
      -- registry:2 image and answered 200 and 202 with the Docker-Upload-Uuid header.
      finalArgument statusArguments
        `shouldBe` "printf 'GET /v2/ HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\n\\r\\n' | nc -w 5 127.0.0.1 5000 2>&1; true"
      finalArgument uploadArguments
        `shouldBe` "printf 'POST /v2/probe-repo/blobs/uploads/ HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nContent-Length: 0\\r\\n\\r\\n' | nc -w 10 127.0.0.1 5000 2>&1; true"
      forM_ [statusArguments, uploadArguments] $ \arguments ->
        finalArgument arguments `shouldNotContain` "wget"

    it "sends the production probe's exact command to the registry container, once" $ do
      -- The target above is a fixture; this is the one production uses.
      asked <- newIORef ([] :: [(FilePath, [String])])
      let runner :: RegistryProbeRunner
          runner tool arguments = do
            modifyIORef' asked (++ [(tool, arguments)])
            pure (Left "not asked for an answer")
      _ <- probeRegistryStorageBackendEdgeWith runner RegistryProbeFromRegistryPod
      calls <- readIORef asked
      calls
        `shouldBe` [
                     ( "kubectl"
                     ,
                       [ "exec"
                       , "--namespace"
                       , "harbor"
                       , "deployment/registry"
                       , "--container"
                       , "registry"
                       , "--"
                       , "/bin/sh"
                       , "-c"
                       , "printf 'POST /v2/prodbox-readiness-probe/blobs/uploads/ HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nContent-Length: 0\\r\\n\\r\\n' | nc -w 10 127.0.0.1 5000 2>&1; true"
                       ]
                     )
                   ]

    it "reads the response of a registry that opened an upload session" $ do
      let session = "6c1d9a52-0000-4f3a-b7d2-9a1a0f3c2d11"
          response protocol =
            [ protocol ++ " 202 Accepted"
            , "Content-Length: 0"
            , "Docker-Distribution-Api-Version: registry/2.0"
            , "Docker-Upload-Uuid: " ++ session
            , "Location: http://127.0.0.1:5000/v2/probe-repo/blobs/uploads/" ++ session ++ "?_state=abc"
            , "Range: 0-0"
            , "X-Content-Type-Options: nosniff"
            , ""
            ]
          expected = Right (RegistryStorageEdgeObservation "202" session)
      -- Go answers in the request's protocol, so a 1.0 request is answered as 1.0.
      parseInPodRegistryResponse (unlines (response "HTTP/1.1")) `shouldBe` expected
      parseInPodRegistryResponse (unlines (response "HTTP/1.0")) `shouldBe` expected
      -- The wire has carriage returns; an indenting tool leaves leading spaces.
      parseInPodRegistryResponse (concatMap (++ "\r\n") (response "HTTP/1.1")) `shouldBe` expected
      parseInPodRegistryResponse (unlines (map ("  " ++) (response "HTTP/1.1"))) `shouldBe` expected
      -- The Location header alone still names a session, after the UUID.
      parseInPodRegistryResponse
        (unlines ["HTTP/1.1 202 Accepted", "Location: /v2/probe-repo/blobs/uploads/abc"])
        `shouldBe` Right (RegistryStorageEdgeObservation "202" "/v2/probe-repo/blobs/uploads/abc")
      -- The final response decides the status when more than one arrived.
      parseInPodRegistryResponse (unlines ["HTTP/1.1 307 Temporary Redirect", "HTTP/1.1 200 OK"])
        `shouldBe` Right (RegistryStorageEdgeObservation "200" "")
      -- A front-door answer names no session, and a body does not change its status.
      parseInPodRegistryResponse (unlines ["HTTP/1.1 200 OK", "Content-Length: 2", "", "{}"])
        `shouldBe` Right (RegistryStorageEdgeObservation "200" "")
      -- A registry that answered 500 is a status, not a missing answer.
      parseInPodRegistryResponse "HTTP/1.1 500 Internal Server Error\n"
        `shouldBe` Right (RegistryStorageEdgeObservation "500" "")

    it "reports output with no HTTP response as what was written, not as a status" $ do
      forM_
        [ "/bin/sh: nc: not found\n"
        , "nc: can't connect to remote host (127.0.0.1): Connection refused\n"
        , "nc: bad address 'registry'\n"
        , ""
        ]
        (expectNoHttpResponse . parseInPodRegistryResponse)
      -- A header-looking line is not a status line.
      parseInPodRegistryResponse "Content-Type: HTTP/1.1 202\n" `shouldSatisfy` isLeftValue

    it "treats a failed exec as the failure detail and an answered request as a reading" $ do
      interpretRegistryProbe
        RegistryProbeFromRegistryPod
        (RegistryProbeStatus "/v2/")
        (ExitFailure 1)
        ""
        "Error from server (NotFound): pods \"registry-0\" not found\n"
        `shouldBe` Left "Error from server (NotFound): pods \"registry-0\" not found"
      interpretRegistryProbe RegistryProbeFromHost (RegistryProbeStatus "/v2/") (ExitFailure 7) "" ""
        `shouldBe` Left "subprocess exited without output"
      interpretRegistryProbe RegistryProbeFromHost (RegistryProbeStatus "/v2/") ExitSuccess "200\n" ""
        `shouldBe` Right (RegistryStorageEdgeObservation "200" "")
      interpretRegistryProbe
        RegistryProbeFromRegistryPod
        (RegistryProbeStatus "/v2/")
        ExitSuccess
        "HTTP/1.1 200 OK\n"
        ""
        `shouldBe` Right (RegistryStorageEdgeObservation "200" "")

    it "keeps reading a curl upload response as it always has" $ do
      parseRegistryStorageEdgeResponse
        (unlines ["HTTP/1.1 202 Accepted", "Docker-Upload-UUID: 9f2c-upload", "Location: /x", "", "202"])
        `shouldBe` RegistryStorageEdgeObservation "202" "9f2c-upload"

    it
      "mints the AWS barrier's witness from the session the EKS registry named, asking only the cluster"
      $ do
        asked <- newIORef ([] :: [(FilePath, [String])])
        let clock = pure (authorityTimeFromMicros 1000000)
            runner :: RegistryProbeRunner
            runner tool arguments = do
              modifyIORef' asked (++ [(tool, arguments)])
              pure
                ( Right
                    ProcessOutput
                      { processExitCode = ExitSuccess
                      , processStdout =
                          unlines
                            [ "HTTP/1.1 202 Accepted"
                            , "Docker-Upload-Uuid: 11111111-2222-3333-4444-555555555555"
                            , "Location: /v2/prodbox-readiness-probe/blobs/uploads/11111111-2222-3333-4444-555555555555"
                            ]
                      , processStderr = ""
                      }
                )
        result <-
          observeRegistryBackendRoundTripOnceWith
            runner
            clock
            (registryProbeVantageFor SubstrateAws)
        case result of
          Right (BackendRoundTripConfirmed _) -> pure ()
          other -> expectationFailure ("expected a confirmed round trip, got " ++ show other)
        calls <- readIORef asked
        map fst calls `shouldBe` ["kubectl"]
        forM_ calls $ \(_, arguments) ->
          concat arguments `shouldSatisfy` (not . isInfixOf ContainerImage.harborRegistryEndpoint)

    it "does not confirm a round trip the registry did not name, or one it refused" $ do
      let clock = pure (authorityTimeFromMicros 1000000)
          answering stdout _ _ =
            pure
              (Right (ProcessOutput {processExitCode = ExitSuccess, processStdout = stdout, processStderr = ""}))
          observe stdout =
            observeRegistryBackendRoundTripOnceWith (answering stdout) clock RegistryProbeFromRegistryPod
      -- A 202 that names no session is not a write, and the gate stays closed.
      unnamed <- observe "HTTP/1.1 202 Accepted\n"
      unnamed `shouldSatisfy` isPendingResult
      -- A registry that cannot reach its storage backend answers 5xx: retryable.
      refused <- observe "HTTP/1.1 500 Internal Server Error\n"
      refused `shouldSatisfy` isPendingResult
      -- No answer at all (nc absent, connection refused) is unreachable, a
      -- refusal to observe rather than a pending one.
      silent <- observe "/bin/sh: nc: not found\n"
      silent `shouldSatisfy` either (const True) (const False)
      -- A failed exec is the same.
      failedExec <-
        observeRegistryBackendRoundTripOnceWith
          (\_ _ -> pure (Right (ProcessOutput (ExitFailure 1) "" "error: unable to upgrade connection")))
          clock
          RegistryProbeFromRegistryPod
      failedExec `shouldSatisfy` either (const True) (const False)

    it "runs the storage-edge probe through the supplied runner only" $ do
      asked <- newIORef (0 :: Int)
      result <-
        probeRegistryStorageBackendEdgeWith
          ( \_ _ -> do
              modifyIORef' asked (+ 1)
              pure (Left "failed to start kubectl: not found")
          )
          RegistryProbeFromRegistryPod
      result `shouldBe` Left "failed to start kubectl: not found"
      readIORef asked `shouldReturn` 1
 where
  target =
    RegistryProbeTarget
      { registryProbeHostEndpoint = "127.0.0.1:30080"
      , registryProbeNamespace = "harbor"
      , registryProbeDeployment = "registry"
      , registryProbeContainer = "registry"
      , registryProbeContainerPort = 5000
      }

  expectNoHttpResponse :: Either String RegistryStorageEdgeObservation -> Expectation
  expectNoHttpResponse reading = case reading of
    Left detail -> detail `shouldContain` "no HTTP response"
    Right observation -> expectationFailure ("read a status from nothing: " ++ show observation)

  finalArgument :: [String] -> String
  finalArgument = foldl (\_ argument -> argument) ""

  isLeftValue :: Either a b -> Bool
  isLeftValue = either (const True) (const False)

  isPendingResult :: Either Text.Text BackendRoundTripResult -> Bool
  isPendingResult result = case result of
    Right (BackendRoundTripPending _) -> True
    _ -> False
