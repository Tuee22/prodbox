{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 5.44: a real-child process-boundary harness that can assert a
-- credential __arrived__.
--
-- __Why the canonical suite needed one.__ Every test that covered the ephemeral
-- Kubernetes client's bearer token asserted only that it was absent — from
-- argv, from the environment, from retained evidence, from the rendered
-- kubeconfig. A suite of absence assertions about a secret is satisfied
-- perfectly by a secret that is never produced, and that is exactly what
-- happened: the client's token writer had never served a byte on any live run,
-- and the deleted real-subprocess case that came closest spawned a fake
-- @kubectl@ which logged its arguments and printed a cluster UID without ever
-- opening the token file, so the writer's death was invisible to it by
-- construction.
--
-- __What this harness does instead.__ The child re-execs this test binary,
-- parses the kubeconfig it was handed exactly as @kubectl@ would, reads the
-- credential through @users[0].user.tokenFile@ by the mechanism production
-- expects, and echoes it. The assertion is therefore that the exact credential
-- bytes reached a separate process, which no absence assertion can be satisfied
-- by.
--
-- __Why it lives here and not in "TestSupport".__ The shared support module is
-- compiled into five of the eight test suites, two of which depend on neither
-- @process@ nor @unix@. A harness that spawns a child cannot live there. What
-- does live there is the elapsed-time vocabulary, which needs only
-- "GHC.Clock" from @base@.
--
-- __The tier decision, against the policy's own table.__ Unit-tier fakes
-- substitute above the process boundary, so no unit case reaches the bounded
-- subprocess runner; integration-tier fakes are real binaries on @PATH@, but
-- those suites never reach the EKS or DNS01 teardown paths. The boundary sat in
-- the gap between the two tiers, which is why the policy's real-process row is
-- the right home for it and why this module is registered in the primary unit
-- suite rather than in the integration one.
module CredentialDeliveryHarness
  ( credentialDeliveryHarnessSuite
  , ephemeralKubectlCredentialSuite
  , runCredentialDeliveryHelper
  )
where

import Control.Exception (IOException, finally, try)
import Control.Monad (unless)
import Data.Aeson (Value, decodeFileStrict', encode, object, (.=))
import Data.Aeson.Types (Parser, parseEither, withObject, (.:))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection (EksClientAuthProjection)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EphemeralKubectl
  , EphemeralKubectlUnavailable
  , ephemeralKubeconfig
  , ephemeralKubectlWallClockSeconds
  , runEphemeralKubectl
  , withEphemeralKubectlForProjection
  , writePrivateFile
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( accessModes
  , createNamedPipe
  , fileMode
  , getFileStatus
  , intersectFileModes
  , ownerReadMode
  , ownerWriteMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import TestSupport

-- | The argv sentinel that turns this test binary into the fake @kubectl@.
--
-- The same self-exec idiom the journal tests already use, rather than a second
-- one: one shape for a real child in the unit tier is the whole point.
credentialHelperPrefix :: String
credentialHelperPrefix = "--prodbox-unit-credential-helper"

-- | The credential the fixtures deliver.  Distinctive on purpose, so a test
-- that claims it arrived cannot be satisfied by an empty string.
fixtureCredential :: ByteString.ByteString
fixtureCredential = "prodbox-fixture-bearer-token-9d41f2"

-- | Dispatch the private self-exec mode.  Ordinary tasty arguments return
-- 'False' and fall through into the suite.
runCredentialDeliveryHelper :: [String] -> IO Bool
runCredentialDeliveryHelper arguments = case arguments of
  [prefix, "--kubeconfig", kubeconfigPath]
    | prefix == credentialHelperPrefix ->
        echoCredential NonBlockingRead kubeconfigPath >> pure True
  [prefix, "--blocking-kubeconfig", kubeconfigPath]
    | prefix == credentialHelperPrefix ->
        echoCredential BlockingRead kubeconfigPath >> pure True
  -- Sprint 7.39: the shape the real client produces. `runBoundedKubectl`
  -- prepends `--kubeconfig <path>` and appends whatever the caller passed, so
  -- the sentinel arrives last rather than first.
  ["--kubeconfig", kubeconfigPath, prefix]
    | prefix == credentialHelperPrefix ->
        echoCredential NonBlockingRead kubeconfigPath >> pure True
  ["--kubeconfig", kubeconfigPath, prefix, "--twice"]
    | prefix == credentialHelperPrefix -> do
        -- Two reads in one invocation, which is what `kubectl` itself does and
        -- what a stream cannot serve.
        echoCredential NonBlockingRead kubeconfigPath
        echoCredential NonBlockingRead kubeconfigPath
        pure True
  prefix : _
    | prefix == credentialHelperPrefix ->
        failHelper "expected --kubeconfig or --blocking-kubeconfig PATH" >> pure True
  _ -> pure False

-- | How the child opens the credential the kubeconfig names.
--
-- The distinction is not decoration. GHC opens a file non-blocking, so a
-- Haskell child reading a writerless FIFO gets an immediate empty read, while
-- @kubectl@ — an ordinary C program — opens blocking and waits for a writer
-- that never comes. Both are real failures and they are different failures, so
-- the harness can produce either on demand rather than silently modelling one
-- as the other.
data CredentialReadMode
  = NonBlockingRead
  | BlockingRead

-- | Read the credential the way the real client's subject reads it, and echo it.
--
-- Reading it through the kubeconfig rather than from a path the parent passed
-- directly is what makes this a boundary test: the parent asserts that the
-- token reached a separate process __by the route production uses__, not that
-- the parent could have read a file it wrote itself.
echoCredential :: CredentialReadMode -> FilePath -> IO ()
echoCredential mode kubeconfigPath = do
  decoded <- decodeFileStrict' kubeconfigPath
  case decoded of
    Nothing -> failHelper ("kubeconfig is not readable at " ++ kubeconfigPath)
    Just document -> case parseEither tokenFilePath document of
      Left err -> failHelper ("kubeconfig has no token file: " ++ err)
      Right tokenPath -> do
        token <- readCredential mode tokenPath
        ByteString8.hPutStr stdout token
 where
  tokenFilePath :: Value -> Parser FilePath
  tokenFilePath = withObject "kubeconfig" $ \root -> do
    users <- root .: "users"
    case users of
      [] -> fail "kubeconfig names no users"
      user : _ -> withObject "user" (\entry -> entry .: "user" >>= (.: "tokenFile")) user

-- | Read the credential, in the mode the caller asked for.
--
-- The blocking arm goes through 'openFd' with @nonBlock@ cleared, which is what
-- an ordinary C program's @open@ does and therefore what the real subject does.
readCredential :: CredentialReadMode -> FilePath -> IO ByteString.ByteString
readCredential mode tokenPath = case mode of
  NonBlockingRead -> ByteString.readFile tokenPath
  BlockingRead -> do
    descriptor <-
      openFd tokenPath ReadOnly defaultFileFlags {nonBlock = False, cloexec = True}
    PosixByteString.fdRead descriptor 4096 `finally` closeFd descriptor

failHelper :: String -> IO ()
failHelper message = do
  hPutStrLn stderr ("credential helper: " ++ message)
  ioError (userError ("credential helper: " ++ message))

credentialDeliveryHarnessSuite :: SuiteBuilder ()
credentialDeliveryHarnessSuite =
  describe "Sprint 5.44 real-child credential delivery" $ do
    it "observes the exact credential arriving in a separate process" $
      withSystemTempDirectory "prodbox-credential-arrives" $ \directory -> do
        -- A working delivery mechanism: the credential is present at the path
        -- the kubeconfig names when the child opens it.
        let tokenPath = directory </> "bearer-token"
        ByteString.writeFile tokenPath fixtureCredential
        (outcome, _) <- withElapsedMicros (runHelperAgainst directory tokenPath)
        delivered <- expectDelivered outcome
        delivered `shouldBe` fixtureCredential

    it "fails when the credential never arrives, so it can disagree with its subject" $
      withSystemTempDirectory "prodbox-credential-never-arrives" $ \directory -> do
        -- The proven-broken shape, reproduced as the state it leaves behind: a
        -- FIFO with no writer. Reproducing the writer's death is unnecessary and
        -- would be less faithful — GHC opens a FIFO non-blocking, so the real
        -- writer fails with ENXIO before the reader exists and the FIFO is
        -- writerless from that instant. The child blocks in `open` for ever, and
        -- the bounded runner is the only thing that ends it.
        let tokenPath = directory </> "bearer-token"
        createNamedPipe tokenPath (ownerReadMode `unionFileModes` ownerWriteMode)
        (outcome, elapsedMicros) <-
          withElapsedMicros (runHelperAgainst directory tokenPath)
        -- The child completes and delivers nothing, which is what an absence
        -- assertion about a secret cannot tell apart from success. This is the
        -- disagreement the harness exists to be capable of.
        delivered <- expectDelivered outcome
        delivered `shouldNotBe` fixtureCredential
        delivered `shouldBe` ByteString.empty
        elapsedMicros `shouldSatisfy` (< fixtureWallClockMicros)

    it "pins the wedge signature: elapsed equal to the bound, and a wall-clock refusal" $
      withSystemTempDirectory "prodbox-credential-wedged" $ \directory -> do
        -- The negative control. A blocking open against a writerless FIFO is
        -- exactly what `kubectl` does and exactly what the live failure showed:
        -- the call never completes, and its duration tracks the bound rather
        -- than the work — thirty seconds under thirty, forty under forty. The
        -- shape is named here so it is recognised rather than rediscovered.
        let tokenPath = directory </> "bearer-token"
        createNamedPipe tokenPath (ownerReadMode `unionFileModes` ownerWriteMode)
        (outcome, elapsedMicros) <-
          withElapsedMicros (runBlockingHelperAgainst directory tokenPath)
        outcome `shouldSatisfy` isWallClockRefusal
        elapsedMicros `shouldSatisfy` (>= fixtureWallClockMicros)
        elapsedMicros `shouldSatisfy` (< 3 * fixtureWallClockMicros)

    it "fails a deliberately slow delivery and passes a fast one" $
      withSystemTempDirectory "prodbox-credential-slow" $ \directory -> do
        -- The elapsed-time assertion has to be able to fail, or it is decoration.
        let tokenPath = directory </> "bearer-token"
        ByteString.writeFile tokenPath fixtureCredential
        (_, fastMicros) <- withElapsedMicros (runHelperAgainst directory tokenPath)
        fastMicros `shouldSatisfy` (< fixtureWallClockMicros)
        (_, slowMicros) <- withElapsedMicros (sleepMicros (fixtureWallClockMicros + 50_000))
        slowMicros `shouldSatisfy` (>= fixtureWallClockMicros)

    it "hands the child a real environment rather than an empty one" $
      withSystemTempDirectory "prodbox-credential-environment" $ \directory -> do
        -- The runner passes an explicit environment, so `Just []` leaves the
        -- child with no PATH, no HOME and no LANG. The deleted prior art did
        -- exactly that and survived only because its fake carried an absolute
        -- shebang.
        environment <- helperEnvironment
        lookup "PATH" environment `shouldSatisfy` maybe False (not . null)
        let tokenPath = directory </> "bearer-token"
        ByteString.writeFile tokenPath fixtureCredential
        (outcome, _) <- withElapsedMicros (runHelperAgainst directory tokenPath)
        delivered <- expectDelivered outcome
        delivered `shouldBe` fixtureCredential

-- | Run the fake @kubectl@ against a kubeconfig naming @tokenPath@.
runHelperAgainst :: FilePath -> FilePath -> IO (Either String ProcessOutput)
runHelperAgainst = runHelperWith "--kubeconfig"

-- | The same child, opening the credential the way @kubectl@ does.
runBlockingHelperAgainst :: FilePath -> FilePath -> IO (Either String ProcessOutput)
runBlockingHelperAgainst = runHelperWith "--blocking-kubeconfig"

runHelperWith
  :: String -> FilePath -> FilePath -> IO (Either String ProcessOutput)
runHelperWith readFlag directory tokenPath = do
  executable <- getExecutablePath
  environment <- helperEnvironment
  let kubeconfigPath = directory </> "kubeconfig.json"
  LazyByteString.writeFile kubeconfigPath (encode (fixtureKubeconfig tokenPath))
  result <-
    captureSubprocessBounded
      fixtureLimits
      Subprocess
        { subprocessPath = executable
        , subprocessArguments = [credentialHelperPrefix, readFlag, kubeconfigPath]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just directory
        }
  pure (either (Left . show) Right result)

-- | The child's environment: the parent's, which is what a real caller inherits.
helperEnvironment :: IO [(String, String)]
helperEnvironment = getEnvironment

fixtureKubeconfig :: FilePath -> Value
fixtureKubeconfig tokenPath =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Config" :: String)
    , "current-context" .= ("prodbox-fixture" :: String)
    , "users"
        .= [ object
               [ "name" .= ("prodbox-fixture" :: String)
               , "user" .= object ["tokenFile" .= tokenPath]
               ]
           ]
    ]

-- | A deliberately small wall clock, so the wedge case costs a second rather
-- than the forty the production client's derived bound would.
fixtureWallClockMicros :: Integer
fixtureWallClockMicros = 1_000_000

fixtureLimits :: BoundedSubprocessLimits
fixtureLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 64 * 1024
    , boundedSubprocessMaximumStderrBytes = 64 * 1024
    , boundedSubprocessTimeoutMicros = fromIntegral fixtureWallClockMicros
    }

expectDelivered :: Either String ProcessOutput -> IO ByteString.ByteString
expectDelivered outcome = case outcome of
  Left err -> do
    expectationFailure ("expected the credential to arrive, got " ++ err)
    pure ByteString.empty
  Right output -> do
    unless
      (processExitCode output == ExitSuccess)
      (expectationFailure ("credential helper exited with " ++ show (processExitCode output)))
    pure (ByteString8.pack (processStdout output))

-- | The bounded runner's exact wall-clock refusal, not merely a 'Left'.
isWallClockRefusal :: Either String ProcessOutput -> Bool
isWallClockRefusal outcome = case outcome of
  Left err -> "wall-clock timeout" `isInfixOf` err
  Right _ -> False

-- | Sprint 7.39: the ephemeral Kubernetes client actually delivers its
-- credential.
--
-- Nothing covered this module's runtime before. `withEphemeralKubectlForProjection`,
-- `runEphemeralKubectl`, `ephemeralKubeconfig` and `writePrivateFile` had zero
-- test callers, and the only assertions anywhere near the bearer token were that
-- it was absent from a log — which is why a credential mechanism that had never
-- served a byte passed every gate for weeks.
ephemeralKubectlCredentialSuite :: SuiteBuilder ()
ephemeralKubectlCredentialSuite =
  describe "Sprint 7.39 ephemeral Kubernetes client credential" $ do
    it "delivers the byte-exact bearer credential to a real child" $ do
      executable <- getExecutablePath
      environment <- helperEnvironment
      (outcome, elapsedMicros) <-
        withElapsedMicros
          ( withEphemeralKubectlForProjection
              executable
              environment
              Nothing
              fixtureProjection
              (runThroughClient [credentialHelperPrefix])
          )
      outcome `shouldBe` Right (Text.unpack fixtureBearerToken)
      -- A small fraction of the client's own bound, asserted rather than
      -- inferred. Under the superseded FIFO this consumed the entire 40 seconds.
      elapsedMicros
        `shouldSatisfy` (< fromIntegral ephemeralKubectlWallClockSeconds * 100_000)

    it "serves the credential on a second read in the same invocation" $ do
      -- The re-read semantics the chosen mechanism promises, and the measurement
      -- that chose it: `kubectl` opens the token file exactly twice per
      -- invocation, independently of how many API requests it makes. A stream
      -- serves the first open and blocks on the second.
      executable <- getExecutablePath
      environment <- helperEnvironment
      outcome <-
        withEphemeralKubectlForProjection
          executable
          environment
          Nothing
          fixtureProjection
          (runThroughClient [credentialHelperPrefix, "--twice"])
      outcome
        `shouldBe` Right (Text.unpack fixtureBearerToken <> Text.unpack fixtureBearerToken)

    it "refuses a pre-placed credential path and writes owner-only" $
      withSystemTempDirectory "prodbox-credential-protections" $ \directory -> do
        -- The protections the module claims for the credential, exercised
        -- rather than asserted in prose. `writePrivateFile` is the same call the
        -- kubeconfig has always used, and Sprint 7.39 reuses it for the token;
        -- O_EXCL is what makes "a pre-placed path cannot capture it" true.
        let credentialPath = directory </> "bearer-token"
        writePrivateFile credentialPath "first"
        ByteString.readFile credentialPath `shouldReturn` "first"
        status <- getFileStatus credentialPath
        intersectFileModes (fileMode status) accessModes
          `shouldBe` (ownerReadMode `unionFileModes` ownerWriteMode)
        captured <-
          try (writePrivateFile credentialPath "second") :: IO (Either IOException ())
        captured `shouldSatisfy` either (const True) (const False)
        -- And the pre-placed content is untouched, so a capture attempt cannot
        -- even truncate what is already there.
        ByteString.readFile credentialPath `shouldReturn` "first"

    it "builds the client only after the credential reads back" $ do
      -- "Client alive, credential absent" was the superseded mechanism's state
      -- and nothing could observe it. The client is now constructed only after
      -- the credential is written, fsynced, and read back equal. The failing arm
      -- is not constructible from a test without mutating the module — the write
      -- and the read-back share one `try` inside a temp directory the test does
      -- not own — so what is asserted here is the positive half: a client that
      -- exists delivers the exact credential, which the two cases above prove,
      -- and the guard that makes the negative half unreachable is named in the
      -- module rather than left implicit.
      executable <- getExecutablePath
      environment <- helperEnvironment
      built <-
        withEphemeralKubectlForProjection
          executable
          environment
          Nothing
          fixtureProjection
          clientWasBuilt
      built `shouldBe` True

    it "keeps the bearer credential out of the rendered kubeconfig" $ do
      -- The absence assertion is still worth making; what changed is that it is
      -- no longer the only assertion about this credential.
      let rendered = show (ephemeralKubeconfig fixtureProjection "/tmp/bearer-token")
      rendered `shouldNotContain` Text.unpack fixtureBearerToken
      rendered `shouldContain` "tokenFile"

-- | Drive one bounded call through a prepared client, flattening both failure
-- shapes into the text a case can assert on.
runThroughClient
  :: [String]
  -> Either EphemeralKubectlUnavailable EphemeralKubectl
  -> IO (Either String String)
runThroughClient arguments built = case built of
  Left unavailable -> pure (Left (show unavailable))
  Right client -> either (Left . show) Right <$> runEphemeralKubectl client arguments

clientWasBuilt :: Either EphemeralKubectlUnavailable EphemeralKubectl -> IO Bool
clientWasBuilt built = case built of
  Left _ -> pure False
  Right _ -> pure True

fixtureBearerToken :: Text.Text
fixtureBearerToken = "prodbox-ephemeral-bearer-token-7f31a9"

-- | Through `TestSupport`'s synthetic constructor: a complete region coordinate
-- compiled into Haskell is refused by the gate, fixtures included.
fixtureRegion :: Text.Text
fixtureRegion = fixtureAwsRegion FixtureCaCentral1

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  case testEksClientAuthProjection
    "111122223333"
    fixtureRegion
    "prodbox-eks"
    ("arn:aws:eks:" <> fixtureRegion <> ":111122223333:cluster/prodbox-eks")
    "https://127.0.0.1:59999"
    "Y2EtZGF0YQ=="
    fixtureBearerToken
    1_800 of
    Left err -> error ("CredentialDeliveryHarness: invalid fixture projection: " <> show err)
    Right projection -> projection
