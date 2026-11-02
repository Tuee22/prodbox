{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Hold the canonical home Authority inputs before registration fences reads.
-- These values are neither a host/process permit nor proof of a running pin.
module Prodbox.ControlPlane.RpcAdmissionBirthChart
  ( RpcBirthChartTemplate
  , RpcBirthChartRevision
  , RpcBirthChartError (..)
  , prepareRpcBirthChart
  , prepareRpcBirthChartWithObservers
  , pinRpcBirthChart
  , rpcBirthChartValues
  , rpcBirthChartDescriptor
  , rpcBirthChartFiles
  , rpcBirthChartStorageBindings
  , rpcBirthChartMaximumInputBytes
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (foldM, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Lazy8
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Parser qualified as Parser
import Dhall.TypeCheck qualified as TypeCheck
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.ControlPlane.RpcAdmissionBirth
  ( RpcBirthDescriptor
  , rpcBirthDescriptorDigest
  , rpcBirthDescriptorGeneration
  , rpcBirthDescriptorScope
  )
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.Runtime qualified as Runtime
import Prodbox.Lib.ChartPlatform
  ( ChartDeploymentPlan (..)
  , ChartPlanObservers (..)
  , ChartReleasePlan (..)
  , ResolvedCustomImage
  , buildChartDeploymentPlanForSubstrateWithObservers
  , productionChartPlanObservers
  , valuesForLifecycleAuthorityWithRpcBirth
  )
import Prodbox.Lib.Storage (ChartStorageBinding)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Settings (ValidatedSettings)
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import System.Directory (canonicalizePath)
import System.FilePath (normalise, takeExtension, (</>))
import System.IO.Error (isEOFError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  , openFdAt
  )
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (Fd (..))

data RpcBirthChartError
  = RpcBirthChartPlanUnavailable
  | RpcBirthChartIdentityMismatch
  | RpcBirthChartConfigInvalid
  | RpcBirthChartSourcePinConflict
  | RpcBirthChartInputTooLarge
  | RpcBirthChartSourceUnsafe
  | RpcBirthChartSourceChanged
  | RpcBirthChartSourceUnavailable
  deriving (Eq, Show)

-- Neither constructor nor a raw-plan minting function is exported. The only
-- builder selects the canonical home root; it never accepts caller-authored
-- values, release coordinates, storage bindings or a different substrate.
data RpcBirthChartTemplate
  = RpcBirthChartTemplate
      !AuthorityScope
      !RpcBirthConfig
      !Value
      !Text
      !ResolvedCustomImage
      !(Map FilePath ByteString)
      ![ChartStorageBinding]

data RpcBirthChartRevision
  = RpcBirthChartRevision
      !RpcBirthDescriptor
      !ByteString
      !(Map FilePath ByteString)
      ![ChartStorageBinding]

data RuntimeImageObservation
  = RuntimeImageNotObserved
  | RuntimeImageObserved !ResolvedCustomImage
  | RuntimeImageUnavailable
  | RuntimeImageRepeated

-- This is a rejection ceiling for held serialized inputs, not a heap estimate
-- or an admission grant. The eventual host permit must fund decoded/working
-- memory and parent/child/helper concurrency separately.
rpcBirthChartMaximumInputBytes :: Int
rpcBirthChartMaximumInputBytes = 256 * 1024

prepareRpcBirthChart
  :: AuthorityScope
  -> FilePath
  -> ValidatedSettings
  -> IO (Either RpcBirthChartError RpcBirthChartTemplate)
prepareRpcBirthChart = prepareRpcBirthChartWithObservers productionChartPlanObservers

-- | The canonical planner's observation seam. The operation-owned adapter feeds
-- only its held bounded observations; ordinary callers use the factory above.
prepareRpcBirthChartWithObservers
  :: ChartPlanObservers
  -> AuthorityScope
  -> FilePath
  -> ValidatedSettings
  -> IO (Either RpcBirthChartError RpcBirthChartTemplate)
prepareRpcBirthChartWithObservers observers scope repoRoot settings = do
  imageObservation <- newIORef RuntimeImageNotObserved
  let holdingObservers =
        observers
          { observeRuntimeChartImage = \substrate -> do
              result <- observeRuntimeChartImage observers substrate
              atomicModifyIORef' imageObservation $ \prior ->
                let selected = case prior of
                      RuntimeImageNotObserved -> case result of
                        Right (Just image) -> RuntimeImageObserved image
                        Right Nothing -> RuntimeImageUnavailable
                        Left _ -> RuntimeImageUnavailable
                      RuntimeImageObserved _ -> RuntimeImageRepeated
                      RuntimeImageUnavailable -> RuntimeImageRepeated
                      RuntimeImageRepeated -> RuntimeImageRepeated
                 in (selected, ())
              pure result
          }
  attempted <-
    try
      ( buildChartDeploymentPlanForSubstrateWithObservers
          holdingObservers
          SubstrateHomeLocal
          repoRoot
          settings
          "lifecycle-authority"
          Map.empty
          Map.empty
      )
  let planned = case attempted of
        Left (_ :: IOException) -> Left RpcBirthChartPlanUnavailable
        Right result -> first (const RpcBirthChartPlanUnavailable) result
  selected <- readIORef imageObservation
  let prepared = do
        release <- planned >>= selectRoot
        image <- case selected of
          RuntimeImageObserved value -> Right value
          RuntimeImageNotObserved -> Left RpcBirthChartPlanUnavailable
          RuntimeImageUnavailable -> Left RpcBirthChartPlanUnavailable
          RuntimeImageRepeated -> Left RpcBirthChartPlanUnavailable
        (pin, values, role, endpoint, inputBytes) <- heldValues scope release
        expected <- canonicalRole scope endpoint image pin
        unless (role == expected) (Left RpcBirthChartConfigInvalid)
        pure (release, pin, values, endpoint, image, inputBytes)
  case prepared of
    Left cause -> pure (Left cause)
    Right (release, pin, values, endpoint, image, inputBytes) -> do
      snapshot <- snapshotChart repoRoot (rpcBirthChartMaximumInputBytes - inputBytes)
      pure $
        ( \files ->
            RpcBirthChartTemplate
              scope
              pin
              values
              endpoint
              image
              files
              (chartReleasePlanStorageBindings release)
        )
          <$> snapshot
 where
  selectRoot plan = do
    unless
      ( chartDeploymentPlanRootChart plan == "lifecycle-authority"
          && chartDeploymentPlanNamespace plan == "lifecycle-authority"
          && chartDeploymentPlanSubstrate plan == SubstrateHomeLocal
      )
      (Left RpcBirthChartIdentityMismatch)
    case filter ((== "lifecycle-authority") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
      [release]
        | chartReleasePlanChartName release == "lifecycle-authority"
            && chartReleasePlanNamespace release == "lifecycle-authority"
            && normalise (chartReleasePlanChartDir release)
              == normalise (repoRoot </> "charts" </> "lifecycle-authority") ->
            Right release
      _ -> Left RpcBirthChartIdentityMismatch

heldValues
  :: AuthorityScope
  -> ChartReleasePlan
  -> Either RpcBirthChartError (RpcBirthConfig, Value, Text, Text, Int)
heldValues scope release = do
  let bytes = Lazy.toStrict (Lazy8.pack (chartReleasePlanValuesJson release))
  when (BS.length bytes > rpcBirthChartMaximumInputBytes) (Left RpcBirthChartInputTooLarge)
  values <- first (const RpcBirthChartConfigInvalid) (eitherDecodeStrict' bytes)
  role <- roleDhall values
  -- No import, environment lookup or remote resolution is possible here or
  -- after the fence. Only the canonical renderer's closed expression is held.
  parsed <-
    first (const RpcBirthChartConfigInvalid) (Parser.exprFromText "held Authority configuration" role)
  closed <- traverse (const (Left RpcBirthChartConfigInvalid)) parsed
  _ <- first (const RpcBirthChartConfigInvalid) (TypeCheck.typeOf closed)
  config <-
    first (const RpcBirthChartConfigInvalid) $
      Dhall.toMonadic (Dhall.extract Dhall.auto (Core.normalize closed))
  _ <-
    first
      (const RpcBirthChartConfigInvalid)
      (Runtime.validateControlPlaneConfig LifecycleAuthorityRuntime config)
  unless (Runtime.cluster_id config == authorityScopeText scope) (Left RpcBirthChartIdentityMismatch)
  endpoint <- case Runtime.role_store config of
    Runtime.RoleStorePrimary store -> Right (Runtime.primary_endpoint store)
    _ -> Left RpcBirthChartConfigInvalid
  pure (Runtime.rpc_registration config, values, role, endpoint, BS.length bytes)

canonicalRole
  :: AuthorityScope -> Text -> ResolvedCustomImage -> RpcBirthConfig -> Either RpcBirthChartError Text
canonicalRole scope endpoint image pin = do
  values <-
    first (const RpcBirthChartConfigInvalid) $
      valuesForLifecycleAuthorityWithRpcBirth
        pin
        (authorityScopeText scope)
        endpoint
        "lifecycle-authority"
        "lifecycle-authority"
        (Just image)
  roleDhall values

roleDhall :: Value -> Either RpcBirthChartError Text
roleDhall (Object values) = case KeyMap.lookup "config" values of
  Just (Object config) -> case KeyMap.lookup "roleDhall" config of
    Just (String role) -> Right role
    _ -> Left RpcBirthChartConfigInvalid
  _ -> Left RpcBirthChartConfigInvalid
roleDhall _ = Left RpcBirthChartConfigInvalid

-- | Use the canonical role renderer with held inputs. Semantic equivalence
-- alone is insufficient: Helm's config checksum observes the exact text.
-- All other chart values/bytes remain held. Deadline/identity coordination
-- still belongs to the caller's fold,
-- including recovery of a committed descriptor whose preparation has expired.
pinRpcBirthChart
  :: RpcBirthChartTemplate -> RpcBirthDescriptor -> Either RpcBirthChartError RpcBirthChartRevision
pinRpcBirthChart (RpcBirthChartTemplate scope original values endpoint image files storage) descriptor = do
  unless (rpcBirthDescriptorScope descriptor == scope) (Left RpcBirthChartIdentityMismatch)
  let desired =
        RpcBirthConfigRegistered
          ( RpcBirthConfigPin
              (authorityScopeText scope)
              (rpcBirthDescriptorGeneration descriptor)
              (rpcBirthDescriptorDigest descriptor)
          )
  _ <-
    first
      (const RpcBirthChartConfigInvalid)
      (validateRpcBirthConfig LifecycleAuthorityRuntime scope desired)
  unless
    (original == RpcBirthConfigLegacy || original == desired)
    (Left RpcBirthChartSourcePinConflict)
  role <- canonicalRole scope endpoint image desired
  updated <- case values of
    Object fields -> case KeyMap.lookup "config" fields of
      Just (Object config) ->
        Right
          (Object (KeyMap.insert "config" (Object (KeyMap.insert "roleDhall" (String role) config)) fields))
      _ -> Left RpcBirthChartConfigInvalid
    _ -> Left RpcBirthChartConfigInvalid
  let encoded = Lazy.toStrict (encode updated)
  when
    (BS.length encoded + sum (map BS.length (Map.elems files)) > rpcBirthChartMaximumInputBytes)
    (Left RpcBirthChartInputTooLarge)
  pure (RpcBirthChartRevision descriptor encoded files storage)

rpcBirthChartDescriptor :: RpcBirthChartRevision -> RpcBirthDescriptor
rpcBirthChartDescriptor (RpcBirthChartRevision descriptor _ _ _) = descriptor

rpcBirthChartValues :: RpcBirthChartRevision -> ByteString
rpcBirthChartValues (RpcBirthChartRevision _ values _ _) = values

rpcBirthChartFiles :: RpcBirthChartRevision -> [(FilePath, ByteString)]
rpcBirthChartFiles (RpcBirthChartRevision _ _ files _) = Map.toAscList files

rpcBirthChartStorageBindings :: RpcBirthChartRevision -> [ChartStorageBinding]
rpcBirthChartStorageBindings (RpcBirthChartRevision _ _ _ storage) = storage

type Snapshot = ExceptT RpcBirthChartError IO

-- Every path below the canonical repository is opened relative to held
-- directory descriptors, without symlinks. Enumeration also uses the held
-- directory, rather than reopening its mutable original pathname.
snapshotChart :: FilePath -> Int -> IO (Either RpcBirthChartError (Map FilePath ByteString))
snapshotChart repoRoot available = do
  attempted <- try $ do
    root <- canonicalizePath repoRoot
    bracket (openFd root ReadOnly directoryFlags) closeFd $ \repository ->
      runExceptT $
        withNode repository "charts" $ \charts ->
          withNode charts "lifecycle-authority" $ \chart -> do
            (files, _, _) <- readTree chart "" 0 64 available
            unless
              ( all
                  (`Map.member` Map.fromList files)
                  ["Chart.yaml", "values.yaml", "templates/statefulset.yaml", "templates/configmap-config.yaml"]
              )
              (throwE RpcBirthChartSourceUnsafe)
            pure (Map.fromList files)
  pure $ case attempted of
    Left (_ :: IOException) -> Left RpcBirthChartSourceUnavailable
    Right result -> result

directoryFlags :: OpenFileFlags
directoryFlags = defaultFileFlags {nofollow = True, cloexec = True, nonBlock = True, directory = True}

withNode :: Fd -> FilePath -> (Fd -> Snapshot value) -> Snapshot value
withNode parent name action = ExceptT $ do
  before <- getSymbolicLinkStatus (descriptorPath parent </> name)
  if not (isRegularFile before || isDirectory before)
    then pure (Left RpcBirthChartSourceUnsafe)
    else bracket (openFdAt (Just parent) name ReadOnly (directoryFlags {directory = False})) closeFd $ \fd ->
      runExceptT $ do
        opened <- lift (getFdStatus fd)
        unless (sameVersion before opened) (throwE RpcBirthChartSourceChanged)
        result <- action fd
        after <- lift (getFdStatus fd)
        unless (sameVersion opened after) (throwE RpcBirthChartSourceChanged)
        pure result

descriptorPath :: Fd -> FilePath
descriptorPath (Fd fd) = "/proc/self/fd/" <> show fd

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && fileSize a == fileSize b
    && modificationTimeHiRes a == modificationTimeHiRes b
    && statusChangeTimeHiRes a == statusChangeTimeHiRes b

readTree :: Fd -> FilePath -> Int -> Int -> Int -> Snapshot ([(FilePath, ByteString)], Int, Int)
readTree directoryFd prefix depth entriesLeft bytesLeft = do
  status <- lift (getFdStatus directoryFd)
  unless (isDirectory status) (throwE RpcBirthChartSourceUnsafe)
  when (depth > 4 || entriesLeft <= 0) (throwE RpcBirthChartInputTooLarge)
  names <- ExceptT $ bracket (openDirStream (descriptorPath directoryFd)) closeDirStream $ \stream ->
    let collect count result = do
          name <- readDirStream stream
          case name of
            "" -> pure (Right (sort result))
            "." -> collect count result
            ".." -> collect count result
            _
              | length name > 255 || '/' `elem` name -> pure (Left RpcBirthChartSourceUnsafe)
              | count >= entriesLeft -> pure (Left RpcBirthChartInputTooLarge)
              | otherwise -> collect (count + 1) (name : result)
     in collect 0 []
  foldM readEntry ([], entriesLeft - length names, bytesLeft) names
 where
  readEntry (held, remainingEntries, remainingBytes) name =
    withNode directoryFd name $ \fd -> do
      status <- lift (getFdStatus fd)
      let relative = if null prefix then name else prefix </> name
      if isDirectory status
        then do
          unless (relative == "templates") (throwE RpcBirthChartSourceUnsafe)
          (files, entries, bytes) <- readTree fd relative (depth + 1) remainingEntries remainingBytes
          pure (held ++ files, entries, bytes)
        else do
          unless
            ( isRegularFile status
                && ( relative `elem` ["Chart.yaml", "values.yaml", ".helmignore"]
                       || prefix == "templates" && takeExtension name `elem` [".yaml", ".yml", ".tpl"]
                   )
            )
            (throwE RpcBirthChartSourceUnsafe)
          when (fileSize status > fromIntegral remainingBytes) (throwE RpcBirthChartInputTooLarge)
          bytes <- readBytes fd remainingBytes [] 0
          pure ((relative, bytes) : held, remainingEntries, remainingBytes - BS.length bytes)

readBytes :: Fd -> Int -> [ByteString] -> Int -> Snapshot ByteString
readBytes fd maximumBytes chunks count = do
  next <- lift $ do
    result <- try (Posix.fdRead fd (fromIntegral (min 8192 (maximumBytes - count + 1))))
    case result of
      Left failure | isEOFError failure -> pure BS.empty
      Left failure -> ioError failure
      Right bytes -> pure bytes
  if BS.null next
    then pure (BS.concat (reverse chunks))
    else do
      let total = count + BS.length next
      when (total > maximumBytes) (throwE RpcBirthChartInputTooLarge)
      readBytes fd maximumBytes (next : chunks) total
