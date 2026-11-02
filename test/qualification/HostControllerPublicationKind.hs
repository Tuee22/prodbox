{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- Actual canonical owner/manager/kernel boundaries, with synthetic inputs.
-- Four closed publisher/controller combinations share the original native
-- profile. No Authority or AWS effect is requested.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import GHC.Clock (getMonotonicTimeNSec)
import HostOperationRpcBirthFixture
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
    ["birth", directory] -> launch Identity.RpcBirthController Identity.RpcBirthController directory
    ["cross", directory] -> launch Identity.RpcBirthController Identity.OrdinaryCascadeController directory
    ["ordinary", directory] -> launch Identity.OrdinaryCascadeController Identity.OrdinaryCascadeController directory
    ["reverse", directory] -> launch Identity.OrdinaryCascadeController Identity.RpcBirthController directory
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
          helper <- maybe (fail "helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
          intent <- right =<< Family.newHostOperationIntent kind plan helper key window
          uid <- getEffectiveUserID
          entered <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) (socket uid) $ \connection -> lift $
            Kernel.withObservedOperationParent connection intent program $ \owner -> do
              checked <- Kernel.verifyOperationParentBeforeEffect owner
              case checked of
                Left cause -> pure (Left cause)
                Right () -> do
                  writeFile (takeDirectory configuration </> "controller-kind-observed") (show kind)
                  pure (Right ())
          right =<< right entered
      )

launch :: Identity.HostControllerKind -> Identity.HostControllerKind -> FilePath -> IO ()
launch publisherKind kind supplied = do
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
        "synthetic closed request"
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
                                  waitUntil work (doesFileExist (takeDirectory configuration </> "controller-kind-observed"))
                                  seen <- readFile (takeDirectory configuration </> "controller-kind-observed")
                                  unless (seen == show kind) (fail "controller kind differed from the selected program")
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
