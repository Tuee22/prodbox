{-# LANGUAGE CPP #-}

module Prodbox.Host.Tool
  ( AbsExe
  , HostTool (..)
  , absExePath
  , hostToolCommandName
  , mkAbsExe
  , resolveHostTool
  )
where

import System.Directory (findExecutable)
import System.FilePath (isAbsolute)

#ifdef mingw32_HOST_OS
data HostTool
  = Docker
  | Rke2
  | Kubectl
  | Helm
  | Kind
  | Sudo
  | Sysctl
  | Limactl
  | Incus
  | Wsl
  | Bcdedit
  deriving (Eq, Ord, Show)
#else
data HostTool
  = Docker
  | Rke2
  | Kubectl
  | Helm
  | Kind
  | Sudo
  | Sysctl
  | Limactl
  | Incus
  deriving (Eq, Ord, Show)
#endif

newtype AbsExe = AbsExe {absExePath :: FilePath}
  deriving (Eq, Show)

mkAbsExe :: FilePath -> Either String AbsExe
mkAbsExe path
  | isAbsolute path = Right (AbsExe path)
  | otherwise = Left ("not an absolute path: " ++ path)

hostToolCommandName :: HostTool -> FilePath
#ifdef mingw32_HOST_OS
hostToolCommandName tool =
  case tool of
    Docker -> "docker"
    Rke2 -> "rke2"
    Kubectl -> "kubectl"
    Helm -> "helm"
    Kind -> "kind"
    Sudo -> "sudo"
    Sysctl -> "sysctl"
    Limactl -> "limactl"
    Incus -> "incus"
    Wsl -> "wsl"
    Bcdedit -> "bcdedit"
#else
hostToolCommandName tool =
  case tool of
    Docker -> "docker"
    Rke2 -> "rke2"
    Kubectl -> "kubectl"
    Helm -> "helm"
    Kind -> "kind"
    Sudo -> "sudo"
    Sysctl -> "sysctl"
    Limactl -> "limactl"
    Incus -> "incus"
#endif

resolveHostTool :: HostTool -> IO (Either String AbsExe)
resolveHostTool tool = do
  maybePath <- findExecutable (hostToolCommandName tool)
  pure $ case maybePath of
    Nothing -> Left ("missing host tool: " ++ hostToolCommandName tool)
    Just path -> mkAbsExe path
