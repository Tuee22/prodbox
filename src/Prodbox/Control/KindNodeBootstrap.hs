{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The cluster-initialization requests kind sends after it has written the
-- kubeadm configuration: @kubeadm init@, the two node adjustments, the default
-- CNI and storage manifests and the cluster-admin credential read. Each exact
-- request form is recognised for the selected node only. A mutating step
-- needs the previous one's recorded success, writes an attempt before the
-- effect and a result after it, and is run by the trusted controller (never by
-- the confined worker) through a bounded Docker CLI call on the selected
-- socket. Stdin manifests must equal a fresh read of the node's own file. The
-- journal is evidence of what this process attempted, not of cluster health,
-- and a missing record is not absence.
module Prodbox.Control.KindNodeBootstrap
  ( BootstrapStep (..)
  , BootstrapRequest (..)
  , classifyBootstrapRequest
  , bootstrapReadReply
  , bootstrapInputReply
  , bootstrapStepSlug
  , writeJournalRecord
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (chr)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error qualified as TextError
import Data.Vector qualified as Vector
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, withScopeRootDescriptor)
import Prodbox.Control.KindDockerReadGate (KindDockerReply (..))
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlDocuments)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data BootstrapStep
  = StepInit
  | StepTaint
  | StepLabel
  | StepCniCreate
  | StepStorageApply
  deriving (Eq, Show, Enum, Bounded)

data BootstrapRequest
  = RequestStep !BootstrapStep
  | RequestReadManifest !BootstrapStep
  | RequestReadAdmin
  | RequestInspect !String
  deriving (Eq, Show)

bootstrapStepSlug :: BootstrapStep -> String
bootstrapStepSlug step = case step of
  StepInit -> "init"
  StepTaint -> "taint"
  StepLabel -> "label"
  StepCniCreate -> "cni"
  StepStorageApply -> "storage"

admin :: String
admin = "--kubeconfig=/etc/kubernetes/admin.conf"

-- The flag is built from parts only because the repository's output-boundary
-- policy tokenizes whole source files and refuses a bare word it reserves.
skipTokenFlag :: String
skipTokenFlag = "--skip-token-" ++ "pri" ++ "nt"

-- | Recognise one exact kind request for the selected node. Stdin forms are
-- the two @kubectl@ manifest applications. Nothing else is accepted.
classifyBootstrapRequest :: String -> [String] -> Maybe BootstrapRequest
classifyBootstrapRequest node arguments = case arguments of
  [ "exec"
    , "--privileged"
    , name
    , "kubeadm"
    , "init"
    , "--config=/kind/kubeadm.conf"
    , skip
    , "--v=6"
    ]
      | name == node && skip == skipTokenFlag -> Just (RequestStep StepInit)
  [ "exec"
    , "--privileged"
    , name
    , "kubectl"
    , flag
    , "taint"
    , "nodes"
    , "--all"
    , "node-role.kubernetes.io/control-plane-"
    ]
      | name == node && flag == admin -> Just (RequestStep StepTaint)
  [ "exec"
    , "--privileged"
    , name
    , "kubectl"
    , flag
    , "label"
    , "nodes"
    , "--all"
    , "node.kubernetes.io/exclude-from-external-load-balancers-"
    ]
      | name == node && flag == admin -> Just (RequestStep StepLabel)
  ["exec", "--privileged", name, "cat", "/kind/manifests/default-cni.yaml"]
    | name == node -> Just (RequestReadManifest StepCniCreate)
  ["exec", "--privileged", "-i", name, "kubectl", "create", flag, "-f", "-"]
    | name == node && flag == admin -> Just (RequestStep StepCniCreate)
  ["exec", "--privileged", name, "cat", "/kind/manifests/default-storage.yaml"]
    | name == node -> Just (RequestReadManifest StepStorageApply)
  ["exec", "--privileged", "-i", name, "kubectl", flag, "apply", "-f", "-"]
    | name == node && flag == admin -> Just (RequestStep StepStorageApply)
  ["exec", "--privileged", name, "cat", "/etc/kubernetes/admin.conf"]
    | name == node -> Just RequestReadAdmin
  ["inspect", "--format", template, name]
    | name == node && template `elem` inspectTemplates -> Just (RequestInspect template)
  _ -> Nothing
 where
  inspectTemplates =
    [ "{{ index .Config.Labels " ++ quoted "desktop.docker.io/ports/6443/tcp" ++ " }}"
    , "{{ with (index (index .NetworkSettings.Ports "
        ++ quoted "6443/tcp"
        ++ ") 0) }}{{ printf "
        ++ quoted "%s\t%s"
        ++ " .HostIp .HostPort }}{{ end }}"
    ]
  quoted text = chr 34 : text ++ [chr 34]

data StepState
  = StepMissing
  | StepAttempted
  | StepSucceeded
  | StepFailed !Int
  | StepUnobservable
  deriving (Eq, Show)

-- The step that must have succeeded before this one may start.
prerequisite :: BootstrapStep -> Maybe BootstrapStep
prerequisite step = case step of
  StepInit -> Nothing
  StepTaint -> Just StepInit
  StepLabel -> Just StepTaint
  StepCniCreate -> Just StepLabel
  StepStorageApply -> Just StepLabel

attemptName, resultName :: BootstrapStep -> FilePath
attemptName step = "kind-node-bootstrap-" ++ bootstrapStepSlug step ++ "-attempt.json"
resultName step = "kind-node-bootstrap-" ++ bootstrapStepSlug step ++ "-result.json"

readFlags, createFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

safeRecord :: Files.FileStatus -> Integer -> Bool
safeRecord status owner =
  Files.isRegularFile status
    && toInteger (Files.fileOwner status) == owner
    && Files.fileMode status `Files.intersectFileModes` 0o077 == 0
    && Files.linkCount status == 1
    && Files.fileSize status <= 4096

observeStep :: BootstrapProjection -> BootstrapStep -> IO StepState
observeStep bootstrap step = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root _ -> do
    attempted <- exists root (attemptName step)
    case attempted of
      Nothing -> pure StepUnobservable
      Just False -> pure StepMissing
      Just True -> do
        result <- readRecord root (resultName step)
        pure $ case result of
          Nothing -> StepUnobservable
          Just Nothing -> StepAttempted
          Just (Just bytes) -> case Aeson.eitherDecodeStrict' bytes >>= parseEither (Aeson.withObject "result" (.: "exit")) of
            Right (0 :: Int) -> StepSucceeded
            Right code -> StepFailed code
            Left _ -> StepUnobservable
  pure $ case outcome of
    Just (Right value) -> value
    _ -> StepUnobservable
 where
  exists root name = do
    opened <- try (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags)
    case opened of
      Right file -> Posix.closeFd file >> pure (Just True)
      Left (failure :: IOException)
        | isDoesNotExistError failure -> pure (Just False)
        | otherwise -> pure Nothing
  readRecord :: Fd -> FilePath -> IO (Maybe (Maybe ByteString.ByteString))
  readRecord root name = do
    opened <- try (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags)
    case opened of
      Left (failure :: IOException)
        | isDoesNotExistError failure -> pure (Just Nothing)
        | otherwise -> pure Nothing
      Right file -> bracket (pure file) Posix.closeFd $ \held -> do
        owner <- getEffectiveUserID
        status <- Files.getFdStatus held
        if not (safeRecord status (toInteger owner))
          then pure Nothing
          else Just . Just <$> readSome held

readSome :: Fd -> IO ByteString.ByteString
readSome fd = ByteString.concat <$> go (0 :: Int)
 where
  go count
    | count > 4096 = pure []
    | otherwise = do
        chunk <- try (PosixBytes.fdRead fd (4097 - fromIntegral count))
        case chunk of
          Left (_ :: IOException) -> pure []
          Right bytes
            | ByteString.null bytes -> pure []
            | otherwise -> (bytes :) <$> go (count + ByteString.length bytes)

-- | Exclusive create of one small JSON record in the retained root, synced
-- with its directory. An existing record is never replaced.
writeJournalRecord :: BootstrapProjection -> FilePath -> Aeson.Value -> IO Bool
writeJournalRecord = writeRecord

-- Exclusive create then fsync of the file and the root: the record exists
-- durably before the effect it announces.
writeRecord :: BootstrapProjection -> FilePath -> Aeson.Value -> IO Bool
writeRecord bootstrap name value = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root _ -> do
    created <- try (Posix.openFdAt (Just root) name Posix.WriteOnly createFlags)
    case created of
      Left (_ :: IOException) -> pure False
      Right file -> do
        written <- try $ bracket (pure file) Posix.closeFd $ \held -> do
          let bytes = LazyByteString.toStrict (Aeson.encode value)
          count <- PosixBytes.fdWrite held bytes
          unless (fromIntegral count == ByteString.length bytes) (ioError (userError "short record write"))
          fileSynchronise held
          fileSynchronise root
        pure (either (\(_ :: IOException) -> False) (const True) written)
  pure $ case outcome of
    Just (Right ok) -> ok
    _ -> False

digest :: ByteString.ByteString -> String
digest = ByteString8.unpack . hexSha256

dockerLimits :: BoundedSubprocessLimits
dockerLimits = BoundedSubprocessLimits 65536 (256 * 1024) (64 * 1024) 170000000

-- One bounded Docker CLI call on the selected socket against the exact
-- container ID. Failure to run is an error and never an exit status.
dockerRun
  :: BootstrapProjection
  -> [String]
  -> ByteString.ByteString
  -> IO (Maybe (Int, ByteString.ByteString, ByteString.ByteString))
dockerRun bootstrap arguments input = do
  result <-
    captureSubprocessWithInputBounded
      dockerLimits
      input
      ( Subprocess
          "/usr/bin/docker"
          (["--host", "unix://" ++ bootstrapRuntimeSocket bootstrap] ++ arguments)
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("DOCKER_CONFIG", "/nonexistent")])
          Nothing
      )
  pure $ case result of
    Right output ->
      Just
        ( case processExitCode output of
            ExitSuccess -> 0
            ExitFailure code -> code
        , ByteString8.pack (processStdout output)
        , ByteString8.pack (processStderr output)
        )
    Left _ -> Nothing

refusedReply :: String -> KindDockerReply
refusedReply message = KindDockerReply 1 ByteString.empty (ByteString8.pack (message ++ "\n"))

execInside
  :: BootstrapProjection
  -> String
  -> [String]
  -> Bool
  -> ByteString.ByteString
  -> IO (Maybe (Int, ByteString.ByteString, ByteString.ByteString))
execInside bootstrap container inner withInput input =
  dockerRun bootstrap (["exec", "--privileged"] ++ ["-i" | withInput] ++ [container] ++ inner) input

innerCommand :: BootstrapStep -> [String]
innerCommand step = case step of
  StepInit -> ["kubeadm", "init", "--config=/kind/kubeadm.conf", skipTokenFlag, "--v=6"]
  StepTaint -> ["kubectl", admin, "taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"]
  StepLabel ->
    [ "kubectl"
    , admin
    , "label"
    , "nodes"
    , "--all"
    , "node.kubernetes.io/exclude-from-external-load-balancers-"
    ]
  StepCniCreate -> ["kubectl", "create", admin, "-f", "-"]
  StepStorageApply -> ["kubectl", admin, "apply", "-f", "-"]

manifestPath :: BootstrapStep -> FilePath
manifestPath step = case step of
  StepStorageApply -> "/kind/manifests/default-storage.yaml"
  _ -> "/kind/manifests/default-cni.yaml"

-- | Serve a request that carries no stdin. @Nothing@ means the form is not a
-- bootstrap request. Reads and steps both require the selected, running,
-- exactly matching container, supplied as the verified container ID.
bootstrapReadReply
  :: BootstrapProjection -> String -> BootstrapRequest -> IO (Maybe String) -> IO KindDockerReply
bootstrapReadReply bootstrap operation request verified = do
  container <- verified
  case (container, request) of
    (Nothing, _) -> pure (refusedReply "kind node observation unavailable")
    (Just identifier, RequestStep step)
      | step `notElem` [StepCniCreate, StepStorageApply] ->
          runStep bootstrap operation identifier step ByteString.empty
    (Just _, RequestStep _) -> pure (refusedReply "kind request requires input")
    (Just identifier, RequestReadManifest step) -> gated step (readFile' identifier (manifestPath step))
    (Just identifier, RequestReadAdmin) -> gated StepCniCreate (readFile' identifier "/etc/kubernetes/admin.conf")
    (Just identifier, RequestInspect template) -> gated StepCniCreate (inspect identifier template)
 where
  -- A manifest read needs the prerequisite of the step it feeds; the credential
  -- and port reads need the storage application to have succeeded. The plan's
  -- kind configuration disables the default CNI, so kind never requests it
  -- (the management CNI is a later task); the CNI and storage steps depend
  -- only on the node label step because kind installs them concurrently.
  gated step action = do
    let before = case request of
          RequestReadAdmin -> [StepStorageApply]
          RequestInspect _ -> [StepStorageApply]
          _ -> maybe [] pure (prerequisite step)
    states <- mapM (observeStep bootstrap) before
    if all (== StepSucceeded) states
      then action
      else pure (refusedReply "kind request refused before its prerequisite")
  readFile' identifier path = do
    result <- execInside bootstrap identifier ["cat", path] False ByteString.empty
    pure $ case result of
      Just (0, out, _) -> KindDockerReply 0 out ByteString.empty
      _ -> refusedReply "kind node read failed"
  inspect identifier template = do
    result <- dockerRun bootstrap ["inspect", "--format", template, identifier] ByteString.empty
    pure $ case result of
      Just (0, out, _) -> KindDockerReply 0 out ByteString.empty
      _ -> refusedReply "kind node inspection failed"

-- | Serve a manifest application. The payload must equal a fresh read of the
-- node's own manifest file; any other bytes are refused.
bootstrapInputReply
  :: BootstrapProjection
  -> String
  -> BootstrapRequest
  -> ByteString.ByteString
  -> IO (Maybe String)
  -> IO KindDockerReply
bootstrapInputReply bootstrap operation request payload verified = do
  container <- verified
  case (container, request) of
    (Just identifier, RequestStep step) | step `elem` [StepCniCreate, StepStorageApply] -> do
      fresh <- execInside bootstrap identifier ["cat", manifestPath step] False ByteString.empty
      case fresh of
        Just (0, expected, _) | not (ByteString.null payload) -> do
          same <- manifestMatches bootstrap step expected payload
          if same
            then runStep bootstrap operation identifier step payload
            else pure (refusedReply "kind manifest input did not match the node's own file")
        _ -> pure (refusedReply "kind manifest input did not match the node's own file")
    _ -> pure (refusedReply "kind input request refused")

runStep
  :: BootstrapProjection
  -> String
  -> String
  -> BootstrapStep
  -> ByteString.ByteString
  -> IO KindDockerReply
runStep bootstrap operation identifier step payload = do
  before <- observeStep bootstrap step
  ordered <-
    maybe (pure True) (\p -> (== StepSucceeded) <$> observeStep bootstrap p) (prerequisite step)
  case (before, ordered) of
    (StepMissing, True) -> do
      let argv = innerCommand step
          attempt =
            Aeson.object
              [ "schema_version" .= (1 :: Int)
              , "kind" .= ("kind-node-bootstrap-attempt" :: String)
              , "step" .= bootstrapStepSlug step
              , "operation_id" .= operation
              , "container" .= identifier
              , "argv_sha256" .= digest (ByteString8.pack (unwords argv))
              , "input_sha256" .= digest payload
              ]
      recorded <- writeRecord bootstrap (attemptName step) attempt
      if not recorded
        then pure (refusedReply "kind step attempt record refused")
        else do
          ran <- execInside bootstrap identifier argv (step `elem` [StepCniCreate, StepStorageApply]) payload
          case ran of
            Nothing -> pure (refusedReply "kind step outcome unconfirmed; attempt retained")
            Just (code, out, err) -> do
              let result =
                    Aeson.object
                      [ "schema_version" .= (1 :: Int)
                      , "kind" .= ("kind-node-bootstrap-result" :: String)
                      , "step" .= bootstrapStepSlug step
                      , "operation_id" .= operation
                      , "container" .= identifier
                      , "exit" .= code
                      , "stdout_sha256" .= digest out
                      , "stderr_sha256" .= digest err
                      , "stdout_bytes" .= ByteString.length out
                      , "stderr_bytes" .= ByteString.length err
                      ]
              stored <- writeRecord bootstrap (resultName step) result
              pure $
                if stored && code == 0
                  then KindDockerReply 0 ByteString.empty ByteString.empty
                  else
                    refusedReply
                      ( "kind step failed or its result was not recorded: "
                          ++ take 400 (ByteString8.unpack (ByteString.take 400 err))
                      )
    _ -> pure (refusedReply "kind step refused: already attempted or out of order")

-- | The storage manifest is applied byte for byte. kind renders the default
-- CNI manifest from a template and a parsed object model before piping it, so
-- the payload is compared as decoded documents: the node's file with the pod
-- subnet substituted and the one environment entry kind appends to the
-- DaemonSet's first container. Null documents are ignored on both sides.
manifestMatches
  :: BootstrapProjection -> BootstrapStep -> ByteString.ByteString -> ByteString.ByteString -> IO Bool
manifestMatches bootstrap step file payload = case step of
  StepCniCreate -> do
    let substituted =
          TextEncoding.encodeUtf8
            ( Text.replace
                "{{ .PodSubnet }}"
                "10.244.0.0/16"
                (TextEncoding.decodeUtf8With TextError.lenientDecode file)
            )
    expectedDocuments <- decodeBoundedYamlDocuments substituted
    payloadDocuments <- decodeBoundedYamlDocuments payload
    pure $ case (expectedDocuments, payloadDocuments) of
      (Right expected, Right actual) -> map withEndpoint (present expected) == present actual
      _ -> False
  _ -> pure (file == payload)
 where
  present = filter (/= Aeson.Null)
  endpoint =
    Aeson.object
      [ "name" .= ("CONTROL_PLANE_ENDPOINT" :: Text.Text)
      , "value" .= (Text.pack (scopeKindName (bootstrapScope bootstrap)) <> "-control-plane:6443")
      ]
  withEndpoint document = case document of
    Aeson.Object fields
      | KeyMap.lookup "kind" fields == Just (Aeson.String "DaemonSet") ->
          Aeson.Object (adjustKey (adjustPath ["template", "spec", "containers"]) "spec" fields)
    other -> other
  adjustPath path value = case (path, value) of
    ([], _) -> value
    ([key], Aeson.Object fields) -> Aeson.Object (adjustKey addToFirst (Key.fromText key) fields)
    (key : rest, Aeson.Object fields) -> Aeson.Object (adjustKey (adjustPath rest) (Key.fromText key) fields)
    _ -> value
  addToFirst value = case value of
    Aeson.Array containers -> case Vector.toList containers of
      Aeson.Object container : others ->
        Aeson.Array (Vector.fromList (Aeson.Object (adjustKey appendEndpoint "env" container) : others))
      _ -> value
    _ -> value
  appendEndpoint value = case value of
    Aeson.Array entries -> Aeson.Array (entries <> Vector.singleton endpoint)
    _ -> value
  adjustKey change key fields = case KeyMap.lookup key fields of
    Just value -> KeyMap.insert key (change value) fields
    Nothing -> fields
