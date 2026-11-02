{-# LANGUAGE OverloadedStrings #-}

-- | Rebind only a positively unlinked, uninitialized home Vault mount. The
-- retained directory and its contents are never mutation targets.
module Prodbox.Infra.VaultRetainedMount
  ( VaultMountBinding
  , KernelBootIdentity
  , DirectoryIdentity
  , VaultPodRetirement
  , VaultMountDecision (..)
  , VaultMountCause (..)
  , VaultMountStage (..)
  , VaultMountError (..)
  , VaultMountEffects (..)
  , observeVaultMountBinding
  , parseKernelBootIdentity
  , parseDirectoryIdentity
  , decideVaultMount
  , vaultPodRetirementOptions
  , reconcileHomeVaultMount
  , reconcileHomeVaultMountWith
  , renderVaultMountError
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (filterM, unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Types (Object, Parser, parseEither, withObject, (.!=), (.:), (.:?))
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (readHex)
import Prodbox.ControlPlane.Deadline
import Prodbox.Error (AppError)
import Prodbox.Lib.Storage
  ( retainedStatefulSetPersistentVolumeClaimName
  , retainedStatefulSetPersistentVolumeName
  )
import Prodbox.Subprocess
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute)
import Text.Read (readMaybe)

data VaultMountBinding = VaultMountBinding
  { bindingControllerUid :: !Text
  , bindingGeneration :: !Integer
  , bindingRevision :: !Text
  , bindingImage :: !Text
  , bindingPodUid :: !Text
  , bindingPodVersion :: !Text
  , bindingNode :: !Text
  , bindingNodeUid :: !Text
  , bindingKernel :: !KernelBootIdentity
  , bindingClaimUid :: !Text
  , bindingVolumeUid :: !Text
  , bindingHostPath :: !FilePath
  }
  deriving (Eq, Show)

data DirectoryIdentity = DirectoryIdentity !Integer !Integer !Integer
  deriving (Eq, Show)

newtype KernelBootIdentity = KernelBootIdentity Text
  deriving (Eq, Show)

parseKernelBootIdentity :: ByteString -> Either VaultMountCause KernelBootIdentity
parseKernelBootIdentity bytes = do
  value <- either (const (Left InvalidVaultBinding)) Right (TextEncoding.decodeUtf8' bytes)
  let normalized = Text.toLower (Text.strip value)
      parts = Text.splitOn "-" normalized
      hexadecimal c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
  if map Text.length parts == [8, 4, 4, 4, 12] && Text.all hexadecimal (Text.concat parts)
    then Right (KernelBootIdentity normalized)
    else Left InvalidVaultBinding

data VaultPodRetirement = VaultPodRetirement !Text !Text
  deriving (Eq, Show)

data VaultMountDecision
  = VaultRootAlreadyBound
  | RetireUnlinkedVaultPod !VaultPodRetirement
  deriving (Eq, Show)

data VaultMountCause
  = InvalidVaultBinding
  | InvalidDirectoryObservation
  | DeclaredRootUnlinked
  | LinkedRootIdentityMismatch
  | VaultInitializationUnobservable
  | InitializedVaultHasUnlinkedRoot
  | VaultBindingChanged
  | VaultRootChanged
  deriving (Eq, Show)

data VaultMountStage
  = AwaitVaultRollout
  | ObserveVaultBinding
  | ObserveDeclaredRoot
  | ObserveMountedRoot
  | ObserveVaultInitialization
  | RetireVaultPod
  | AwaitFreshVaultPod
  deriving (Eq, Show)

data VaultMountError
  = VaultMountRefused !VaultMountCause
  | VaultMountDeadlineExpired !VaultMountStage
  | VaultMountTransportFailed !VaultMountStage
  | VaultMountCommandFailed !VaultMountStage !Int
  deriving (Eq, Show)

data VaultMountEffects = VaultMountEffects
  { captureVaultMountSubprocess
      :: BoundedSubprocessLimits -> ByteString -> Subprocess -> IO (Either AppError ProcessOutput)
  , vaultMountMonotonicNow :: IO MonotonicInstant
  , pauseVaultMountMicros :: Int -> IO ()
  }

vaultClaimName :: Text
vaultClaimName = Text.pack (retainedStatefulSetPersistentVolumeClaimName "vault" 0)

vaultVolumeName :: Text
vaultVolumeName = Text.pack (retainedStatefulSetPersistentVolumeName "vault" "vault" 0)

observeVaultMountBinding
  :: FilePath
  -> KernelBootIdentity
  -> Value
  -> Value
  -> Value
  -> Value
  -> Value
  -> Either VaultMountCause VaultMountBinding
observeVaultMountBinding hostPath kernel controller pod claim volume nodeValue =
  either (const (Left InvalidVaultBinding)) Right $ parseEither parse controller
 where
  parse = withObject "Vault StatefulSet" $ \root -> do
    unless (isAbsolute hostPath && '\0' `notElem` hostPath) (fail "invalid declared root")
    controllerUid <- exactMetadata "apps/v1" "StatefulSet" "vault" (Just "vault") root
    metadata <- root .: "metadata"
    generation <- metadata .: "generation"
    spec <- root .: "spec"
    replicas <- spec .: "replicas"
    policy <- spec .:? "podManagementPolicy" .!= ("OrderedReady" :: Text)
    strategy <- spec .: "updateStrategy"
    strategyType <- strategy .: "type"
    rolling <- strategy .:? "rollingUpdate" .!= mempty
    partition <- rolling .:? "partition" .!= (0 :: Integer)
    unless
      ( generation > 0
          && replicas == (1 :: Integer)
          && policy == "OrderedReady"
          && strategyType == ("RollingUpdate" :: Text)
          && partition == 0
      )
      (fail "unsupported Vault controller")
    template <- spec .: "template"
    templateSpec <- template .: "spec"
    container <- soleVaultContainer templateSpec
    image <- container .: "image" >>= nonempty
    status <- root .: "status"
    observed <- status .: "observedGeneration"
    revision <- status .: "updateRevision" >>= nonempty
    current <- status .: "currentRevision"
    unless (observed == generation && current == revision) (fail "Vault revision is not current")
    (podUid, podVersion, node) <- parsePod controllerUid revision image pod
    nodeUid <- parseNode kernel node nodeValue
    claimUid <- parseClaim claim
    volumeUid <- parseVolume hostPath claimUid node volume
    pure
      ( VaultMountBinding
          controllerUid
          generation
          revision
          image
          podUid
          podVersion
          node
          nodeUid
          kernel
          claimUid
          volumeUid
          hostPath
      )

parseNode :: KernelBootIdentity -> Text -> Value -> Parser Text
parseNode expected name = withObject "local Vault node" $ \root -> do
  uid <- exactMetadata "v1" "Node" name Nothing root
  status <- root .: "status"
  info <- status .: "nodeInfo"
  boot <- info .: "bootID"
  observed <-
    either
      (const (fail "node kernel boot identity is unavailable"))
      pure
      (parseKernelBootIdentity (TextEncoding.encodeUtf8 boot))
  unless (observed == expected) (fail "Vault node does not share the operator kernel")
  pure uid

exactMetadata :: Text -> Text -> Text -> Maybe Text -> Object -> Parser Text
exactMetadata api kind name namespace root = do
  actualApi <- root .: "apiVersion"
  actualKind <- root .: "kind"
  metadata <- root .: "metadata"
  actualName <- metadata .: "name"
  actualNamespace <- metadata .:? "namespace"
  deleting <- metadata .:? "deletionTimestamp"
  unless
    ( actualApi == api
        && actualKind == kind
        && actualName == name
        && actualNamespace == namespace
        && deleting == (Nothing :: Maybe Text)
    )
    (fail "unexpected Vault resource identity")
  metadata .: "uid" >>= nonempty

nonempty :: Text -> Parser Text
nonempty value
  | Text.null (Text.strip value) = fail "empty resource identity"
  | otherwise = pure value

soleVaultContainer :: Object -> Parser Object
soleVaultContainer spec = do
  containers <- spec .: "containers"
  case containers of
    [container] -> do
      name <- container .: "name"
      unless (name == ("vault" :: Text)) (fail "unexpected Vault container")
      pure container
    _ -> fail "Vault must have one registered container"

parsePod :: Text -> Text -> Text -> Value -> Parser (Text, Text, Text)
parsePod controllerUid revision image = withObject "Vault Pod" $ \root -> do
  uid <- exactMetadata "v1" "Pod" "vault-0" (Just "vault") root
  metadata <- root .: "metadata"
  version <- metadata .: "resourceVersion" >>= nonempty
  labels <- metadata .: "labels"
  actualRevision <- labels .: "controller-revision-hash"
  owners <- metadata .: "ownerReferences"
  controllers <- filterM (\owner -> owner .:? "controller" .!= False) owners
  case controllers of
    [owner] -> do
      ownerApi <- owner .: "apiVersion"
      ownerKind <- owner .: "kind"
      ownerName <- owner .: "name"
      ownerUid <- owner .: "uid"
      unless
        ( ownerApi == ("apps/v1" :: Text)
            && ownerKind == ("StatefulSet" :: Text)
            && ownerName == ("vault" :: Text)
            && ownerUid == controllerUid
        )
        (fail "unexpected Vault Pod owner")
    _ -> fail "Vault must have one controller owner"
  spec <- root .: "spec"
  node <- spec .: "nodeName" >>= nonempty
  container <- soleVaultContainer spec
  actualImage <- container .: "image"
  mounts <- container .: "volumeMounts"
  mount <- namedDataObject mounts
  mountPath <- mount .: "mountPath"
  readOnly <- mount .:? "readOnly" .!= False
  subPath <- mount .:? "subPath"
  subPathExpr <- mount .:? "subPathExpr"
  volumes <- spec .: "volumes"
  volume <- namedDataObject volumes
  pvc <- volume .: "persistentVolumeClaim"
  claimName <- pvc .: "claimName"
  claimReadOnly <- pvc .:? "readOnly" .!= False
  status <- root .: "status"
  phase <- status .: "phase"
  conditions <- status .: "conditions"
  ready <- filterM (\condition -> (== ("Ready" :: Text)) <$> condition .: "type") conditions
  readiness <- case ready of
    [condition] -> condition .: "status"
    _ -> fail "Vault readiness is not observed"
  unless
    ( actualRevision == revision
        && actualImage == image
        && mountPath == ("/vault/data" :: Text)
        && not readOnly
        && subPath == (Nothing :: Maybe Text)
        && subPathExpr == (Nothing :: Maybe Text)
        && claimName == vaultClaimName
        && not claimReadOnly
        && phase == ("Running" :: Text)
        && readiness == ("True" :: Text)
    )
    (fail "Vault Pod does not match its declared storage and revision")
  pure (uid, version, node)

namedDataObject :: [Object] -> Parser Object
namedDataObject objects = do
  selected <- filterM (\value -> (== ("data" :: Text)) <$> value .: "name") objects
  case selected of
    [value] -> pure value
    _ -> fail "Vault must have one data binding"

parseClaim :: Value -> Parser Text
parseClaim = withObject "Vault claim" $ \root -> do
  uid <- exactMetadata "v1" "PersistentVolumeClaim" vaultClaimName (Just "vault") root
  spec <- root .: "spec"
  volumeName <- spec .: "volumeName"
  storageClass <- spec .: "storageClassName"
  mode <- spec .: "volumeMode"
  access <- spec .: "accessModes"
  status <- root .: "status"
  phase <- status .: "phase"
  unless
    ( volumeName == vaultVolumeName
        && storageClass == ("manual" :: Text)
        && mode == ("Filesystem" :: Text)
        && access == (["ReadWriteOnce"] :: [Text])
        && phase == ("Bound" :: Text)
    )
    (fail "Vault claim is not exactly bound")
  pure uid

parseVolume :: FilePath -> Text -> Text -> Value -> Parser Text
parseVolume hostPath claimUid node = withObject "Vault volume" $ \root -> do
  uid <- exactMetadata "v1" "PersistentVolume" vaultVolumeName Nothing root
  spec <- root .: "spec"
  storageClass <- spec .: "storageClassName"
  retention <- spec .: "persistentVolumeReclaimPolicy"
  host <- spec .: "hostPath"
  path <- host .: "path"
  hostType <- host .: "type"
  ref <- spec .: "claimRef"
  refName <- ref .: "name"
  refNamespace <- ref .: "namespace"
  refUid <- ref .: "uid"
  refApi <- ref .: "apiVersion"
  refKind <- ref .: "kind"
  affinity <- spec .: "nodeAffinity"
  required <- affinity .: "required"
  terms <- required .: "nodeSelectorTerms"
  observedNode <- case terms of
    [term] -> do
      expressions <- term .: "matchExpressions"
      case expressions of
        [expression] -> do
          key <- expression .: "key"
          operator <- expression .: "operator"
          unless
            (key == ("kubernetes.io/hostname" :: Text) && operator == ("In" :: Text))
            (fail "unexpected Vault node affinity")
          expression .: "values"
        _ -> fail "Vault node affinity is not exact"
    _ -> fail "Vault node affinity is not exact"
  status <- root .: "status"
  phase <- status .: "phase"
  unless
    ( storageClass == ("manual" :: Text)
        && retention == ("Retain" :: Text)
        && path == hostPath
        && hostType == ("DirectoryOrCreate" :: Text)
        && refName == vaultClaimName
        && refNamespace == ("vault" :: Text)
        && refUid == claimUid
        && refApi == ("v1" :: Text)
        && refKind == ("PersistentVolumeClaim" :: Text)
        && observedNode == [node]
        && phase == ("Bound" :: Text)
    )
    (fail "Vault retained volume is not exactly bound")
  pure uid

parseDirectoryIdentity :: ByteString -> Either VaultMountCause DirectoryIdentity
parseDirectoryIdentity bytes = case Text.splitOn ":" (Text.strip (TextEncoding.decodeUtf8With (\_ _ -> Just '\xfffd') bytes)) of
  [deviceText, inodeText, linksText, modeText] ->
    case (decimal deviceText, decimal inodeText, decimal linksText, hexadecimal modeText) of
      (Just device, Just inode, Just links, Just mode)
        | device >= 0 && inode > 0 && links >= 0 && mode .&. 0xf000 == 0x4000 ->
            Right (DirectoryIdentity device inode links)
      _ -> Left InvalidDirectoryObservation
  _ -> Left InvalidDirectoryObservation
 where
  decimal value
    | Text.null value
        || Text.length value > 20
        || not (Text.all (\c -> c >= '0' && c <= '9') value) =
        Nothing
    | otherwise = do
        number <- readMaybe (Text.unpack value)
        if number <= 18446744073709551615 then Just number else Nothing
  hexadecimal value
    | Text.null value || Text.length value > 8 = Nothing
    | otherwise = case readHex (Text.unpack value) of
        [(mode, "")] -> Just (mode :: Integer)
        _ -> Nothing

decideVaultMount
  :: VaultMountBinding
  -> DirectoryIdentity
  -> DirectoryIdentity
  -> Maybe Bool
  -> Either VaultMountCause VaultMountDecision
decideVaultMount binding host@(DirectoryIdentity _ _ hostLinks) mounted@(DirectoryIdentity _ _ mountedLinks) initialized
  | hostLinks == 0 = Left DeclaredRootUnlinked
  | mountedLinks > 0 =
      if sameDirectory host mounted then Right VaultRootAlreadyBound else Left LinkedRootIdentityMismatch
  | otherwise = case initialized of
      Nothing -> Left VaultInitializationUnobservable
      Just True -> Left InitializedVaultHasUnlinkedRoot
      Just False ->
        Right
          (RetireUnlinkedVaultPod (VaultPodRetirement (bindingPodUid binding) (bindingPodVersion binding)))

sameDirectory :: DirectoryIdentity -> DirectoryIdentity -> Bool
sameDirectory (DirectoryIdentity device inode _) (DirectoryIdentity otherDevice otherInode _) =
  device == otherDevice && inode == otherInode

vaultPodRetirementOptions :: VaultPodRetirement -> Value
vaultPodRetirementOptions (VaultPodRetirement uid version) =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "preconditions" .= object ["uid" .= uid, "resourceVersion" .= version]
    ]

reconcileHomeVaultMount :: FilePath -> FilePath -> IO (Either VaultMountError ())
reconcileHomeVaultMount =
  reconcileHomeVaultMountWith
    (VaultMountEffects captureSubprocessWithInputBounded monotonicNow threadDelay)

reconcileHomeVaultMountWith
  :: VaultMountEffects -> FilePath -> FilePath -> IO (Either VaultMountError ())
reconcileHomeVaultMountWith effects repoRoot hostPath = do
  start <- vaultMountMonotonicNow effects
  runExceptT (reconcile (deadlineAtOffset start (RemainingDuration 300000000)))
 where
  reconcile deadline = do
    rollout deadline
    original <- observeBinding deadline
    host <- directory deadline ObserveDeclaredRoot "sudo" ["stat", "-c", "%d:%i:%h:%f", "--", hostPath]
    mounted <- mountedRoot deadline
    decision <- decide deadline original host mounted
    case decision of
      VaultRootAlreadyBound -> pure ()
      RetireUnlinkedVaultPod retirement -> do
        confirmed <- observeBinding deadline
        unless (confirmed == original) (refuse VaultBindingChanged)
        currentHost <-
          directory deadline ObserveDeclaredRoot "sudo" ["stat", "-c", "%d:%i:%h:%f", "--", hostPath]
        currentMount <- mountedRoot deadline
        unless (sameDirectory host currentHost && mounted == currentMount) (refuse VaultRootChanged)
        confirmedDecision <- decide deadline confirmed currentHost currentMount
        unless (confirmedDecision == decision) (refuse VaultRootChanged)
        _ <-
          kubectl
            deadline
            RetireVaultPod
            30000000
            (LazyByteString.toStrict (encode (vaultPodRetirementOptions retirement)))
            ["delete", "--raw=/api/v1/namespaces/vault/pods/vault-0", "--filename=-"]
        awaitFresh deadline original host
    _ <- remaining deadline ObserveMountedRoot
    pure ()

  decide _ binding host@(DirectoryIdentity _ _ 0) mounted =
    admit binding host mounted Nothing
  decide deadline binding host mounted@(DirectoryIdentity _ _ 0) = do
    initialized <- observeInitialized deadline
    admit binding host mounted (Just initialized)
  decide _ binding host mounted = admit binding host mounted Nothing

  admit binding host mounted initialized =
    either (throwE . VaultMountRefused) pure (decideVaultMount binding host mounted initialized)

  observeInitialized deadline = do
    bytes <-
      request
        deadline
        ObserveVaultInitialization
        5000000
        [ExitSuccess, ExitFailure 2]
        ByteString.empty
        "kubectl"
        ["exec", "vault-0", "-n", "vault", "--", "vault", "status", "-format=json"]
    value <- decodeValue ObserveVaultInitialization bytes
    either
      (const (refuse VaultInitializationUnobservable))
      pure
      (parseEither (withObject "Vault status" (.: "initialized")) value)

  observeBinding deadline = do
    controller <- get deadline "statefulset" "vault"
    pod <- get deadline "pod" "vault-0"
    claim <- get deadline "pvc" (Text.unpack vaultClaimName)
    volume <- get deadline "pv" (Text.unpack vaultVolumeName)
    nodeName <-
      either
        (const (refuse InvalidVaultBinding))
        pure
        (parseEither (withObject "Vault Pod" $ \root -> root .: "spec" >>= (.: "nodeName")) pod)
    unless (validNodeName nodeName) (refuse InvalidVaultBinding)
    node <- get deadline "node" (Text.unpack nodeName)
    bootBytes <-
      request
        deadline
        ObserveVaultBinding
        5000000
        [ExitSuccess]
        ByteString.empty
        "cat"
        ["/proc/sys/kernel/random/boot_id"]
    kernel <- either (throwE . VaultMountRefused) pure (parseKernelBootIdentity bootBytes)
    either
      (throwE . VaultMountRefused)
      pure
      (observeVaultMountBinding hostPath kernel controller pod claim volume node)

  validNodeName name =
    not (Text.null name)
      && Text.length name <= 253
      && Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c `elem` ['-', '.']) name
      && not (any (`Text.isPrefixOf` name) ["-", "."])
      && not (any (`Text.isSuffixOf` name) ["-", "."])

  get deadline kind name = do
    bytes <-
      kubectl deadline ObserveVaultBinding 5000000 ByteString.empty ["get", kind, name, "-o", "json"]
    decodeValue ObserveVaultBinding bytes

  mountedRoot deadline =
    directory
      deadline
      ObserveMountedRoot
      "kubectl"
      ["exec", "vault-0", "-n", "vault", "--", "stat", "-c", "%d:%i:%h:%f", "/vault/data"]

  directory deadline stage program arguments = do
    bytes <- request deadline stage 5000000 [ExitSuccess] ByteString.empty program arguments
    either (throwE . VaultMountRefused) pure (parseDirectoryIdentity bytes)

  rollout deadline = do
    budget <- remaining deadline AwaitVaultRollout
    _ <-
      kubectl
        deadline
        AwaitVaultRollout
        budget
        ByteString.empty
        [ "rollout"
        , "status"
        , "statefulset/vault"
        , "--timeout=" ++ show ((budget + 999999) `div` 1000000) ++ "s"
        ]
    pure ()

  awaitFresh deadline original expectedRoot = do
    bytes <-
      kubectl
        deadline
        AwaitFreshVaultPod
        5000000
        ByteString.empty
        ["get", "pod", "vault-0", "--ignore-not-found=true", "-o", "json"]
    fresh <-
      if ByteString.null bytes
        then pure False
        else do
          value <- decodeValue AwaitFreshVaultPod bytes
          (uid, ready) <-
            either
              (const (refuse InvalidVaultBinding))
              pure
              ( parseEither
                  ( withObject "Vault replacement" $ \root -> do
                      api <- root .: "apiVersion"
                      kind <- root .: "kind"
                      metadata <- root .: "metadata"
                      name <- metadata .: "name"
                      namespace <- metadata .: "namespace"
                      deleting <- metadata .:? "deletionTimestamp"
                      unless
                        ( api == ("v1" :: Text)
                            && kind == ("Pod" :: Text)
                            && name == ("vault-0" :: Text)
                            && namespace == ("vault" :: Text)
                        )
                        (fail "unexpected Vault replacement")
                      uid <- metadata .: "uid" >>= nonempty
                      status <- root .: "status"
                      conditions <- status .:? "conditions" .!= []
                      ready <- filterM (\condition -> (== ("Ready" :: Text)) <$> condition .: "type") conditions
                      isReady <- case ready of
                        [condition] -> (== ("True" :: Text)) <$> condition .: "status"
                        _ -> pure False
                      pure (uid, isReady && deleting == (Nothing :: Maybe Text))
                  )
                  value
              )
          pure (uid /= bindingPodUid original && ready)
    if not fresh
      then do
        budget <- remaining deadline AwaitFreshVaultPod
        liftPause (min 250000 budget)
        awaitFresh deadline original expectedRoot
      else do
        closing <- observeBinding deadline
        unless
          ( sameController original closing
              && bindingClaimUid original == bindingClaimUid closing
              && bindingVolumeUid original == bindingVolumeUid closing
              && bindingNodeUid original == bindingNodeUid closing
              && bindingKernel original == bindingKernel closing
              && bindingPodUid closing /= bindingPodUid original
          )
          (refuse VaultBindingChanged)
        host <- directory deadline ObserveDeclaredRoot "sudo" ["stat", "-c", "%d:%i:%h:%f", "--", hostPath]
        mounted <- mountedRoot deadline
        unless (sameDirectory expectedRoot host) (refuse VaultRootChanged)
        result <- either (throwE . VaultMountRefused) pure (decideVaultMount closing host mounted Nothing)
        unless (result == VaultRootAlreadyBound) (refuse VaultRootChanged)

  sameController before after =
    bindingControllerUid before == bindingControllerUid after
      && bindingGeneration before == bindingGeneration after
      && bindingRevision before == bindingRevision after
      && bindingImage before == bindingImage after

  liftPause micros = ExceptT (Right <$> pauseVaultMountMicros effects micros)
  refuse = throwE . VaultMountRefused
  decodeValue stage = either (const (throwE (VaultMountTransportFailed stage))) pure . eitherDecodeStrict'
  kubectl deadline stage ceilingMicros input arguments =
    request deadline stage ceilingMicros [ExitSuccess] input "kubectl" (arguments ++ ["-n", "vault"])

  request deadline stage ceilingMicros accepted input program arguments = do
    budget <- remaining deadline stage
    result <- ExceptT $ do
      attempted <-
        captureVaultMountSubprocess
          effects
          BoundedSubprocessLimits
            { boundedSubprocessTimeoutMicros = min ceilingMicros budget
            , boundedSubprocessMaximumInputBytes = 16384
            , boundedSubprocessMaximumStdoutBytes = 1048576
            , boundedSubprocessMaximumStderrBytes = 16384
            }
          input
          (Subprocess program arguments Nothing (Just repoRoot))
      pure $ case attempted of
        Left _ -> Left (VaultMountTransportFailed stage)
        Right output ->
          if processExitCode output `elem` accepted
            then Right output
            else case processExitCode output of
              ExitSuccess -> Left (VaultMountCommandFailed stage 0)
              ExitFailure code -> Left (VaultMountCommandFailed stage code)
    _ <- remaining deadline stage
    pure (TextEncoding.encodeUtf8 (Text.pack (processStdout result)))

  remaining :: Deadline -> VaultMountStage -> ExceptT VaultMountError IO Int
  remaining deadline stage = ExceptT $ do
    now <- vaultMountMonotonicNow effects
    pure $ case deadlineObservation now deadline of
      DeadlineExpired -> Left (VaultMountDeadlineExpired stage)
      DeadlineOpen (RemainingDuration budget) -> Right (fromIntegral budget)

monotonicNow :: IO MonotonicInstant
monotonicNow = monotonicInstantFromMicros . fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec

renderVaultMountError :: VaultMountError -> String
renderVaultMountError failure = "Home Vault retained-mount reconciliation failed: " ++ show failure ++ remedy
 where
  remedy = case failure of
    VaultMountRefused cause -> case cause of
      InitializedVaultHasUnlinkedRoot ->
        "; NukeOnly: retain the running Vault for operator recovery/decommission; ordinary reconcile cannot discard its process state"
      LinkedRootIdentityMismatch ->
        "; NukeOnly: retain both linked roots for operator recovery/decommission; ordinary reconcile cannot choose between their contents"
      InvalidVaultBinding -> retry
      InvalidDirectoryObservation -> retry
      DeclaredRootUnlinked -> retry
      VaultInitializationUnobservable -> retry
      VaultBindingChanged -> retry
      VaultRootChanged -> retry
    VaultMountDeadlineExpired _ -> retry
    VaultMountTransportFailed _ -> retry
    VaultMountCommandFailed _ _ -> retry
  retry = "; retry prodbox cluster reconcile; retained storage was not reset"
