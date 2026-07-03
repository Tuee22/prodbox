module Prodbox.Host.Lima
  ( LimaVM (..)
  , defaultLimaVM
  , limaShellPrefix
  )
where

newtype LimaVM = LimaVM {limaVmName :: String}
  deriving (Eq, Ord, Show)

defaultLimaVM :: LimaVM
defaultLimaVM = LimaVM "prodbox-ubuntu-2404"

limaShellPrefix :: LimaVM -> [String]
limaShellPrefix vm =
  ["shell", limaVmName vm, "--"]
