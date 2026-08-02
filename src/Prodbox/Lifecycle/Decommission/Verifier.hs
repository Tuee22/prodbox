{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The externally exported, byte-pinned Decommission Runner artifact.
--
-- The binding is deliberately public-data-only: exact absolute path, executable
-- digest, dependency-closure digest, and schema/registry identities.  Artifact,
-- dependency, and canonical metadata bytes are each fsynced, the parent directory
-- is fsynced, and every byte is reopened before a binding can be returned.
module Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierMetadata
  , VerifierMetadataError (..)
  , currentVerifierMetadataVersion
  , mkVerifierMetadata
  , verifierDependencyDigest
  , verifierManifestSchemaVersion
  , verifierManifestSchemaDigest
  , verifierInterpreterRegistryVersion
  , verifierInterpreterRegistryDigest
  , VerifierMetadataCodecError (..)
  , encodeVerifierMetadata
  , decodeVerifierMetadata
  , ExternalArtifactPath
  , ExternalArtifactPathError (..)
  , mkExternalArtifactPath
  , externalArtifactPath
  , verifierMetadataPath
  , verifierDependencyPath
  , ExternalReceiptPath
  , ExternalReceiptPathError (..)
  , mkExternalReceiptPath
  , externalReceiptPath
  , DeletionRootPath
  , DeletionRootPathError (..)
  , mkDeletionRootPath
  , deletionRootPath
  , ExternalDurablePaths
  , ExternalDurablePathsError (..)
  , mkExternalDurablePaths
  , HostValidatedExternalDurablePaths
  , hostValidatedArtifactPath
  , hostValidatedReceiptPath
  , validateExternalDurablePathsOnHost
  , durableArtifactPath
  , durableReceiptPath
  , VerifierArtifact
  , VerifierArtifactError (..)
  , mkVerifierArtifact
  , verifierArtifactBytes
  , verifierDependencyMetadata
  , verifierArtifactMetadata
  , VerifierBinding
  , VerifierBindingError (..)
  , verifierBindingOf
  , validateVerifierBinding
  , boundArtifactPath
  , boundArtifactDigest
  , boundMetadata
  , VerifierExportError (..)
  , exportVerifierArtifact
  , RunningVerifierExportError (..)
  , inspectRunningVerifierArtifact
  , exportVerifierArtifactFromExecutable
  , exportRunningVerifierArtifact
  , VerifierPreflightRefusal (..)
  , PreflightedVerifierArtifact
  , preflightedVerifierBinding
  , VerifierPreflightResult (..)
  , runVerifierPreflight
  , verifierPreflightReady
  , PinnedExecutionDecision
  , decidePinnedArtifactExecution
  , pinnedExecutionBinding
  , pinnedExecutionIsCurrent
  , pinnedSelfExecutionPath
  , PinnedProcessTransition (..)
  , applyPinnedExecutionDecisionWith
  , replaceWithPinnedVerifier
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.List (isPrefixOf, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest (FrameDigest), contentDigest)
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (getExecutablePath)
import System.FilePath (isAbsolute, normalise, splitDirectories, takeDirectory, takeFileName)
import System.IO.Error (isEOFError)
import System.Posix.Files
  ( fileMode
  , fileSize
  , getFdStatus
  , intersectFileModes
  , isRegularFile
  , nullFileMode
  , ownerExecuteMode
  , ownerReadMode
  , ownerWriteMode
  , setFdMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Process (executeFile)
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

currentVerifierMetadataVersion :: Word
currentVerifierMetadataVersion = 1

maximumVerifierArtifactBytes :: Integer
maximumVerifierArtifactBytes = 256 * 1024 * 1024

maximumDependencyMetadataBytes :: Integer
maximumDependencyMetadataBytes = 1024 * 1024

maximumVerifierMetadataBytes :: Int
maximumVerifierMetadataBytes = 64 * 1024

-- | Closed, canonical public metadata for the exported build.  There is no field
-- capable of carrying an admin credential, signing secret, or runtime secret.
data VerifierMetadata = VerifierMetadata
  { verifierMetadataVersion :: !Word
  , verifierDependencyDigest :: !FrameDigest
  , verifierManifestSchemaVersion :: !Word
  , verifierManifestSchemaDigest :: !FrameDigest
  , verifierInterpreterRegistryVersion :: !Word
  , verifierInterpreterRegistryDigest :: !FrameDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data VerifierMetadataError
  = VerifierMetadataVersionInvalid
  | VerifierMetadataDigestInvalid
  deriving stock (Eq, Show)

mkVerifierMetadata
  :: FrameDigest
  -> Word
  -> FrameDigest
  -> Word
  -> FrameDigest
  -> Either VerifierMetadataError VerifierMetadata
mkVerifierMetadata dependencyDigest schemaVersion schemaDigest registryVersion registryDigest
  | schemaVersion == 0 || registryVersion == 0 = Left VerifierMetadataVersionInvalid
  | not (all validDigest [dependencyDigest, schemaDigest, registryDigest]) =
      Left VerifierMetadataDigestInvalid
  | otherwise =
      Right
        VerifierMetadata
          { verifierMetadataVersion = currentVerifierMetadataVersion
          , verifierDependencyDigest = dependencyDigest
          , verifierManifestSchemaVersion = schemaVersion
          , verifierManifestSchemaDigest = schemaDigest
          , verifierInterpreterRegistryVersion = registryVersion
          , verifierInterpreterRegistryDigest = registryDigest
          }

validDigest :: FrameDigest -> Bool
validDigest (FrameDigest bytes) = ByteString.length bytes == 32

data VerifierMetadataCodecError
  = VerifierMetadataTooLarge
  | VerifierMetadataInvalid
  | VerifierMetadataUnsupportedVersion
  | VerifierMetadataNonCanonical
  | VerifierMetadataSemanticInvalid !VerifierMetadataError
  deriving stock (Eq, Show)

encodeVerifierMetadata :: VerifierMetadata -> ByteString
encodeVerifierMetadata = LazyByteString.toStrict . serialise

decodeVerifierMetadata :: Int -> ByteString -> Either VerifierMetadataCodecError VerifierMetadata
decodeVerifierMetadata maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > maximumBytes =
      Left VerifierMetadataTooLarge
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left VerifierMetadataInvalid
      Right metadata
        | verifierMetadataVersion metadata /= currentVerifierMetadataVersion ->
            Left VerifierMetadataUnsupportedVersion
        | encodeVerifierMetadata metadata /= bytes -> Left VerifierMetadataNonCanonical
        | otherwise ->
            case mkVerifierMetadata
              (verifierDependencyDigest metadata)
              (verifierManifestSchemaVersion metadata)
              (verifierManifestSchemaDigest metadata)
              (verifierInterpreterRegistryVersion metadata)
              (verifierInterpreterRegistryDigest metadata) of
              Left err -> Left (VerifierMetadataSemanticInvalid err)
              Right validated -> Right validated

newtype ExternalArtifactPath = ExternalArtifactPath FilePath
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data ExternalArtifactPathError
  = ArtifactPathNotAbsolute
  | ArtifactPathNotCanonical
  | ArtifactPathInvalid
  deriving stock (Eq, Show)

-- | Bind the export to one exact canonical absolute file path.  This does not
-- attempt to infer the deletion graph from host paths; that disjointness proof is
-- supplied by the Nuke composition layer before this smart constructor is called.
mkExternalArtifactPath :: FilePath -> Either ExternalArtifactPathError ExternalArtifactPath
mkExternalArtifactPath path
  | not (isAbsolute path) = Left ArtifactPathNotAbsolute
  | normalise path /= path || any isDotComponent (splitDirectories path) =
      Left ArtifactPathNotCanonical
  | length path > 4096 || null (takeFileName path) || any isControl path =
      Left ArtifactPathInvalid
  | otherwise = Right (ExternalArtifactPath path)
 where
  isDotComponent component = component == "." || component == ".."

externalArtifactPath :: ExternalArtifactPath -> FilePath
externalArtifactPath (ExternalArtifactPath path) = path

verifierMetadataPath :: ExternalArtifactPath -> FilePath
verifierMetadataPath path = externalArtifactPath path ++ ".meta"

verifierDependencyPath :: ExternalArtifactPath -> FilePath
verifierDependencyPath path = externalArtifactPath path ++ ".deps"

-- | Exact canonical absolute path of the non-secret external receipt.  It is a
-- distinct type from the exported executable so the two cannot be accidentally
-- interchanged at the composition boundary.
newtype ExternalReceiptPath = ExternalReceiptPath FilePath
  deriving stock (Eq, Ord, Show)

data ExternalReceiptPathError
  = ReceiptPathNotAbsolute
  | ReceiptPathNotCanonical
  | ReceiptPathInvalid
  deriving stock (Eq, Show)

mkExternalReceiptPath :: FilePath -> Either ExternalReceiptPathError ExternalReceiptPath
mkExternalReceiptPath path
  | not (isAbsolute path) = Left ReceiptPathNotAbsolute
  | normalise path /= path || any isDotComponent (splitDirectories path) =
      Left ReceiptPathNotCanonical
  | length path > 4096 || null (takeFileName path) || any isControl path =
      Left ReceiptPathInvalid
  | otherwise = Right (ExternalReceiptPath path)
 where
  isDotComponent component = component == "." || component == ".."

externalReceiptPath :: ExternalReceiptPath -> FilePath
externalReceiptPath (ExternalReceiptPath path) = path

-- | One exact canonical absolute filesystem root removed by the decommission
-- graph.  Non-filesystem resources (AWS accounts, buckets, Vault data) are
-- disjoint from a host path by type; every host deletion root must be supplied
-- here by the production composition.
newtype DeletionRootPath = DeletionRootPath FilePath
  deriving stock (Eq, Ord, Show)

data DeletionRootPathError
  = DeletionRootNotAbsolute
  | DeletionRootNotCanonical
  | DeletionRootInvalid
  deriving stock (Eq, Show)

mkDeletionRootPath :: FilePath -> Either DeletionRootPathError DeletionRootPath
mkDeletionRootPath path
  | not (isAbsolute path) = Left DeletionRootNotAbsolute
  | normalise path /= path || any isDotComponent (splitDirectories path) =
      Left DeletionRootNotCanonical
  | length path > 4096 || any isControl path = Left DeletionRootInvalid
  | otherwise = Right (DeletionRootPath path)
 where
  isDotComponent component = component == "." || component == ".."

deletionRootPath :: DeletionRootPath -> FilePath
deletionRootPath (DeletionRootPath path) = path

-- | Opaque proof that all four durable files (runner, dependency closure,
-- metadata, and receipt) are distinct where required and outside every exact
-- host path removed by the graph.  Component comparison deliberately avoids the
-- unsafe string-prefix case where @/var/lib/prodbox-other@ would be mistaken for
-- a child of @/var/lib/prodbox@.
data ExternalDurablePaths = ExternalDurablePaths
  { durableArtifactPath :: !ExternalArtifactPath
  , durableReceiptPath :: !ExternalReceiptPath
  }
  deriving stock (Eq, Show)

-- | Filesystem-resolved form required by receipt initialization.  Its
-- constructor is intentionally private; the lexical constructor alone cannot
-- authorize a point-of-no-return artifact.
newtype HostValidatedExternalDurablePaths = HostValidatedExternalDurablePaths ExternalDurablePaths
  deriving stock (Eq, Show)

hostValidatedArtifactPath :: HostValidatedExternalDurablePaths -> ExternalArtifactPath
hostValidatedArtifactPath (HostValidatedExternalDurablePaths paths) = durableArtifactPath paths

hostValidatedReceiptPath :: HostValidatedExternalDurablePaths -> ExternalReceiptPath
hostValidatedReceiptPath (HostValidatedExternalDurablePaths paths) = durableReceiptPath paths

data ExternalDurablePathsError
  = ExternalDeletionRootInventoryEmpty
  | ExternalDurableFileCollision !FilePath
  | ExternalDurableFileInsideDeletionRoot !FilePath !DeletionRootPath
  | ExternalDurablePathResolutionFailed !FilePath !Text
  | ExternalDurablePathNotResolvedCanonical !FilePath !FilePath
  deriving stock (Eq, Show)

mkExternalDurablePaths
  :: [DeletionRootPath]
  -> ExternalArtifactPath
  -> ExternalReceiptPath
  -> Either ExternalDurablePathsError ExternalDurablePaths
mkExternalDurablePaths deletionRoots artifactPath receiptPath
  | null deletionRoots = Left ExternalDeletionRootInventoryEmpty
  | Just collision <- firstDuplicate durableFiles = Left (ExternalDurableFileCollision collision)
  | Just (durableFile, root) <- firstContained durableFiles deletionRoots =
      Left (ExternalDurableFileInsideDeletionRoot durableFile root)
  | otherwise = Right (ExternalDurablePaths artifactPath receiptPath)
 where
  durableFiles =
    [ externalArtifactPath artifactPath
    , verifierDependencyPath artifactPath
    , verifierMetadataPath artifactPath
    , externalReceiptPath receiptPath
    ]
  firstDuplicate values = case filter ((> 1) . occurrenceCount values) (nub values) of
    [] -> Nothing
    duplicate : _ -> Just duplicate
  occurrenceCount values candidate = length (filter (== candidate) values)
  firstContained files roots =
    case [ (file, root)
         | root <- roots
         , file <- files
         , pathAtOrBelow (deletionRootPath root) file
         ] of
      [] -> Nothing
      contained : _ -> Just contained
  pathAtOrBelow root file = splitDirectories root `isPrefixOf` splitDirectories file

-- | Host-side strengthening of the lexical proof.  Every supplied path must be
-- unchanged by filesystem canonicalization, rejecting a symlinked ancestor or
-- alias that could lexically appear outside a deletion root while resolving
-- inside it.  The production composition calls this after creating the external
-- parent directory and before exporting or initializing any durable file.
validateExternalDurablePathsOnHost
  :: [DeletionRootPath]
  -> ExternalArtifactPath
  -> ExternalReceiptPath
  -> IO (Either ExternalDurablePathsError HostValidatedExternalDurablePaths)
validateExternalDurablePathsOnHost deletionRoots artifactPath receiptPath =
  case mkExternalDurablePaths deletionRoots artifactPath receiptPath of
    Left err -> pure (Left err)
    Right paths -> do
      resolved <- mapM resolveExact allPaths
      pure $ case firstLeft resolved of
        Just err -> Left err
        Nothing -> Right (HostValidatedExternalDurablePaths paths)
 where
  allPaths =
    fmap deletionRootPath deletionRoots
      ++ [ externalArtifactPath artifactPath
         , verifierDependencyPath artifactPath
         , verifierMetadataPath artifactPath
         , externalReceiptPath receiptPath
         ]
  resolveExact path = do
    result <- try (canonicalizePath path)
    pure $ case result :: Either IOException FilePath of
      Left err -> Left (ExternalDurablePathResolutionFailed path (Text.pack (show err)))
      Right resolved
        | resolved == path -> Right ()
        | otherwise -> Left (ExternalDurablePathNotResolvedCanonical path resolved)
  firstLeft results = case [err | Left err <- results] of
    [] -> Nothing
    err : _ -> Just err

-- | Opaque public artifact material.  The signing key and all runtime/admin
-- credentials are absent by construction; callers supply only build bytes,
-- public dependency metadata, and the closed metadata record.
data VerifierArtifact = VerifierArtifact
  { verifierArtifactBytes :: !ByteString
  , verifierDependencyMetadata :: !ByteString
  , verifierArtifactMetadata :: !VerifierMetadata
  }
  deriving stock (Eq)

instance Show VerifierArtifact where
  show artifact =
    "VerifierArtifact { artifactDigest = "
      ++ show (contentDigest (verifierArtifactBytes artifact))
      ++ ", dependencyDigest = "
      ++ show (contentDigest (verifierDependencyMetadata artifact))
      ++ ", metadata = "
      ++ show (verifierArtifactMetadata artifact)
      ++ " }"

data VerifierArtifactError
  = VerifierArtifactEmpty
  | VerifierArtifactTooLarge
  | VerifierDependencyMetadataEmpty
  | VerifierDependencyMetadataTooLarge
  | VerifierDependencyMetadataDigestMismatch
  deriving stock (Eq, Show)

mkVerifierArtifact
  :: ByteString
  -> ByteString
  -> VerifierMetadata
  -> Either VerifierArtifactError VerifierArtifact
mkVerifierArtifact artifactBytes dependencyBytes metadata
  | ByteString.null artifactBytes = Left VerifierArtifactEmpty
  | fromIntegral (ByteString.length artifactBytes) > maximumVerifierArtifactBytes =
      Left VerifierArtifactTooLarge
  | ByteString.null dependencyBytes = Left VerifierDependencyMetadataEmpty
  | fromIntegral (ByteString.length dependencyBytes) > maximumDependencyMetadataBytes =
      Left VerifierDependencyMetadataTooLarge
  | contentDigest dependencyBytes /= verifierDependencyDigest metadata =
      Left VerifierDependencyMetadataDigestMismatch
  | otherwise =
      Right
        VerifierArtifact
          { verifierArtifactBytes = artifactBytes
          , verifierDependencyMetadata = dependencyBytes
          , verifierArtifactMetadata = metadata
          }

-- | The complete public identity committed by the signed manifest and receipt
-- header, including the one exact path the runner must later self-execute.
data VerifierBinding = VerifierBinding
  { boundArtifactPath :: !ExternalArtifactPath
  , boundArtifactDigest :: !FrameDigest
  , boundMetadata :: !VerifierMetadata
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data VerifierBindingError
  = VerifierBindingPathInvalid !ExternalArtifactPathError
  | VerifierBindingArtifactDigestInvalid
  | VerifierBindingMetadataInvalid !VerifierMetadataError
  deriving stock (Eq, Show)

verifierBindingOf :: ExternalArtifactPath -> VerifierArtifact -> VerifierBinding
verifierBindingOf path artifact =
  VerifierBinding
    { boundArtifactPath = path
    , boundArtifactDigest = contentDigest (verifierArtifactBytes artifact)
    , boundMetadata = verifierArtifactMetadata artifact
    }

-- | Re-enter every smart constructor after a binding crosses a wire boundary.
validateVerifierBinding :: VerifierBinding -> Either VerifierBindingError VerifierBinding
validateVerifierBinding binding = do
  path <-
    either
      (Left . VerifierBindingPathInvalid)
      Right
      (mkExternalArtifactPath (externalArtifactPath (boundArtifactPath binding)))
  if validDigest (boundArtifactDigest binding)
    then pure ()
    else Left VerifierBindingArtifactDigestInvalid
  metadata <-
    either
      (Left . VerifierBindingMetadataInvalid)
      Right
      ( mkVerifierMetadata
          (verifierDependencyDigest (boundMetadata binding))
          (verifierManifestSchemaVersion (boundMetadata binding))
          (verifierManifestSchemaDigest (boundMetadata binding))
          (verifierInterpreterRegistryVersion (boundMetadata binding))
          (verifierInterpreterRegistryDigest (boundMetadata binding))
      )
  pure binding {boundArtifactPath = path, boundMetadata = metadata}

data VerifierExportError
  = VerifierExportArtifactBytesReadBackMismatch
  | VerifierExportArtifactModeReadBackMismatch
  | VerifierExportArtifactOversized
  | VerifierExportArtifactNotRegular
  | VerifierExportArtifactUnreadable !Text
  | VerifierExportDependencyReadBackMismatch
  | VerifierExportMetadataReadBackMismatch
  | VerifierExportIoFailure !Text
  deriving stock (Eq, Show)

data RunningVerifierExportError
  = RunningVerifierSourceIsExportTarget
  | RunningVerifierSourcePathInvalid !ExternalArtifactPathError
  | RunningVerifierSourceUnreadable !Text
  | RunningVerifierSourceOversized
  | RunningVerifierSourceNotRegular
  | RunningVerifierSourceNotExecutable
  | RunningVerifierArtifactInvalid !VerifierArtifactError
  | RunningVerifierExportFailed !VerifierExportError
  deriving stock (Eq, Show)

-- | Export all three files with file+directory durability, then reopen and compare
-- every byte before returning the binding.
exportVerifierArtifact
  :: ExternalArtifactPath
  -> VerifierArtifact
  -> IO (Either VerifierExportError VerifierBinding)
exportVerifierArtifact path artifact = do
  let artifactBytes = verifierArtifactBytes artifact
      dependencyBytes = verifierDependencyMetadata artifact
      metadataBytes = encodeVerifierMetadata (verifierArtifactMetadata artifact)
      artifactPath = externalArtifactPath path
  result <- try $ do
    writeAndSync verifierExecutableFileMode artifactPath artifactBytes
    writeAndSync verifierDataFileMode (verifierDependencyPath path) dependencyBytes
    writeAndSync verifierDataFileMode (verifierMetadataPath path) metadataBytes
    artifactBack <- readBoundedNoFollow maximumVerifierArtifactBytes artifactPath
    dependencyBack <-
      readBoundedNoFollow maximumDependencyMetadataBytes (verifierDependencyPath path)
    metadataBack <-
      readBoundedNoFollow (fromIntegral maximumVerifierMetadataBytes) (verifierMetadataPath path)
    pure (artifactBack, dependencyBack, metadataBack)
  pure $ case result :: Either IOException (BoundedFileRead, BoundedFileRead, BoundedFileRead) of
    Left err -> Left (VerifierExportIoFailure (Text.pack (show err)))
    Right (BoundedFileBytes bytes _, _, _)
      | bytes /= artifactBytes -> Left VerifierExportArtifactBytesReadBackMismatch
    Right (BoundedFileBytes _ False, _, _) ->
      Left VerifierExportArtifactModeReadBackMismatch
    Right (BoundedFileOversized, _, _) -> Left VerifierExportArtifactOversized
    Right (BoundedFileNotRegular, _, _) -> Left VerifierExportArtifactNotRegular
    Right (BoundedFileIo detail, _, _) -> Left (VerifierExportArtifactUnreadable detail)
    Right (_, dependencyBack, _)
      | dependencyBack /= BoundedFileBytes dependencyBytes False ->
          Left VerifierExportDependencyReadBackMismatch
    Right (_, _, metadataBack)
      | metadataBack /= BoundedFileBytes metadataBytes False ->
          Left VerifierExportMetadataReadBackMismatch
    Right _ -> Right (verifierBindingOf path artifact)

-- | Copy the exact bytes of a named running executable into the durable export.
-- The dependency closure and closed build metadata are supplied separately and
-- are exported by the same fsync/read-back primitive.  The source is opened
-- no-follow, bounded, and required to be a regular executable file.
exportVerifierArtifactFromExecutable
  :: FilePath
  -> ExternalArtifactPath
  -> ByteString
  -> VerifierMetadata
  -> IO (Either RunningVerifierExportError VerifierBinding)
exportVerifierArtifactFromExecutable executablePath exportPath dependencyBytes metadata
  | normalise executablePath == externalArtifactPath exportPath =
      pure (Left RunningVerifierSourceIsExportTarget)
  | otherwise = do
      inspected <- inspectVerifierArtifact executablePath dependencyBytes metadata
      case inspected of
        Left err -> pure (Left err)
        Right runningArtifact ->
          either (Left . RunningVerifierExportFailed) Right
            <$> exportVerifierArtifact exportPath runningArtifact

-- | Inspect the exact currently executing regular file through the same
-- no-follow and size bounds used by export.  Returning the opaque artifact lets
-- the Nuke composition derive both the running-path identity and the proposed
-- external-path identity before deciding whether an existing export is an
-- exact idempotent replay; it never treats the export target as the running
-- process merely because their bytes happen to match.
inspectRunningVerifierArtifact
  :: ByteString
  -> VerifierMetadata
  -> IO
       ( Either
           RunningVerifierExportError
           (ExternalArtifactPath, VerifierArtifact)
       )
inspectRunningVerifierArtifact dependencyBytes metadata = do
  executablePath <- getExecutablePath
  case mkExternalArtifactPath executablePath of
    Left err -> pure (Left (RunningVerifierSourcePathInvalid err))
    Right typedPath -> do
      inspected <- inspectVerifierArtifact executablePath dependencyBytes metadata
      pure ((,) typedPath <$> inspected)

inspectVerifierArtifact
  :: FilePath
  -> ByteString
  -> VerifierMetadata
  -> IO (Either RunningVerifierExportError VerifierArtifact)
inspectVerifierArtifact executablePath dependencyBytes metadata = do
  executableRead <- readBoundedNoFollow maximumVerifierArtifactBytes executablePath
  pure $ case executableRead of
    BoundedFileIo detail -> Left (RunningVerifierSourceUnreadable detail)
    BoundedFileOversized -> Left RunningVerifierSourceOversized
    BoundedFileNotRegular -> Left RunningVerifierSourceNotRegular
    BoundedFileBytes _ False -> Left RunningVerifierSourceNotExecutable
    BoundedFileBytes executableBytes True ->
      either
        (Left . RunningVerifierArtifactInvalid)
        Right
        (mkVerifierArtifact executableBytes dependencyBytes metadata)

-- | Production source-path discovery for the currently executing image.
exportRunningVerifierArtifact
  :: ExternalArtifactPath
  -> ByteString
  -> VerifierMetadata
  -> IO (Either RunningVerifierExportError VerifierBinding)
exportRunningVerifierArtifact exportPath dependencyBytes metadata = do
  executablePath <- getExecutablePath
  exportVerifierArtifactFromExecutable executablePath exportPath dependencyBytes metadata

data VerifierPreflightRefusal
  = VerifierArtifactAbsent
  | VerifierDependencyMetadataAbsent
  | VerifierMetadataAbsent
  | VerifierArtifactUnreadable !Text
  | VerifierArtifactOversized
  | VerifierDependencyMetadataOversized
  | VerifierMetadataOversized
  | VerifierArtifactNotRegular
  | VerifierDependencyMetadataNotRegular
  | VerifierMetadataNotRegular
  | VerifierArtifactNotExecutable
  | VerifierArtifactDigestMismatch
  | VerifierDependencyDigestMismatch
  | VerifierMetadataInvalidOnDisk !VerifierMetadataCodecError
  | VerifierManifestSchemaDrift
  | VerifierInterpreterRegistryDrift
  deriving stock (Eq, Show)

newtype PreflightedVerifierArtifact = PreflightedVerifierArtifact VerifierBinding
  deriving stock (Eq, Show)

preflightedVerifierBinding :: PreflightedVerifierArtifact -> VerifierBinding
preflightedVerifierBinding (PreflightedVerifierArtifact binding) = binding

data VerifierPreflightResult
  = VerifierReady !PreflightedVerifierArtifact
  | VerifierRefused !VerifierPreflightRefusal
  deriving stock (Eq, Show)

verifierPreflightReady :: VerifierPreflightResult -> Bool
verifierPreflightReady (VerifierReady _) = True
verifierPreflightReady (VerifierRefused _) = False

-- | Reopen the exact path committed by the binding.  The caller cannot substitute
-- another same-content path at resume time.
runVerifierPreflight :: VerifierBinding -> IO VerifierPreflightResult
runVerifierPreflight expected = do
  let path = boundArtifactPath expected
      artifactPath = externalArtifactPath path
      dependencyPath = verifierDependencyPath path
      metadataPath = verifierMetadataPath path
  artifactExists <- doesFileExist artifactPath
  dependencyExists <- doesFileExist dependencyPath
  metadataExists <- doesFileExist metadataPath
  if not artifactExists
    then pure (VerifierRefused VerifierArtifactAbsent)
    else
      if not dependencyExists
        then pure (VerifierRefused VerifierDependencyMetadataAbsent)
        else
          if not metadataExists
            then pure (VerifierRefused VerifierMetadataAbsent)
            else preflightExisting expected artifactPath dependencyPath metadataPath

preflightExisting
  :: VerifierBinding
  -> FilePath
  -> FilePath
  -> FilePath
  -> IO VerifierPreflightResult
preflightExisting expected artifactPath dependencyPath metadataPath = do
  artifactRead <- readBoundedNoFollow maximumVerifierArtifactBytes artifactPath
  case artifactRead of
    BoundedFileIo err -> pure (VerifierRefused (VerifierArtifactUnreadable err))
    BoundedFileOversized -> pure (VerifierRefused VerifierArtifactOversized)
    BoundedFileNotRegular -> pure (VerifierRefused VerifierArtifactNotRegular)
    BoundedFileBytes _ False -> pure (VerifierRefused VerifierArtifactNotExecutable)
    BoundedFileBytes artifactBytes True -> do
      dependencyRead <- readBoundedNoFollow maximumDependencyMetadataBytes dependencyPath
      case dependencyRead of
        BoundedFileIo err -> pure (VerifierRefused (VerifierArtifactUnreadable err))
        BoundedFileOversized -> pure (VerifierRefused VerifierDependencyMetadataOversized)
        BoundedFileNotRegular -> pure (VerifierRefused VerifierDependencyMetadataNotRegular)
        BoundedFileBytes dependencyBytes _ -> do
          metadataRead <-
            readBoundedNoFollow (fromIntegral maximumVerifierMetadataBytes) metadataPath
          pure $ case metadataRead of
            BoundedFileIo err -> VerifierRefused (VerifierArtifactUnreadable err)
            BoundedFileOversized -> VerifierRefused VerifierMetadataOversized
            BoundedFileNotRegular -> VerifierRefused VerifierMetadataNotRegular
            BoundedFileBytes metadataBytes _ ->
              verifyAgainst expected artifactBytes dependencyBytes metadataBytes

verifyAgainst
  :: VerifierBinding
  -> ByteString
  -> ByteString
  -> ByteString
  -> VerifierPreflightResult
verifyAgainst expected artifactBytes dependencyBytes metadataBytes
  | contentDigest artifactBytes /= boundArtifactDigest expected =
      VerifierRefused VerifierArtifactDigestMismatch
  | contentDigest dependencyBytes /= verifierDependencyDigest expectedMetadata =
      VerifierRefused VerifierDependencyDigestMismatch
  | otherwise = case decodeVerifierMetadata maximumVerifierMetadataBytes metadataBytes of
      Left err -> VerifierRefused (VerifierMetadataInvalidOnDisk err)
      Right metadata
        | schemaDrift metadata -> VerifierRefused VerifierManifestSchemaDrift
        | registryDrift metadata -> VerifierRefused VerifierInterpreterRegistryDrift
        | verifierDependencyDigest metadata /= verifierDependencyDigest expectedMetadata ->
            VerifierRefused VerifierDependencyDigestMismatch
        | otherwise -> VerifierReady (PreflightedVerifierArtifact expected)
 where
  expectedMetadata = boundMetadata expected
  schemaDrift metadata =
    verifierManifestSchemaVersion metadata /= verifierManifestSchemaVersion expectedMetadata
      || verifierManifestSchemaDigest metadata /= verifierManifestSchemaDigest expectedMetadata
  registryDrift metadata =
    verifierInterpreterRegistryVersion metadata /= verifierInterpreterRegistryVersion expectedMetadata
      || verifierInterpreterRegistryDigest metadata /= verifierInterpreterRegistryDigest expectedMetadata

-- | A mismatched/current new build is never allowed to interpret the receipt.
-- Once the pinned artifact has passed preflight, the only safe decision is to
-- replace the current process with the exact exported path.
data PinnedExecutionDecision
  = ExecuteCurrentPinnedArtifact !VerifierBinding
  | RefuseCurrentAndSelfExecutePinned !VerifierBinding !ExternalArtifactPath
  deriving stock (Eq, Show)

decidePinnedArtifactExecution
  :: PreflightedVerifierArtifact
  -> VerifierBinding
  -> PinnedExecutionDecision
decidePinnedArtifactExecution preflighted runningIdentity
  | pinnedBinding == runningIdentity = ExecuteCurrentPinnedArtifact pinnedBinding
  | otherwise =
      RefuseCurrentAndSelfExecutePinned
        pinnedBinding
        (boundArtifactPath pinnedBinding)
 where
  pinnedBinding = preflightedVerifierBinding preflighted

-- | The exact, successfully reopened binding on which the decision was based.
-- This keeps downstream authorization from combining a readiness token for one
-- build with an execution decision made for another.
pinnedExecutionBinding :: PinnedExecutionDecision -> VerifierBinding
pinnedExecutionBinding decision = case decision of
  ExecuteCurrentPinnedArtifact binding -> binding
  RefuseCurrentAndSelfExecutePinned binding _ -> binding

pinnedExecutionIsCurrent :: PinnedExecutionDecision -> Bool
pinnedExecutionIsCurrent (ExecuteCurrentPinnedArtifact _) = True
pinnedExecutionIsCurrent (RefuseCurrentAndSelfExecutePinned _ _) = False

pinnedSelfExecutionPath :: PinnedExecutionDecision -> Maybe ExternalArtifactPath
pinnedSelfExecutionPath (ExecuteCurrentPinnedArtifact _) = Nothing
pinnedSelfExecutionPath (RefuseCurrentAndSelfExecutePinned _ path) = Just path

data PinnedProcessTransition
  = PinnedProcessAlreadyCurrent
  | PinnedProcessReplacementInvoked !ExternalArtifactPath
  deriving stock (Eq, Show)

-- | Injected process-replacement boundary.  Tests can prove the exact path and
-- argument vector without replacing themselves; production supplies @exec@.
applyPinnedExecutionDecisionWith
  :: (Monad m)
  => (FilePath -> [String] -> m ())
  -> [String]
  -> PinnedExecutionDecision
  -> m PinnedProcessTransition
applyPinnedExecutionDecisionWith replace arguments decision = case decision of
  ExecuteCurrentPinnedArtifact _ -> pure PinnedProcessAlreadyCurrent
  RefuseCurrentAndSelfExecutePinned _ path -> do
    replace (externalArtifactPath path) arguments
    pure (PinnedProcessReplacementInvoked path)

-- | Replace this process with the exact preflighted external artifact.  On a
-- real successful @exec@ this never returns; preserving the argument vector
-- lets the pinned runner reopen the same manifest/receipt invocation.
replaceWithPinnedVerifier
  :: [String]
  -> PinnedExecutionDecision
  -> IO PinnedProcessTransition
replaceWithPinnedVerifier =
  applyPinnedExecutionDecisionWith (\path arguments -> executeFile path False arguments Nothing)

verifierDataFileMode :: FileMode
verifierDataFileMode = ownerReadMode `unionFileModes` ownerWriteMode

verifierExecutableFileMode :: FileMode
verifierExecutableFileMode = verifierDataFileMode `unionFileModes` ownerExecuteMode

writeAndSync :: FileMode -> FilePath -> ByteString -> IO ()
writeAndSync mode path bytes = do
  bracket
    ( openFd
        path
        WriteOnly
        defaultFileFlags
          { trunc = True
          , creat = Just mode
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    ( \fd -> do
        setFdMode fd mode
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

data BoundedFileRead
  = BoundedFileBytes !ByteString !Bool
  | BoundedFileOversized
  | BoundedFileNotRegular
  | BoundedFileIo !Text
  deriving stock (Eq, Show)

-- | Read through a no-follow file descriptor, bounding both the initial file size
-- and bytes observed if a concurrent writer grows the file after the status check.
-- The Boolean records the owner-execute bit needed by the pinned runner itself.
readBoundedNoFollow :: Integer -> FilePath -> IO BoundedFileRead
readBoundedNoFollow maximumBytes path = do
  result <-
    try
      ( bracket
          (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
          safeCloseFd
          (\fd -> readOpenBoundedFile maximumBytes fd)
      )
  pure $ case result :: Either IOException BoundedFileRead of
    Left err -> BoundedFileIo (Text.pack (show err))
    Right readResult -> readResult

readOpenBoundedFile :: Integer -> Fd -> IO BoundedFileRead
readOpenBoundedFile maximumBytes fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then pure BoundedFileNotRegular
    else
      if fromIntegral (fileSize status) > maximumBytes
        then pure BoundedFileOversized
        else do
          bytes <- readBoundedChunks fd maximumBytes 0 []
          pure $ case bytes of
            Nothing -> BoundedFileOversized
            Just content ->
              BoundedFileBytes
                content
                (fileMode status `intersectFileModes` ownerExecuteMode /= nullFileMode)

readBoundedChunks
  :: Fd
  -> Integer
  -> Integer
  -> [ByteString]
  -> IO (Maybe ByteString)
readBoundedChunks fd maximumBytes observed chunks = do
  let remaining = maximumBytes - observed
      requestBytes = min 65536 (remaining + 1)
  readResult <- try (PosixBS.fdRead fd (fromIntegral requestBytes))
  case readResult :: Either IOException ByteString of
    Left err
      | isEOFError err -> pure (Just (ByteString.concat (reverse chunks)))
      | otherwise -> ioError err
    Right chunk
      | ByteString.null chunk -> pure (Just (ByteString.concat (reverse chunks)))
      | otherwise -> do
          let chunkBytes = fromIntegral (ByteString.length chunk)
          if chunkBytes > remaining
            then pure Nothing
            else readBoundedChunks fd maximumBytes (observed + chunkBytes) (chunk : chunks)
