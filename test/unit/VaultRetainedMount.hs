{-# LANGUAGE OverloadedStrings #-}

module VaultRetainedMount (vaultRetainedMountSuite) where

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
import Prodbox.ControlPlane.Deadline
import Prodbox.Error (fatalError)
import Prodbox.Infra.VaultRetainedMount
import Prodbox.Subprocess (BoundedSubprocessLimits (..), ProcessOutput (..), Subprocess (..))
import System.Exit (ExitCode (..))
import TestSupport

data Recording = Recording
  { controller :: Value
  , pod :: Value
  , claim :: Value
  , volume :: Value
  , node :: Value
  , bootId :: ByteString
  , hostStat :: ByteString
  , mountedStat :: ByteString
  }

hostPath :: FilePath
hostPath = "/recorded/manual-root/vault/vault/0"

vaultRetainedMountSuite :: SuiteBuilder ()
vaultRetainedMountSuite = describe "VAULT-RETAINED-MOUNT-UNLINKED-2026-10-22" $ do
  it "admits only the recorded unlinked and freshly uninitialized root with exact API preconditions" $ do
    r <- recording
    binding <- requireRight (bindingOf r)
    host <- requireRight (parseDirectoryIdentity (hostStat r))
    mounted <- requireRight (parseDirectoryIdentity (mountedStat r))
    case decideVaultMount binding host mounted (Just False) of
      Right (RetireUnlinkedVaultPod retirement) ->
        vaultPodRetirementOptions retirement
          `shouldBe` object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("DeleteOptions" :: Text)
            , "preconditions"
                .= object
                  [ "uid" .= ("recorded-vault-pod-uid" :: Text)
                  , "resourceVersion" .= field ["metadata", "resourceVersion"] (pod r)
                  ]
            ]
      other -> expectationFailure (show other)

  it "keeps a healthy initialized or sealed root without requiring an init observation" $ do
    r <- recording
    binding <- requireRight (bindingOf r)
    host <- requireRight (parseDirectoryIdentity (hostStat r))
    forM_ [Nothing, Just True, Just False] $ \initialized ->
      decideVaultMount binding host host initialized `shouldBe` Right VaultRootAlreadyBound

  it "refuses initialized or unobservable orphan state and every linked identity mismatch" $ do
    r <- recording
    binding <- requireRight (bindingOf r)
    host <- requireRight (parseDirectoryIdentity (hostStat r))
    orphan <- requireRight (parseDirectoryIdentity (mountedStat r))
    otherDirectory <- requireRight (parseDirectoryIdentity "2050:999:2:41f8")
    decideVaultMount binding host orphan (Just True) `shouldBe` Left InitializedVaultHasUnlinkedRoot
    decideVaultMount binding host orphan Nothing `shouldBe` Left VaultInitializationUnobservable
    decideVaultMount binding host otherDirectory (Just False) `shouldBe` Left LinkedRootIdentityMismatch
    decideVaultMount binding orphan orphan (Just False) `shouldBe` Left DeclaredRootUnlinked
    renderVaultMountError (VaultMountRefused InitializedVaultHasUnlinkedRoot)
      `shouldContain` "NukeOnly: retain the running Vault"

  forM_
    [ ""
    , "2050:1:2"
    , "2050:1:2:81f8"
    , "2050:1:2:a1ff"
    , "-1:1:2:41f8"
    , "2050:0:2:41f8"
    , "2050:1:-2:41f8"
    , "1e3:1:2:41f8"
    , "18446744073709551616:1:2:41f8"
    , "2050:1:2:41f8:extra"
    , ByteString.pack [255]
    ]
    $ \bytes ->
      it ("refuses malformed or non-directory stat " ++ show bytes) $
        parseDirectoryIdentity bytes `shouldSatisfy` isLeft

  forM_
    ["", "not-a-boot-id", "11111111-2222-4333-8444-55555555555z", "11111111222243338444555555555555"]
    $ \bytes ->
      it ("refuses an unobservable local kernel identity " ++ show bytes) $
        parseKernelBootIdentity bytes `shouldSatisfy` isLeft

  forM_
    [
      ( "different node kernel"
      , \r ->
          r
            { node = put ["status", "nodeInfo", "bootID"] (String "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") (node r)
            }
      )
    , ("unknown node kernel", \r -> r {node = put ["status", "nodeInfo", "bootID"] (String "") (node r)})
    , ("different node object", \r -> r {node = put ["metadata", "name"] (String "foreign") (node r)})
    ,
      ( "controller namespace"
      , \r -> r {controller = put ["metadata", "namespace"] (String "foreign") (controller r)}
      )
    , ("controller UID", \r -> r {controller = put ["metadata", "uid"] (String "") (controller r)})
    , ("multiple replicas", \r -> r {controller = put ["spec", "replicas"] (Number 2) (controller r)})
    ,
      ( "unobserved generation"
      , \r -> r {controller = put ["status", "observedGeneration"] (Number 0) (controller r)}
      )
    ,
      ( "non-current revision"
      , \r -> r {controller = put ["status", "currentRevision"] (String "other") (controller r)}
      )
    ,
      ( "OnDelete"
      , \r -> r {controller = put ["spec", "updateStrategy", "type"] (String "OnDelete") (controller r)}
      )
    , ("different ordinal", \r -> r {pod = put ["metadata", "name"] (String "vault-1") (pod r)})
    ,
      ( "deleting Pod"
      , \r -> r {pod = put ["metadata", "deletionTimestamp"] (String "2026-10-22T00:00:00Z") (pod r)}
      )
    , ("Pod resourceVersion", \r -> r {pod = put ["metadata", "resourceVersion"] (String "") (pod r)})
    ,
      ( "Pod revision"
      , \r -> r {pod = put ["metadata", "labels", "controller-revision-hash"] (String "other") (pod r)}
      )
    ,
      ( "foreign controller owner"
      , \r -> r {pod = put ["metadata", "ownerReferences"] (toJSON [owner "foreign"]) (pod r)}
      )
    ,
      ( "unknown readiness"
      , \r -> r {pod = put ["status", "conditions"] (toJSON [ready "Unknown"]) (pod r)}
      )
    ,
      ( "duplicate readiness"
      , \r -> r {pod = put ["status", "conditions"] (toJSON [ready "True", ready "True"]) (pod r)}
      )
    , ("different claim volume", \r -> r {claim = put ["spec", "volumeName"] (String "other") (claim r)})
    , ("unbound claim", \r -> r {claim = put ["status", "phase"] (String "Pending") (claim r)})
    ,
      ( "foreign host path"
      , \r -> r {volume = put ["spec", "hostPath", "path"] (String "/other") (volume r)}
      )
    ,
      ( "different claim UID"
      , \r -> r {volume = put ["spec", "claimRef", "uid"] (String "other") (volume r)}
      )
    ,
      ( "Delete retention"
      , \r -> r {volume = put ["spec", "persistentVolumeReclaimPolicy"] (String "Delete") (volume r)}
      )
    , ("unbound volume", \r -> r {volume = put ["status", "phase"] (String "Released") (volume r)})
    , ("different node", \r -> r {pod = put ["spec", "nodeName"] (String "foreign-node") (pod r)})
    ]
    $ \(label, change) -> it ("refuses " ++ label ++ " before a retirement permit exists") $ do
      r <- recording
      bindingOf (change r) `shouldSatisfy` isLeft

  it "does not promote the frozen successful rollout into proof of a writable retained root" $ do
    r <- recording
    (oldEffects, _) <- fixture r Ordinary
    old <-
      captureVaultMountSubprocess
        oldEffects
        limits
        ByteString.empty
        (Subprocess "kubectl" ["rollout", "status", "statefulset/vault", "--timeout=300s"] Nothing (Just "."))
    case old of
      Left err -> expectationFailure (show err)
      Right output -> processExitCode output `shouldBe` ExitSuccess
    (effects, calls) <- fixture r Ordinary
    reconcileHomeVaultMountWith effects "." hostPath `shouldReturn` Right ()
    observed <- readIORef calls
    length (deletes observed) `shouldBe` 1
    forM_ observed $ \(instant, bound, _, command) -> do
      boundedSubprocessTimeoutMicros bound `shouldSatisfy` (<= 300000000 - instant)
      subprocessArguments command `shouldSatisfy` (not . any (`elem` ["--force", "--grace-period=0"]))
    forM_ (deletes observed) $ \(_, _, body, command) -> do
      eitherDecodeStrict' body `shouldSatisfy` (either (const False) hasPreconditions)
      subprocessArguments command
        `shouldBe` ["delete", "--raw=/api/v1/namespaces/vault/pods/vault-0", "--filename=-", "-n", "vault"]

  forM_ [Healthy, Initialized, InitializationUnavailable, ChangeController, ChangeHostRoot, Conflict] $ \scenario ->
    it ("preserves the registered refusal/healthy sibling " ++ show scenario) $ do
      r <- recording
      (effects, calls) <- fixture r scenario
      outcome <- reconcileHomeVaultMountWith effects "." hostPath
      case scenario of
        Healthy -> outcome `shouldBe` Right ()
        _ -> outcome `shouldSatisfy` isLeft
      observed <- readIORef calls
      length (deletes observed) `shouldBe` if scenario == Conflict then 1 else 0

  it "resumes after an applied delete with a lost reply without a second retirement" $ do
    r <- recording
    (effects, calls) <- fixture r LostDeleteReply
    reconcileHomeVaultMountWith effects "." hostPath
      `shouldReturn` Left (VaultMountTransportFailed RetireVaultPod)
    reconcileHomeVaultMountWith effects "." hostPath `shouldReturn` Right ()
    observed <- readIORef calls
    length (deletes observed) `shouldBe` 1

  forM_ [ClosingOrphan, ClosingOwnerChanged, ClosingRootChanged, SameUidForever] $ \scenario ->
    it ("refuses lying closing evidence: " ++ show scenario) $ do
      r <- recording
      (effects, calls) <- fixture r scenario
      outcome <- reconcileHomeVaultMountWith effects "." hostPath
      outcome `shouldSatisfy` isLeft
      observed <- readIORef calls
      length (deletes observed) `shouldBe` 1

  it "waits through graceful termination and positive temporary absence under the original deadline" $ do
    r <- recording
    (effects, _) <- fixture r GracefulReplacement
    reconcileHomeVaultMountWith effects "." hostPath `shouldReturn` Right ()

  it "cannot extend the rollout budget after a boundary has consumed it" $ do
    r <- recording
    (effects, calls) <- fixture r ExpireAtRollout
    reconcileHomeVaultMountWith effects "." hostPath
      `shouldReturn` Left (VaultMountDeadlineExpired AwaitVaultRollout)
    observed <- readIORef calls
    length observed `shouldBe` 1

type Call = (Int, BoundedSubprocessLimits, ByteString, Subprocess)

data Scenario
  = Ordinary
  | Healthy
  | Initialized
  | InitializationUnavailable
  | ChangeController
  | ChangeHostRoot
  | Conflict
  | LostDeleteReply
  | ClosingOrphan
  | ClosingOwnerChanged
  | ClosingRootChanged
  | SameUidForever
  | GracefulReplacement
  | ExpireAtRollout
  deriving (Eq, Show)

fixture :: Recording -> Scenario -> IO (VaultMountEffects, IORef [Call])
fixture r scenario = do
  calls <- newIORef []
  clock <- newIORef 0
  deleted <- newIORef False
  controllerReads <- newIORef (0 :: Int)
  rootReads <- newIORef (0 :: Int)
  polls <- newIORef (0 :: Int)
  let capture bound input command = do
        now <- readIORef clock
        modifyIORef' calls (++ [(now, bound, input, command)])
        modifyIORef' clock (+ 1000)
        isDeleted <- readIORef deleted
        let args = subprocessArguments command
            healthyPod =
              put
                ["metadata", "resourceVersion"]
                (String "new-version")
                (put ["metadata", "uid"] (String "replacement-vault-pod-uid") (pod r))
            currentPod
              | not isDeleted || scenario == SameUidForever = pod r
              | scenario == ClosingOwnerChanged =
                  put ["metadata", "ownerReferences"] (toJSON [owner "foreign"]) healthyPod
              | otherwise = healthyPod
            success bytes = pure (Right (ProcessOutput ExitSuccess (Text.unpack (TextEncoding.decodeUtf8 bytes)) ""))
            json = success . LazyByteString.toStrict . encode
        case (subprocessPath command, args) of
          ("cat", ["/proc/sys/kernel/random/boot_id"]) -> success (bootId r)
          ("sudo", "stat" : _) -> do
            modifyIORef' rootReads (+ 1)
            n <- readIORef rootReads
            if (scenario == ChangeHostRoot && n > 1) || (scenario == ClosingRootChanged && isDeleted)
              then success "2050:777:2:41f8"
              else success (hostStat r)
          ("kubectl", "rollout" : _) -> do
            if scenario == ExpireAtRollout then writeIORef clock 300000000 else pure ()
            success ""
          ("kubectl", "get" : "statefulset" : _) -> do
            modifyIORef' controllerReads (+ 1)
            n <- readIORef controllerReads
            if scenario == ChangeController && n > 1
              then
                json
                  ( put
                      ["status", "observedGeneration"]
                      (Number 2)
                      (put ["metadata", "generation"] (Number 2) (controller r))
                  )
              else json (controller r)
          ("kubectl", "get" : "pod" : _)
            | "--ignore-not-found=true" `elem` args && scenario == GracefulReplacement -> do
                modifyIORef' polls (+ 1)
                n <- readIORef polls
                case n of
                  1 -> json (put ["metadata", "deletionTimestamp"] (String "2026-10-22T00:00:00Z") (pod r))
                  2 -> success ""
                  _ -> json currentPod
            | otherwise -> json currentPod
          ("kubectl", "get" : "pvc" : _) -> json (claim r)
          ("kubectl", "get" : "pv" : _) -> json (volume r)
          ("kubectl", "get" : "node" : _) -> json (node r)
          ("kubectl", "exec" : _)
            | "stat" `elem` args ->
                success $
                  if scenario == Healthy || (isDeleted && scenario /= ClosingOrphan)
                    then if scenario == ClosingRootChanged then "2050:777:2:41f8" else hostStat r
                    else mountedStat r
            | "status" `elem` args ->
                if scenario == InitializationUnavailable
                  then pure (Right (ProcessOutput (ExitFailure 1) "" "unavailable"))
                  else
                    pure
                      ( Right
                          ( ProcessOutput
                              (ExitFailure 2)
                              (if scenario == Initialized then "{\"initialized\":true}" else "{\"initialized\":false}")
                              ""
                          )
                      )
          ("kubectl", "delete" : _)
            | scenario == Conflict -> pure (Right (ProcessOutput (ExitFailure 1) "" "conflict"))
            | otherwise -> do
                writeIORef deleted True
                if scenario == LostDeleteReply then pure (Left (fatalError "simulated reply loss")) else success ""
          _ -> pure (Left (fatalError "unexpected boundary call"))
      effects =
        VaultMountEffects
          capture
          (monotonicInstantFromMicros . fromIntegral <$> readIORef clock)
          (\micros -> modifyIORef' clock (+ micros))
  pure (effects, calls)

recording :: IO Recording
recording = do
  bytes <- ByteString.readFile "test/qualification/VAULT-RETAINED-MOUNT-UNLINKED-2026-10-22.json"
  requireRight $ do
    value <- eitherDecodeStrict' bytes
    parseEither
      ( withObject "recording" $ \root ->
          Recording
            <$> root .: "controller"
            <*> root .: "pod"
            <*> root .: "claim"
            <*> root .: "volume"
            <*> root .: "node"
            <*> (TextEncoding.encodeUtf8 <$> root .: "host_boot_id")
            <*> (TextEncoding.encodeUtf8 <$> root .: "host_stat")
            <*> (TextEncoding.encodeUtf8 <$> root .: "mounted_stat")
      )
      value

bindingOf :: Recording -> Either VaultMountCause VaultMountBinding
bindingOf r = do
  kernel <- parseKernelBootIdentity (bootId r)
  observeVaultMountBinding hostPath kernel (controller r) (pod r) (claim r) (volume r) (node r)

requireRight :: (Show err) => Either err value -> IO value
requireRight = either (fail . show) pure

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 16384 1048576 16384 300000000

deletes :: [Call] -> [Call]
deletes = filter (\(_, _, _, command) -> take 1 (subprocessArguments command) == ["delete"])

hasPreconditions :: Value -> Bool
hasPreconditions value =
  field ["preconditions", "uid"] value == String "recorded-vault-pod-uid"
    && field ["preconditions", "resourceVersion"] value /= Null

owner :: Text -> Value
owner uid =
  object
    [ "apiVersion" .= ("apps/v1" :: Text)
    , "kind" .= ("StatefulSet" :: Text)
    , "name" .= ("vault" :: Text)
    , "controller" .= True
    , "uid" .= uid
    ]

ready :: Text -> Value
ready status = object ["type" .= ("Ready" :: Text), "status" .= status]

field :: [Text] -> Value -> Value
field [] value = value
field (key : rest) (Object values) = maybe Null (field rest) (KeyMap.lookup (Key.fromText key) values)
field _ _ = Null

put :: [Text] -> Value -> Value -> Value
put [] replacement _ = replacement
put (key : rest) replacement (Object values) =
  let name = Key.fromText key
   in Object
        ( KeyMap.insert
            name
            (put rest replacement (maybe (Object mempty) id (KeyMap.lookup name values)))
            values
        )
put path replacement _ = put path replacement (Object mempty)
