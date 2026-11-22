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
import Control.Exception (IOException, try)
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
  , scopeRoot
  )
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Directory (doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode, WriteMode), withBinaryFile)
import System.Posix.Files (setFileMode)

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
readerObject = "reader/prodbox-bootstrap/vault-unlock-test.json"

bucketObject :: String
bucketObject = "local/prodbox-bootstrap/vault-unlock-test.json"

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
      let root = scopeRoot scope
          kubeconfig = root </> "control" </> "kubeconfig"
          pendingPath = root </> "control" </> "vault-unlock-pending.json"
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
              Right (code, _, err) -> Left ("unseal exit " ++ show code ++ ": " ++ take 160 (filter (/= '\n') err))
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
              Right (code, _, err) -> step "secret-roundtrip" False ("round trip failed (exit " ++ show code ++ "): " ++ take 120 err)
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
              Right (code, _, err) -> Left ("client token not minted (exit " ++ show code ++ "): " ++ take 120 err)
              Left failure -> Left failure
      present <- doesFileExist kubeconfig
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
              existing <- fetchBundle
              pendingExists <- doesFileExist pendingPath
              -- local procedures
              let mintAndStore bundle0 rootCredential = do
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
                          written <-
                            try
                              ( withBinaryFile
                                  pendingPath
                                  WriteMode
                                  (\handle -> ByteString.hPut handle (bundleBytes privatePending))
                              )
                              :: IO (Either IOException ())
                          _ <- try (setFileMode pendingPath 0o600) :: IO (Either IOException ())
                          stored <- putBundle (bundleBytes bundle)
                          cleared <-
                            if stored then try (removeFile pendingPath) else pure (Right ()) :: IO (Either IOException ())
                          let custodyStep =
                                step
                                  "unlock-object"
                                  (stored && either (const False) (const True) written)
                                  ( if stored
                                      then
                                        "the unlock bundle was written to this environment's MinIO and read back identical; the private pending record was "
                                          ++ either (const "left for continuation") (const "removed") cleared
                                      else "the unlock object was not confirmed; the private pending record is kept so a rerun continues"
                                  )
                          unsealed <- if stored then unseal (ByteString8.pack (Text.unpack key)) else pure (Left "skipped")
                          let unsealStep = step "unseal" (unsealed == Right ()) (fromLeft "Vault unsealed" unsealed)
                          (mintStep, clientToken) <-
                            if unsealed == Right ()
                              then mintAndStore bundle rootToken
                              else pure (step "client-token" False "skipped", Nothing)
                          trip <- maybe (pure (step "secret-roundtrip" False "skipped")) roundTrip clientToken
                          pure
                            ( UnlockOutcome
                                ( prior
                                    ++ [ step "init" True "Vault initialized once with one key share"
                                       , custodyStep
                                       , unsealStep
                                       , mintStep
                                       , trip
                                       ]
                                )
                            )
                      Right (code, _, err) ->
                        pure
                          (UnlockOutcome (prior ++ [step "init" False ("init exit " ++ show code ++ ": " ++ take 120 err)]))
                      Left failure -> pure (UnlockOutcome (prior ++ [step "init" False failure]))
                  continuePending prior = do
                    bytes <-
                      try (withBinaryFile pendingPath ReadMode ByteString.hGetContents)
                        :: IO (Either IOException ByteString.ByteString)
                    case bytes of
                      Right content | Just pendingBundle <- parseBundle content -> do
                        let publicContent = bundleBytes pendingBundle {bundleRoot = ""}
                            rootFromPending = if Text.null (bundleRoot pendingBundle) then Nothing else Just (bundleRoot pendingBundle)
                        stored <- putBundle publicContent
                        if stored
                          then do
                            _ <- try (removeFile pendingPath) :: IO (Either IOException ())
                            useBundle
                              ( prior
                                  ++ [ step
                                         "unlock-object"
                                         True
                                         "an interrupted upload was continued from the private pending record and read back identical"
                                     ]
                              )
                              publicContent
                              True
                              rootFromPending
                          else
                            pure
                              ( UnlockOutcome
                                  (prior ++ [step "unlock-object" False "the pending record could not be stored; it is kept"])
                              )
                      _ ->
                        pure
                          ( UnlockOutcome
                              (prior ++ [step "unlock-object" False "the pending record is unreadable; recovery required"])
                          )
                  useBundle prior bytes needsUnseal mintFrom = case parseBundle bytes of
                    Nothing ->
                      pure
                        (UnlockOutcome (prior ++ [step "unlock-object" False "the unlock object is not a valid bundle"]))
                    Just bundle
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
                          pure
                            ( UnlockOutcome
                                ( prior
                                    ++ [ step "unlock-object" True "the unlock object matches this environment and root generation"
                                       , unsealStep
                                       ]
                                    ++ mintSteps
                                    ++ [ trip
                                       ]
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
              case state of
                VaultUnobservable _ -> pure (UnlockOutcome early)
                VaultUninitialized -> case (existing, pendingExists) of
                  (Right _, _) ->
                    pure
                      ( UnlockOutcome
                          ( early
                              ++ [ step
                                     "refused"
                                     False
                                     "an unlock object exists but this Vault is not initialized: the storage identity disagrees; it will not be initialized over it"
                                 ]
                          )
                      )
                  (_, True) ->
                    pure
                      ( UnlockOutcome
                          ( early
                              ++ [ step
                                     "refused"
                                     False
                                     "a pending unlock record exists but Vault is not initialized: foreign retained state; it will not be initialized"
                                 ]
                          )
                      )
                  _
                    | initialisationAllowed state (either (const False) (const True) existing) pendingExists ->
                        initialise early
                    | otherwise ->
                        pure (UnlockOutcome (early ++ [step "refused" False "initialization is not allowed in this state"]))
                VaultSealed -> case existing of
                  Right bytes -> useBundle early bytes True Nothing
                  Left _
                    | pendingExists -> continuePending early
                    | otherwise ->
                        pure
                          ( UnlockOutcome
                              ( early
                                  ++ [ step
                                         "recovery-required"
                                         False
                                         "Vault is initialized and sealed but no unlock object or pending record exists: this is a data-loss condition; it will not be re-initialized"
                                     ]
                              )
                          )
                VaultUnsealed -> case existing of
                  Right bytes -> useBundle early bytes False Nothing
                  Left _ ->
                    pure
                      ( UnlockOutcome
                          ( early
                              ++ [step "unlock-object" False "Vault is unsealed but no unlock object is available to prove access"]
                          )
                      )
