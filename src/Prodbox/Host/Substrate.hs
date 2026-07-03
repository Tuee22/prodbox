module Prodbox.Host.Substrate
  ( HostSubstrate (..)
  , classifyHost
  , detectHostSubstrate
  , hostSubstrateNeedsLift
  , renderHostSubstrate
  )
where

import Data.Char (toLower)
import Data.Maybe (isJust)
import System.Directory (findExecutable)
import System.Info qualified as SystemInfo

data HostSubstrate
  = AppleSilicon
  | LinuxCpu
  | LinuxGpu
  | WindowsCpu
  | WindowsGpu
  deriving (Eq, Ord, Show)

classifyHost :: String -> String -> Bool -> Either String HostSubstrate
classifyHost osName rawArch hasGpu =
  case map toLower osName of
    "darwin"
      | isArm64 rawArch -> Right AppleSilicon
      | otherwise -> Left "prodbox supports Apple Silicon (arm64) only on macOS"
    "linux" -> Right (if hasGpu then LinuxGpu else LinuxCpu)
    "mingw32" -> Right (if hasGpu then WindowsGpu else WindowsCpu)
    "cygwin32" -> Right (if hasGpu then WindowsGpu else WindowsCpu)
    other -> Left ("unsupported host platform: " ++ other)

detectHostSubstrate :: IO (Either String HostSubstrate)
detectHostSubstrate = do
  hasGpu <- isJust <$> findExecutable "nvidia-smi"
  pure (classifyHost SystemInfo.os SystemInfo.arch hasGpu)

hostSubstrateNeedsLift :: HostSubstrate -> Bool
hostSubstrateNeedsLift substrate =
  case substrate of
    AppleSilicon -> True
    WindowsCpu -> True
    WindowsGpu -> True
    LinuxCpu -> False
    LinuxGpu -> False

renderHostSubstrate :: HostSubstrate -> String
renderHostSubstrate substrate =
  case substrate of
    AppleSilicon -> "apple-silicon"
    LinuxCpu -> "linux-cpu"
    LinuxGpu -> "linux-gpu"
    WindowsCpu -> "windows-cpu"
    WindowsGpu -> "windows-gpu"

isArm64 :: String -> Bool
isArm64 rawArch =
  map toLower rawArch `elem` ["arm64", "aarch64"]
