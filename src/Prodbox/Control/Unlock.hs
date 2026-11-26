{-# LANGUAGE OverloadedStrings #-}

-- | Phase 2 slice: initialise, unseal and self-unseal the pinned Vault with the
-- test-only MinIO unlock object, and prove a secret round trip.
--
-- Two policies exist and are distinct values. 'TestSelfUnseal' may keep the
-- unlock bundle as an object in the environment's own MinIO under the MinIO
-- bootstrap credential; 'ProtectedProduction' may not, and refuses before any
-- observation or read. The policy is derived from the selected environment, so a
-- production identity cannot load the test policy by configuration.
--
-- Vault is initialised at most once per retained identity. An initialised Vault
-- whose unlock object is missing, or an unlock object that names another
-- environment or root generation, is reported as a recovery condition and never
-- re-initialised. The unseal key and root token are handled only as bytes in
-- memory, standard input of the commands that need them and one private file
-- (written exclusively before the upload so an interruption can continue); they
-- are never printed, logged or placed in an argument vector or an error.
module Prodbox.Control.Unlock
  ( UnlockPolicy (..)
  , unlockPolicyFor
  , VaultState (..)
  , initialisationAllowed
  , UnlockStep (..)
  , UnlockOutcome (..)
  , unlockVault
  , renderUnlockOutcome
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Aeson ((.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (fromLeft)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (..)
  , scopeEnvironment
  , scopeKindName
  , withScopeRootDescriptor
  )
import Prodbox.Control.KindControllerReceipt
  ( ControllerReceiptObservation (ControllerReceiptObserved)
  , observeControllerReceipt
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches, KindIntentMissing)
  , observeKindIntent
  , observeKindTeardownAdmission
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshotBound)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (KindOperationCallbackReturned)
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNodeBootstrap
  ( JournalRecordObservation (..)
  , observeJournalRecord
  , writeJournalRecord
  )
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.Control.ManagementRestore (managementRestoreIdle)
import Prodbox.Control.Status (observeNodeCaBindingUnderLease)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (Fd))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data UnlockPolicy = TestSelfUnseal | ProtectedProduction
  deriving (Eq, Show)

-- | The policy is a function of the environment and nothing else.
unlockPolicyFor :: DeploymentEnvironment -> UnlockPolicy
unlockPolicyFor environment = case environment of
  Test -> TestSelfUnseal
  _ -> ProtectedProduction

data UnlockStep = UnlockStep
  { unlockStepName :: !String
  , unlockStepOk :: !Bool
  , unlockStepDetail :: !String
  }
  deriving (Eq, Show)

newtype UnlockOutcome = UnlockOutcome [UnlockStep]
  deriving (Eq, Show)

renderUnlockOutcome :: UnlockOutcome -> (Bool, String)
renderUnlockOutcome (UnlockOutcome steps) =
  ( not (null steps) && all unlockStepOk steps
  , unlines
      [ "  "
          ++ unlockStepName step
          ++ ": "
          ++ (if unlockStepOk step then "ok" else "NOT completed")
          ++ " - "
          ++ unlockStepDetail step
      | step <- steps
      ]
  )

data VaultState = VaultUnobservable String | VaultUninitialized | VaultSealed | VaultUnsealed
  deriving (Eq, Show)

-- | Vault is initialized at most once per retained identity. Initialization is
-- allowed only when the observed Vault is uninitialized, no unlock object
-- exists for it and no pending unlock record exists; anything else is a
-- storage-identity disagreement or an interrupted initialization and must be
-- recovered, never re-initialized over.
initialisationAllowed :: VaultState -> Bool -> Bool -> Bool
initialisationAllowed state objectPresent pendingPresent =
  state == VaultUninitialized && not objectPresent && not pendingPresent

data Bundle = Bundle
  { bundleScope :: Text
  , bundleGeneration :: Text
  , bundleKey :: Text
  , bundleToken :: Text
  -- ^ The limited client token minted after the first unseal (a policy that
  -- covers only the test KV mount). The initial root token is never stored in
  -- MinIO: it lives in the private pending file only until it has been used
  -- once to mint this token and is then revoked. Empty when none was minted.
  , bundleRoot :: Text
  -- ^ Only in the private local pending record, never in MinIO: the initial
  -- root token, held until the one use that mints the client token.
  }

bundleBytes :: Bundle -> ByteString.ByteString
bundleBytes bundle =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            ( [ "schema_version" .= (1 :: Int)
              , "scope" .= bundleScope bundle
              , "root_generation" .= bundleGeneration bundle
              , "unseal_key" .= bundleKey bundle
              , "client_token" .= bundleToken bundle
              ]
                ++ ["pending_root" .= bundleRoot bundle | not (Text.null (bundleRoot bundle))]
            )
        )
    )

parseBundle :: ByteString.ByteString -> Maybe Bundle
parseBundle bytes = do
  value <- Aeson.decodeStrict bytes
  AesonTypes.parseMaybe
    ( Aeson.withObject "bundle" $ \object ->
        Bundle
          <$> object .: "scope"
          <*> object .: "root_generation"
          <*> object .: "unseal_key"
          <*> (object .:? "client_token" .!= "")
          <*> (object .:? "pending_root" .!= "")
    )
    value

limits :: Int -> BoundedSubprocessLimits
limits seconds = BoundedSubprocessLimits (1024 * 1024) (1024 * 1024) (256 * 1024) (seconds * 1000000)

readerObject :: String
readerObject = "reader/" ++ unlockObjectPath

bucketObject :: String
bucketObject = "local/" ++ unlockObjectPath

unlockObjectPath :: String
unlockObjectPath = "prodbox-bootstrap/vault-unlock-test.json"

-- The pinned MinIO client maps only a missing key to this cause for the
-- exact HEAD request. A denied, unavailable or malformed observation is
-- distinct from a missing key. No object content is read with this alias.
missingUnlockObject :: ByteString.ByteString -> Bool
missingUnlockObject bytes = case Aeson.decodeStrict bytes of
  Just value -> AesonTypes.parseMaybe missing value == Just True
  Nothing -> False
 where
  missing = Aeson.withObject "stat" $ \stat -> do
    status <- stat .: "status"
    failure <- stat .: "error"
    Aeson.withObject "error" (details status) failure
  details (status :: Text) failure = do
    message <- failure .: "message"
    cause <- failure .: "cause"
    Aeson.withObject "cause" (exactCause status message) cause
  exactCause status (message :: Text) cause = do
    description <- cause .: "message"
    pure
      ( status == "error"
          && message == Text.pack ("Unable to stat `" ++ bucketObject ++ "`.")
          && (description :: Text) == "Object does not exist"
      )

data BundleObservation
  = BundlePresent !ByteString.ByteString
  | BundleAbsent
  | BundleUnobservable

initializationRecordName :: FilePath
initializationRecordName = "vault-test-init-intent.json"

data PendingObservation
  = PendingAbsent
  | PendingPresent !Bundle
  | PendingUnobservable

pendingName :: FilePath
pendingName = "vault-unlock-pending.json"

pendingFlags :: Posix.OpenFileFlags
pendingFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

withPendingDirectory :: BootstrapProjection -> (Fd -> IO a) -> IO (Maybe a)
withPendingDirectory bootstrap action = do
  result <- try $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root same ->
    bracket
      (Posix.openFdAt (Just root) "control" Posix.ReadOnly (pendingFlags {Posix.directory = True}))
      Posix.closeFd
      $ \control -> do
        owner <- getEffectiveUserID
        entry <- Files.getFdStatus control
        current <- same
        unless
          ( current
              && Files.fileOwner entry == owner
              && Files.fileMode entry `Files.intersectFileModes` 0o077 == 0
          )
          (ioError (userError "the unlock custody directory is unbound"))
        action control
  pure $ case result of
    Right (Right found) -> Just found
    Left (_ :: IOException) -> Nothing
    _ -> Nothing

observePending :: BootstrapProjection -> IO PendingObservation
observePending bootstrap = do
  observed <- withPendingDirectory bootstrap $ \control -> do
    opened <- try (Posix.openFdAt (Just control) pendingName Posix.ReadOnly pendingFlags)
    case opened of
      Left (failure :: IOException)
        | isDoesNotExistError failure -> pure PendingAbsent
        | otherwise -> pure PendingUnobservable
      Right file -> bracket (pure file) Posix.closeFd $ \held -> do
        owner <- getEffectiveUserID
        entry <- Files.getFdStatus held
        if not (Files.isRegularFile entry)
          || Files.fileOwner entry /= owner
          || Files.fileMode entry `Files.intersectFileModes` 0o077 /= 0
          || Files.linkCount entry /= 1
          || Files.fileSize entry > 16384
          then pure PendingUnobservable
          else do
            bytes <- PosixBytes.fdRead held 16385
            pure $ case parseBundle bytes of
              Just bundle | fromIntegral (ByteString.length bytes) == Files.fileSize entry -> PendingPresent bundle
              _ -> PendingUnobservable
  pure (maybe PendingUnobservable id observed)

recordPending :: BootstrapProjection -> Bundle -> IO Bool
recordPending bootstrap bundle = do
  written <- withPendingDirectory bootstrap $ \control ->
    bracket
      ( Posix.openFdAt
          (Just control)
          pendingName
          Posix.WriteOnly
          (pendingFlags {Posix.exclusive = True, Posix.creat = Just 0o600})
      )
      Posix.closeFd
      $ \file -> do
        let bytes = bundleBytes bundle
        count <- PosixBytes.fdWrite file bytes
        fileSynchronise file
        fileSynchronise control
        pure (fromIntegral count == ByteString.length bytes)
  pure (written == Just True)

retirePending :: BootstrapProjection -> IO Bool
retirePending bootstrap =
  (== Just ())
    <$> withPendingDirectory
      bootstrap
      ( \control@(Fd descriptor) -> do
          Files.removeLink ("/proc/self/fd" </> show descriptor </> pendingName)
          fileSynchronise control
      )

-- | The pre-Vault read capability: self-unseal reads the unlock object with a
-- MinIO user whose policy allows exactly GetObject on that object, never with
-- the bootstrap root credential.
readerPrefix :: String
readerPrefix =
  "mc alias set reader http://minio:9000 \"$MINIO_READER_USER\" \"$MINIO_READER_PASSWORD\" >/dev/null 2>&1 && "

mcPrefix :: String
mcPrefix = "mc alias set local http://minio:9000 \"$MINIO_USER\" \"$MINIO_PASSWORD\" >/dev/null 2>&1 && "

unlockVault :: BootstrapProjection -> IO UnlockOutcome
unlockVault bootstrap = do
  let scope = bootstrapScope bootstrap
      policy = unlockPolicyFor (scopeEnvironment scope)
  case policy of
    ProtectedProduction ->
      -- Refuse before reading anything: the test policy is never loaded here.
      pure
        ( UnlockOutcome
            [ UnlockStep
                "policy"
                False
                "protected production may not use the test MinIO self-unseal policy; no unlock material was read"
            ]
        )
    TestSelfUnseal -> do
      current <- observeKindIntent bootstrap
      case current of
        KindIntentMatches operation -> do
          result <- withRecoveredKindOperation bootstrap operation $ \stable -> do
            let admitted = do
                  held <- stable
                  checkpoint <- observeKindTeardownAdmission bootstrap
                  idle <- managementRestoreIdle bootstrap
                  final <- stable
                  pure (held && final && checkpoint == KindIntentMissing && idle)
            receipt <- observeControllerReceipt bootstrap operation admitted
            case receipt of
              ControllerReceiptObserved node -> do
                snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config file -> do
                  let bound = observeNodeCaBindingUnderLease bootstrap operation node config admitted
                  verified <- bound
                  if verified then unlockTestVault bootstrap file bound else pure unlockUnbound
                pure (either (const unlockUnbound) id snapshot)
              _ -> pure unlockUnbound
          pure $ case result of
            KindOperationCallbackReturned outcome -> outcome
            _ -> unlockUnbound
        _ -> pure unlockUnbound

unlockUnbound :: UnlockOutcome
unlockUnbound =
  UnlockOutcome
    [ UnlockStep
        "environment"
        False
        "the recorded running kind operation and its Kubernetes credential could not be verified"
    ]

unlockTestVault :: BootstrapProjection -> FilePath -> IO Bool -> IO UnlockOutcome
unlockTestVault bootstrap kubeconfig bound = do
  let scope = bootstrapScope bootstrap
      generation = bootstrapRootGeneration bootstrap
      scopeName = Text.pack (scopeKindName scope)
      kubectl seconds arguments input = do
        result <-
          captureSubprocessWithInputBounded
            (limits seconds)
            input
            ( Subprocess
                "/usr/bin/kubectl"
                (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
                (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                Nothing
            )
        pure $ case result of
          Right output ->
            Right
              ( case processExitCode output of
                  ExitSuccess -> 0 :: Int
                  ExitFailure code -> code
              , ByteString8.pack (processStdout output)
              , processStderr output
              )
          Left failure -> Left (show failure)
      -- A container-runtime exec can answer "container not found" for a Pod that is
      -- running and unrestarted (observed intermittently); the exec had no effect,
      -- so it is retried a bounded number of times.
      exec pod argv input = execAttempt (3 :: Int) pod argv input
      execAttempt attempts pod argv input = do
        result <- kubectl 120 (["-n", managementNamespace, "exec", "-i", pod, "--"] ++ argv) input
        case result of
          Right (code, _, err)
            | code /= 0 && attempts > 1 && "container not found" `isInfixOf` err -> do
                threadDelay 3000000
                execAttempt (attempts - 1) pod argv input
          _ -> pure result
      mc script input = exec "mc" ["/bin/sh", "-c", mcPrefix ++ script] input
      vaultEnv = ["env", "VAULT_ADDR=http://127.0.0.1:8200"]
      proxy path =
        kubectl
          60
          ["get", "--raw", "/api/v1/namespaces/" ++ managementNamespace ++ "/pods/vault:8200/proxy/" ++ path]
          ByteString.empty
      stateOf = do
        result <- proxy "v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
        pure $ case result of
          Right (0, out, _) -> case Aeson.decodeStrict out of
            Just (Aeson.Object fields) -> case (KeyMap.lookup "initialized" fields, KeyMap.lookup "sealed" fields) of
              (Just (Aeson.Bool False), _) -> VaultUninitialized
              (Just (Aeson.Bool True), Just (Aeson.Bool True)) -> VaultSealed
              (Just (Aeson.Bool True), Just (Aeson.Bool False)) -> VaultUnsealed
              _ -> VaultUnobservable "the health answer did not state initialized and sealed"
            _ -> VaultUnobservable "the health answer was not JSON"
          Right (code, _, err) -> VaultUnobservable ("health read exit " ++ show code ++ ": " ++ take 120 err)
          Left failure -> VaultUnobservable failure
      step name ok detail = UnlockStep name ok detail
      policyStep = step "policy" True "test MinIO self-unseal policy selected from the test environment"
      fetchBundle = do
        result <- exec "mc" ["/bin/sh", "-c", readerPrefix ++ "mc cat " ++ readerObject] ByteString.empty
        pure $ case result of
          Right (0, out, _) -> Right out
          Right (code, _, _) -> Left ("object read exit " ++ show code)
          Left failure -> Left failure
      observeBundle = do
        bundle <- fetchBundle
        case bundle of
          Right bytes -> pure (BundlePresent bytes)
          Left _ -> do
            result <- mc ("mc --json stat --no-list " ++ bucketObject) ByteString.empty
            pure $ case result of
              Right (1, out, _) | missingUnlockObject out -> BundleAbsent
              _ -> BundleUnobservable
      putBundle bytes = do
        -- A known-size copy from a file: `mc pipe` of a stream of unknown length
        -- allocates a part-sized buffer and was OOM-killed at the Pod's limit.
        stored <-
          mc
            ( "umask 077; cat > /tmp/object-upload && mc cp /tmp/object-upload "
                ++ bucketObject
                ++ " >/dev/null; code=$?; rm -f /tmp/object-upload; exit $code"
            )
            bytes
        case stored of
          Right (0, _, _) -> do
            back <- fetchBundle
            pure (back == Right bytes)
          _ -> pure False
      unseal key = do
        result <- exec "vault" (vaultEnv ++ ["vault", "write", "sys/unseal", "key=-"]) key
        pure $ case result of
          Right (0, _, _) -> Right ()
          Right (code, _, _) -> Left ("unseal exit " ++ show code)
          Left failure -> Left failure
      roundTrip token = do
        marker <- withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 12)
        let value = take 24 (ByteString8.unpack (hexSha256 marker))
            script =
              "read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; "
                ++ "vault secrets enable -path=secret kv-v2 >/dev/null 2>&1; "
                ++ "vault kv put -mount=secret phase2/roundtrip marker="
                ++ value
                ++ " >/dev/null && vault kv get -mount=secret -field=marker phase2/roundtrip"
        result <- exec "vault" ["/bin/sh", "-c", script] (ByteString8.pack (Text.unpack token ++ "\n"))
        pure $ case result of
          Right (0, out, _)
            | ByteString8.unpack out == value ->
                step
                  "secret-roundtrip"
                  True
                  "an authenticated write and read of a fresh marker returned the same value"
          Right (code, _, _) -> step "secret-roundtrip" False ("round trip failed (exit " ++ show code ++ ")")
          Left failure -> step "secret-roundtrip" False failure
  let mintClient rootToken = do
        let script =
              "read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; "
                ++ "vault secrets enable -path=secret kv-v2 >/dev/null 2>&1; "
                ++ "printf 'path \"secret/*\" {capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"]}\\n' "
                ++ "| vault policy write phase2-client - >/dev/null && "
                ++ "T=$(vault token create -orphan -policy=phase2-client -period=768h -field=token) && "
                ++ "vault token revoke -self >/dev/null && printf %s \"$T\""
        result <- exec "vault" ["/bin/sh", "-c", script] (ByteString8.pack (Text.unpack rootToken ++ "\n"))
        pure $ case result of
          Right (0, out, _) | not (ByteString.null out) -> Right (Text.pack (ByteString8.unpack out))
          Right (code, _, _) -> Left ("client token not minted (exit " ++ show code ++ ")")
          Left failure -> Left failure
  present <- bound
  if not present
    then
      pure
        ( UnlockOutcome
            [ policyStep
            , step
                "environment"
                False
                "no installed cluster credential; run `control reconcile` and `control services` first"
            ]
        )
    else do
      state <- stateOf
      bucket <- mc "mc mb --ignore-existing local/prodbox-bootstrap >/dev/null" ByteString.empty
      let bucketStep = case bucket of
            Right (0, _, _) -> step "unlock-bucket" True "the unlock bucket exists in this environment's MinIO"
            Right (code, _, err) -> step "unlock-bucket" False ("mc exit " ++ show code ++ ": " ++ take 120 err)
            Left failure -> step "unlock-bucket" False failure
          stateStep = case state of
            VaultUnobservable reason -> step "vault-state" False reason
            VaultUninitialized -> step "vault-state" True "initialized=false"
            VaultSealed -> step "vault-state" True "initialized=true sealed=true"
            VaultUnsealed -> step "vault-state" True "initialized=true sealed=false"
          early = [policyStep, stateStep, bucketStep]
      if not (unlockStepOk stateStep && unlockStepOk bucketStep)
        then pure (UnlockOutcome early)
        else do
          existing <- observeBundle
          pending <- observePending bootstrap
          let pendingExists = case pending of
                PendingAbsent -> False
                _ -> True
              initRecord =
                Aeson.object
                  [ "schema_version" .= (1 :: Int)
                  , "scope" .= scopeName
                  , "root_generation" .= generation
                  ]
              reserveInitialization = do
                previous <- observeJournalRecord bootstrap initializationRecordName
                permitted <- bound
                if previous /= JournalRecordMissing || not permitted
                  then pure False
                  else do
                    written <- writeJournalRecord bootstrap initializationRecordName initRecord
                    found <- observeJournalRecord bootstrap initializationRecordName
                    stillBound <- bound
                    pure (written && found == JournalRecordObserved initRecord && stillBound)
              mintAndStore bundle0 rootCredential = do
                minted <- mintClient rootCredential
                case minted of
                  Left failure -> pure (step "client-token" False failure, Nothing)
                  Right clientToken -> do
                    recorded <- putBundle (bundleBytes bundle0 {bundleToken = clientToken})
                    pure
                      ( step
                          "client-token"
                          recorded
                          ( if recorded
                              then
                                "a limited client token was minted, the initial root token revoked, and the token recorded without it"
                              else "the limited client token could not be recorded"
                          )
                      , if recorded then Just clientToken else Nothing
                      )
              initialise prior = do
                initialised <-
                  exec
                    "vault"
                    (vaultEnv ++ ["vault", "operator", "init", "-key-shares=1", "-key-threshold=1", "-format=json"])
                    ByteString.empty
                case initialised of
                  Right (0, out, _) -> case parseInit out of
                    Nothing ->
                      pure
                        ( UnlockOutcome
                            (prior ++ [step "init" False "Vault initialized but its answer could not be read; recovery required"])
                        )
                    Just (key, rootToken) -> do
                      let bundle = Bundle scopeName generation key "" ""
                          privatePending = Bundle scopeName generation key "" rootToken
                      written <- recordPending bootstrap privatePending
                      stored <- if written then putBundle (bundleBytes bundle) else pure False
                      let custodyStep =
                            step
                              "unlock-object"
                              stored
                              ( if stored
                                  then "the unlock bundle was written to this environment's MinIO and read back identical"
                                  else "durable unlock custody was not confirmed; recover the retained Vault initialization"
                              )
                      unsealed <- if stored then unseal (ByteString8.pack (Text.unpack key)) else pure (Left "skipped")
                      let unsealStep = step "unseal" (unsealed == Right ()) (fromLeft "Vault unsealed" unsealed)
                      (mintStep, clientToken) <-
                        if unsealed == Right ()
                          then mintAndStore bundle rootToken
                          else pure (step "client-token" False "skipped", Nothing)
                      trip <- maybe (pure (step "secret-roundtrip" False "skipped")) roundTrip clientToken
                      settlement <- settlePending trip
                      pure
                        ( UnlockOutcome
                            ( prior
                                ++ [ step "init" True "Vault initialized once with one key share"
                                   , custodyStep
                                   , unsealStep
                                   , mintStep
                                   , trip
                                   ]
                                ++ settlement
                            )
                        )
                  Right (code, _, _) ->
                    pure
                      ( UnlockOutcome
                          ( prior
                              ++ [ step
                                     "init"
                                     False
                                     ("init exit " ++ show code ++ "; keep the retained initialization intent for recovery")
                                 ]
                          )
                      )
                  Left failure -> pure (UnlockOutcome (prior ++ [step "init" False failure]))
              settlePending trip =
                if unlockStepOk trip
                  then do
                    retired <- retirePending bootstrap
                    after <- observePending bootstrap
                    pure
                      [ case after of
                          PendingAbsent
                            | retired ->
                                step
                                  "pending-custody"
                                  True
                                  "the temporary local custody was retired after proving the limited client"
                          _ -> step "pending-custody" False "retirement of temporary local custody could not be verified"
                      ]
                  else
                    pure [step "pending-custody" False "the retained local custody requires recovery before retirement"]
              continuePending needsUnseal pendingBundle
                | bundleScope pendingBundle /= scopeName || bundleGeneration pendingBundle /= generation =
                    pure
                      ( UnlockOutcome
                          ( early
                              ++ [ step
                                     "unlock-object"
                                     False
                                     "the pending record names another environment or root generation; it was not used"
                                 ]
                          )
                      )
                | otherwise = do
                    let publicContent = bundleBytes pendingBundle {bundleRoot = ""}
                        rootFromPending = if Text.null (bundleRoot pendingBundle) then Nothing else Just (bundleRoot pendingBundle)
                    stored <- putBundle publicContent
                    if stored
                      then
                        useBundle
                          ( early
                              ++ [ step
                                     "unlock-object"
                                     True
                                     "an interrupted upload was continued from the private pending record and read back identical"
                                 ]
                          )
                          publicContent
                          needsUnseal
                          rootFromPending
                      else
                        pure
                          ( UnlockOutcome
                              (early ++ [step "unlock-object" False "the pending record could not be stored; it is kept"])
                          )
              useBundle prior bytes needsUnseal mintFrom = case parseBundle bytes of
                Nothing ->
                  pure
                    (UnlockOutcome (prior ++ [step "unlock-object" False "the unlock object is not a valid bundle"]))
                Just bundle
                  | not (Text.null (bundleRoot bundle)) ->
                      pure
                        ( UnlockOutcome
                            ( prior
                                ++ [ step "unlock-object" False "the MinIO object contains unexpected private custody; recovery required"
                                   ]
                            )
                        )
                  | bundleScope bundle /= scopeName || bundleGeneration bundle /= generation ->
                      pure
                        ( UnlockOutcome
                            ( prior
                                ++ [ step
                                       "unlock-object"
                                       False
                                       "the unlock object names another environment or root generation; it was not used"
                                   ]
                            )
                        )
                  | otherwise -> do
                      unsealed <-
                        if needsUnseal
                          then unseal (ByteString8.pack (Text.unpack (bundleKey bundle)))
                          else pure (Right ())
                      let unsealStep =
                            step
                              "unseal"
                              (unsealed == Right ())
                              ( if needsUnseal
                                  then fromLeft "Vault self-unsealed from this environment's unlock object" unsealed
                                  else "Vault was already unsealed"
                              )
                      (mintSteps, clientToken) <- case (unsealed == Right (), mintFrom) of
                        (True, Just rootCredential) -> do
                          (mintStep, minted) <- mintAndStore bundle rootCredential
                          pure ([mintStep], minted)
                        (True, Nothing)
                          | Text.null (bundleToken bundle) -> pure ([], Nothing)
                          | otherwise -> pure ([], Just (bundleToken bundle))
                        _ -> pure ([], Nothing)
                      trip <-
                        if unsealed == Right ()
                          then
                            maybe
                              (pure (step "secret-roundtrip" False "no client token is recorded for this environment"))
                              roundTrip
                              clientToken
                          else pure (step "secret-roundtrip" False "skipped")
                      settlement <- if pendingExists then settlePending trip else pure []
                      pure
                        ( UnlockOutcome
                            ( prior
                                ++ [ step "unlock-object" True "the unlock object matches this environment and root generation"
                                   , unsealStep
                                   ]
                                ++ mintSteps
                                ++ [ trip
                                   ]
                                ++ settlement
                            )
                        )
              parseInit out = do
                value <- Aeson.decodeStrict out
                AesonTypes.parseMaybe
                  ( Aeson.withObject "init" $ \object -> do
                      keys <- object .: Key.fromString "unseal_keys_b64"
                      token <- object .: Key.fromString "root_token"
                      case keys of
                        [key] -> pure (key, token)
                        _ -> fail "unexpected key count"
                  )
                  value
          let refuseObject =
                UnlockOutcome
                  ( early
                      ++ [ step "unlock-object" False "the exact MinIO unlock object could not be observed; recovery required"
                         ]
                  )
              refusePending =
                UnlockOutcome
                  ( early
                      ++ [ step
                             "unlock-object"
                             False
                             "the pending record is unreadable or disagrees with the unlock object; recovery required"
                         ]
                  )
              refuseInitialization reason = UnlockOutcome (early ++ [step "refused" False reason])
              initializeObserved objectPresent
                | initialisationAllowed state objectPresent pendingExists = do
                    reserved <- reserveInitialization
                    if reserved
                      then initialise early
                      else
                        pure
                          ( refuseInitialization
                              "this retained deployment has prior Vault initialization history or the intent could not be recorded; recover the original Vault storage"
                          )
                | objectPresent =
                    pure
                      ( refuseInitialization
                          "an unlock object exists but this Vault is not initialized: the storage identity disagrees; it will not be initialized over it"
                      )
                | otherwise =
                    pure
                      ( refuseInitialization
                          "a pending unlock record exists but Vault is not initialized: foreign retained state; it will not be initialized"
                      )
              recover needsUnseal = case (existing, pending) of
                (_, PendingUnobservable) -> pure refusePending
                (BundleUnobservable, _) -> pure refuseObject
                (BundleAbsent, PendingPresent bundle) -> continuePending needsUnseal bundle
                (BundlePresent bytes, PendingPresent private) -> case parseBundle bytes of
                  Just public
                    | bundleScope private == bundleScope public
                    , bundleGeneration private == bundleGeneration public
                    , bundleKey private == bundleKey public ->
                        let credential =
                              if Text.null (bundleToken public) && not (Text.null (bundleRoot private))
                                then Just (bundleRoot private)
                                else Nothing
                         in useBundle early bytes needsUnseal credential
                  _ -> pure refusePending
                (BundlePresent bytes, PendingAbsent) -> useBundle early bytes needsUnseal Nothing
                (BundleAbsent, PendingAbsent) ->
                  pure
                    ( refuseInitialization
                        "Vault is initialized but no unlock object or pending record exists: this is a data-loss condition; it will not be re-initialized"
                    )
          case state of
            VaultUnobservable _ -> pure (UnlockOutcome early)
            VaultUninitialized -> case existing of
              BundlePresent _ -> initializeObserved True
              BundleAbsent -> initializeObserved False
              BundleUnobservable -> pure refuseObject
            VaultSealed -> recover True
            VaultUnsealed -> recover False
