module Prodbox.Host.Wsl2
  ( Wsl2VM (..)
  , defaultWsl2VM
  , wsl2ShellPrefix
  )
where

newtype Wsl2VM = Wsl2VM {wsl2DistroName :: String}
  deriving (Eq, Ord, Show)

defaultWsl2VM :: Wsl2VM
defaultWsl2VM = Wsl2VM "prodbox-ubuntu-2404"

wsl2ShellPrefix :: Wsl2VM -> [String]
wsl2ShellPrefix vm =
  ["-d", wsl2DistroName vm, "--"]
