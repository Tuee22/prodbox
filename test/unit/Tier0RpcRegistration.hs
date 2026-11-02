{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Tier0RpcRegistration (tier0RpcRegistrationSuite, runTier0PublicationHelper) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), bracket, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Prodbox.Config.FloorDhall (loadUnencryptedBasicsAtPath)
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.Config.Tier0File
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator qualified as Coordinator
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthPublication (tier0RpcBirthPublicationAtPath)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef (SecretRef (SecretRefTestPlaintext))
import System.Directory (createDirectory, doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
import System.Posix.IO
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import TestSupport
import Tier0Fixture

tier0RpcRegistrationSuite :: SuiteBuilder ()
tier0RpcRegistrationSuite = describe "Sprint 6.5 independent Tier-0 registration pin" $ do
  it "connects coordinator publication to exact native scoped source and idempotent durability" $
    withPinConfig RpcBirthConfigLegacy $ \_ path -> do
      deadline <- sourcePublicationDeadline
      let boundary =
            tier0RpcBirthPublicationAtPath
              (must (Coordinate.mkAuthorityScope scope))
              path
              (\_ _ -> fail "source publication must not run the rollout slot")
      Coordinator.coordinationReadSource boundary deadline `shouldReturn` Right RpcBirthConfigLegacy
      Coordinator.coordinationPublishSource boundary deadline RpcBirthConfigLegacy registered
        `shouldReturn` Right ()
      Coordinator.coordinationReadSource boundary deadline `shouldReturn` Right registered
      before <- BS.readFile path
      Coordinator.coordinationPublishSource boundary deadline RpcBirthConfigLegacy registered
        `shouldReturn` Right ()
      BS.readFile path `shouldReturn` before

  it "refuses a coordinator source for another Authority without rewriting it" $
    withPinConfig RpcBirthConfigLegacy $ \_ path -> do
      deadline <- sourcePublicationDeadline
      before <- BS.readFile path
      let boundary =
            tier0RpcBirthPublicationAtPath
              (must (Coordinate.mkAuthorityScope "foreign"))
              path
              (\_ _ -> fail "foreign source must not reach rollout")
      Coordinator.coordinationReadSource boundary deadline >>= (`shouldSatisfy` isLeft)
      Coordinator.coordinationPublishSource boundary deadline RpcBirthConfigLegacy registered
        >>= (`shouldSatisfy` isLeft)
      BS.readFile path `shouldReturn` before

  it "preserves an independently published different pin at the native coordinator boundary" $
    withPinConfig registered $ \_ path -> do
      deadline <- sourcePublicationDeadline
      before <- BS.readFile path
      let boundary =
            tier0RpcBirthPublicationAtPath
              (must (Coordinate.mkAuthorityScope scope))
              path
              (\_ _ -> fail "conflicting source must not reach rollout")
      Coordinator.coordinationPublishSource boundary deadline RpcBirthConfigLegacy replacement
        >>= (`shouldSatisfy` isLeft)
      BS.readFile path `shouldReturn` before

  it
    "retains independent source observation with incompatible parameters and refuses publication safely"
    $ withSystemTempDirectory "prodbox-coordinator-source-invalid"
    $ \directory -> do
      let body = Text.unpack (Tier0.renderProjectConfigDhall (project RpcBirthConfigLegacy))
          malformed = "let source = (" <> body <> ") in source // { parameters = \"fixture-private-sentinel\" }"
          path = tier0FixturePath directory
          boundary =
            tier0RpcBirthPublicationAtPath
              (must (Coordinate.mkAuthorityScope scope))
              path
              (\_ _ -> fail "invalid parameters must not reach rollout")
      writeTier0Fixture directory (rawTier0Fixture (MustNotTypeCheckAgainst "parameters") malformed)
      deadline <- sourcePublicationDeadline
      before <- BS.readFile path
      Coordinator.coordinationReadSource boundary deadline `shouldReturn` Right RpcBirthConfigLegacy
      refused <- Coordinator.coordinationPublishSource boundary deadline RpcBirthConfigLegacy registered
      refused `shouldSatisfy` isLeft
      show refused `shouldSatisfy` (not . Text.isInfixOf "fixture-private-sentinel" . Text.pack)
      BS.readFile path `shouldReturn` before

  it "rejects an expired native source bound before creating a context or lock" $
    withSystemTempDirectory "prodbox-coordinator-source-expired" $ \directory -> do
      let path = tier0FixturePath directory
          boundary =
            tier0RpcBirthPublicationAtPath
              (must (Coordinate.mkAuthorityScope scope))
              path
              (\_ _ -> fail "expired source must not reach rollout")
          expired = authorityTimeFromMicros 0
      Coordinator.coordinationReadSource boundary expired >>= (`shouldSatisfy` isLeft)
      Coordinator.coordinationPublishSource boundary expired RpcBirthConfigLegacy registered
        >>= (`shouldSatisfy` isLeft)
      doesFileExist path `shouldReturn` False
      doesFileExist (path <> ".lock") `shouldReturn` False

  it "carries the public pin through the exact source decoder, settings and sealed floor" $
    withPinConfig registered $ \directory path -> do
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered
      loaded <- must <$> Settings.validateAndLoadSettingsAtPath path directory
      Settings.deploymentRpcRegistration (Settings.validatedDeploymentContext loaded)
        `shouldBe` registered
      loadUnencryptedBasicsAtPath path >>= (`shouldSatisfy` (not . isLeft))

  forM_
    [ ("scope", RpcBirthConfigRegistered (RpcBirthConfigPin "foreign" 1 digest))
    , ("generation", RpcBirthConfigRegistered (RpcBirthConfigPin scope 0 digest))
    , ("digest", RpcBirthConfigRegistered (RpcBirthConfigPin scope 1 "bad"))
    ]
    $ \(name, pin) ->
      it ("refuses an invalid source " <> name <> " before publishing") $
        withSystemTempDirectory "prodbox-pin-invalid" $ \directory -> do
          let path = tier0FixturePath directory
          Tier0.writeTier0AtPath path (project pin) >>= (`shouldSatisfy` isLeft)
          doesFileExist path `shouldReturn` False

  it "preserves the pin while reauthoring parameters" $
    withPinConfig registered $ \_ path -> do
      let updated =
            syntheticConfigFile
              { Settings.domain = (Settings.domain syntheticConfigFile) {Settings.demo_ttl = 321}
              }
      Tier0.writeOperatorParametersToTier0AtPath path updated `shouldReturn` Right ()
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered
      Settings.demo_ttl (Tier0.domain (Tier0.parameters decoded)) `shouldBe` 321

  it "repairs incompatible parameters while preserving the independently readable context" $
    withSystemTempDirectory "prodbox-pin-parameter-repair" $ \directory -> do
      let original = Text.unpack (Tier0.renderProjectConfigDhall (project registered))
          badParameters = "let source = (" <> original <> ") in source // { parameters = 1 }"
          path = tier0FixturePath directory
      writeTier0Fixture directory (rawTier0Fixture (MustNotTypeCheckAgainst "parameters") badParameters)
      Tier0.writeOperatorParametersToTier0AtPath path syntheticConfigFile `shouldReturn` Right ()
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered
      Tier0.cluster_id (Tier0.context decoded) `shouldBe` scope
      Tier0.parameters decoded `shouldBe` Tier0.configFileToTier0Parameters syntheticConfigFile

  it "preserves the pin during setup that changes endpoint coordinates" $
    withPinConfig registered $ \_ path -> do
      Tier0.writeOperatorDeploymentConfigToTier0AtPath
        path
        syntheticConfigFile
        (input RpcBirthConfigLegacy) {Settings.contextInputVaultAddress = "https://vault.new.test"}
        `shouldReturn` Right ()
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered
      Tier0.vault_address (Tier0.context decoded) `shouldBe` "https://vault.new.test"

  it "refuses a scope change while retaining the exact pinned file" $
    withPinConfig registered $ \_ path -> do
      before <- BS.readFile path
      Tier0.writeOperatorDeploymentConfigToTier0AtPath
        path
        syntheticConfigFile
        (input RpcBirthConfigLegacy) {Settings.contextInputClusterId = "foreign"}
        >>= (`shouldSatisfy` isLeft)
      BS.readFile path `shouldReturn` before

  it "preserves the required pin through floor stamping and refuses scope relabeling" $
    withPinConfig registered $ \_ path -> do
      Tier0.writeTier0FloorPreservingParametersAtPath path scope "https://vault.rebuilt.test"
        `shouldReturn` Right ()
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered
      before <- BS.readFile path
      Tier0.writeTier0FloorPreservingParametersAtPath path "foreign" "https://vault.rebuilt.test"
        >>= (`shouldSatisfy` isLeft)
      BS.readFile path `shouldReturn` before

  it "does not replace a published pin through generic generation or setup" $
    withPinConfig registered $ \_ path -> do
      before <- BS.readFile path
      Tier0.writeTier0AtPath path (project RpcBirthConfigLegacy) >>= (`shouldSatisfy` isLeft)
      Tier0.writeOperatorDeploymentConfigToTier0AtPath path syntheticConfigFile (input replacement)
        >>= (`shouldSatisfy` isLeft)
      BS.readFile path `shouldReturn` before

  it "publishes a pin by CAS and confirms a retry without replacing the file" $
    withPinConfig RpcBirthConfigLegacy $ \_ path -> do
      Tier0.compareAndSwapTier0RpcRegistrationAtPath path RpcBirthConfigLegacy registered
        `shouldReturn` Right ()
      before <- getSymbolicLinkStatus path
      Tier0.compareAndSwapTier0RpcRegistrationAtPath path RpcBirthConfigLegacy registered
        `shouldReturn` Right ()
      after <- getSymbolicLinkStatus path
      fileID after `shouldBe` fileID before
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered

  it "refuses stale, foreign, replacement and unpin requests without changing source" $
    withPinConfig registered $ \_ path -> do
      before <- BS.readFile path
      forM_
        [(RpcBirthConfigLegacy, replacement), (registered, replacement), (registered, RpcBirthConfigLegacy)]
        $ \(old, next) ->
          Tier0.compareAndSwapTier0RpcRegistrationAtPath path old next >>= (`shouldSatisfy` isLeft)
      BS.readFile path `shouldReturn` before

  it "confirms an applied publication after its caller loses the reply" $
    withPinConfig RpcBirthConfigLegacy $ \_ path -> do
      lost <- try $ do
        Tier0.compareAndSwapTier0RpcRegistrationAtPath path RpcBirthConfigLegacy registered
          `shouldReturn` Right ()
        throwIO ThreadKilled
      (lost :: Either AsyncException ()) `shouldBe` Left ThreadKilled
      Tier0.compareAndSwapTier0RpcRegistrationAtPath path RpcBirthConfigLegacy registered
        `shouldReturn` Right ()
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered

  it "does not publish into a missing source context" $
    withSystemTempDirectory "prodbox-pin-missing" $ \directory -> do
      let path = tier0FixturePath directory
      Tier0.compareAndSwapTier0RpcRegistrationAtPath path RpcBirthConfigLegacy registered
        >>= (`shouldSatisfy` isLeft)
      doesFileExist path `shouldReturn` False

  forM_ [False, True] $ \oldSchema ->
    it ("retains undecodable existing source without defaulting, old schema = " <> show oldSchema) $
      withSystemTempDirectory "prodbox-pin-corrupt" $ \directory -> do
        let original = Text.unpack (Tier0.renderProjectConfigDhall (project registered))
            source =
              if oldSchema
                then
                  "let source = ("
                    <> original
                    <> ") in source // { context = source.context.{ project, binary, context_kind, cluster_id, vault_address, minio_endpoint, topology, capabilities } }"
                else "{ broken = }"
            path = tier0FixturePath directory
        writeTier0Fixture
          directory
          (rawTier0Fixture (MustNotTypeCheckAgainst "context.rpc_registration") source)
        before <- BS.readFile path
        Tier0.writeOperatorParametersToTier0AtPath path syntheticConfigFile >>= (`shouldSatisfy` isLeft)
        Tier0.writeOperatorDeploymentConfigToTier0AtPath
          path
          syntheticConfigFile
          (input RpcBirthConfigLegacy)
          >>= (`shouldSatisfy` isLeft)
        BS.readFile path `shouldReturn` before

  it "refuses literal secret proposals before rendering or writing them" $
    withPinConfig registered $ \_ path -> do
      let previous = project registered
          parameters = Tier0.parameters previous
          credentials = Tier0.aws parameters
          unsafe =
            previous
              { Tier0.parameters =
                  parameters
                    { Tier0.aws =
                        credentials {Settings.awsCredentialAccessKeyId = SecretRefTestPlaintext "must-never-be-rendered"}
                    }
              }
      before <- BS.readFile path
      refused <- Tier0.writeTier0AtPath path unsafe
      refused `shouldSatisfy` isLeft
      show refused `shouldNotContain` "must-never-be-rendered"
      BS.readFile path `shouldReturn` before

  it "preserves permissions and keeps new public config readable by the daemon" $
    withPinConfig registered $ \_ path -> do
      public <- getSymbolicLinkStatus path
      fileMode public `intersectFileModes` otherReadMode `shouldBe` otherReadMode
      setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode)
      Tier0.writeOperatorParametersToTier0AtPath path syntheticConfigFile `shouldReturn` Right ()
      private <- getSymbolicLinkStatus path
      fileMode private
        `intersectFileModes` accessModes
        `shouldBe` (ownerReadMode `unionFileModes` ownerWriteMode)

  it "refuses a concurrent canonical writer in the same process" $
    withPinConfig RpcBirthConfigLegacy $ \_ path -> do
      started <- newEmptyMVar
      release <- newEmptyMVar
      let held =
            modifyTier0File
              path
              (\_ -> putMVar started () >> takeMVar release >> pure (Right (Tier0FileKeep ())))
      withAsync held $ \worker -> do
        takeMVar started
        Tier0.writeOperatorParametersToTier0AtPath path syntheticConfigFile >>= (`shouldSatisfy` isLeft)
        putMVar release ()
        wait worker `shouldReturn` Right ()
      Tier0.compareAndSwapTier0RpcRegistrationAtPath path RpcBirthConfigLegacy registered
        `shouldReturn` Right ()
      Tier0.writeOperatorParametersToTier0AtPath path syntheticConfigFile `shouldReturn` Right ()
      decoded <- must <$> Tier0.decodeProjectConfigDhall path
      Tier0.rpc_registration (Tier0.context decoded) `shouldBe` registered

  it "propagates cancellation and releases both locks" $
    withPublicFile $ \path -> do
      BS.writeFile path "before"
      interrupted <- try (modifyTier0File path (\_ -> throwIO ThreadKilled))
      (interrupted :: Either AsyncException (Either Tier0FileError ())) `shouldBe` Left ThreadKilled
      replacePublic path "after" `shouldReturn` Right ()
      BS.readFile path `shouldReturn` "after"

  it "refuses an input changed outside the canonical lock" $
    withPublicFile $ \path -> do
      BS.writeFile path "before"
      result <- modifyTier0File path $ \_ -> do
        BS.writeFile path "external-change"
        pure (Right (Tier0FileReplace "stale-overwrite" ()))
      result `shouldBe` Left Tier0FileChanged
      BS.readFile path `shouldReturn` "external-change"

  it "bounds both existing input and proposed output" $
    withPublicFile $ \path -> do
      let oversized = BS.replicate (tier0FileMaximumBytes + 1) 65
      BS.writeFile path oversized
      reached <- newIORef False
      modifyTier0File path (\_ -> writeIORef reached True >> pure (Right (Tier0FileKeep ())))
        `shouldReturn` Left Tier0FileTooLarge
      readIORef reached `shouldReturn` False
      BS.writeFile path "before"
      replacePublic path oversized `shouldReturn` Left Tier0FileTooLarge
      BS.readFile path `shouldReturn` "before"

  forM_ ["symlink", "dangling", "directory", "fifo", "hardlink", "writable"] $ \kind ->
    it ("refuses unsafe host input without following or blocking: " <> kind) $
      withSystemTempDirectory "prodbox-pin-kind" $ \directory -> do
        let path = directory </> "public-input"
            target = directory </> "target"
        BS.writeFile target "protected"
        case kind of
          "symlink" -> createSymbolicLink target path
          "dangling" -> createSymbolicLink (directory </> "absent") path
          "directory" -> createDirectory path
          "fifo" -> createNamedPipe path ownerReadMode
          "hardlink" -> createLink target path
          "writable" ->
            BS.writeFile path "before"
              >> setFileMode path (ownerReadMode `unionFileModes` ownerWriteMode `unionFileModes` otherWriteMode)
          _ -> fail "closed fixture kind"
        attempted <- timeout 1000000 (replacePublic path "forbidden")
        attempted `shouldSatisfy` maybe False isLeft
        BS.readFile target `shouldReturn` "protected"

  forM_ [".lock", ".publish.tmp"] $ \suffix ->
    it ("refuses an unsafe publication sidecar " <> suffix) $
      withPublicFile $ \path -> do
        BS.writeFile path "before"
        let target = path <> ".target"
        BS.writeFile target "protected"
        createSymbolicLink target (path <> suffix)
        replacePublic path "forbidden" >>= (`shouldSatisfy` isLeft)
        BS.readFile path `shouldReturn` "before"
        BS.readFile target `shouldReturn` "protected"

  it "does not adopt a stale temporary proposal" $
    withPublicFile $ \path -> do
      BS.writeFile path "current"
      BS.writeFile (path <> ".publish.tmp") "unconfirmed-old-proposal"
      replacePublic path "new" `shouldReturn` Right ()
      BS.readFile path `shouldReturn` "new"
      doesFileExist (path <> ".publish.tmp") `shouldReturn` False

  it "honors another process's record lock" $
    withPublicFile $ \path ->
      bracket
        ( openFd
            (path <> ".lock")
            ReadWrite
            defaultFileFlags {creat = Just (ownerReadMode `unionFileModes` ownerWriteMode)}
        )
        closeFd
        ( \fd -> do
            setLock fd (WriteLock, AbsoluteSeek, 0, 0)
            binary <- getExecutablePath
            status <-
              timeout 2000000 (readProcessWithExitCode binary ["--tier0-publication-lock-probe", path] "")
            fmap (\(code, _, _) -> code) status `shouldBe` Just ExitSuccess
        )

-- A fresh executable process avoids inheriting the parent's Haskell locks.
-- This helper is owned by the unit frontend, never the production CLI.
runTier0PublicationHelper :: [String] -> IO Bool
runTier0PublicationHelper arguments = case arguments of
  ["--tier0-publication-lock-probe", path] -> do
    result <- modifyTier0File path (\_ -> pure (Right (Tier0FileKeep ())))
    if result == Left Tier0FileBusy
      then pure True
      else fail "external Tier-0 record lock was not respected"
  _ -> pure False

scope :: Text.Text
scope = "synthetic-test-cluster"

sourcePublicationDeadline :: IO AuthorityTime
sourcePublicationDeadline = do
  now <- rpcBirthSystemTime
  pure (authorityTimeFromMicros (authorityTimeMicros now + 10000000))

digest :: Text.Text
digest = Text.replicate 64 "a"

registered, replacement :: RpcBirthConfig
registered = RpcBirthConfigRegistered (RpcBirthConfigPin scope 1 digest)
replacement = RpcBirthConfigRegistered (RpcBirthConfigPin scope 2 (Text.replicate 64 "b"))

project :: RpcBirthConfig -> Tier0.ProdboxProjectConfig
project pin =
  syntheticProjectConfig
    { Tier0.context = (Tier0.context syntheticProjectConfig) {Tier0.rpc_registration = pin}
    }

input :: RpcBirthConfig -> Settings.DeploymentContextInput
input pin = Settings.DeploymentContextInput scope "http://127.0.0.1:31820" "http://127.0.0.1:39000" pin

withPinConfig :: RpcBirthConfig -> (FilePath -> FilePath -> IO value) -> IO value
withPinConfig pin action = withSystemTempDirectory "prodbox-rpc-pin" $ \directory -> do
  let path = tier0FixturePath directory
  Tier0.writeTier0AtPath path (project pin) `shouldReturn` Right ()
  action directory path

withPublicFile :: (FilePath -> IO value) -> IO value
withPublicFile action = withSystemTempDirectory "prodbox-public-file" $ \directory -> action (directory </> "public-input")

replacePublic :: FilePath -> BS.ByteString -> IO (Either Tier0FileError ())
replacePublic path bytes = modifyTier0File path (const (pure (Right (Tier0FileReplace bytes ()))))

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
