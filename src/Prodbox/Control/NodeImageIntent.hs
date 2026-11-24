{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Durable, non-authorizing intent for one node-image load attempt. A record
-- does not prove daemon identity, admit an effect, or settle a prior worker.
module Prodbox.Control.NodeImageIntent
  ( NodeImageIntent
  , mkNodeImageIntent
  , bindNodeImageIntent
  , NodeImageIntentObservation (..)
  , NodeImageIntentWrite (..)
  , observeNodeImageIntent
  , observeRecordedNodeImageIntent
  , NodeImageIdentityObservation (..)
  , observeRecordedNodeImageIdentity
  , nodeImageIntentConfigDigest
  , nodeImageIntentManifestDigest
  , recordNodeImageIntent
  , NodeImageAttemptObservation (..)
  , NodeImageAttemptWrite (..)
  , observeNodeImageAttempt
  , observeRecordedNodeImageAttempt
  , recordNodeImageAttempt
  , NodeImageResultObservation (..)
  , NodeImageResultWrite (..)
  , observeRecordedNodeImageResult
  , observeNodeImageResult
  , recordNodeImageResult
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:), (.:?))
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
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
import Prodbox.Config.KindPlan (kindPlanNodeImage)
import Prodbox.Control.DockerConnectedInfo (DockerImageLoadResult (..), DockerImageLoadStream (..))
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , DockerSocketIdentity (..)
  , classifyDockerDaemon
  )
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data NodeImageIntent
  = NodeImageIntent !String !String !String !String !Integer !(Maybe (String, DockerSocketIdentity))
  deriving (Eq, Show)

nodeImageIntentConfigDigest :: NodeImageIntent -> String
nodeImageIntentConfigDigest (NodeImageIntent _ _ config _ _ _) = config

nodeImageIntentManifestDigest :: NodeImageIntent -> String
nodeImageIntentManifestDigest (NodeImageIntent _ manifest _ _ _ _) = manifest

data NodeImageIdentityObservation
  = NodeImageIdentityRefused !NodeImageIntentObservation
  | NodeImageIdentityObserved !NodeImageIntent !DockerDaemonObservation
  deriving (Eq, Show)

mkNodeImageIntent :: String -> String -> String -> String -> Integer -> Maybe NodeImageIntent
mkNodeImageIntent operation manifest config staged bytes
  | validRootGeneration operation
      && all validDigest [manifest, config, staged]
      && bytes > 0
      && bytes <= 4294967296 =
      Just (NodeImageIntent operation manifest config staged bytes Nothing)
  | otherwise = Nothing

-- | Bind the record to a daemon/socket observation. A prior binding cannot be
-- replaced by a different one. This does not authenticate the daemon or make
-- the record an effect permit.
bindNodeImageIntent :: NodeImageIntent -> DockerDaemonObservation -> Maybe NodeImageIntent
bindNodeImageIntent (NodeImageIntent operation manifest config staged bytes existing) observed = case observed of
  DockerDaemonObserved identifier socket@(DockerSocketIdentity device inode owner mode)
    | device >= 0
        && inode > 0
        && owner >= 0
        && mode >= 0
        && mode .&. 0o170000 == 0o140000
        && classifyDockerDaemon (Just socket) (Just identifier) (Just socket) (Just identifier) (Just socket)
          == observed
        && maybe True (== (identifier, socket)) existing ->
        Just (NodeImageIntent operation manifest config staged bytes (Just (identifier, socket)))
  _ -> Nothing

validDigest :: String -> Bool
validDigest value =
  take 7 value == "sha256:"
    && length value == 71
    && all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (drop 7 value)

data NodeImageIntentObservation
  = NodeImageIntentMissing
  | NodeImageIntentMatches
  | NodeImageIntentBound !DockerDaemonObservation
  | NodeImageIntentConflict
  | NodeImageIntentInvalid
  | NodeImageIntentUnobservable
  deriving (Eq, Show)

data NodeImageIntentWrite
  = NodeImageIntentRecorded
  | NodeImageIntentAlreadyExists
  | NodeImageIntentRefused
  | NodeImageIntentIncomplete
  deriving (Eq, Show)

-- This record means an effect may have been attempted, not that one ran or
-- settled. Missing local state is never proof that a daemon effect is absent.
data NodeImageAttemptObservation
  = NodeImageAttemptMissing
  | NodeImageAttemptMatches
  | NodeImageAttemptConflict
  | NodeImageAttemptInvalid
  | NodeImageAttemptUnobservable
  deriving (Eq, Show)

data NodeImageAttemptWrite
  = NodeImageAttemptRecorded
  | NodeImageAttemptAlreadyExists
  | NodeImageAttemptRefused
  | NodeImageAttemptIncomplete
  deriving (Eq, Show)

data NodeImageResultObservation
  = NodeImageResultMissing
  | NodeImageResultObserved !DockerImageLoadResult
  | NodeImageResultConflict
  | NodeImageResultInvalid
  | NodeImageResultUnobservable
  deriving (Eq, Show)

data NodeImageResultWrite
  = NodeImageResultRecorded
  | NodeImageResultAlreadyExists
  | NodeImageResultRefused
  | NodeImageResultIncomplete
  deriving (Eq, Show)

-- | Persist only a bounded transport observation after the exact attempt
-- marker is present. This is not proof of image ownership or settlement.
recordNodeImageResult
  :: BootstrapProjection
  -> NodeImageIntent
  -> DockerImageLoadResult
  -> IO Bool
  -> IO NodeImageResultWrite
recordNodeImageResult bootstrap intent result stable = do
  touched <- newIORef False
  -- The closing read independently repeats the bounded admission checks. Its
  -- budget must fit inside the writer's budget, including the checks before
  -- the durable write; the enclosing operation still supplies its deadline.
  outcome <- timeout 60000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try (writeRecord touched root sameRoot)
    pure (either (const NodeImageResultRefused) id (checked :: Either IOException NodeImageResultWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right value) | value /= NodeImageResultRefused -> value
    _ | changed -> NodeImageResultIncomplete
    _ -> NodeImageResultRefused
 where
  writeRecord touched root sameRoot = do
    ready <- resultReady bootstrap intent stable sameRoot
    status <- Files.getFdStatus root
    let bytes = resultBytes bootstrap intent status result
    if not (ready && validResult result) || BS.length bytes > 8192
      then pure NodeImageResultRefused
      else mask $ \restore -> do
        created <- try (Posix.openFdAt (Just root) resultName Posix.WriteOnly createFlags)
        case created of
          Left failure | isAlreadyExistsError failure -> pure NodeImageResultAlreadyExists
          Left (_ :: IOException) -> pure NodeImageResultRefused
          Right file -> do
            writeIORef touched True
            written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
              writeAll held bytes
              fileSynchronise held
              fileSynchronise root
            case written of
              Left (_ :: IOException) -> pure NodeImageResultIncomplete
              Right () -> do
                observed <- observeNodeImageResult bootstrap intent stable
                pure
                  ( if observed == NodeImageResultObserved result
                      then NodeImageResultRecorded
                      else NodeImageResultIncomplete
                  )

observeRecordedNodeImageResult :: BootstrapProjection -> String -> IO NodeImageResultObservation
observeRecordedNodeImageResult bootstrap operation =
  withRecordedCandidate
    bootstrap
    operation
    (const NodeImageResultUnobservable)
    (observeNodeImageResult bootstrap)

observeNodeImageResult
  :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO NodeImageResultObservation
observeNodeImageResult bootstrap intent stable = do
  outcome <- timeout 30000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try (readRecord root sameRoot)
    pure
      ( either
          (const NodeImageResultUnobservable)
          id
          (checked :: Either IOException NodeImageResultObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeImageResultUnobservable
 where
  readRecord root sameRoot = do
    ready <- resultReady bootstrap intent stable sameRoot
    if not ready
      then pure NodeImageResultUnobservable
      else do
        owner <- getEffectiveUserID
        rootStatus <- Files.getFdStatus root
        opened <- try (Posix.openFdAt (Just root) resultName Posix.ReadOnly readFlags)
        case opened of
          Left failure | isDoesNotExistError failure -> do
            still <- resultReady bootstrap intent stable sameRoot
            pure (if still then NodeImageResultMissing else NodeImageResultUnobservable)
          Left (_ :: IOException) -> pure NodeImageResultUnobservable
          Right file -> bracket (pure file) Posix.closeFd $ \held -> do
            initial <- Files.getFdStatus held
            if not (safeFile owner initial)
              then pure NodeImageResultUnobservable
              else do
                bytes <- readBounded held
                checked <- decodeBoundedYamlValue bytes
                after <- Files.getFdStatus held
                named <-
                  bracket
                    (Posix.openFdAt (Just root) resultName Posix.ReadOnly readFlags)
                    Posix.closeFd
                    Files.getFdStatus
                still <- resultReady bootstrap intent stable sameRoot
                pure $
                  if still && sameVersion initial after && sameVersion after named
                    then decodeResult bootstrap intent rootStatus bytes checked
                    else NodeImageResultUnobservable

resultReady :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO Bool -> IO Bool
resultReady bootstrap intent stable sameRoot = do
  before <- stable
  root <- sameRoot
  attempt <- observeNodeImageAttempt bootstrap intent (pure True)
  after <- stable
  pure (before && root && attempt == NodeImageAttemptMatches && after)

-- | Write once before a possible image submission. The caller must hold the
-- operation lease and establish separate admission and worker settlement. The
-- record is bound to an existing daemon-bound intent; it is not a permit.
recordNodeImageAttempt
  :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO NodeImageAttemptWrite
recordNodeImageAttempt bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try (writeRecord touched root sameRoot)
    pure
      (either (const NodeImageAttemptRefused) id (checked :: Either IOException NodeImageAttemptWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeImageAttemptRefused -> result
    _ | changed -> NodeImageAttemptIncomplete
    _ -> NodeImageAttemptRefused
 where
  writeRecord touched root sameRoot = do
    before <- attemptReady bootstrap intent stable sameRoot
    status <- Files.getFdStatus root
    let bytes = attemptBytes bootstrap intent status
    if not before || BS.length bytes > 8192
      then pure NodeImageAttemptRefused
      else mask $ \restore -> do
        created <- try (Posix.openFdAt (Just root) attemptName Posix.WriteOnly createFlags)
        case created of
          Left failure | isAlreadyExistsError failure -> pure NodeImageAttemptAlreadyExists
          Left (_ :: IOException) -> pure NodeImageAttemptRefused
          Right file -> do
            writeIORef touched True
            written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
              writeAll held bytes
              fileSynchronise held
              fileSynchronise root
            case written of
              Left (_ :: IOException) -> pure NodeImageAttemptIncomplete
              Right () -> do
                observed <- observeNodeImageAttempt bootstrap intent stable
                pure
                  (if observed == NodeImageAttemptMatches then NodeImageAttemptRecorded else NodeImageAttemptIncomplete)

-- | Observe only this local attempt marker. Neither a match nor a missing
-- marker determines whether an earlier daemon-side worker is still active.
observeNodeImageAttempt
  :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO NodeImageAttemptObservation
observeNodeImageAttempt bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try (readRecord root sameRoot)
    pure
      ( either
          (const NodeImageAttemptUnobservable)
          id
          (checked :: Either IOException NodeImageAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeImageAttemptUnobservable
 where
  readRecord root sameRoot = do
    ready <- attemptReady bootstrap intent stable sameRoot
    if not ready
      then pure NodeImageAttemptUnobservable
      else do
        owner <- getEffectiveUserID
        rootStatus <- Files.getFdStatus root
        opened <- try (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
        case opened of
          Left failure | isDoesNotExistError failure -> do
            still <- attemptReady bootstrap intent stable sameRoot
            pure (if still then NodeImageAttemptMissing else NodeImageAttemptUnobservable)
          Left (_ :: IOException) -> pure NodeImageAttemptUnobservable
          Right file -> bracket (pure file) Posix.closeFd $ \held -> do
            initial <- Files.getFdStatus held
            if not (safeFile owner initial)
              then pure NodeImageAttemptUnobservable
              else do
                bytes <- readBounded held
                decoded <- decodeBoundedYamlValue bytes
                after <- Files.getFdStatus held
                named <-
                  bracket
                    (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
                    Posix.closeFd
                    Files.getFdStatus
                still <- attemptReady bootstrap intent stable sameRoot
                pure $
                  if not (still && sameVersion initial after && sameVersion after named)
                    then NodeImageAttemptUnobservable
                    else case classify bytes decoded (attemptBytes bootstrap intent rootStatus) of
                      NodeImageIntentMatches -> NodeImageAttemptMatches
                      NodeImageIntentConflict -> NodeImageAttemptConflict
                      _ -> NodeImageAttemptInvalid

attemptReady :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO Bool -> IO Bool
attemptReady bootstrap intent stable sameRoot = case intent of
  NodeImageIntent _ _ _ _ _ Nothing -> pure False
  NodeImageIntent _ _ _ _ _ (Just _) -> do
    before <- stable
    rootBefore <- sameRoot
    if not (before && rootBefore)
      then pure False
      else do
        -- The intent reader independently checks the root, generation and
        -- parent operation. Bracket it with the caller's full recheck instead
        -- of recursively repeating that potentially expensive recheck inside.
        observed <- observeNodeImageIntent bootstrap intent (pure True)
        rootAfter <- sameRoot
        after <- stable
        pure (observed == NodeImageIntentMatches && rootAfter && after)

attemptBytes :: BootstrapProjection -> NodeImageIntent -> Files.FileStatus -> BS.ByteString
attemptBytes bootstrap intent root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("node-image-attempt" :: String)
        , "intent" Aeson..= TextEncoding.decodeUtf8 (intentBytes bootstrap intent root)
        ]

validResult :: DockerImageLoadResult -> Bool
validResult result = case result of
  DockerImageLoadNotStarted -> True
  DockerImageLoadUnconfirmed -> True
  DockerImageLoadReply status stream ->
    status >= 100 && status <= 599 && case stream of
      DockerImageLoadMessages count -> count > 0 && count <= 1024
      DockerImageLoadErrorMessage -> True
      DockerImageLoadInvalidStream -> True

resultValue :: DockerImageLoadResult -> Aeson.Value
resultValue result = case result of
  DockerImageLoadNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerImageLoadUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerImageLoadReply status stream ->
    Aeson.object $
      ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]
        ++ case stream of
          DockerImageLoadMessages count -> ["stream" Aeson..= ("messages" :: String), "count" Aeson..= count]
          DockerImageLoadErrorMessage -> ["stream" Aeson..= ("error" :: String)]
          DockerImageLoadInvalidStream -> ["stream" Aeson..= ("invalid" :: String)]

resultBytes
  :: BootstrapProjection -> NodeImageIntent -> Files.FileStatus -> DockerImageLoadResult -> BS.ByteString
resultBytes bootstrap intent root result =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("node-image-result" :: String)
        , "attempt" Aeson..= TextEncoding.decodeUtf8 (attemptBytes bootstrap intent root)
        , "result" Aeson..= resultValue result
        ]

decodeResult
  :: BootstrapProjection
  -> NodeImageIntent
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> NodeImageResultObservation
decodeResult bootstrap intent root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right verified) | value == verified -> case parseEither parser value of
    Right result | validResult result ->
      case Aeson.eitherDecodeStrict' (resultBytes bootstrap intent root result) of
        Right expected | value == expected -> NodeImageResultObserved result
        _ -> NodeImageResultConflict
    _ -> NodeImageResultInvalid
  _ -> NodeImageResultInvalid
 where
  parser = Aeson.withObject "node image result" $ \object -> object .: "result" >>= parseResult
  parseResult = Aeson.withObject "image load transport" $ \object -> do
    state <- object .: "state" :: Parser String
    case state of
      "not-started" -> pure DockerImageLoadNotStarted
      "unconfirmed" -> pure DockerImageLoadUnconfirmed
      "reply" -> do
        status <- object .: "status"
        stream <- object .: "stream" :: Parser String
        outcome <- case stream of
          "messages" -> DockerImageLoadMessages <$> object .: "count"
          "error" -> pure DockerImageLoadErrorMessage
          "invalid" -> pure DockerImageLoadInvalidStream
          _ -> fail "invalid image load stream"
        pure (DockerImageLoadReply status outcome)
      _ -> fail "invalid image load result"

-- | The caller must hold the operation lease and independently admit any
-- effect. The supplied recheck must bind that lease and its operation intent.
recordNodeImageIntent
  :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO NodeImageIntentWrite
recordNodeImageIntent bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try (writeRecord touched root sameRoot)
    pure (either (const NodeImageIntentRefused) id (checked :: Either IOException NodeImageIntentWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeImageIntentRefused -> result
    _ | changed -> NodeImageIntentIncomplete
    _ -> NodeImageIntentRefused
 where
  writeRecord touched root sameRoot = do
    before <- preconditions bootstrap intent stable sameRoot
    if not before
      then pure NodeImageIntentRefused
      else mask $ \restore -> writeMasked touched root restore
  writeMasked touched root restore = do
    created <- try (Posix.openFdAt (Just root) recordName Posix.WriteOnly createFlags)
    case created of
      Left failure | isAlreadyExistsError failure -> pure NodeImageIntentAlreadyExists
      Left (_ :: IOException) -> pure NodeImageIntentRefused
      Right file -> do
        writeIORef touched True
        written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
          rootStatus <- Files.getFdStatus root
          writeAll held (intentBytes bootstrap intent rootStatus)
          fileSynchronise held
          fileSynchronise root
        case written of
          Left (_ :: IOException) -> pure NodeImageIntentIncomplete
          Right () -> do
            observed <- observeNodeImageIntent bootstrap intent stable
            pure $
              if observed == NodeImageIntentMatches then NodeImageIntentRecorded else NodeImageIntentIncomplete

-- | A missing record is only a local observation. This comparison cannot
-- establish whether a Docker worker ran or whether any image is absent.
observeNodeImageIntent
  :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO NodeImageIntentObservation
observeNodeImageIntent bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try (readRecord root sameRoot)
    pure
      ( either
          (const NodeImageIntentUnobservable)
          id
          (checked :: Either IOException NodeImageIntentObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeImageIntentUnobservable
 where
  readRecord root sameRoot = do
    ready <- preconditions bootstrap intent stable sameRoot
    if not ready
      then pure NodeImageIntentUnobservable
      else do
        owner <- getEffectiveUserID
        rootStatus <- Files.getFdStatus root
        opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
        case opened of
          Left failure | isDoesNotExistError failure -> do
            still <- preconditions bootstrap intent stable sameRoot
            pure (if still then NodeImageIntentMissing else NodeImageIntentUnobservable)
          Left (_ :: IOException) -> pure NodeImageIntentUnobservable
          Right file -> bracket (pure file) Posix.closeFd $ \held -> do
            initial <- Files.getFdStatus held
            if not (safeFile owner initial)
              then pure NodeImageIntentUnobservable
              else do
                bytes <- readBounded held
                decoded <- decodeBoundedYamlValue bytes
                after <- Files.getFdStatus held
                named <-
                  bracket
                    (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
                    Posix.closeFd
                    Files.getFdStatus
                still <- preconditions bootstrap intent stable sameRoot
                pure $
                  if not (still && sameVersion initial after && sameVersion after named)
                    then NodeImageIntentUnobservable
                    else classify bytes decoded (intentBytes bootstrap intent rootStatus)

-- | Observe an existing record for the exact parent operation without
-- requiring the caller to know its staged digest. This reports local record
-- consistency only; it does not observe or settle the daemon effect.
observeRecordedNodeImageIntent :: BootstrapProjection -> String -> IO NodeImageIntentObservation
observeRecordedNodeImageIntent bootstrap operation =
  withRecordedCandidate bootstrap operation id report
 where
  report (NodeImageIntent _ _ _ _ _ (Just (identifier, socket))) _ =
    pure (NodeImageIntentBound (DockerDaemonObserved identifier socket))
  report _ _ = pure NodeImageIntentMatches

-- | Return the complete validated intent and its bound daemon observation.
-- Equality of subsequent results detects changes to every recorded field; it
-- does not authenticate the daemon, prove the archive or admit an effect.
observeRecordedNodeImageIdentity :: BootstrapProjection -> String -> IO NodeImageIdentityObservation
observeRecordedNodeImageIdentity bootstrap operation =
  withRecordedCandidate bootstrap operation NodeImageIdentityRefused report
 where
  report intent@(NodeImageIntent _ _ _ _ _ (Just (identifier, socket))) _ =
    pure (NodeImageIdentityObserved intent (DockerDaemonObserved identifier socket))
  report _ _ = pure (NodeImageIdentityRefused NodeImageIntentMatches)

-- | Inspect the local attempt marker using the independently re-read parent
-- image intent. If that intent cannot be validated, attempt state is unknown.
observeRecordedNodeImageAttempt :: BootstrapProjection -> String -> IO NodeImageAttemptObservation
observeRecordedNodeImageAttempt bootstrap operation =
  withRecordedCandidate
    bootstrap
    operation
    (const NodeImageAttemptUnobservable)
    (observeNodeImageAttempt bootstrap)

withRecordedCandidate
  :: BootstrapProjection
  -> String
  -> (NodeImageIntentObservation -> value)
  -> (NodeImageIntent -> IO Bool -> IO value)
  -> IO value
withRecordedCandidate bootstrap operation failureResult useCandidate
  | not (validRootGeneration operation) = pure (failureResult NodeImageIntentUnobservable)
  | otherwise = do
      outcome <- timeout 10000000 $ try (withScopeRootDescriptor (bootstrapScope bootstrap) inspect)
      pure $ case outcome of
        Just (Right (Right result)) -> result
        Just (Left (_ :: IOException)) -> failureResult NodeImageIntentUnobservable
        _ -> failureResult NodeImageIntentUnobservable
 where
  inspect root sameRoot = do
    let stable = do
          rootStable <- sameRoot
          parent <- observeKindIntent bootstrap
          pure (rootStable && parent == KindIntentMatches operation)
    ready <- stable
    if not ready
      then pure (failureResult NodeImageIntentUnobservable)
      else do
        owner <- getEffectiveUserID
        opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
        case opened of
          Left failure | isDoesNotExistError failure -> do
            final <- stable
            pure (failureResult (if final then NodeImageIntentMissing else NodeImageIntentUnobservable))
          Left (_ :: IOException) -> pure (failureResult NodeImageIntentUnobservable)
          Right file -> bracket (pure file) Posix.closeFd (readCandidate root owner stable)
  readCandidate root owner stable held = do
    initial <- Files.getFdStatus held
    if not (safeFile owner initial)
      then pure (failureResult NodeImageIntentUnobservable)
      else do
        bytes <- readBounded held
        checked <- decodeBoundedYamlValue bytes
        final <- Files.getFdStatus held
        named <-
          bracket
            (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
            Posix.closeFd
            Files.getFdStatus
        ready <- stable
        if not (ready && sameVersion initial final && sameVersion final named)
          then pure (failureResult NodeImageIntentUnobservable)
          else case decodeCandidate bytes checked of
            Nothing -> pure (failureResult NodeImageIntentInvalid)
            Just candidate -> do
              result <- observeNodeImageIntent bootstrap candidate stable
              if result /= NodeImageIntentMatches
                then pure (failureResult result)
                else do
                  value <- useCandidate candidate stable
                  lastStatus <- Files.getFdStatus held
                  lastNamed <-
                    bracket
                      (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- stable
                  pure $
                    if still && sameVersion final lastStatus && sameVersion lastStatus lastNamed
                      then value
                      else failureResult NodeImageIntentUnobservable
  decodeCandidate bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
    (Right value, Right validated)
      | value == validated ->
          either (const Nothing) id (parseEither parseCandidate value)
    _ -> Nothing
  parseCandidate = Aeson.withObject "node image intent" parseCandidateObject
  parseCandidateObject object = do
    recordedOperation <- object .: "operation_id"
    manifest <- object .: "manifest_digest"
    config <- object .: "config_digest"
    staged <- object .: "staged_digest"
    bytes <- object .: "staged_bytes"
    daemon <- object .:? "daemon_observation"
    let base =
          if recordedOperation == operation
            then mkNodeImageIntent operation manifest config staged bytes
            else Nothing
    case daemon of
      Nothing -> pure base
      Just value -> do
        observed <- Aeson.withObject "daemon observation" parseDaemon value
        pure (base >>= (`bindNodeImageIntent` observed))
  parseDaemon object = do
    identifier <- object .: "id"
    device <- object .: "socket_device"
    inode <- object .: "socket_inode"
    owner <- object .: "socket_owner"
    mode <- object .: "socket_mode"
    pure (DockerDaemonObserved identifier (DockerSocketIdentity device inode owner mode))

classify
  :: BS.ByteString -> Either failure Aeson.Value -> BS.ByteString -> NodeImageIntentObservation
classify actual parsed expected = case (Aeson.eitherDecodeStrict' actual, parsed, Aeson.eitherDecodeStrict' expected) of
  (Right value, Right checked, Right wanted)
    | value == checked ->
        if value == wanted then NodeImageIntentMatches else NodeImageIntentConflict
  _ -> NodeImageIntentInvalid

preconditions :: BootstrapProjection -> NodeImageIntent -> IO Bool -> IO Bool -> IO Bool
preconditions bootstrap (NodeImageIntent operation _ _ _ _ _) stable sameRoot = do
  first <- stable
  root <- sameRoot
  generation <-
    observeScopeGeneration (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
  observed <- observeKindIntent bootstrap
  lastCheck <- stable
  pure
    ( first
        && root
        && generation == Right ScopeGenerationMatches
        && observed == KindIntentMatches operation
        && lastCheck
        && bootstrapNodeArtifact bootstrap /= Nothing
    )

intentBytes :: BootstrapProjection -> NodeImageIntent -> Files.FileStatus -> BS.ByteString
intentBytes bootstrap (NodeImageIntent operation manifest config staged bytes daemon) root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object $
        [ "schema_version" Aeson..= (maybe (1 :: Int) (const 2) daemon)
        , "operation_id" Aeson..= operation
        , "operation" Aeson..= ("node-image-load" :: String)
        , "cluster" Aeson..= scopeKindName (bootstrapScope bootstrap)
        , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
        , "root_device" Aeson..= toInteger (Files.deviceID root)
        , "root_inode" Aeson..= toInteger (Files.fileID root)
        , "runtime_socket" Aeson..= bootstrapRuntimeSocket bootstrap
        , "selected_image" Aeson..= kindPlanNodeImage (bootstrapKindPlan bootstrap)
        , "source_artifact" Aeson..= fmap artifact (bootstrapNodeArtifact bootstrap)
        , "manifest_digest" Aeson..= manifest
        , "config_digest" Aeson..= config
        , "staged_digest" Aeson..= staged
        , "staged_bytes" Aeson..= bytes
        ]
          ++ maybe [] (\entry -> ["daemon_observation" Aeson..= daemonValue entry]) daemon
 where
  daemonValue (identifier, DockerSocketIdentity device inode owner mode) =
    Aeson.object
      [ "id" Aeson..= identifier
      , "socket_device" Aeson..= device
      , "socket_inode" Aeson..= inode
      , "socket_owner" Aeson..= owner
      , "socket_mode" Aeson..= mode
      ]
  artifact item =
    Aeson.object
      [ "path" Aeson..= artifactPath item
      , "digest" Aeson..= artifactDigest item
      , "maximum_bytes" Aeson..= artifactMaximumBytes item
      ]

recordName :: FilePath
recordName = "node-image-intent.json"
attemptName :: FilePath
attemptName = "node-image-attempt.json"
resultName :: FilePath
resultName = "node-image-result.json"
readFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
createFlags :: Posix.OpenFileFlags
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

safeFile :: UserID -> Files.FileStatus -> Bool
safeFile owner status =
  Files.isRegularFile status
    && Files.fileOwner status == owner
    && Files.fileMode status .&. 0o077 == 0
    && Files.linkCount status == 1
    && Files.fileSize status >= 0
    && Files.fileSize status <= 8192
sameVersion :: Files.FileStatus -> Files.FileStatus -> Bool
sameVersion a b =
  Files.deviceID a == Files.deviceID b
    && Files.fileID a == Files.fileID b
    && Files.fileSize a == Files.fileSize b
    && Files.fileMode a == Files.fileMode b
    && Files.fileOwner a == Files.fileOwner b
    && Files.linkCount a == Files.linkCount b
    && Files.modificationTimeHiRes a == Files.modificationTimeHiRes b
    && Files.statusChangeTimeHiRes a == Files.statusChangeTimeHiRes b

readBounded :: Fd -> IO BS.ByteString
readBounded fd = go [] 0
 where
  go chunks count = do
    result <- try (PosixBytes.fdRead fd (fromIntegral (8193 - count)))
    case result of
      Left failure | isEOFError failure -> pure (BS.concat (reverse chunks))
      Left failure -> throwIO failure
      Right bytes | BS.null bytes -> pure (BS.concat (reverse chunks))
      Right bytes | count + BS.length bytes > 8192 -> pure (BS.concat (reverse (bytes : chunks)))
      Right bytes -> go (bytes : chunks) (count + BS.length bytes)
writeAll :: Fd -> BS.ByteString -> IO ()
writeAll fd bytes = unless (BS.null bytes) $ do
  count <- PosixBytes.fdWrite fd bytes
  if count <= 0
    then ioError (userError "short node image intent write")
    else writeAll fd (BS.drop (fromIntegral count) bytes)
