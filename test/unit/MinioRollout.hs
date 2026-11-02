{-# LANGUAGE OverloadedStrings #-}

module MinioRollout (minioRolloutSuite) where

import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ContainerImage (publicMinioImage, renderImageRef)
import Prodbox.Error (fatalError)
import Prodbox.Infra.MinioRollout
import Prodbox.Subprocess (BoundedSubprocessLimits (..), ProcessOutput (..), Subprocess (..))
import System.Exit (ExitCode (..))
import TestSupport

minioRolloutSuite :: SuiteBuilder ()
minioRolloutSuite = describe "MINIO-BOOTSTRAP-ORDEREDREADY-2026-10-22" $ do
  it "admits only the recorded obsolete owned Pod with exact UID and resourceVersion" $ do
    (controller, pod) <- recording
    case decideMinioRollout controller (Just pod) of
      Right (RetireObsoleteMinioPod retirement) ->
        minioPodRetirementOptions retirement
          `shouldBe` object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("DeleteOptions" :: Text)
            , "preconditions"
                .= object ["uid" .= ("recorded-obsolete-pod-uid" :: Text), "resourceVersion" .= ("123" :: Text)]
            ]
      other -> expectationFailure (show other)

  forM_
    [ ("healthy old Pod", setReady "True")
    , ("already selected image", setPodImage desiredImage)
    , ("terminating Pod", put ["metadata", "deletionTimestamp"] (String "2026-10-22T00:00:00Z"))
    ]
    $ \(label, change) -> it label $ do
      (controller, pod) <- recording
      decideMinioRollout controller (Just (change pod)) `shouldBe` Right AwaitMinioRollout

  it "waits for a positively absent Pod and a controller not yet observing its generation" $ do
    (controller, pod) <- recording
    decideMinioRollout controller Nothing `shouldBe` Right AwaitMinioRollout
    decideMinioRollout (put ["status", "observedGeneration"] (Number 1) controller) (Just pod)
      `shouldBe` Right AwaitMinioRollout

  forM_
    [
      ( "foreign owner"
      , put
          ["metadata", "ownerReferences"]
          ( toJSON
              [ object
                  [ "apiVersion" .= ("apps/v1" :: Text)
                  , "kind" .= ("StatefulSet" :: Text)
                  , "name" .= ("minio" :: Text)
                  , "controller" .= True
                  , "uid" .= ("foreign-controller" :: Text)
                  ]
              ]
          )
      )
    , ("foreign namespace", put ["metadata", "namespace"] (String "other"))
    , ("different ordinal", put ["metadata", "name"] (String "minio-1"))
    , ("empty UID", put ["metadata", "uid"] (String ""))
    , ("empty resourceVersion", put ["metadata", "resourceVersion"] (String ""))
    ,
      ( "unrecorded revision"
      , put ["metadata", "labels", "controller-revision-hash"] (String "third-revision")
      )
    , ("unknown readiness", setReady "Unknown")
    ,
      ( "duplicate readiness"
      , put ["status", "conditions"] (toJSON [readyCondition "False", readyCondition "True"])
      )
    ]
    $ \(label, change) -> it ("refuses " <> label) $ do
      (controller, pod) <- recording
      decideMinioRollout controller (Just (change pod)) `shouldSatisfy` isLeft

  forM_
    [
      ( "unseeded desired image"
      , put ["spec", "template", "spec", "containers"] (toJSON [container "untrusted/image:tag"])
      )
    , ("foreign controller namespace", put ["metadata", "namespace"] (String "other"))
    , ("empty controller UID", put ["metadata", "uid"] (String ""))
    , ("multiple replicas", put ["spec", "replicas"] (Number 2))
    , ("OnDelete strategy", put ["spec", "updateStrategy", "type"] (String "OnDelete"))
    , ("nonzero partition", put ["spec", "updateStrategy", "rollingUpdate", "partition"] (Number 1))
    ]
    $ \(label, change) -> it ("refuses " <> label) $ do
      (controller, pod) <- recording
      decideMinioRollout (change controller) (Just pod) `shouldSatisfy` isLeft

  it "accepts a fresh controller publishing its first selected revision within the same generation" $ do
    (controller, pod) <- recording
    let fresh = put ["status"] (Object mempty) controller
        (readyController, readyPod) = completed controller pod
    decideMinioRollout fresh Nothing `shouldBe` Right AwaitMinioRollout
    confirmMinioRollout fresh readyController readyPod AwaitMinioRollout `shouldBe` Right ()

  it "accepts exact closing readback and refuses same-UID, not-ready and changed-generation claims" $ do
    (controller, pod) <- recording
    case decideMinioRollout controller (Just pod) of
      Left err -> expectationFailure (show err)
      Right decision -> do
        let (completedController, completedPod) = completed controller pod
        confirmMinioRollout controller completedController completedPod decision `shouldBe` Right ()
        confirmMinioRollout
          controller
          completedController
          (put ["metadata", "uid"] (String "recorded-obsolete-pod-uid") completedPod)
          decision
          `shouldBe` Left DesiredMinioPodNotReady
        confirmMinioRollout controller completedController (setReady "False" completedPod) decision
          `shouldBe` Left DesiredMinioPodNotReady
        confirmMinioRollout
          controller
          (put ["metadata", "generation"] (Number 3) completedController)
          completedPod
          decision
          `shouldBe` Left ControllerChangedBeforeRetirement

  it "retains the wait-only failure and replacement pass on one recorded topology and budget" $ do
    (controller, pod) <- recording
    (effects, calls) <- fixture controller pod Ordinary
    old <-
      captureMinioRolloutSubprocess
        effects
        limits
        ByteString.empty
        ( Subprocess
            "kubectl"
            ["rollout", "status", "statefulset/minio", "-n", "prodbox", "--timeout=300s"]
            Nothing
            (Just ".")
        )
    case old of
      Left _ -> expectationFailure "wait-only control could not execute"
      Right output -> processExitCode output `shouldBe` ExitFailure 1
    reconcileHomeMinioRolloutWith effects "." `shouldReturn` Right ()
    observed <- readIORef calls
    let deletes = [(body, args) | (_, body, args) <- observed, take 1 args == ["delete"]]
    length deletes `shouldBe` 1
    all (\(bound, _, _) -> boundedSubprocessTimeoutMicros bound <= 300000000) observed `shouldBe` True
    all (\(_, _, args) -> not (any (`elem` ["--force", "--grace-period=0", "pvc", "pv"]) args)) observed
      `shouldBe` True
    map snd deletes
      `shouldBe` [["delete", "--raw=/api/v1/namespaces/prodbox/pods/minio-0", "--filename=-", "-n", "prodbox"]]

  it "recovers a lost applied-delete reply without repeating that retirement" $ do
    (controller, pod) <- recording
    (effects, calls) <- fixture controller pod LoseDeleteReply
    reconcileHomeMinioRolloutWith effects "."
      `shouldReturn` Left (MinioRolloutTransportFailed RetireMinioPod)
    reconcileHomeMinioRolloutWith effects "." `shouldReturn` Right ()
    observed <- readIORef calls
    length [() | (_, _, args) <- observed, take 1 args == ["delete"]] `shouldBe` 1

  it "refuses changed controller confirmation without a delete" $ do
    (controller, pod) <- recording
    (effects, calls) <- fixture controller pod ChangeController
    reconcileHomeMinioRolloutWith effects "."
      `shouldReturn` Left (MinioRolloutRefused ControllerChangedBeforeRetirement)
    observed <- readIORef calls
    [args | (_, _, args) <- observed, take 1 args == ["delete"]] `shouldBe` []

  it "retains a UID/resourceVersion conflict and never accepts a lying rollout success" $ do
    (controller, pod) <- recording
    (conflict, _) <- fixture controller pod RefuseDelete
    reconcileHomeMinioRolloutWith conflict "."
      `shouldReturn` Left (MinioRolloutCommandFailed RetireMinioPod 1)
    (lying, _) <- fixture controller pod LieAboutCompletion
    reconcileHomeMinioRolloutWith lying "."
      `shouldReturn` Left (MinioRolloutRefused DesiredMinioPodNotReady)

recording :: IO (Value, Value)
recording = do
  bytes <- ByteString.readFile "test/qualification/MINIO-BOOTSTRAP-ORDEREDREADY-2026-10-22.json"
  case eitherDecodeStrict' bytes
    >>= parseEither (withObject "recording" (\value -> (,) <$> value .: "controller" <*> value .: "pod")) of
    Left err -> expectationFailure err >> pure (Null, Null)
    Right values -> pure values

desiredImage :: Text
desiredImage = Text.pack (renderImageRef publicMinioImage)

container :: Text -> Value
container image = object ["name" .= ("minio" :: Text), "image" .= image]

readyCondition :: Text -> Value
readyCondition status = object ["type" .= ("Ready" :: Text), "status" .= status]

setReady :: Text -> Value -> Value
setReady status = put ["status", "conditions"] (toJSON [readyCondition status])

setPodImage :: Text -> Value -> Value
setPodImage image = put ["spec", "containers"] (toJSON [container image])

put :: [Text] -> Value -> Value -> Value
put [] replacement _ = replacement
put (field : rest) replacement (Object values) =
  let key = Key.fromText field
      existing = KeyMap.lookup key values
   in Object (KeyMap.insert key (put rest replacement (maybe (Object mempty) id existing)) values)
put path replacement _ = put path replacement (Object mempty)

getRevision :: Value -> Text
getRevision value = case parseEither
  (withObject "controller" (\fields -> fields .: "status" >>= (.: "updateRevision")))
  value of
  Left _ -> "invalid-recording"
  Right revision -> revision

completed :: Value -> Value -> (Value, Value)
completed controller pod =
  let revision = getRevision controller
   in ( put ["status", "currentRevision"] (String revision) controller
      , setReady "True"
          . setPodImage desiredImage
          . put ["metadata", "labels", "controller-revision-hash"] (String revision)
          . put ["metadata", "uid"] (String "replacement-pod-uid")
          $ pod
      )

data ReplyMode = Ordinary | LoseDeleteReply | ChangeController | RefuseDelete | LieAboutCompletion
  deriving (Eq)

type Captured = (BoundedSubprocessLimits, ByteString, [String])

fixture :: Value -> Value -> ReplyMode -> IO (MinioRolloutEffects, IORef [Captured])
fixture controller pod mode = do
  retired <- newIORef False
  controllerReads <- newIORef (0 :: Int)
  calls <- newIORef []
  let (newController, newPod) = completed controller pod
      capture bound body spec = do
        let args = subprocessArguments spec
        modifyIORef' calls (<> [(bound, body, args)])
        isRetired <- readIORef retired
        response isRetired body args
      response isRetired body args
        | take 3 args == ["get", "statefulset", "minio"] = do
            count <- atomicModifyIORef' controllerReads (\n -> (n + 1, n + 1))
            pure
              ( ok
                  ( if isRetired
                      then newController
                      else
                        if mode == ChangeController && count > 1
                          then put ["metadata", "generation"] (Number 3) controller
                          else controller
                  )
              )
        | take 3 args == ["get", "pod", "minio-0"] = pure (ok (if isRetired then newPod else pod))
        | take 1 args == ["delete"] = deleteReply body
        | take 2 args == ["rollout", "status"] =
            pure
              ( Right
                  (ProcessOutput (if isRetired || mode == LieAboutCompletion then ExitSuccess else ExitFailure 1) "" "")
              )
        | otherwise = pure (Right (ProcessOutput (ExitFailure 2) "" "unexpected subprocess"))
      deleteReply body =
        case eitherDecodeStrict' body of
          Left _ -> pure (Right (ProcessOutput (ExitFailure 1) "" "invalid delete options"))
          Right options -> admitDeleteOptions options
      admitDeleteOptions options =
        case decideMinioRollout controller (Just pod) of
          Right (RetireObsoleteMinioPod retirement)
            | options == minioPodRetirementOptions retirement -> applyDelete
          _ -> pure (Right (ProcessOutput (ExitFailure 1) "" "precondition conflict"))
      applyDelete
        | mode == RefuseDelete = pure (Right (ProcessOutput (ExitFailure 1) "" "precondition conflict"))
        | mode == LieAboutCompletion = pure (Right (ProcessOutput ExitSuccess "" ""))
        | otherwise = do
            writeIORef retired True
            pure
              ( if mode == LoseDeleteReply
                  then Left (fatalError "lost applied reply")
                  else Right (ProcessOutput ExitSuccess "" "")
              )
  pure (MinioRolloutEffects capture, calls)

ok :: Value -> Either error ProcessOutput
ok value =
  Right
    ( ProcessOutput
        ExitSuccess
        (Text.unpack (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode value))))
        ""
    )

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 16384 1048576 16384 300000000
