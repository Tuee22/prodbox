module Prodbox.Host.Lift
  ( ContainerLift (..)
  , HostDispatch (..)
  , IncusVM (..)
  , LiftLayer (..)
  , SelfRef (..)
  , clusterFrame
  , defaultIncusVM
  , foldHostLift
  )
where

import Prodbox.Host.Lima (LimaVM (..), defaultLimaVM, limaShellPrefix)
import Prodbox.Host.Substrate (HostSubstrate (..))
import Prodbox.Host.Wsl2 (Wsl2VM (..), defaultWsl2VM, wsl2ShellPrefix)

newtype SelfRef = SelfRef {selfRefPath :: FilePath}
  deriving (Eq, Show)

data HostDispatch = HostDispatch
  { dispatchProgram :: FilePath
  , dispatchArguments :: [String]
  }
  deriving (Eq, Show)

newtype IncusVM = IncusVM {incusVmName :: String}
  deriving (Eq, Ord, Show)

newtype ContainerLift = ContainerLift {containerLiftImage :: String}
  deriving (Eq, Ord, Show)

data LiftLayer
  = ViaVM IncusVM
  | ViaLimaVM LimaVM
  | ViaWsl2VM Wsl2VM
  | ViaContainer ContainerLift
  deriving (Eq, Ord, Show)

defaultIncusVM :: IncusVM
defaultIncusVM = IncusVM "prodbox-ubuntu-2404"

clusterFrame :: HostSubstrate -> [LiftLayer]
clusterFrame substrate =
  case substrate of
    AppleSilicon -> [ViaLimaVM defaultLimaVM]
    WindowsCpu -> [ViaWsl2VM defaultWsl2VM]
    WindowsGpu -> [ViaWsl2VM defaultWsl2VM]
    LinuxCpu -> []
    LinuxGpu -> []

foldHostLift :: SelfRef -> [LiftLayer] -> [String] -> HostDispatch
foldHostLift self layers commandArgs =
  foldr wrapLayer (HostDispatch (selfRefPath self) commandArgs) layers

wrapLayer :: LiftLayer -> HostDispatch -> HostDispatch
wrapLayer layer inner =
  case layer of
    ViaVM vm ->
      HostDispatch
        "incus"
        (["exec", incusVmName vm, "--", dispatchProgram inner] ++ dispatchArguments inner)
    ViaLimaVM vm ->
      HostDispatch "limactl" (limaShellPrefix vm ++ [dispatchProgram inner] ++ dispatchArguments inner)
    ViaWsl2VM vm -> HostDispatch "wsl" (wsl2ShellPrefix vm ++ [dispatchProgram inner] ++ dispatchArguments inner)
    ViaContainer lift ->
      HostDispatch
        "docker"
        (["run", "--rm", containerLiftImage lift, dispatchProgram inner] ++ dispatchArguments inner)
