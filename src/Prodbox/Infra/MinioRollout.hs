{-# LANGUAGE OverloadedStrings #-}

-- | Repair the OrderedReady obsolete-image deadlock without force deletion or
-- touching retained storage. Only the registered home MinIO Pod is selectable.
module Prodbox.Infra.MinioRollout
  ( MinioRolloutDecision (..)
  , MinioPodRetirement
  , MinioRolloutCause (..)
  , MinioRolloutStage (..)
  , MinioRolloutError (..)
  , MinioRolloutEffects (..)
  , decideMinioRollout
  , confirmMinioRollout
  , minioPodRetirementOptions
  , reconcileHomeMinioRollout
  , reconcileHomeMinioRolloutWith
  ) where

import Control.Monad (filterM, unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Types (Object, Parser, parseEither, withObject, (.!=), (.:), (.:?))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.ContainerImage (publicMinioImage, renderImageRef)
import Prodbox.ControlPlane.Deadline
import Prodbox.Error (AppError)
import Prodbox.Minio.ObjectStoreTypes (minioClusterServiceName, minioClusterServiceNamespace)
import Prodbox.Subprocess
import System.Exit (ExitCode (..))

data MinioPodRetirement = MinioPodRetirement Text Text
  deriving (Eq, Show)

data MinioRolloutDecision
  = AwaitMinioRollout
  | RetireObsoleteMinioPod MinioPodRetirement
  deriving (Eq, Show)

data MinioRolloutCause
  = InvalidControllerObservation
  | InvalidPodObservation
  | UnexpectedPodOwner
  | UnobservedPodRevision
  | UnobservedPodReadiness
  | ControllerChangedBeforeRetirement
  | DesiredMinioPodNotReady
  deriving (Eq, Show)

data MinioRolloutStage
  = ObserveMinioController
  | ObserveMinioPod
  | ConfirmMinioController
  | RetireMinioPod
  | AwaitMinioReady
  deriving (Eq, Show)

data MinioRolloutError
  = MinioRolloutRefused MinioRolloutCause
  | MinioRolloutDeadlineExpired MinioRolloutStage
  | MinioRolloutTransportFailed MinioRolloutStage
  | MinioRolloutCommandFailed MinioRolloutStage Int
  deriving (Eq, Show)

newtype MinioRolloutEffects = MinioRolloutEffects
  { captureMinioRolloutSubprocess
      :: BoundedSubprocessLimits -> ByteString -> Subprocess -> IO (Either AppError ProcessOutput)
  }

data Controller = Controller
  { controllerUid :: Text
  , controllerGeneration :: Integer
  , controllerObservedGeneration :: Maybe Integer
  , controllerCurrentRevision :: Maybe Text
  , controllerUpdateRevision :: Maybe Text
  }
  deriving (Eq, Show)

data Pod = Pod
  { podUid :: Text
  , podResourceVersion :: Text
  , podOwnerUid :: Text
  , podRevision :: Text
  , podImage :: Text
  , podReady :: Maybe Bool
  , podTerminating :: Bool
  }

expectedImage :: Text
expectedImage = Text.pack (renderImageRef publicMinioImage)

minioName :: Text
minioName = Text.pack minioClusterServiceName

minioNamespace :: Text
minioNamespace = Text.pack minioClusterServiceNamespace

decideMinioRollout :: Value -> Maybe Value -> Either MinioRolloutCause MinioRolloutDecision
decideMinioRollout controllerValue podValue = do
  controller <- decodeController controllerValue
  case podValue of
    Nothing -> Right AwaitMinioRollout
    Just value -> do
      pod <- either (const (Left InvalidPodObservation)) Right (parseEither parsePod value)
      decideOwnedPod controller pod

decodeController :: Value -> Either MinioRolloutCause Controller
decodeController value =
  either (const (Left InvalidControllerObservation)) Right (parseEither parseController value)

parseController :: Value -> Parser Controller
parseController = withObject "MinIO StatefulSet" $ \value -> do
  apiVersion <- value .: "apiVersion"
  kind <- value .: "kind"
  metadata <- value .: "metadata"
  name <- metadata .: "name"
  namespace <- metadata .: "namespace"
  uid <- metadata .: "uid" >>= nonempty
  generation <- metadata .: "generation"
  unless
    ( apiVersion == ("apps/v1" :: Text)
        && kind == ("StatefulSet" :: Text)
        && name == minioName
        && namespace == minioNamespace
        && generation > 0
    )
    (fail "unexpected MinIO controller identity")
  spec <- value .: "spec"
  replicas <- spec .: "replicas"
  policy <- spec .:? "podManagementPolicy" .!= ("OrderedReady" :: Text)
  strategy <- spec .: "updateStrategy"
  strategyType <- strategy .: "type"
  rolling <- strategy .:? "rollingUpdate"
  partition <- maybe (pure (0 :: Integer)) (\fields -> fields .:? "partition" .!= 0) rolling
  unless
    ( replicas == (1 :: Integer)
        && policy == "OrderedReady"
        && strategyType == ("RollingUpdate" :: Text)
        && partition == 0
    )
    (fail "unsupported MinIO controller shape")
  template <- spec .: "template"
  templateSpec <- template .: "spec"
  image <- singleMinioImage templateSpec
  unless (image == expectedImage) (fail "desired source image is not observed")
  status <- value .:? "status" .!= mempty
  Controller uid generation
    <$> status .:? "observedGeneration"
    <*> status .:? "currentRevision"
    <*> status .:? "updateRevision"

parsePod :: Value -> Parser Pod
parsePod = withObject "MinIO Pod" $ \value -> do
  apiVersion <- value .: "apiVersion"
  kind <- value .: "kind"
  metadata <- value .: "metadata"
  name <- metadata .: "name"
  namespace <- metadata .: "namespace"
  uid <- metadata .: "uid" >>= nonempty
  version <- metadata .: "resourceVersion" >>= nonempty
  labels <- metadata .: "labels"
  revision <- labels .: "controller-revision-hash" >>= nonempty
  unless
    ( apiVersion == ("v1" :: Text)
        && kind == ("Pod" :: Text)
        && name == minioName <> "-0"
        && namespace == minioNamespace
    )
    (fail "unexpected MinIO Pod identity")
  owners <- metadata .: "ownerReferences"
  ownerUid <- soleControllerOwner owners
  terminating <- metadata .:? "deletionTimestamp"
  spec <- value .: "spec"
  image <- singleMinioImage spec
  status <- value .: "status"
  conditions <- status .:? "conditions" .!= []
  ready <- podReadiness conditions
  pure (Pod uid version ownerUid revision image ready (terminating /= (Nothing :: Maybe Text)))

nonempty :: Text -> Parser Text
nonempty value
  | Text.null (Text.strip value) = fail "empty Kubernetes identity"
  | otherwise = pure value

singleMinioImage :: Object -> Parser Text
singleMinioImage spec = do
  containers <- spec .: "containers"
  case containers of
    [container] -> do
      name <- container .: "name"
      unless (name == minioName) (fail "unexpected MinIO container")
      container .: "image" >>= nonempty
    _ -> fail "MinIO must have one registered container"

soleControllerOwner :: [Object] -> Parser Text
soleControllerOwner owners = do
  controllers <- filterM (\owner -> owner .:? "controller" .!= False) owners
  case controllers of
    [owner] -> do
      apiVersion <- owner .: "apiVersion"
      kind <- owner .: "kind"
      name <- owner .: "name"
      unless
        (apiVersion == ("apps/v1" :: Text) && kind == ("StatefulSet" :: Text) && name == minioName)
        (fail "unexpected Pod owner")
      owner .: "uid" >>= nonempty
    _ -> fail "Pod must have one controller owner"

podReadiness :: [Object] -> Parser (Maybe Bool)
podReadiness conditions = do
  ready <- filterM (\condition -> (== ("Ready" :: Text)) <$> condition .: "type") conditions
  case ready of
    [] -> pure Nothing
    [condition] -> condition .: "status" >>= readinessStatus
    _ -> fail "duplicate Ready condition"
 where
  readinessStatus :: Text -> Parser (Maybe Bool)
  readinessStatus "True" = pure (Just True)
  readinessStatus "False" = pure (Just False)
  readinessStatus "Unknown" = pure Nothing
  readinessStatus _ = fail "invalid Ready condition"

decideOwnedPod :: Controller -> Pod -> Either MinioRolloutCause MinioRolloutDecision
decideOwnedPod controller pod
  | podOwnerUid pod /= controllerUid controller = Left UnexpectedPodOwner
  | podTerminating pod || podReady pod == Just True = Right AwaitMinioRollout
  | controllerObservedGeneration controller /= Just (controllerGeneration controller) =
      Right AwaitMinioRollout
  | controllerCurrentRevision controller == controllerUpdateRevision controller =
      Right AwaitMinioRollout
  | podImage pod == expectedImage = Right AwaitMinioRollout
  | controllerCurrentRevision controller /= Just (podRevision pod) = Left UnobservedPodRevision
  | maybe True Text.null (controllerUpdateRevision controller) = Left UnobservedPodRevision
  | podReady pod /= Just False = Left UnobservedPodReadiness
  | otherwise =
      Right (RetireObsoleteMinioPod (MinioPodRetirement (podUid pod) (podResourceVersion pod)))

minioPodRetirementOptions :: MinioPodRetirement -> Value
minioPodRetirementOptions (MinioPodRetirement uid version) =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "preconditions" .= object ["uid" .= uid, "resourceVersion" .= version]
    ]

confirmMinioRollout
  :: Value -> Value -> Value -> MinioRolloutDecision -> Either MinioRolloutCause ()
confirmMinioRollout originalValue currentValue podValue decision = do
  original <- decodeController originalValue
  current <- decodeController currentValue
  pod <- either (const (Left InvalidPodObservation)) Right (parseEither parsePod podValue)
  unless
    ( controllerUid current == controllerUid original
        && controllerGeneration current == controllerGeneration original
        && maybe
          True
          (\revision -> controllerUpdateRevision current == Just revision)
          (controllerUpdateRevision original)
    )
    (Left ControllerChangedBeforeRetirement)
  unless (podOwnerUid pod == controllerUid current) (Left UnexpectedPodOwner)
  unless
    ( controllerObservedGeneration current == Just (controllerGeneration current)
        && controllerCurrentRevision current == controllerUpdateRevision current
        && controllerUpdateRevision current == Just (podRevision pod)
        && podReady pod == Just True
        && not (podTerminating pod)
        && podImage pod == expectedImage
        && replacementObserved decision pod
    )
    (Left DesiredMinioPodNotReady)
 where
  replacementObserved AwaitMinioRollout _ = True
  replacementObserved (RetireObsoleteMinioPod (MinioPodRetirement oldUid _)) pod = podUid pod /= oldUid

reconcileHomeMinioRollout :: FilePath -> IO (Either MinioRolloutError ())
reconcileHomeMinioRollout = reconcileHomeMinioRolloutWith (MinioRolloutEffects captureSubprocessWithInputBounded)

reconcileHomeMinioRolloutWith :: MinioRolloutEffects -> FilePath -> IO (Either MinioRolloutError ())
reconcileHomeMinioRolloutWith effects repoRoot = do
  start <- monotonicNow
  let deadline = deadlineAtOffset start (RemainingDuration 300000000)
  runExceptT (reconcile deadline)
 where
  reconcile deadline = do
    controllerBytes <-
      request
        deadline
        ObserveMinioController
        5000000
        ByteString.empty
        ["get", "statefulset", Text.unpack minioName, "-o", "json"]
    controllerValue <- decodeValue ObserveMinioController controllerBytes
    controller <- either (throwE . MinioRolloutRefused) pure (decodeController controllerValue)
    podBytes <-
      request
        deadline
        ObserveMinioPod
        5000000
        ByteString.empty
        ["get", "pod", Text.unpack (minioName <> "-0"), "--ignore-not-found=true", "-o", "json"]
    podValue <- optionalPod podBytes
    decision <- either (throwE . MinioRolloutRefused) pure (decideMinioRollout controllerValue podValue)
    retireIfNeeded deadline controller decision
    remaining <- remainingMicros deadline AwaitMinioReady
    _ <-
      request
        deadline
        AwaitMinioReady
        remaining
        ByteString.empty
        [ "rollout"
        , "status"
        , "statefulset/" <> Text.unpack minioName
        , "--timeout=" <> show ((remaining + 999999) `div` 1000000) <> "s"
        ]
    completedControllerBytes <-
      request
        deadline
        ObserveMinioController
        5000000
        ByteString.empty
        ["get", "statefulset", Text.unpack minioName, "-o", "json"]
    completedPodBytes <-
      request
        deadline
        ObserveMinioPod
        5000000
        ByteString.empty
        ["get", "pod", Text.unpack (minioName <> "-0"), "-o", "json"]
    completedController <- decodeValue ObserveMinioController completedControllerBytes
    completedPod <- decodeValue ObserveMinioPod completedPodBytes
    either
      (throwE . MinioRolloutRefused)
      pure
      (confirmMinioRollout controllerValue completedController completedPod decision)
    _ <- remainingMicros deadline AwaitMinioReady
    pure ()

  retireIfNeeded _ _ AwaitMinioRollout = pure ()
  retireIfNeeded deadline original (RetireObsoleteMinioPod retirement) = do
    confirmedBytes <-
      request
        deadline
        ConfirmMinioController
        5000000
        ByteString.empty
        ["get", "statefulset", Text.unpack minioName, "-o", "json"]
    confirmedValue <- decodeValue ConfirmMinioController confirmedBytes
    confirmed <- either (throwE . MinioRolloutRefused) pure (decodeController confirmedValue)
    unless (confirmed == original) (throwE (MinioRolloutRefused ControllerChangedBeforeRetirement))
    _ <-
      request
        deadline
        RetireMinioPod
        30000000
        (LazyByteString.toStrict (encode (minioPodRetirementOptions retirement)))
        [ "delete"
        , "--raw=/api/v1/namespaces/"
            <> minioClusterServiceNamespace
            <> "/pods/"
            <> Text.unpack (minioName <> "-0")
        , "--filename=-"
        ]
    pure ()

  request deadline stage ceilingMicros input arguments = ExceptT $ do
    remaining <- runExceptT (remainingMicros deadline stage)
    case remaining of
      Left err -> pure (Left err)
      Right budget -> do
        attempted <-
          captureMinioRolloutSubprocess
            effects
            BoundedSubprocessLimits
              { boundedSubprocessTimeoutMicros = min ceilingMicros budget
              , boundedSubprocessMaximumInputBytes = 16384
              , boundedSubprocessMaximumStdoutBytes = 1048576
              , boundedSubprocessMaximumStderrBytes = 16384
              }
            input
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments = arguments <> ["-n", minioClusterServiceNamespace]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        pure (classifyResponse stage attempted)

  classifyResponse stage (Left _) = Left (MinioRolloutTransportFailed stage)
  classifyResponse stage (Right output) = case processExitCode output of
    ExitSuccess -> Right (TextEncoding.encodeUtf8 (Text.pack (processStdout output)))
    ExitFailure code -> Left (MinioRolloutCommandFailed stage code)

  optionalPod bytes
    | ByteString.null bytes = pure Nothing
    | otherwise = Just <$> decodeValue ObserveMinioPod bytes
  decodeValue stage = either (const (throwE (MinioRolloutTransportFailed stage))) pure . eitherDecodeStrict'

remainingMicros :: Deadline -> MinioRolloutStage -> ExceptT MinioRolloutError IO Int
remainingMicros deadline stage = ExceptT $ do
  now <- monotonicNow
  pure $ case deadlineObservation now deadline of
    DeadlineExpired -> Left (MinioRolloutDeadlineExpired stage)
    DeadlineOpen (RemainingDuration budget) -> Right (fromIntegral budget)

monotonicNow :: IO MonotonicInstant
monotonicNow = monotonicInstantFromMicros . fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec
