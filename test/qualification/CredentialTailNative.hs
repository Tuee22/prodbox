{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- Actual canonical owner/manager/kernel boundaries, with synthetic inputs.
-- Credential Job/coordinator/worker/tail controls share the original native profile.
-- No live Authority, Kubernetes or AWS service is contacted.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import CredentialTailMockKubectl (runMockKubectl)
import CredentialTailNativeScenario
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import HostOperationRpcBirthFixture
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Subprocess qualified as Process
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputRetirement qualified as Reaper
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)
import "crypton" Crypto.Random (getRandomBytes)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "internal-rpc-birth-controller" : flags -> worker Identity.RpcBirthController flags
    "internal-cascade-controller" : flags -> worker Identity.OrdinaryCascadeController flags
    "--kubeconfig" : _ -> runMockKubectl arguments
    [mode, directory]
      | mode `elem` ["healthy", "empty-attach", "cleanup-held", "cleanup-released"] ->
          launch mode directory
    _ -> fail "expected one closed publication-kind fixture"

worker :: Identity.HostControllerKind -> [String] -> IO ()
worker kind flags = do
  arguments <- right (Arguments.parseHostControllerArguments flags)
  let window = Arguments.controllerOriginalWindow arguments
      work = Identity.hostExecutionWorkEnd window
      key = Arguments.controllerOperationKey arguments
      configuration = Arguments.controllerConfigurationPath arguments
      request = Arguments.controllerRequestPath arguments
  right
    =<< Family.withPinnedHostControllerProgram
      kind
      work
      (Arguments.controllerInputFingerprint arguments)
      configuration
      request
      ( \program -> do
          bytes <- right =<< Family.readHostControllerProgramInputs program
          observed <- right (decodeObserved (Lazy.fromStrict (Family.hostControllerConfigurationBytes bytes)))
          plan <- fixturePlanFrom observed
          let (mode, encodedDeadline) = break (== ':') (Bytes.unpack (Family.hostControllerRequestBytes bytes))
          deadlineMicros <-
            maybe (fail "original authority deadline absent") pure (readMaybe (drop 1 encodedDeadline))
          let deadline = authorityTimeFromMicros deadlineMicros
          helper <- maybe (fail "helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
          intent <- right =<< Family.newHostOperationIntent kind plan helper key window
          uid <- getEffectiveUserID
          borrowed <- newIORef Nothing
          borrowedRetirement <- newIORef Nothing
          entered <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) (socket uid) $ \connection -> lift $
            Kernel.withObservedOperationParent connection intent program $ \owner -> do
              checked <- Kernel.verifyOperationParentBeforeEffect owner
              case checked of
                Left cause -> pure (Left cause)
                Right () -> do
                  unless
                    (kind == Identity.OrdinaryCascadeController)
                    (fail "credential fixture requires ordinary kind")
                  limits <- right (Process.mkOperationStreamLimits 131072 8192 100000)
                  transport <- right (Process.mkOperationStreamLimits 4096 4096 100000)
                  owned <- right (Process.operationSubprocesses owner limits transport)
                  writeIORef borrowed (Just owned)
                  checks <- checkCredentialTail mode deadline configuration owned borrowedRetirement
                  Lazy.writeFile (takeDirectory configuration </> "credential-checks.json") (encode checks)
                  writeFile (takeDirectory configuration </> "controller-kind-observed") (show kind)
                  -- This negative control deliberately reaches the original
                  -- work end; it must preserve the parent's closing refusal.
                  when (mode == "cleanup-held") (awaitOriginalWorkEnd work)
                  pure (Right owned)
          let closing = fmap void entered
          writeFile (takeDirectory configuration </> "parent-closing-result") (show closing)
          if mode == "cleanup-held"
            then
              unless
                (closing == Right (Left Kernel.KernelScopeDeadlineReached))
                (fail "held credential Job did not preserve original-work closing refusal")
            else right =<< right closing
          owned <- readIORef borrowed >>= maybe (fail "original parent was not borrowed") pure
          escaped <- Process.verifyOperationSubprocessesBeforeEffect owned
          case escaped of
            Left (Process.OperationScopeRefused Kernel.KernelHostPlacementClosed) -> pure ()
            _ -> fail "escaped credential parent did not refuse as closed"
          retirement <- readIORef borrowedRetirement >>= maybe (fail "retirement was not borrowed") pure
          verifyBorrowedRetirement retirement
          writeFile (takeDirectory configuration </> "controller-complete") "complete"
      )

awaitOriginalWorkEnd :: Word64 -> IO ()
awaitOriginalWorkEnd ending = do
  now <- getMonotonicTimeNSec
  when (now < ending) (threadDelay 1000 >> awaitOriginalWorkEnd ending)

launch :: String -> FilePath -> IO ()
launch mode supplied = do
  let publisherKind = Identity.OrdinaryCascadeController
      kind = Identity.OrdinaryCascadeController
  directory <- makeAbsolute supplied
  setFileMode directory 0o700
  (plan, observed) <- fixturePlan
  nonce <- getRandomBytes 32
  key <-
    maybe
      (fail "fixture key")
      pure
      (Identity.hostExecutionKeyFromText (concatMap hexadecimal (BS.unpack nonce)))
  started <- getMonotonicTimeNSec
  authorityStarted <- getPOSIXTime
  let authorityDeadlineMicros = floor (authorityStarted * 1000000) + 15000000 :: Integer
  let outer = started + 20000000000
      work = started + 15000000000
      hard = started + 16000000000
      stop = started + 17000000000
      finish = started + 18000000000
  window <-
    maybe (fail "fixture window") pure (Identity.hostExecutionWindow outer work hard stop finish)
  helper <- maybe (fail "helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
  intent <- right =<< Family.newHostOperationIntent kind plan helper key window
  uid <- getEffectiveUserID
  result <-
    right
      =<< Publication.withPublishedHostControllerOwner
        publisherKind
        work
        key
        (Lazy.toStrict (encode (observedValue observed)))
        (Bytes.pack (mode <> ":" <> show authorityDeadlineMicros))
        ( \publication -> do
            let (configuration, request) = Publication.hostPublicationPaths publication
            Lazy.writeFile (directory </> "field.json") $
              encode $
                object
                  [ "kind" .= show kind
                  , "key" .= Identity.hostExecutionKeyText key
                  , "configuration" .= configuration
                  , "request" .= request
                  , "units" .= map (Family.hostOperationUnitName intent) [minBound .. maxBound]
                  , "outer_ns" .= outer
                  , "work_ns" .= work
                  , "hard_ns" .= hard
                  , "stop_ns" .= stop
                  , "finish_ns" .= finish
                  ]
            right
              =<< Publication.withHostPublicationSubmission
                publication
                ( \permit ->
                    right
                      =<< Family.withCurrentHostControllerProgram
                        kind
                        work
                        configuration
                        request
                        ( \program -> do
                            submitted <- Bus.withSystemdBus outer (socket uid) $ \connection -> lift $ do
                              sent <- Family.submitPublishedHostOperationFamily permit connection intent program
                              writeFile (directory </> "submission-result") (show sent)
                              case sent of
                                Left cause -> pure (Left cause)
                                Right () -> do
                                  waitUntil stop (doesFileExist (takeDirectory configuration </> "controller-complete"))
                                  seen <- readFile (takeDirectory configuration </> "controller-kind-observed")
                                  unless (seen == show kind) (fail "controller kind differed from the selected program")
                                  checks <- BS.readFile (takeDirectory configuration </> "credential-checks.json")
                                  BS.writeFile (directory </> "credential-checks.json") checks
                                  waitUntil finish $
                                    Family.hostOperationAbsent
                                      <$> (right =<< runExceptT (Family.observeHostOperationFamily connection intent))
                                  pure (Right ())
                            right submitted
                        )
                )
        )
        ( \disposition -> do
            ending <- (+ 10000000000) <$> getMonotonicTimeNSec
            case disposition of
              Publication.PublicationNeverSent proof -> do
                _ <- right =<< Reaper.retireNeverSentHostControllerInputs ending proof
                pure ("never-sent" :: String)
              Publication.PublicationPossiblySent -> do
                let published = Publication.hostControllerPublishedDirectory publisherKind uid key
                    request = published </> Publication.hostControllerRequestName
                closed <- Bus.withSystemdBus ending (socket uid) $ \connection -> lift $ do
                  record <- right =<< Inputs.readHostControllerSubmission ending request key
                  writeFile (directory </> "retirement-kind") (show (Inputs.hostControllerSubmissionKind record))
                  Retirement.withHostOperationRetirement connection record $ \owner -> do
                    receipt <- right =<< Reaper.retireHostControllerInputs ending owner record
                    unless
                      (Reaper.hostInputRetirementReceiptMatches receipt record)
                      (fail "input retirement changed the original record")
                _ <- right =<< right closed
                pure "submitted"
        )
  writeFile (directory </> "closing-result") (show result)

socket :: (Show uid) => uid -> FilePath
socket uid = "/run/user/" <> show uid <> "/bus"

waitUntil :: (Integral clock) => clock -> IO Bool -> IO ()
waitUntil ending test = do
  done <- test
  unless done $ do
    now <- getMonotonicTimeNSec
    if toInteger now >= toInteger ending
      then fail "original fixture observation deadline reached"
      else threadDelay 1000 >> waitUntil ending test

hexadecimal :: (Integral byte) => byte -> String
hexadecimal value = [digits !! (fromIntegral value `div` 16), digits !! (fromIntegral value `mod` 16)]
 where
  digits = "0123456789abcdef"
