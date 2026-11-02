{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- Read-back of actual native producer records; all payloads are synthetic.
module Main (main) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Maybe (isNothing)
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.HostControllerInputRetirement qualified as Reaper
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostControllerPublicationRecord qualified as Record
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import "crypton" Crypto.Random (getRandomBytes)

right :: (Show errorValue) => Either errorValue value -> IO value
right = either (fail . show) pure

require :: String -> Bool -> IO ()
require label condition = unless condition (fail label)

requireNeverSentDisposition :: Publication.HostPublicationDisposition -> IO ()
requireNeverSentDisposition disposition = case disposition of
  Publication.PublicationNeverSent _ -> pure ()
  Publication.PublicationPossiblySent -> fail "wrong-kind refusal spent possible-send"

main :: IO ()
main = do
  [historical] <- getArgs
  old <- BS.readFile historical
  original <- maybe (fail "historical producer rejected") pure (Record.decodePublicationBirth old)
  require
    "historical registration kind changed"
    (Record.publicationBirthKind original == Identity.RpcBirthController)
  require "historical producer bytes changed" (Record.encodePublicationBirth original == old)
  putStrLn "PASS exact historical registration producer codec"
  forM_ [Identity.RpcBirthController, Identity.OrdinaryCascadeController] $ \kind -> do
    nonce <- getRandomBytes 32
    key <-
      maybe
        (fail "fixture key")
        pure
        (Identity.hostExecutionKeyFromText (concatMap hexadecimal (BS.unpack nonce)))
    ending <- (+ 3000000000) <$> getMonotonicTimeNSec
    let wrong = case kind of
          Identity.RpcBirthController -> Identity.OrdinaryCascadeController
          Identity.OrdinaryCascadeController -> Identity.RpcBirthController
    (paths, ()) <-
      right
        =<< Publication.withPublishedHostControllerOwner
          kind
          ending
          key
          "synthetic configuration"
          "synthetic request"
          ( \owner -> do
              let paths@(configuration, request) = Publication.hostPublicationPaths owner
                  producer = takeDirectory request </> Record.publicationBirthName
              bytes <- BS.readFile producer
              decoded <- maybe (fail "native producer decode failed") pure (Record.decodePublicationBirth bytes)
              require "native producer kind changed" (Record.publicationBirthKind decoded == kind)
              require "native producer bytes changed" (Record.encodePublicationBirth decoded == bytes)
              forM_ [BS.empty, BS.init bytes, bytes <> "\NUL", BS.replicate 8193 0] $ \invalid ->
                require
                  "malformed/trailing/oversized producer accepted"
                  (isNothing (Record.decodePublicationBirth invalid))
              case kind of
                Identity.RpcBirthController -> pure ()
                Identity.OrdinaryCascadeController -> do
                  let prefix = "prodbox-host-controller-publication/birth/kind/v1\NUL"
                  payload <- maybe (fail "ordinary producer prefix missing") pure (BS.stripPrefix prefix bytes)
                  (version, tag, legacy) <- right (deserialiseOrFail (Lazy.fromStrict payload))
                  require "ordinary version/tag changed" (version == (1 :: Word8) && tag == (1 :: Word8))
                  untagged <-
                    maybe
                      (fail "ordinary inner registration encoding rejected")
                      pure
                      (Record.decodePublicationBirth legacy)
                  require
                    "ordinary inner registration bytes changed"
                    ( Record.publicationBirthKind untagged == Identity.RpcBirthController
                        && Record.encodePublicationBirth untagged == legacy
                    )
                  forM_
                    [ prefix <> Lazy.toStrict (serialise (2 :: Word8, tag, legacy))
                    , prefix <> Lazy.toStrict (serialise (version, 0 :: Word8, legacy))
                    , prefix <> Lazy.toStrict (serialise (version, 2 :: Word8, legacy))
                    , prefix <> Lazy.toStrict (serialise (version, tag, bytes))
                    ]
                    $ \invalid ->
                      require
                        "unknown/nested ordinary producer accepted"
                        (isNothing (Record.decodePublicationBirth invalid))
              right
                =<< Publication.withHostPublicationSubmission
                  owner
                  ( \permit -> do
                      require
                        "submission borrow changed publisher kind"
                        (Publication.hostPublicationSubmissionKind permit == kind)
                      refused <- Publication.markHostPublicationPossibleSend permit wrong key ending configuration request
                      require
                        "wrong-kind possible-send was admitted"
                        (refused == Left Publication.ControllerPublicationSubmissionMismatch)
                      present <- doesFileExist (takeDirectory request </> Record.publicationPossibleSendName)
                      require "wrong-kind possible-send published metadata" (not present)
                  )
              pure paths
          )
          requireNeverSentDisposition
    readEnd <- (+ 3000000000) <$> getMonotonicTimeNSec
    refused <-
      Publication.withRecoveredHostPublicationNeverSent
        wrong
        readEnd
        key
        (const (fail "foreign kind entered recovery"))
    require "wrong-kind recovery was admitted" (isLeft refused)
    require "wrong-kind recovery removed a payload"
      =<< ((&&) <$> doesFileExist (fst paths) <*> doesFileExist (snd paths))
    recovered <- Publication.withRecoveredHostPublicationNeverSent kind readEnd key $ \proof -> do
      require "recovered never-sent kind changed" (Publication.hostPublicationNeverSentKind proof == kind)
      _ <- right =<< Reaper.retireNeverSentHostControllerInputs readEnd proof
      pure ()
    _ <- right recovered
    configurationPresent <- doesFileExist (fst paths)
    requestPresent <- doesFileExist (snd paths)
    require "cold recovery retained payloads" (not configurationPresent && not requestPresent)
    putStrLn ("PASS producer codec, double kind guard and cold retirement " <> show kind)
  putStrLn "PASS all publication-kind codec and cold recovery controls"

hexadecimal :: (Integral byte) => byte -> String
hexadecimal value = [digits !! (fromIntegral value `div` 16), digits !! (fromIntegral value `mod` 16)]
 where
  digits = "0123456789abcdef"
