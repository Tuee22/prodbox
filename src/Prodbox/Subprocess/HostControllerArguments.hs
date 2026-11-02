-- | Closed wire arguments shared by the family declaration and its loader.
-- These values grant neither a file lease nor physical/Authority admission.
module Prodbox.Subprocess.HostControllerArguments
  ( HostControllerArguments (..)
  , HostControllerArgumentsError (..)
  , parseHostControllerArguments
  , renderHostControllerArguments
  ) where

import Control.Monad (unless)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Subprocess.HostControllerInputs
  ( HostControllerInputFingerprint
  , hostControllerInputFingerprintText
  , parseHostControllerInputFingerprint
  )
import Prodbox.Subprocess.SystemdIdentity
import System.FilePath (isAbsolute, normalise, splitDirectories, takeFileName)

data HostControllerArguments = HostControllerArguments
  { controllerConfigurationPath :: !FilePath
  , controllerRequestPath :: !FilePath
  , controllerInputFingerprint :: !HostControllerInputFingerprint
  , controllerOperationKey :: !HostExecutionKey
  , controllerOriginalWindow :: !HostExecutionWindow
  }
  deriving (Eq)

instance Show HostControllerArguments where
  showsPrec precedence = showsPrec precedence . renderHostControllerArguments

data HostControllerArgumentsError
  = ControllerArgumentsShapeInvalid
  | ControllerArgumentsPathInvalid
  | ControllerArgumentsFingerprintInvalid
  | ControllerArgumentsKeyInvalid
  | ControllerArgumentsClockInvalid
  deriving (Eq, Show)

parseHostControllerArguments
  :: [String] -> Either HostControllerArgumentsError HostControllerArguments
parseHostControllerArguments arguments = case arguments of
  [ "--config"
    , configuration
    , "--request"
    , request
    , "--input-fingerprint"
    , fingerprintText
    , "--operation-key"
    , keyText
    , "--outer-ns"
    , outerText
    , "--work-ns"
    , workText
    , "--hard-ns"
    , hardText
    , "--stop-ns"
    , stopText
    , "--finish-ns"
    , finishText
    ] -> do
      unless (validPath configuration && validPath request) (Left ControllerArgumentsPathInvalid)
      fingerprint <-
        maybe
          (Left ControllerArgumentsFingerprintInvalid)
          Right
          (parseHostControllerInputFingerprint fingerprintText)
      key <- maybe (Left ControllerArgumentsKeyInvalid) Right (hostExecutionKeyFromText keyText)
      outer <- clock outerText
      work <- clock workText
      hard <- clock hardText
      stop <- clock stopText
      finish <- clock finishText
      window <-
        maybe (Left ControllerArgumentsClockInvalid) Right (hostExecutionWindow outer work hard stop finish)
      pure (HostControllerArguments configuration request fingerprint key window)
  _ -> Left ControllerArgumentsShapeInvalid
 where
  validPath value =
    length (take 4097 value) <= 4096
      && '\0' `notElem` value
      && isAbsolute value
      && normalise value == value
      && all (`notElem` [".", ".."]) (splitDirectories value)
      && takeFileName value `notElem` ["", ".", ".."]
  clock value = do
    let canonical = case value of
          [] -> False
          '0' : _ -> False
          _ -> True
    unless
      (length (take 21 value) <= 20 && canonical && all (\c -> c >= '0' && c <= '9') value)
      (Left ControllerArgumentsClockInvalid)
    let number = foldl' (\total digit -> total * 10 + fromIntegral (fromEnum digit - 48)) 0 value :: Natural
    unless
      (number > 0 && number < fromIntegral (maxBound :: Word64))
      (Left ControllerArgumentsClockInvalid)
    pure (fromIntegral number)

renderHostControllerArguments :: HostControllerArguments -> [String]
renderHostControllerArguments arguments =
  [ "--config"
  , controllerConfigurationPath arguments
  , "--request"
  , controllerRequestPath arguments
  , "--input-fingerprint"
  , hostControllerInputFingerprintText (controllerInputFingerprint arguments)
  , "--operation-key"
  , hostExecutionKeyText (controllerOperationKey arguments)
  ]
    <> concatMap
      (\(flag, field) -> [flag, show (field (controllerOriginalWindow arguments))])
      [ ("--outer-ns", hostExecutionOuterEnd)
      , ("--work-ns", hostExecutionWorkEnd)
      , ("--hard-ns", hostExecutionHardEnd)
      , ("--stop-ns", hostExecutionStopEnd)
      , ("--finish-ns", hostExecutionFinishEnd)
      ]
