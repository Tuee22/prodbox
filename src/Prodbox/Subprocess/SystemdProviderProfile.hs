{-# LANGUAGE OverloadedStrings #-}

-- | Exact source-reviewed protocol images. These pins describe a provider
-- contract, not aggregate deployment qualification or arbitrary loaded libraries.
module Prodbox.Subprocess.SystemdProviderProfile
  ( ProviderProfile (..)
  , ProviderImage (..)
  , selectProviderProfile
  , providerImagePin
  , providerContractReference
  ) where

import Codec.Serialise (serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Word (Word8)

data ProviderProfile = ProviderAmd64 | ProviderArm64
  deriving (Bounded, Enum, Eq, Show)

data ProviderImage = ManagerExecutable | ManagerCore | ManagerBus | RouterExecutable | RouterBus
  deriving (Bounded, Enum, Eq, Show)

selectProviderProfile :: String -> String -> Maybe ProviderProfile
selectProviderProfile platform architecture = case (platform, architecture) of
  ("linux", "x86_64") -> Just ProviderAmd64
  ("linux", "aarch64") -> Just ProviderArm64
  _ -> Nothing

providerImagePin :: ProviderProfile -> ProviderImage -> (FilePath, ByteString)
providerImagePin profile image = case (profile, image) of
  (ProviderAmd64, ManagerExecutable) -> ("/usr/lib/systemd/systemd", "9a813714ffd4dadb692afe44384c9c5b334fa323a4ec1dd5157aebdcbbb0667a")
  (ProviderAmd64, ManagerCore) ->
    ( "/usr/lib/x86_64-linux-gnu/systemd/libsystemd-core-255.so"
    , "83b5487a063ad1d096760c8bbbf73808d59e36777c13e3ddb26cf0c12dd0bc3a"
    )
  (ProviderAmd64, ManagerBus) ->
    ( "/usr/lib/x86_64-linux-gnu/systemd/libsystemd-shared-255.so"
    , "cdc32d0d168e15bcf35707fb8b35a79a0326337a44c1b9306ae97c9f4cde22b6"
    )
  (ProviderAmd64, RouterExecutable) -> ("/usr/bin/dbus-daemon", "8c479f1fcddfd6693c736ce541da0955f6752834bdeeef4b928e27f5e974c247")
  (ProviderAmd64, RouterBus) ->
    ( "/usr/lib/x86_64-linux-gnu/libdbus-1.so.3.32.4"
    , "a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413"
    )
  (ProviderArm64, ManagerExecutable) -> ("/usr/lib/systemd/systemd", "4456d1bd9f11cd8c69d26f08f2b1c1dad419c973f6da80c6773904f353fcb3c6")
  (ProviderArm64, ManagerCore) ->
    ( "/usr/lib/aarch64-linux-gnu/systemd/libsystemd-core-255.so"
    , "7700840e7a5c32c2e22c5367554470f76c4c40c8481d3eb0fe50ee88d166702c"
    )
  (ProviderArm64, ManagerBus) ->
    ( "/usr/lib/aarch64-linux-gnu/systemd/libsystemd-shared-255.so"
    , "9fc54a91c42ae9f98e11f94145e5e86837db9ffd6760f5c8b05de304428d0e04"
    )
  (ProviderArm64, RouterExecutable) -> ("/usr/bin/dbus-daemon", "42f32cef025bf558013890bd28062932c253710c083e8428fc79ae34d7ccf7c2")
  (ProviderArm64, RouterBus) ->
    ( "/usr/lib/aarch64-linux-gnu/libdbus-1.so.3.32.4"
    , "9b8d0d8b10bdffc68f6699b03e7be99d4dc40552aca189be43b55c5f84753241"
    )

-- Bump this closed policy whenever its normative conditions/program contract
-- change. The image list and architecture participate, preventing build relabeling.
providerContractReference :: ProviderProfile -> ByteString
providerContractReference profile = SHA256.hash (Lazy.toStrict (serialise policy))
 where
  policy =
    ( "prodbox-native-systemd-provider/1" :: Text
    , fromIntegral (fromEnum profile) :: Word8
    ,
      [ "nonroot-same-uid-zero-permitted-effective-ambient-capabilities" :: Text
      , "same-mount-namespace-selinuxfs-absent-apparmor-unconfined"
      , "root-owned-same-descriptor-images-and-executable-mappings"
      , "systemd-255.4-1ubuntu8.18-synchronous-same-uid-start-transient"
      , "dbus-1.14.10-4ubuntu4.1-disconnect-after-queued-frames-fifo"
      , "pinned-api-owner-reexec-disconnection-and-closing-domain"
      , "prodbox-closed-host-operation-family/1"
      ]
    , [ (fromIntegral (fromEnum role) :: Word8, providerImagePin profile role)
      | role <- [minBound .. maxBound]
      ]
    )
