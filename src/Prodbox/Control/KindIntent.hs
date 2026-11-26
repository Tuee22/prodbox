{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A durable, non-authorizing record of a proposed kind operation. The
-- lifecycle interpreter must still provide admission, exclusion, settlement,
-- resource observation, and recovery before it may perform any effect.
module Prodbox.Control.KindIntent
  ( KindIntentResult (..)
  , KindIntentObservation (..)
  , recordKindIntent
  , recordKindFamilyIntent
  , recordKindOwnerFamilyIntent
  , observeKindIntent
  , observeKindFamilyIntent
  , observeKindOwnerFamilyIntent
  , observeKindExternalFamilyIntent
  , observeKindTeardownAdmission
  , recordKindTeardownAdmission
  , recordKindVolumeIntent
  , observeKindVolumeIntent
  )
where

import Control.Exception (IOException, bracket, mask, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeGenerationObservation (..)
  , observeScopeGeneration
  , scopeKindName
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Config.KindPlan (renderKindConfig)
import Prodbox.Config.KindVolume
  ( KindVolume
  , kindVolume
  , kindVolumeCapacityMib
  , kindVolumeGeneration
  , kindVolumeName
  , kindVolumeNamespace
  , kindVolumeNodePath
  , kindVolumeScope
  )
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import System.FilePath (splitDirectories)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data KindIntentResult
  = KindIntentRecorded
  | KindIntentAlreadyExists
  | KindIntentInvalidOperation
  | KindIntentWrongGeneration
  | KindIntentWrongVolume
  | KindIntentIncomplete
  | KindIntentUnobservable
  deriving (Eq, Show)

data KindIntentObservation
  = KindIntentMissing
  | KindIntentMatches !String
  | KindIntentVolumeMatches !String !KindVolume
  | KindIntentConflict
  | KindIntentInvalid
  | KindIntentGenerationUnavailable
  | KindIntentObservationUnobservable
  deriving (Eq, Show)

data IntentProtocol = LegacyIntent | FamilyIntent | OwnerFamilyIntent
  deriving (Eq)

data IntentPurpose = ReconcileIntent | TeardownAdmission
  deriving (Eq)

intentName :: IntentPurpose -> FilePath
intentName ReconcileIntent = "kind-intent.json"
intentName TeardownAdmission = "kind-teardown-admission.json"

data IntentSelection = AnyIntent | AnyFamilyIntent | OwnerFamilyOnly | ExternalFamilyOnly
  deriving (Eq)

-- | Independently observe a pending record. A matching record is evidence of
-- its stored bytes, not a permit, completed operation, or proof of absence.
observeKindIntent :: BootstrapProjection -> IO KindIntentObservation
observeKindIntent bootstrap = observeKindIntentFor bootstrap Nothing

-- A family intent is written as the original intent, not inferred from the
-- absence of legacy records. Older readers reject its different schema.
observeKindFamilyIntent :: BootstrapProjection -> IO KindIntentObservation
observeKindFamilyIntent bootstrap = observeKindIntentForMode bootstrap Nothing AnyFamilyIntent

-- This protocol declares that all prerequisite effects belong to the
-- submitted family; family-v1 does not make that claim.
observeKindOwnerFamilyIntent :: BootstrapProjection -> IO KindIntentObservation
observeKindOwnerFamilyIntent bootstrap = observeKindIntentForMode bootstrap Nothing OwnerFamilyOnly

observeKindExternalFamilyIntent :: BootstrapProjection -> IO KindIntentObservation
observeKindExternalFamilyIntent bootstrap = observeKindIntentForMode bootstrap Nothing ExternalFamilyOnly

-- | Verify an exact volume intent against the requested scope and coordinates.
observeKindVolumeIntent :: BootstrapProjection -> KindVolume -> IO KindIntentObservation
observeKindVolumeIntent bootstrap volume
  | not (volumeMatchesBootstrap bootstrap volume) = pure KindIntentConflict
  | otherwise = observeKindIntentFor bootstrap (Just volume)

observeKindIntentFor :: BootstrapProjection -> Maybe KindVolume -> IO KindIntentObservation
observeKindIntentFor bootstrap expectedVolume = observeKindIntentForMode bootstrap expectedVolume AnyIntent

observeKindIntentForMode
  :: BootstrapProjection -> Maybe KindVolume -> IntentSelection -> IO KindIntentObservation
observeKindIntentForMode = observeIntentRecord ReconcileIntent

-- A receipt only binds the durable decision to a scope. Its consumer must
-- also hold the matching operation and keep Authority deployment fenced.
observeKindTeardownAdmission :: BootstrapProjection -> IO KindIntentObservation
observeKindTeardownAdmission bootstrap = observeIntentRecord TeardownAdmission bootstrap Nothing OwnerFamilyOnly

observeIntentRecord
  :: IntentPurpose
  -> BootstrapProjection
  -> Maybe KindVolume
  -> IntentSelection
  -> IO KindIntentObservation
observeIntentRecord purpose bootstrap expectedVolume selection = do
  result <- withScopeRootDescriptor scope $ \root sameRoot -> do
    attempted <- try (inspect root sameRoot)
    pure $
      either
        (const KindIntentObservationUnobservable)
        id
        (attempted :: Either IOException KindIntentObservation)
  pure $ either (const KindIntentObservationUnobservable) id result
 where
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  inspect root sameRoot = do
    owner <- getEffectiveUserID
    rootStatus <- getFdStatus root
    generationState <- observeScopeGeneration scope generation
    if not (isDirectory rootStatus && fileOwner rootStatus == owner && fileMode rootStatus .&. 0o022 == 0)
      then pure KindIntentObservationUnobservable
      else
        if generationState /= Right ScopeGenerationMatches
          then pure KindIntentGenerationUnavailable
          else do
            result <- mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) (intentName purpose) Posix.ReadOnly flags)
              case opened of
                Left (failure :: IOException)
                  | isDoesNotExistError failure -> pure KindIntentMissing
                  | otherwise -> pure KindIntentObservationUnobservable
                Right descriptor -> do
                  inspected <- try $ bracket (pure descriptor) Posix.closeFd $ \file -> restore $ do
                    before <- getFdStatus file
                    if not
                      ( isRegularFile before
                          && fileOwner before == owner
                          && fileMode before .&. 0o022 == 0
                          && linkCount before == 1
                          && fileSize before <= 32768
                      )
                      then pure KindIntentObservationUnobservable
                      else do
                        bytes <- readBounded file
                        checked <- decodeBoundedYamlValue bytes
                        after <- getFdStatus file
                        named <-
                          bracket
                            (Posix.openFdAt (Just root) (intentName purpose) Posix.ReadOnly flags)
                            Posix.closeFd
                            getFdStatus
                        pure $
                          if sameVersion before after && sameVersion after named
                            then classify rootStatus bytes checked
                            else KindIntentObservationUnobservable
                  pure $
                    either
                      (const KindIntentObservationUnobservable)
                      id
                      (inspected :: Either IOException KindIntentObservation)
            stable <- sameRoot
            finalRootStatus <- getFdStatus root
            finalGeneration <- observeScopeGeneration scope generation
            pure $
              if not stable
                || not
                  ( isDirectory finalRootStatus
                      && fileOwner finalRootStatus == owner
                      && fileMode finalRootStatus .&. 0o022 == 0
                  )
                || finalGeneration /= Right ScopeGenerationMatches
                then KindIntentObservationUnobservable
                else result
  classify rootStatus bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
    (Right value, Right checkedValue) | value == checkedValue -> case parseEither (Aeson.withObject "kind intent" (.: "operation_id")) value of
      Left _ -> KindIntentInvalid
      Right operationId
        | not (validRootGeneration operationId) -> KindIntentInvalid
        | selection /= ExternalFamilyOnly
        , expectedVolume == Nothing
        , Aeson.decodeStrict'
            (kindIntentBytes purpose bootstrap operationId rootStatus Nothing OwnerFamilyIntent)
            == Just value ->
            KindIntentMatches operationId
        | selection /= OwnerFamilyOnly
        , expectedVolume == Nothing
        , Aeson.decodeStrict' (kindIntentBytes purpose bootstrap operationId rootStatus Nothing FamilyIntent)
            == Just value ->
            KindIntentMatches operationId
        | selection == AnyIntent
        , Aeson.decodeStrict'
            (kindIntentBytes purpose bootstrap operationId rootStatus expectedVolume LegacyIntent)
            == Just value ->
            KindIntentMatches operationId
        | selection == AnyIntent
        , Nothing <- expectedVolume
        , Right candidate <- recordedVolume value
        , Aeson.decodeStrict'
            (kindIntentBytes purpose bootstrap operationId rootStatus (Just candidate) LegacyIntent)
            == Just value ->
            KindIntentVolumeMatches operationId candidate
        | otherwise -> KindIntentConflict
    _ -> KindIntentInvalid
  recordedVolume = parseEither $ Aeson.withObject "kind intent" $ \object -> do
    details <- object .: "volume"
    Aeson.withObject
      "volume"
      ( \fields -> do
          namespace <- fields .: "namespace"
          path <- fields .: "node_path"
          capacity <- fields .: "capacity_mib"
          case splitDirectories path of
            ["/", "var", "lib", "prodbox", "control", "volumes", pathGeneration, pathNamespace, service, name]
              | pathGeneration == generation && pathNamespace == namespace ->
                  either (fail . show) pure (kindVolume scope generation namespace service name capacity)
            _ -> fail "unexpected volume path"
      )
      details

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion before after =
  deviceID before == deviceID after
    && fileID before == fileID after
    && fileSize before == fileSize after
    && fileMode before == fileMode after
    && fileOwner before == fileOwner after
    && linkCount before == linkCount after
    && modificationTimeHiRes before == modificationTimeHiRes after
    && statusChangeTimeHiRes before == statusChangeTimeHiRes after

-- | Exclusively create one intent without overwriting it. An existing file is never
-- interpreted as a matching operation; interrupted creation remains explicit
-- for a future recovery handler. No external effect is authorized here.
recordKindIntent :: BootstrapProjection -> String -> IO KindIntentResult
recordKindIntent bootstrap operationId = recordKindIntentFor bootstrap operationId Nothing LegacyIntent

recordKindFamilyIntent :: BootstrapProjection -> String -> IO KindIntentResult
recordKindFamilyIntent bootstrap operationId = recordKindIntentFor bootstrap operationId Nothing FamilyIntent

recordKindOwnerFamilyIntent :: BootstrapProjection -> String -> IO KindIntentResult
recordKindOwnerFamilyIntent bootstrap operationId = recordKindIntentFor bootstrap operationId Nothing OwnerFamilyIntent

-- | Record the exact volume before any directory preparation.
recordKindVolumeIntent :: BootstrapProjection -> String -> KindVolume -> IO KindIntentResult
recordKindVolumeIntent bootstrap operationId volume
  | not (volumeMatchesBootstrap bootstrap volume) = pure KindIntentWrongVolume
  | otherwise = recordKindIntentFor bootstrap operationId (Just volume) LegacyIntent

volumeMatchesBootstrap :: BootstrapProjection -> KindVolume -> Bool
volumeMatchesBootstrap bootstrap volume =
  kindVolumeScope volume == bootstrapScope bootstrap
    && kindVolumeGeneration volume == Text.unpack (bootstrapRootGeneration bootstrap)

recordKindIntentFor
  :: BootstrapProjection -> String -> Maybe KindVolume -> IntentProtocol -> IO KindIntentResult
recordKindIntentFor = recordIntent ReconcileIntent

-- The caller must hold the operation lease and obtain fresh early teardown
-- admission before recording this decision.
recordKindTeardownAdmission :: BootstrapProjection -> String -> IO KindIntentResult
recordKindTeardownAdmission bootstrap operation = do
  owner <- observeKindOwnerFamilyIntent bootstrap
  if owner == KindIntentMatches operation
    then recordIntent TeardownAdmission bootstrap operation Nothing OwnerFamilyIntent
    else pure KindIntentUnobservable

recordIntent
  :: IntentPurpose
  -> BootstrapProjection
  -> String
  -> Maybe KindVolume
  -> IntentProtocol
  -> IO KindIntentResult
recordIntent purpose bootstrap operationId expectedVolume protocol
  | not (validRootGeneration operationId) = pure KindIntentInvalidOperation
  | otherwise = do
      outcome <- withScopeRootDescriptor scope $ \root sameRoot -> do
        attempt <- try (record root sameRoot)
        pure $ either (const KindIntentUnobservable) id (attempt :: Either IOException KindIntentResult)
      pure $ either (const KindIntentUnobservable) id outcome
 where
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  name = intentName purpose
  fileFlags =
    Posix.defaultFileFlags
      { Posix.nofollow = True
      , Posix.cloexec = True
      , Posix.exclusive = True
      , Posix.creat = Just 0o600
      }
  readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  record root sameRoot = do
    owner <- getEffectiveUserID
    rootStatus <- getFdStatus root
    generationState <- observeScopeGeneration scope generation
    rootStable <- sameRoot
    if not
      ( isDirectory rootStatus
          && fileOwner rootStatus == owner
          && fileMode rootStatus .&. 0o022 == 0
          && rootStable
      )
      then pure KindIntentUnobservable
      else
        if generationState /= Right ScopeGenerationMatches
          then pure KindIntentWrongGeneration
          else do
            let contents = kindIntentBytes purpose bootstrap operationId rootStatus expectedVolume protocol
            mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) name Posix.WriteOnly fileFlags)
              case created of
                Left (failure :: IOException)
                  | isAlreadyExistsError failure -> pure KindIntentAlreadyExists
                  | otherwise -> pure KindIntentUnobservable
                Right fd -> do
                  completed <- try $ bracket (pure fd) Posix.closeFd $ \held -> restore $ do
                    writeAll held contents
                    fileSynchronise held
                    written <- getFdStatus held
                    fileSynchronise root
                    reread <- bracket (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags) Posix.closeFd $ \fresh -> do
                      observed <- getFdStatus fresh
                      if not
                        ( isRegularFile observed
                            && fileOwner observed == owner
                            && linkCount observed == 1
                            && fileMode observed .&. 0o022 == 0
                            && fileSize observed <= 32768
                            && deviceID observed == deviceID written
                            && fileID observed == fileID written
                        )
                        then pure False
                        else do
                          bytes <- readBounded fresh
                          after <- getFdStatus fresh
                          named <-
                            bracket (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
                          pure
                            ( bytes == contents
                                && deviceID after == deviceID observed
                                && fileID after == fileID observed
                                && fileSize after == fileSize observed
                                && fileMode after == fileMode observed
                                && fileOwner after == fileOwner observed
                                && linkCount after == linkCount observed
                                && modificationTimeHiRes after == modificationTimeHiRes observed
                                && statusChangeTimeHiRes after == statusChangeTimeHiRes observed
                                && deviceID named == deviceID after
                                && fileID named == fileID after
                                && fileSize named == fileSize after
                                && modificationTimeHiRes named == modificationTimeHiRes after
                                && statusChangeTimeHiRes named == statusChangeTimeHiRes after
                            )
                    stillStable <- sameRoot
                    currentGeneration <- observeScopeGeneration scope generation
                    pure (reread && stillStable && currentGeneration == Right ScopeGenerationMatches)
                  pure $ case completed of
                    Right True -> KindIntentRecorded
                    (_ :: Either IOException Bool) -> KindIntentIncomplete

kindIntentBytes
  :: IntentPurpose
  -> BootstrapProjection
  -> String
  -> FileStatus
  -> Maybe KindVolume
  -> IntentProtocol
  -> ByteString.ByteString
kindIntentBytes purpose bootstrap operationId status expectedVolume protocol =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object $
        [ "schema_version"
            Aeson..= ( case protocol of
                         LegacyIntent -> maybe (1 :: Int) (const 2) expectedVolume
                         FamilyIntent -> 3
                         OwnerFamilyIntent -> 4
                     )
        , "operation_id" Aeson..= operationId
        , "operation"
            Aeson..= ( case purpose of
                         ReconcileIntent -> "kind-reconcile"
                         TeardownAdmission -> "kind-teardown-never-admitted" :: String
                     )
        , "cluster" Aeson..= scopeKindName scope
        , "root_generation" Aeson..= generation
        , "root_device" Aeson..= toInteger (deviceID status)
        , "root_inode" Aeson..= toInteger (fileID status)
        , "runtime_socket" Aeson..= bootstrapRuntimeSocket bootstrap
        , "kind_config_sha256"
            Aeson..= ("sha256:" ++ sha256Hex (LazyByteString.toStrict (renderKindConfig (bootstrapKindPlan bootstrap))))
        , "node_artifact" Aeson..= fmap artifactValue (bootstrapNodeArtifact bootstrap)
        ]
          ++ maybe [] (\tool -> ["kind_tool" Aeson..= artifactValue tool]) (bootstrapKindTool bootstrap)
          ++ maybe [] (\volume -> ["volume" Aeson..= volumeValue volume]) expectedVolume
          ++ case protocol of
            LegacyIntent -> []
            FamilyIntent -> ["controller_protocol" Aeson..= ("family-v1" :: String)]
            OwnerFamilyIntent -> ["controller_protocol" Aeson..= ("family-v2" :: String)]
 where
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  volumeValue volume =
    Aeson.object
      [ "name" Aeson..= kindVolumeName volume
      , "namespace" Aeson..= kindVolumeNamespace volume
      , "node_path" Aeson..= kindVolumeNodePath volume
      , "capacity_mib" Aeson..= kindVolumeCapacityMib volume
      ]
  artifactValue artifact =
    Aeson.object
      [ "path" Aeson..= artifactPath artifact
      , "digest" Aeson..= artifactDigest artifact
      , "maximum_bytes" Aeson..= artifactMaximumBytes artifact
      ]

sha256Hex :: ByteString.ByteString -> String
sha256Hex = concatMap hexByte . ByteString.unpack . SHA256.hash
 where
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll fd bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite fd bytes
      if count <= 0
        then ioError (userError "short intent write")
        else writeAll fd (ByteString.drop (fromIntegral count) bytes)

readBounded :: Fd -> IO ByteString.ByteString
readBounded fd = go [] 0
 where
  go chunks count
    | count > 32768 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        result <- try (PosixBytes.fdRead fd (fromIntegral (32769 - count)))
        case result of
          Left (failure :: IOException)
            | isEOFError failure -> pure (ByteString.concat (reverse chunks))
            | otherwise -> ioError failure
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (chunk : chunks) (count + ByteString.length chunk)
