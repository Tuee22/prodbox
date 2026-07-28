{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.50: the exported, pinned verifier / Decommission-Runner artifact and
-- its preflight — the gate that must succeed before Authority shutdown and the
-- point-of-no-return receipt.
--
-- Before a total teardown deletes anything, the exact manifest-verifier /
-- Decommission-Runner build artifact and its dependency-closure, manifest-schema,
-- and interpreter-registry metadata are exported to an operator/harness-owned
-- durable coordinate that lives OUTSIDE every cluster, Vault, object-store, and AWS
-- resource the deletion graph names. 'exportVerifierArtifact' writes the artifact
-- and its metadata, fsyncs each file and the parent directory, then reopens and
-- reads back every byte to prove the export is durable and intact, and returns the
-- 'VerifierBinding' (artifact digest plus metadata versions/digests) that is bound
-- into the signed manifest and receipt header.
--
-- On resume, 'runVerifierPreflight' reopens the exported artifact and metadata and
-- verifies them against that committed binding. A missing, changed, or drifted
-- runner, dependency closure, manifest schema, or interpreter registry refuses
-- rather than silently upgrading mid-teardown; only an exact match yields the
-- 'VerifierReady' verdict the Decommission Runner permit requires.
module Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierMetadata (..)
  , VerifierArtifact (..)
  , VerifierBinding (..)
  , verifierBindingOf
  , VerifierExportError (..)
  , exportVerifierArtifact
  , VerifierPreflightRefusal (..)
  , VerifierPreflightResult (..)
  , runVerifierPreflight
  , verifierPreflightReady
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest, contentDigest)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory)
import System.Posix.Files (ownerReadMode, ownerWriteMode, unionFileModes)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- | The build metadata pinned alongside the artifact bytes.
data VerifierMetadata = VerifierMetadata
  { verifierDependencyDigest :: !FrameDigest
  , verifierManifestSchemaVersion :: !Word
  , verifierManifestSchemaDigest :: !FrameDigest
  , verifierInterpreterRegistryVersion :: !Word
  , verifierInterpreterRegistryDigest :: !FrameDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The artifact to export: the opaque pinned build bytes plus their metadata.
data VerifierArtifact = VerifierArtifact
  { verifierArtifactBytes :: !ByteString
  , verifierArtifactMetadata :: !VerifierMetadata
  }
  deriving stock (Eq, Show)

-- | What the manifest / receipt header commits to: the artifact's content digest
-- and its metadata. The preflight verifies the on-disk artifact against exactly
-- this.
data VerifierBinding = VerifierBinding
  { boundArtifactDigest :: !FrameDigest
  , boundMetadata :: !VerifierMetadata
  }
  deriving stock (Eq, Show)

verifierBindingOf :: VerifierArtifact -> VerifierBinding
verifierBindingOf artifact =
  VerifierBinding
    { boundArtifactDigest = contentDigest (verifierArtifactBytes artifact)
    , boundMetadata = verifierArtifactMetadata artifact
    }

data VerifierExportError
  = VerifierExportReadBackMismatch
  | VerifierExportIoFailure !Text
  deriving stock (Eq, Show)

metadataPath :: FilePath -> FilePath
metadataPath path = path ++ ".meta"

-- | Export the artifact and its metadata durably, reading back every byte to prove
-- the export landed intact, and return the binding to commit into the manifest.
exportVerifierArtifact
  :: FilePath -> VerifierArtifact -> IO (Either VerifierExportError VerifierBinding)
exportVerifierArtifact path artifact = do
  let artifactBytes = verifierArtifactBytes artifact
      metadataBytes = LazyByteString.toStrict (serialise (verifierArtifactMetadata artifact))
  result <- try $ do
    writeAndSync path artifactBytes
    writeAndSync (metadataPath path) metadataBytes
    artifactBack <- ByteString.readFile path
    metadataBack <- ByteString.readFile (metadataPath path)
    pure (artifactBack == artifactBytes && metadataBack == metadataBytes)
  pure $ case result :: Either IOException Bool of
    Left err -> Left (VerifierExportIoFailure (Text.pack (show err)))
    Right False -> Left VerifierExportReadBackMismatch
    Right True -> Right (verifierBindingOf artifact)

data VerifierPreflightRefusal
  = VerifierArtifactAbsent
  | VerifierArtifactUnreadable !Text
  | VerifierArtifactDigestMismatch
  | VerifierDependencyDigestMismatch
  | VerifierManifestSchemaDrift
  | VerifierInterpreterRegistryDrift
  deriving stock (Eq, Show)

data VerifierPreflightResult
  = VerifierReady
  | VerifierRefused !VerifierPreflightRefusal
  deriving stock (Eq, Show)

verifierPreflightReady :: VerifierPreflightResult -> Bool
verifierPreflightReady VerifierReady = True
verifierPreflightReady (VerifierRefused _) = False

-- | Reopen the exported artifact and metadata and verify them against the committed
-- binding. Any absence, corruption, digest mismatch, or metadata drift refuses.
runVerifierPreflight :: FilePath -> VerifierBinding -> IO VerifierPreflightResult
runVerifierPreflight path expected = do
  artifactExists <- doesFileExist path
  metadataExists <- doesFileExist (metadataPath path)
  if not (artifactExists && metadataExists)
    then pure (VerifierRefused VerifierArtifactAbsent)
    else do
      readResult <-
        try $ do
          artifactBytes <- ByteString.readFile path
          metadataBytes <- ByteString.readFile (metadataPath path)
          pure (artifactBytes, metadataBytes)
      case readResult :: Either IOException (ByteString, ByteString) of
        Left err -> pure (VerifierRefused (VerifierArtifactUnreadable (Text.pack (show err))))
        Right (artifactBytes, metadataBytes) ->
          pure (verifyAgainst expected artifactBytes metadataBytes)

verifyAgainst :: VerifierBinding -> ByteString -> ByteString -> VerifierPreflightResult
verifyAgainst expected artifactBytes metadataBytes
  | contentDigest artifactBytes /= boundArtifactDigest expected =
      VerifierRefused VerifierArtifactDigestMismatch
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict metadataBytes) of
      Left _ -> VerifierRefused (VerifierArtifactUnreadable (Text.pack "metadata is not decodable"))
      Right metadata
        | verifierDependencyDigest metadata /= verifierDependencyDigest expectedMetadata ->
            VerifierRefused VerifierDependencyDigestMismatch
        | schemaDrift metadata -> VerifierRefused VerifierManifestSchemaDrift
        | registryDrift metadata -> VerifierRefused VerifierInterpreterRegistryDrift
        | otherwise -> VerifierReady
 where
  expectedMetadata = boundMetadata expected
  schemaDrift metadata =
    verifierManifestSchemaVersion metadata /= verifierManifestSchemaVersion expectedMetadata
      || verifierManifestSchemaDigest metadata /= verifierManifestSchemaDigest expectedMetadata
  registryDrift metadata =
    verifierInterpreterRegistryVersion metadata /= verifierInterpreterRegistryVersion expectedMetadata
      || verifierInterpreterRegistryDigest metadata /= verifierInterpreterRegistryDigest expectedMetadata

verifierFileMode :: FileMode
verifierFileMode = ownerReadMode `unionFileModes` ownerWriteMode

-- | Truncating durable write: write the bytes, fsync the file, then fsync the
-- parent directory.
writeAndSync :: FilePath -> ByteString -> IO ()
writeAndSync path bytes = do
  bracket
    ( openFd
        path
        WriteOnly
        defaultFileFlags
          { trunc = True
          , creat = Just verifierFileMode
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    ( \fd -> do
        writeAll fd bytes
        fileSynchronise fd
    )
  syncDirectory (takeDirectory path)

syncDirectory :: FilePath -> IO ()
syncDirectory directory =
  bracket
    ( openFd
        directory
        ReadOnly
        defaultFileFlags {directory = True, nofollow = True, cloexec = True}
    )
    safeCloseFd
    fileSynchronise

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixBS.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then fail "verifier artifact write made no progress"
    else writeAll fd (ByteString.drop count bytes)

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = void (try (closeFd fd) :: IO (Either IOException ()))
