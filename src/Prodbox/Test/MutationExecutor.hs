{-# LANGUAGE OverloadedStrings #-}

-- | The bounded source-mutation executor (Phase 1, T07). Each case copies the
-- secret-filtered worktree and its build objects into a private workspace,
-- checks the unmodified build against the designated test (the baseline),
-- applies one reviewed or calibration patch, rebuilds, selects exactly one
-- test and runs it, and classifies the outcome with the reviewed
-- 'classifyMutationAttempt'. Every build and test runs in a container with no
-- network, no Docker socket, no home directory and no secrets: only the
-- workspace and the read-only host toolchain are mounted, and a probe in that
-- same container confirms the boundary before use. Cleanup is verified by a
-- label listing. Real cloud acceptance never uses these mutants.
--
-- Isolation prerequisite: the node image pinned by Phase 1 must be present in
-- the selected Docker daemon (it supplies only a root file system; the host
-- toolchain is mounted over it). Unprivileged namespaces, systemd sandboxing
-- and bubblewrap were each measured on this host and do not provide a
-- boundary, so a container is the isolation mechanism.
module Prodbox.Test.MutationExecutor
  ( runMutationCatalog
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.MutationOutcome
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import Prodbox.Test.Qualification.SourceIdentity (SourceIdentity)
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.ReviewedMutation
  ( ReviewedMutation (..)
  , prepareReviewedMutation
  , preparedMutantBytes
  , reviewedAssertion
  , reviewedPatchDigest
  , reviewedSourcePath
  , reviewedTestPath
  )
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , getCurrentDirectory
  , getHomeDirectory
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (FileStatus, getSymbolicLinkStatus, isRegularFile, setFileMode)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import System.Timeout (timeout)

-- | The pinned node image supplies only a root file system.
containerImage :: String
containerImage = "sha256:152b34afd8a2de5c8348a264426bc99b71058ee0e1a15eab9b30849605e4752d"

data Patch
  = Reviewed ReviewedMutation
  | Calibration String FilePath Text Text

data Case = Case
  { caseName :: String
  , casePatch :: Patch
  , caseTestPath :: Text
  , caseAssertion :: Text
  , caseTestArguments :: [String]
  , caseExpected :: MutationOutcome
  }

catalog :: [Case]
catalog =
  [ Case
      "M01"
      (Reviewed M01OverlappingRoots)
      (reviewedTestPath M01OverlappingRoots)
      (reviewedAssertion M01OverlappingRoots)
      []
      MutationKilled
  , Case
      "M02"
      (Reviewed M02MissingReport)
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      []
      MutationKilled
  , -- Calibration: a compiled change the designated test cannot see survives.
    Case
      "calibration-survivor"
      ( Calibration
          "report-size-bound"
          "src/Prodbox/Test/ScenarioEvidence.hs"
          "maximumReportBytes = 65536"
          "maximumReportBytes = 65537"
      )
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      []
      MutationSurvived
  , -- Calibration: a source that does not compile is invalid, not a kill.
    Case
      "calibration-invalid"
      ( Calibration
          "syntax-error"
          "src/Prodbox/Test/ScenarioEvidence.hs"
          "maximumReportBytes = 65536"
          "maximumReportBytes = = 65536"
      )
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      []
      MutationInvalid
  , -- Calibration: an unrelated timeout of the selected test is inconclusive.
    Case
      "calibration-timeout"
      ( Calibration
          "report-size-bound"
          "src/Prodbox/Test/ScenarioEvidence.hs"
          "maximumReportBytes = 65536"
          "maximumReportBytes = 65537"
      )
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      ["--timeout", "1ns"]
      MutationInconclusive
  ]

limits :: Int -> BoundedSubprocessLimits
limits seconds = BoundedSubprocessLimits 1 (1024 * 1024) (256 * 1024) (seconds * 1000000)

run
  :: Int -> FilePath -> [String] -> IO (Maybe (ExitCode, ByteString.ByteString, ByteString.ByteString))
run seconds program arguments = do
  result <-
    captureSubprocessWithInputBounded
      (limits seconds)
      ByteString.empty
      ( Subprocess
          program
          arguments
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("DOCKER_CONFIG", "/nonexistent")])
          Nothing
      )
  pure $ case result of
    Right output ->
      Just
        ( processExitCode output
        , ByteString8.pack (processStdout output)
        , ByteString8.pack (processStderr output)
        )
    Left _ -> Nothing

digestOf :: ByteString.ByteString -> PublicEvidenceDigest
digestOf = hashPublicEvidence . TextEncoding.decodeUtf8With (\_ _ -> Just '?') . hexSha256

-- | Files that must never enter a mutant workspace.
forbiddenPath :: FilePath -> Bool
forbiddenPath path =
  any
    (`isPrefixOf` path)
    [".data/", ".test-data/", ".build/", ".git/", ".secrets/"]
    || any (`isSuffixOf` path) ["test-secrets.dhall", "prodbox.dhall", "test-config.dhall"]
    || path `elem` ["test-secrets.dhall", "prodbox.dhall", "test-config.dhall"]

-- | Run one command in the isolated container with the workspace and the
-- read-only host toolchain mounted at their own absolute paths.
inContainer
  :: Int
  -> FilePath
  -> String
  -> String
  -> IO (Maybe (ExitCode, ByteString.ByteString, ByteString.ByteString))
inContainer seconds workspace label command = do
  home <- getHomeDirectory
  uid <- getEffectiveUserID
  gid <- getEffectiveGroupID
  run
    seconds
    "/usr/bin/docker"
    [ "run"
    , "--rm"
    , "--network"
    , "none"
    , "--label"
    , "io.prodbox.mutant=" ++ label
    , "--entrypoint"
    , "/usr/bin/sh"
    , "--user"
    , show uid ++ ":" ++ show gid
    , "--memory"
    , "8g"
    , "--pids-limit"
    , "4096"
    , "--cpus"
    , "4"
    , "-v"
    , "/usr:/usr:ro"
    , "-v"
    , "/lib:/lib:ro"
    , "-v"
    , "/lib64:/lib64:ro"
    , "-v"
    , "/etc/alternatives:/etc/alternatives:ro"
    , "-v"
    , home </> ".ghcup" ++ ":" ++ home </> ".ghcup" ++ ":ro"
    , "-v"
    , home </> ".cabal" ++ ":" ++ home </> ".cabal"
    , "-v"
    , workspace ++ ":" ++ workspace
    , "-w"
    , workspace
    , "-e"
    , "HOME=" ++ home </> ".cabal-home"
    , "-e"
    , "CABAL_DIR=" ++ home </> ".cabal"
    , "-e"
    , "PATH=" ++ home </> ".ghcup" </> "bin" ++ ":/usr/bin:/bin"
    , containerImage
    , "-c"
    , command
    ]

buildCommand :: String
buildCommand =
  "cabal build --builddir=.build test:prodbox-unit --enable-tests --ghc-options=-Werror > .build/build.log 2>&1; status=$?; tail -5 .build/build.log; exit $status"

binaryPath :: FilePath -> FilePath
binaryPath workspace =
  workspace
    </> ".build/build/x86_64-linux/ghc-9.12.4/prodbox-0.1.0/t/prodbox-unit/build/prodbox-unit/prodbox-unit"

data CaseResult = CaseResult
  { resultName :: String
  , resultOutcome :: MutationOutcome
  , resultExpected :: MutationOutcome
  , resultDetail :: String
  }

-- | Run the whole catalog. A case passes only when its classified outcome is
-- exactly the expected one; any other outcome keeps its record and fails.
runMutationCatalog :: IO ExitCode
runMutationCatalog = do
  repoRoot <- getCurrentDirectory
  present <- run 20 "/usr/bin/docker" ["image", "inspect", "--format", "{{.Id}}", containerImage]
  sourceResult <- captureSourceIdentity "." []
  case (present, sourceResult) of
    (Just (ExitSuccess, _, _), Right source) -> do
      stamp <- getMonotonicTimeNSec
      let root = repoRoot </> ".build" </> "mutants" </> show stamp
      createDirectoryIfMissing True root
      setFileMode (repoRoot </> ".build" </> "mutants") 0o700
      setFileMode root 0o700
      results <- forM catalog (runCase repoRoot root source)
      forM_ results $ \result ->
        writeOutputLine
          ( resultName result
              ++ ": outcome="
              ++ show (resultOutcome result)
              ++ " expected="
              ++ show (resultExpected result)
              ++ "; "
              ++ resultDetail result
          )
      -- Every case workspace is removed (they hold only copies of source).
      removePathForcibly root
      pure
        ( if all (\result -> resultOutcome result == resultExpected result) results
            then ExitSuccess
            else ExitFailure 1
        )
    (Just (ExitSuccess, _, _), Left failure) -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    _ ->
      writeOutputLine
        "the pinned node image is not present in the selected Docker daemon; import it first"
        >> pure (ExitFailure 2)

runCase :: FilePath -> FilePath -> SourceIdentity -> Case -> IO CaseResult
runCase repoRoot root source mutationCase = do
  let name = caseName mutationCase
      workspace = root </> name
      expectedPath = caseTestPath mutationCase
      assertion = caseAssertion mutationCase
      selection = "$0 == \"" ++ Text.unpack expectedPath ++ "\""
      label = "prodbox-mutant-" ++ name
      finish outcome detail = pure (CaseResult name outcome (caseExpected mutationCase) detail)
  copied <- snapshot repoRoot workspace
  if not copied
    then finish MutationInconclusive "workspace snapshot failed"
    else do
      -- Isolation: probe the same container the build will use.
      probe <-
        inContainer
          120
          workspace
          label
          "echo \"net=$(cat /proc/net/dev | tail -n +3 | cut -d: -f1 | tr -d ' ' | tr '\\n' ',')\"; test -e /var/run/docker.sock && echo SOCKET; test -e /run/docker.sock && echo SOCKET; ls /home 2>/dev/null | tr '\\n' ',' ; ls /root 2>&1 | head -1; test -e test-secrets.dhall && echo SECRETS; echo probe-done"
      let isolated = case probe of
            Just (ExitSuccess, out, _) ->
              let text = ByteString8.unpack out
               in "net=lo," `isInfixOf` text
                    && not ("SOCKET" `isInfixOf` text)
                    && not ("SECRETS" `isInfixOf` text)
                    && "probe-done" `isInfixOf` text
            _ -> False
      -- Baseline: the unmodified snapshot's build and designated test.
      baselineBuild <- inContainer 3600 workspace label buildCommand
      baselineBinary <- readDigest (binaryPath workspace)
      baselineSelection <- selectionObservation workspace label selection expectedPath baselineBinary
      baselineRun <- testObservation workspace label selection assertion []
      let baseline = case baselineRun of
            TestPassed count -> BaselinePassed count
            TestNotRun -> BaselineUnobservable
            _ -> BaselineFailed
          binding =
            MutationBinding
              source
              (maybe (digestOf "missing") id baselineBinary)
              (patchDigest (casePatch mutationCase))
              (digestOf (ByteString8.pack selection))
              expectedPath
              assertion
      case baselineBuild of
        Just (ExitSuccess, _, _) -> do
          patched <- applyPatch workspace (casePatch mutationCase)
          case patched of
            Nothing ->
              finish
                ( classifyMutationAttempt
                    binding
                    ( MutationAttempt
                        binding
                        (boundary isolated)
                        BoundaryConfirmed
                        baseline
                        baselineSelection
                        PatchPreconditionFailed
                        BuildNotRun
                        Nothing
                        TestNotRun
                    )
                )
                "patch precondition failed"
            Just () -> do
              mutantBuild <- inContainer 3600 workspace label buildCommand
              case mutantBuild of
                Just (ExitSuccess, _, _) -> do
                  mutantBinary <- readDigest (binaryPath workspace)
                  mutantSelection <- selectionObservation workspace label selection expectedPath mutantBinary
                  testResult <- testObservation workspace label selection assertion (caseTestArguments mutationCase)
                  cleaned <- cleanupObserved label
                  let attempt =
                        MutationAttempt
                          binding
                          (boundary isolated)
                          (boundary cleaned)
                          baseline
                          baselineSelection
                          PatchApplied
                          (maybe BuildUnobservable BuildSucceeded mutantBinary)
                          mutantSelection
                          testResult
                  finish
                    (classifyMutationAttempt binding attempt)
                    ( "build ok, test="
                        ++ show testResult
                        ++ ", isolation="
                        ++ show isolated
                        ++ ", cleanup="
                        ++ show cleaned
                    )
                Just (_, _, _) -> do
                  cleaned <- cleanupObserved label
                  finish
                    ( classifyMutationAttempt
                        binding
                        ( MutationAttempt
                            binding
                            (boundary isolated)
                            (boundary cleaned)
                            baseline
                            baselineSelection
                            PatchApplied
                            BuildRejected
                            Nothing
                            TestNotRun
                        )
                    )
                    ("build rejected, isolation=" ++ show isolated ++ ", cleanup=" ++ show cleaned)
                Nothing -> finish MutationInconclusive "mutant build did not finish within its bound"
        _ -> finish MutationInconclusive "baseline build failed or timed out"
 where
  boundary True = BoundaryConfirmed
  boundary False = BoundaryFailed
  readDigest path = do
    bytes <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
    pure (either (const Nothing) (Just . digestOf) bytes)
  selectionObservation workspace label selection expectedPath binary = do
    listed <-
      inContainer
        300
        workspace
        label
        ("\"" ++ binaryPath workspace ++ "\" --list-tests -p '" ++ selection ++ "'")
    pure $ case (listed, binary) of
      (Just (code, out, err), Just digest) -> either (const Nothing) Just (validateMutationSelection expectedPath digest code out err)
      _ -> Nothing
  testObservation workspace label selection assertion extra = do
    ran <-
      inContainer
        600
        workspace
        label
        ( "\""
            ++ binaryPath workspace
            ++ "\" --mutation-assertion "
            ++ Text.unpack assertion
            ++ " "
            ++ unwords extra
            ++ " -p '"
            ++ selection
            ++ "'"
        )
    pure $ case ran of
      Just (code, out, err) -> decodeSingleMutationTest assertion code out err
      Nothing -> TestUnobservable
  cleanupObserved label = do
    listing <-
      run 60 "/usr/bin/docker" ["ps", "-a", "-q", "--filter", "label=io.prodbox.mutant=" ++ label]
    pure $ case listing of
      Just (ExitSuccess, out, _) -> null (words (ByteString8.unpack out))
      _ -> False

patchDigest :: Patch -> PublicEvidenceDigest
patchDigest (Reviewed mutation) = reviewedPatchDigest mutation
patchDigest (Calibration label path old new) =
  hashPublicEvidence
    ( Text.intercalate
        "\NUL"
        ["prodbox-calibration-mutation-v1", Text.pack label, Text.pack path, old, new]
    )

applyPatch :: FilePath -> Patch -> IO (Maybe ())
applyPatch workspace patch = case patch of
  Reviewed mutation -> do
    let path = workspace </> reviewedSourcePath mutation
    bytes <- ByteString.readFile path
    case prepareReviewedMutation mutation bytes of
      Left _ -> pure Nothing
      Right prepared -> ByteString.writeFile path (preparedMutantBytes prepared) >> pure (Just ())
  Calibration _ relative old new -> do
    let path = workspace </> relative
    bytes <- ByteString.readFile path
    let text = TextEncoding.decodeUtf8 bytes
    case Text.splitOn old text of
      [prefix, suffix] -> ByteString.writeFile path (TextEncoding.encodeUtf8 (prefix <> new <> suffix)) >> pure (Just ())
      _ -> pure Nothing

-- | Copy only tracked and untracked, non-secret regular files, then the build
-- objects. The workspace is private to this user.
snapshot :: FilePath -> FilePath -> IO Bool
snapshot repoRoot workspace = do
  listing <-
    run
      60
      "/usr/bin/git"
      ["-C", repoRoot, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
  case listing of
    Just (ExitSuccess, out, _) -> do
      let paths = filter (\path -> not (null path) && not (forbiddenPath path)) (splitNul (ByteString8.unpack out))
      createDirectoryIfMissing True workspace
      setFileMode workspace 0o700
      copied <- forM paths $ \path -> do
        status <- try (getSymbolicLinkStatus (repoRoot </> path)) :: IO (Either IOException FileStatus)
        case status of
          Right value | isRegularFile value -> do
            createDirectoryIfMissing True (takeDirectory (workspace </> path))
            result <- try (copyFile (repoRoot </> path) (workspace </> path)) :: IO (Either IOException ())
            pure (either (const False) (const True) result)
          _ -> pure True
      createDirectoryIfMissing True (workspace </> ".build")
      objects <-
        timeout
          600000000
          (run 600 "/usr/bin/cp" ["-a", repoRoot </> ".build" </> "build", workspace </> ".build" </> "build"])
      let objectsCopied = case objects of
            Just (Just (ExitSuccess, _, _)) -> True
            _ -> False
      pure (and copied && objectsCopied)
    _ -> pure False
 where
  splitNul text = case break (== '\NUL') text of
    (chunk, []) -> [chunk]
    (chunk, _ : rest) -> chunk : splitNul rest
