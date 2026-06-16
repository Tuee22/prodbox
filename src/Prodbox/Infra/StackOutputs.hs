{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.16: source-of-truth Pulumi stack query surface.
--
-- Replaces the file-existence snapshot cache as the authoritative
-- answer to \"is stack X present in its backend?\" and
-- \"what outputs did stack X produce?\". Per
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md § 3@,
-- the snapshot file under
-- @.prodbox-state\/\<stack>\/stack-snapshot.json@ was a
-- doctrine-violating predicate proxy because it could drift from the
-- real backend after manual @pulumi destroy@ runs, operator-machine
-- moves, or any failure mode that left the file behind while the
-- backend no longer carried the stack. This module talks to the
-- backend through the Sprint 7.14 encrypted decrypt-to-scratch helpers.
-- The raw @listStacks@ / @fetchOutputs@ functions remain for compatibility
-- and migration code that already holds an explicit @file://@ or legacy
-- backend environment.
--
-- The encrypted helpers own the supported production path: they hydrate
-- a checkpoint into a RAM-backed @file://@ backend, run Pulumi there, and
-- persist only the re-enveloped Model-B object-store body.
module Prodbox.Infra.StackOutputs
  ( StackName (..)
  , StackOutputsError (..)
  , StackListEntry (..)
  , renderStackOutputsError
  , listStacks
  , listEncryptedStack
  , parseListStacksPayload
  , stackPresentInList
  , stackListFromCheckpointPresence
  , fetchOutputs
  , fetchEncryptedOutputs
  , parseOutputsPayload
  )
where

import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError
  , PulumiScratch
  , PulumiStackRef (..)
  , fileBackendEnvironment
  , pulumiScratchCheckpointPath
  , renderEncryptedBackendError
  , withDecryptedStack
  )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))

-- | Canonical Pulumi stack name. Wrapped to keep call sites from
-- accidentally passing project directories or backend URLs where a
-- stack name is required.
newtype StackName = StackName {unStackName :: Text}
  deriving (Eq, Ord, Show)

-- | One entry from @pulumi stack ls --json@. We retain only the
-- fields this module currently uses; additional fields can be added
-- when callers need them.
data StackListEntry = StackListEntry
  { stackListEntryName :: !Text
  -- ^ Pulumi stack name. May be qualified (for example
  -- @organization\/project\/stack@) depending on the Pulumi version
  -- and backend; use 'stackPresentInList' when matching by short
  -- name.
  , stackListEntryCurrent :: !Bool
  -- ^ Whether this is the currently-selected stack in the working
  -- directory.
  }
  deriving (Eq, Show)

-- | Structured failure modes for the two pulumi shell-outs. Each
-- constructor carries the operator-visible detail so the caller's
-- error rendering does not have to re-derive context.
data StackOutputsError
  = -- | @pulumi@ could not be invoked at all (binary missing, fork
    -- failure, etc.).
    StackOutputsSubprocessFailed !String
  | -- | @pulumi@ ran but exited non-zero. The 'String' carries the
    -- combined stderr \/ stdout for the operator.
    StackOutputsCommandFailed !String
  | -- | @pulumi@ ran and exited zero, but the JSON output failed to
    -- decode. The 'String' carries the JSON parser error.
    StackOutputsParseFailed !String
  deriving (Eq, Show)

renderStackOutputsError :: StackOutputsError -> String
renderStackOutputsError err = case err of
  StackOutputsSubprocessFailed detail ->
    "failed to start `pulumi`: " ++ detail
  StackOutputsCommandFailed detail ->
    "`pulumi` exited non-zero: " ++ detail
  StackOutputsParseFailed detail ->
    "failed to parse pulumi JSON output: " ++ detail

-- | Legacy/migration helper: run @pulumi stack ls --json@ inside the supplied project directory
-- with the supplied environment (which must carry
-- @PULUMI_BACKEND_URL@ and any credentials the backend requires).
-- Returns the list of stacks the backend currently reports. An empty
-- list means the project is registered with the backend but has no
-- stacks yet; 'StackOutputsCommandFailed' means the backend itself
-- could not be reached or denied the listing.
listStacks
  :: FilePath
  -- ^ Working directory: the per-stack Pulumi project root
  -- (for example @pulumi\/aws-eks@).
  -> [(String, String)]
  -- ^ Environment for the @pulumi@ subprocess. Must include
  -- @PULUMI_BACKEND_URL@ and the credentials the backend needs.
  -> IO (Either StackOutputsError [StackListEntry])
listStacks projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["stack", "ls", "--json"]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $ case result of
    Failure detail -> Left (StackOutputsSubprocessFailed detail)
    Success output ->
      case processExitCode output of
        ExitFailure _ -> Left (StackOutputsCommandFailed (renderProcessTail output))
        ExitSuccess -> case parseListStacksPayload (processStdout output) of
          Left detail -> Left (StackOutputsParseFailed detail)
          Right entries -> Right entries

-- | Production Sprint 7.14 listing path. A stack is present when the
-- Vault-encrypted Model-B object-store can decrypt its checkpoint into
-- the scratch file backend. This avoids raw @pulumi stack ls@ against
-- MinIO/S3 object names.
listEncryptedStack
  :: FilePath
  -- ^ Repo root.
  -> PulumiStackRef
  -- ^ Pulumi project name + stack id.
  -> IO (Either StackOutputsError [StackListEntry])
listEncryptedStack repoRoot stackRef = do
  result <-
    withDecryptedStack repoRoot stackRef $ \scratch -> do
      checkpointExists <- doesFileExist (pulumiScratchCheckpointPath scratch)
      pure
        ( Right
            ( stackListFromCheckpointPresence
                (StackName (pulumiStackName stackRef))
                checkpointExists
            )
        )
  pure (mapEncryptedBackendResult result)

stackListFromCheckpointPresence :: StackName -> Bool -> [StackListEntry]
stackListFromCheckpointPresence (StackName name) present
  | present =
      [ StackListEntry
          { stackListEntryName = name
          , stackListEntryCurrent = True
          }
      ]
  | otherwise = []

-- | Pure parser for @pulumi stack ls --json@ output. Exposed so the
-- unit suite can pin the wire shape without forcing a live pulumi
-- round-trip.
parseListStacksPayload :: String -> Either String [StackListEntry]
parseListStacksPayload payload =
  case eitherDecode (BL8.pack payload) of
    Left detail -> Left detail
    Right value -> case value of
      Array entries -> Right (foldr decodeEntry [] entries)
      _ -> Left "pulumi stack ls payload must be a JSON array"
 where
  decodeEntry :: Value -> [StackListEntry] -> [StackListEntry]
  decodeEntry (Object obj) acc =
    case KeyMap.lookup (Key.fromString "name") obj of
      Just (String nameText) ->
        let current = case KeyMap.lookup (Key.fromString "current") obj of
              Just (Bool b) -> b
              _ -> False
         in StackListEntry
              { stackListEntryName = nameText
              , stackListEntryCurrent = current
              }
              : acc
      _ -> acc
  decodeEntry _ acc = acc

-- | True when any entry in the listing matches the short stack name
-- (suffix-aware: matches both bare @aws-eks@ and the
-- @organization\/project\/aws-eks@ qualified form some Pulumi
-- versions emit).
stackPresentInList :: StackName -> [StackListEntry] -> Bool
stackPresentInList (StackName name) entries =
  any matches entries
 where
  needle = "/" ++ Text.unpack name
  matches entry =
    let candidate = Text.unpack (stackListEntryName entry)
     in candidate == Text.unpack name || needle `isSuffixOf` candidate

-- | Legacy/migration helper: run @pulumi stack output --show-secrets --json --stack <name>@
-- inside the supplied project directory. Returns the decoded
-- top-level outputs as a @Map@ from output name to its rendered value
-- (strings stay as strings; non-string outputs are re-encoded to
-- compact JSON so the caller has a single textual surface to
-- consume).
fetchOutputs
  :: FilePath
  -- ^ Working directory: the per-stack Pulumi project root.
  -> [(String, String)]
  -- ^ Environment for the @pulumi@ subprocess (carries
  -- @PULUMI_BACKEND_URL@ and credentials).
  -> StackName
  -- ^ Stack to query.
  -> IO (Either StackOutputsError (Map Text Text))
fetchOutputs projectDir environment (StackName name) = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments =
            [ "stack"
            , "output"
            , "--show-secrets"
            , "--json"
            , "--stack"
            , Text.unpack name
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $ case result of
    Failure detail -> Left (StackOutputsSubprocessFailed detail)
    Success output ->
      case processExitCode output of
        ExitFailure _ -> Left (StackOutputsCommandFailed (renderProcessTail output))
        ExitSuccess -> case parseOutputsPayload (processStdout output) of
          Left detail -> Left (StackOutputsParseFailed detail)
          Right outputs -> Right outputs

-- | Production Sprint 7.14 output path. Hydrates the encrypted checkpoint
-- into a scratch @file://@ backend, runs Pulumi's read-only output command
-- there, then lets 'withDecryptedStack' re-envelope the resulting checkpoint
-- back to the Model-B object-store.
fetchEncryptedOutputs
  :: FilePath
  -- ^ Repo root.
  -> FilePath
  -- ^ Working directory: the per-stack Pulumi project root.
  -> PulumiStackRef
  -- ^ Pulumi project name + stack id.
  -> IO (Either StackOutputsError (Map Text Text))
fetchEncryptedOutputs repoRoot projectDir stackRef = do
  result <-
    withDecryptedStack repoRoot stackRef $ \scratch -> do
      checkpointExists <- doesFileExist (pulumiScratchCheckpointPath scratch)
      if not checkpointExists
        then
          pure
            ( Right
                ( Left
                    ( StackOutputsCommandFailed
                        ("encrypted Pulumi checkpoint is absent for stack " ++ Text.unpack (pulumiStackName stackRef))
                    )
                )
            )
        else do
          environment <- encryptedPulumiReadEnv scratch
          loginResult <- loginFileBackend projectDir environment
          case loginResult of
            Left err -> pure (Right (Left err))
            Right () ->
              Right
                <$> fetchOutputs
                  projectDir
                  environment
                  (StackName (pulumiStackName stackRef))
  pure $
    case mapEncryptedBackendResult result of
      Left err -> Left err
      Right outputs -> outputs

encryptedPulumiReadEnv :: PulumiScratch -> IO [(String, String)]
encryptedPulumiReadEnv scratch = do
  currentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" currentEnv)
      home = maybe "" id (lookup "HOME" currentEnv)
  pure
    ( fileBackendEnvironment
        scratch
        [ ("PULUMI_SKIP_UPDATE_CHECK", "true")
        , ("PATH", path)
        , ("HOME", home)
        , ("LANG", "C.UTF-8")
        ]
    )

loginFileBackend :: FilePath -> [(String, String)] -> IO (Either StackOutputsError ())
loginFileBackend projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $ case result of
    Failure detail -> Left (StackOutputsSubprocessFailed detail)
    Success output ->
      case processExitCode output of
        ExitFailure _ -> Left (StackOutputsCommandFailed (renderProcessTail output))
        ExitSuccess -> Right ()

mapEncryptedBackendResult
  :: Either EncryptedBackendError a
  -> Either StackOutputsError a
mapEncryptedBackendResult result = case result of
  Left err -> Left (StackOutputsCommandFailed (renderEncryptedBackendError err))
  Right value -> Right value

-- | Pure parser for @pulumi stack output --json@. The decoded top
-- level is a JSON object; string values are passed through verbatim,
-- and non-string values are re-encoded compactly so callers always
-- see 'Text'. Exposed so the unit suite can pin the wire shape.
parseOutputsPayload :: String -> Either String (Map Text Text)
parseOutputsPayload payload =
  case eitherDecode (BL8.pack payload) of
    Left detail -> Left detail
    Right value -> case value of
      Object obj ->
        Right
          ( KeyMap.foldrWithKey
              (\key entry acc -> Map.insert (Key.toText key) (renderOutput entry) acc)
              Map.empty
              obj
          )
      Null -> Right Map.empty
      _ -> Left "pulumi stack output payload must be a JSON object"

renderOutput :: Value -> Text
renderOutput value = case value of
  String text -> text
  Null -> ""
  other -> Text.pack (BL8.unpack (encode other))

renderProcessTail :: ProcessOutput -> String
renderProcessTail output =
  let stderrText = processStderr output
      stdoutText = processStdout output
      joiner = if null stderrText || null stdoutText then "" else "\n"
   in trim (stderrText ++ joiner ++ stdoutText)

trim :: String -> String
trim = reverse . dropWhile isWs . reverse . dropWhile isWs
 where
  isWs c = c == '\n' || c == '\r' || c == ' ' || c == '\t'
