{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- Actual canonical owner/manager/kernel boundaries, with synthetic inputs.
-- Canonical health reads and expiry share the original native profile.
-- No Authority or AWS effect is requested.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import HostOperationRpcBirthFixture
import Prodbox.Config.LocalRke2RecoveryState.Internal qualified as Health
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
import "crypton" Crypto.Random (getRandomBytes)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "internal-rpc-birth-controller" : flags -> worker Identity.RpcBirthController flags
    "internal-cascade-controller" : flags -> worker Identity.OrdinaryCascadeController flags
    [mode, directory] | mode `elem` ["observe", "expired"] -> launch mode directory
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
          let mode = Bytes.unpack (Family.hostControllerRequestBytes bytes)
          helper <- maybe (fail "helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
          intent <- right =<< Family.newHostOperationIntent kind plan helper key window
          uid <- getEffectiveUserID
          borrowed <- newIORef Nothing
          entered <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) (socket uid) $ \connection -> lift $
            Kernel.withObservedOperationParent connection intent program $ \owner -> do
              checked <- Kernel.verifyOperationParentBeforeEffect owner
              case checked of
                Left cause -> pure (Left cause)
                Right () -> do
                  unless (kind == Identity.OrdinaryCascadeController) (fail "health fixture requires ordinary kind")
                  limits <- right (Process.mkOperationStreamLimits 131072 8192 100000)
                  transport <- right (Process.mkOperationStreamLimits 4096 4096 100000)
                  owned <- right (Process.operationSubprocesses owner limits transport)
                  writeIORef borrowed (Just owned)
                  checks <- checkHealth mode work owned
                  Lazy.writeFile (takeDirectory configuration </> "health-checks.json") (encode checks)
                  writeFile (takeDirectory configuration </> "controller-kind-observed") (show kind)
                  pure (Right owned)
          let closing = fmap void entered
          writeFile (takeDirectory configuration </> "parent-closing-result") (show closing)
          if mode == "expired"
            then
              unless
                (closing == Right (Left Kernel.KernelScopeDeadlineReached))
                (fail "expired parent did not preserve its closing refusal")
            else right =<< right closing
          owned <- readIORef borrowed >>= maybe (fail "original parent was not borrowed") pure
          escaped <- Health.observeLocalRke2RecoveryStateInOperation owned
          case escaped of
            Left
              ( Health.LocalRke2RecoveryStateOperationRefused
                  (Process.OperationScopeRefused Kernel.KernelHostPlacementClosed)
                ) -> pure ()
            _ -> fail "escaped health owner did not refuse as closed"
          writeFile (takeDirectory configuration </> "controller-complete") "complete"
      )

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
        (Bytes.pack mode)
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
                                  checks <- BS.readFile (takeDirectory configuration </> "health-checks.json")
                                  BS.writeFile (directory </> "health-checks.json") checks
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

checkHealth
  :: (Integral clock)
  => String -> clock -> Process.OperationSubprocesses -> IO [(String, Bool)]
checkHealth mode ending owned = do
  case mode of
    "observe" -> do
      observed <- Health.observeLocalRke2RecoveryStateInOperation owned
      case observed of
        Right state ->
          check "canonical-host-observation-completed" $
            Health.localRke2RecoveryStateView state
              `elem` [Health.LocalRke2RecoveryHealthy, Health.LocalRke2RecoveryStopped, Health.LocalRke2RecoveryAbsent]
        Left (Health.LocalRke2RecoveryStateUnobservable failures) ->
          check "canonical-host-ambiguity-remains-unobservable" $
            all completedCommandFailure (NonEmpty.toList failures)
        Left cause -> fail (show cause)
    "expired" -> do
      waitUntil ending ((>= toInteger ending) . toInteger <$> getMonotonicTimeNSec)
      observed <- Health.observeLocalRke2RecoveryStateInOperation owned
      check "original-work-expiry-refuses-health-observation" $
        observed
          == Left
            ( Health.LocalRke2RecoveryStateOperationRefused
                (Process.OperationScopeRefused Kernel.KernelScopeDeadlineReached)
            )
    _ -> fail "unknown health scenario"
 where
  check label passed = unless passed (fail label) >> pure [(label, passed)]
  completedCommandFailure failure =
    let detail = Health.localRke2RecoveryObservationFailureDetail failure
     in not
          ( any
              (`Text.isInfixOf` detail)
              ["OperationScopeRefused", "OperationProcessRefused", "OperationTransportExited"]
          )

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
