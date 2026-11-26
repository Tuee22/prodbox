{-# LANGUAGE OverloadedStrings #-}

-- | The host's question to the Lifecycle Authority: what is this deployment's
-- admission verdict. When an Authority is deployed, the answer comes from the
-- Authority itself through its narrow journal read, over a loopback-only
-- port-forward, with a short-lived ServiceAccount token whose audience and
-- identity are that capability's own (the established local/control identity:
-- it needs the control kubeconfig and no Vault login). A deployed Authority that
-- cannot be asked is "recovery required", never absent and never fresh; no local
-- file is substituted for it. A failed deployment observation also refuses;
-- a retained Authority journal prevents fallback when the service is absent.
-- Only a successfully observed absent service without retained Authority state
-- (or a pre-Authority root without a kubeconfig) permits the local journal.
module Prodbox.Control.AuthorityJournalClient
  ( AdmissionSource (..)
  , decodeAuthorityAdmission
  , currentAdmission
  , currentAuthorityInitialization
  , admitKindTeardown
  , observeKindTeardownAdmissionUnderLease
  , AuthorityRemovalObservation (..)
  , observeAuthorityRemoval
  , withBoundAuthorityRemoval
  , authorityRemovalValue
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, displayException, try)
import Control.Monad (join)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client
  ( HttpException
  , Manager
  , Request (..)
  , defaultManagerSettings
  , httpLbs
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Types.Status (statusCode)
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeKindName
  , scopeKubeconfig
  , scopeRoot
  , validRootGeneration
  )
import Prodbox.Control.AuthorityDeploy
  ( RetainedAuthorityJournal (..)
  , authorityNamespace
  , observeRetainedAuthorityJournal
  , retainedAuthorityCustody
  )
import Prodbox.Control.JournalStore (journalDirectory, observeJournal)
import Prodbox.Control.KindArchiveTransaction (observeActiveAuthorityFence)
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches, KindIntentMissing)
  , KindIntentResult (KindIntentRecorded)
  , observeKindOwnerFamilyIntent
  , observeKindTeardownAdmission
  , recordKindTeardownAdmission
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshot)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (KindOperationCallbackReturned)
  , withRecoveredKindOperation
  )
import Prodbox.Control.ManagementRestore (managementRestoreIdle)
import Prodbox.Control.ServiceSupport (run)
import Prodbox.ControlPlane.AdmissionJournalMirror
  ( JournalInitialization (..)
  , JournalRemovalFence (..)
  , observeJournalRemovalFence
  , recordJournalRemovalFence
  , withJournalCustodyLease
  )
import Prodbox.ControlPlane.AuthorityJournalReadServer
  ( journalReadAudience
  , journalReadServiceAccount
  )
import Prodbox.Error (AppError)
import Prodbox.Lifecycle.AdmissionHistory
  ( AdmissionVerdict (..)
  , RecoveryReason (..)
  , classifyAdmission
  , renderVerdict
  )
import Prodbox.Subprocess
  ( BackgroundProcess
  , Subprocess (..)
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getSymbolicLinkStatus)
import System.Posix.Types (Fd)

data AdmissionSource
  = -- | The time at which the Authority read its journal.
    FromAuthority !Text
  | FromLocalControlJournal
  deriving (Eq, Show)

-- | The verdict and where it came from.
currentAdmission :: BootstrapProjection -> IO (AdmissionVerdict, AdmissionSource)
currentAdmission bootstrap = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      kubeconfig = scopeKubeconfig scope
  kubeconfigPresence <- pathPresence kubeconfig
  retained <- observeRetainedAuthorityJournal bootstrap
  answer <- case (kubeconfigPresence, retained) of
    (Right True, RetainedAuthorityJournalBound) -> query root scope retained
    (Right True, RetainedAuthorityJournalAbsent) -> query root scope retained
    (Right False, RetainedAuthorityJournalAbsent) ->
      currentAdmissionObserved root (Text.pack (scopeKindName scope)) Nothing retained
    (Right False, RetainedAuthorityJournalBound) -> pure unavailable
    (_, RetainedAuthorityJournalReserved) -> pure unavailable
    _ ->
      pure
        (admissionOutcome (Left "the control identity or retained Authority state could not be confirmed"))
  closing <- observeRetainedAuthorityJournal bootstrap
  pure $
    if closing == retained
      then answer
      else admissionOutcome (Left "the retained Authority journal changed during the observation")
 where
  unavailable = admissionOutcome (Left "the retained Authority journal exists but the Authority is unavailable")
  query root scope retained = do
    observed <- withKindKubeconfigSnapshot bootstrap $ \snapshot ->
      currentAdmissionObserved root (Text.pack (scopeKindName scope)) (Just snapshot) retained
    pure $ case observed of
      Right result -> result
      Left _ -> admissionOutcome (Left "the selected control kubeconfig was refused")

currentAuthorityInitialization :: BootstrapProjection -> IO (Either String JournalInitialization)
currentAuthorityInitialization bootstrap = do
  retained <- observeRetainedAuthorityJournal bootstrap
  result <- case retained of
    RetainedAuthorityJournalAbsent -> pure (Right JournalInitializationLegacy)
    RetainedAuthorityJournalBound -> do
      queried <- withKindKubeconfigSnapshot bootstrap $ \snapshot ->
        askAuthority snapshot (decodeInitialization cluster)
      pure (either (const (Left "the selected control kubeconfig was refused")) id queried)
    _ -> pure (Left "the retained Authority journal binding is unconfirmed")
  closing <- observeRetainedAuthorityJournal bootstrap
  pure $
    if retained == closing
      then result
      else Left "the retained Authority journal changed during the initialization observation"
 where
  cluster = Text.pack (scopeKindName (bootstrapScope bootstrap))

-- The early test-only lane may continue when its control API has gone away.
-- Its write-ahead decision and the Authority deployer share the kind lease.
-- An older operation without the record still needs live admission.
admitKindTeardown :: BootstrapProjection -> IO (Either String ())
admitKindTeardown bootstrap
  | scopeEnvironment scope /= Test = pure (Left "early control removal requires a test identity")
  | otherwise = do
      intent <- observeKindOwnerFamilyIntent bootstrap
      case intent of
        KindIntentMatches operation -> do
          outcome <- withRecoveredKindOperation bootstrap operation (admitOwner operation)
          pure $ case outcome of
            KindOperationCallbackReturned decision -> decision
            _ -> Left "the kind operation lease or scope is unconfirmed"
        _ -> do
          checkpoint <- observeKindTeardownAdmission bootstrap
          idle <- managementRestoreIdle bootstrap
          case (checkpoint, idle) of
            (KindIntentMissing, True) -> liveAdmission
            (_, False) -> pure (Left "the retained management restore requires settlement before control removal")
            _ -> pure (Left "the retained teardown decision has no matching owner-family operation")
 where
  scope = bootstrapScope bootstrap
  liveAdmission = do
    (verdict, source) <- currentAdmission bootstrap
    pure $ case source of
      FromLocalControlJournal -> admissionDecision verdict
      FromAuthority _ ->
        Left
          ("an Authority-backed removal needs the original retained kind operation. " ++ renderVerdict verdict)
  admissionDecision verdict
    | verdict == NeverAdmitted = Right ()
    | otherwise = Left (renderVerdict verdict)
  admitOwner operation stable = do
    checkpoint <- observeKindTeardownAdmission bootstrap
    owner <- observeKindOwnerFamilyIntent bootstrap
    idle <- managementRestoreIdle bootstrap
    case (owner == KindIntentMatches operation, idle) of
      (False, _) -> pure (Left "the owner-family operation changed")
      (True, False) -> pure (Left "the retained management restore requires settlement before control removal")
      (True, True) -> case checkpoint of
        KindIntentMissing -> do
          retained <- observeRetainedAuthorityJournal bootstrap
          case retained of
            RetainedAuthorityJournalBound -> admitRetained operation stable
            RetainedAuthorityJournalAbsent -> admitEarly operation stable
            _ -> pure (Left "the retained Authority journal is unconfirmed")
        KindIntentMatches recorded | recorded == operation -> do
          eligible <- observeKindTeardownAdmissionUnderLease bootstrap operation stable
          pure
            ( if eligible
                then Right ()
                else Left "the retained early teardown admission conflicts with the current scope"
            )
        _ -> pure (Left "the retained early teardown decision is foreign or unobservable")
  admitEarly operation stable = do
    (verdict, source) <- currentAdmission bootstrap
    case (verdict, source) of
      (NeverAdmitted, FromLocalControlJournal) -> do
        eligible <- kindTeardownEligible bootstrap operation stable
        if not eligible
          then pure (Left "early teardown admission changed before recording")
          else do
            written <- recordKindTeardownAdmission bootstrap operation
            retained <- observeKindTeardownAdmission bootstrap
            closing <- kindTeardownEligible bootstrap operation stable
            pure $
              if written == KindIntentRecorded && retained == KindIntentMatches operation && closing
                then Right ()
                else Left "the early teardown decision could not be confirmed"
      (other, FromLocalControlJournal) -> pure (admissionDecision other)
      (other, FromAuthority _) -> pure (Left (renderVerdict other))
  admitRetained operation stable = do
    let payload = authorityRemovalRecord bootstrap operation
    outcome <- withJournalCustodyLease (retainedAuthorityCustody bootstrap) $ \custody custodyStable -> do
      fence <- observeJournalRemovalFence custody payload
      let stillSelected = do
            retained <- observeRetainedAuthorityJournal bootstrap
            selected <- (&&) <$> stable <*> custodyStable
            pure (selected && retained == RetainedAuthorityJournalBound)
      case fence of
        JournalRemovalFenceMatches -> do
          selected <- stillSelected
          pure (if selected then Right () else Left "the control removal scope changed")
        JournalRemovalFenceUnconfirmed -> pure (Left "the retained control removal fence is foreign or unobservable")
        JournalRemovalFenceAbsent -> do
          (verdict, source) <- currentAdmission bootstrap
          selected <- stillSelected
          case (selected, verdict, source) of
            (True, NeverAdmitted, FromAuthority _) -> do
              written <- recordJournalRemovalFence custody payload
              observed <- observeJournalRemovalFence custody payload
              closing <- stillSelected
              pure $
                if written && observed == JournalRemovalFenceMatches && closing
                  then Right ()
                  else Left "the Authority-backed control removal fence could not be confirmed"
            _ -> pure (Left (renderVerdict verdict))
    pure (maybe (Left "the retained Authority journal lease is not available") id outcome)

authorityRemovalRecord :: BootstrapProjection -> String -> Char8.ByteString
authorityRemovalRecord bootstrap = LazyByteString.toStrict . Aeson.encode . authorityRemovalValue bootstrap

authorityRemovalValue :: BootstrapProjection -> String -> Aeson.Value
authorityRemovalValue bootstrap operation =
  Aeson.object
    [ "schema_version" .= (1 :: Int)
    , "kind_name" .= scopeKindName (bootstrapScope bootstrap)
    , "root_generation" .= bootstrapRootGeneration bootstrap
    , "kind_operation" .= operation
    ]

data AuthorityRemovalObservation
  = NoAuthorityRemoval
  | BoundAuthorityRemoval !String
  | UnconfirmedAuthorityRemoval
  deriving (Eq)

observeAuthorityRemoval :: BootstrapProjection -> IO AuthorityRemovalObservation
observeAuthorityRemoval bootstrap = do
  retained <- observeRetainedAuthorityJournal bootstrap
  case retained of
    RetainedAuthorityJournalAbsent -> pure NoAuthorityRemoval
    RetainedAuthorityJournalBound -> do
      observed <- withJournalCustodyLease (retainedAuthorityCustody bootstrap) $ \custody stable -> do
        record <- observeActiveAuthorityFence custody
        case record of
          Right Nothing -> do
            fence <- observeJournalRemovalFence custody mempty
            held <- stable
            pure $
              if fence == JournalRemovalFenceAbsent && held
                then NoAuthorityRemoval
                else UnconfirmedAuthorityRemoval
          Right (Just value)
            | Just operation <- AesonTypes.parseMaybe removalOperation value
            , length operation == 32
            , all (`elem` ("0123456789abcdef" :: String)) operation
            , value == authorityRemovalValue bootstrap operation -> do
                fence <- observeJournalRemovalFence custody (authorityRemovalRecord bootstrap operation)
                held <- stable
                pure $
                  if fence == JournalRemovalFenceMatches && held
                    then BoundAuthorityRemoval operation
                    else UnconfirmedAuthorityRemoval
          _ -> pure UnconfirmedAuthorityRemoval
      current <- observeRetainedAuthorityJournal bootstrap
      pure $ case (observed, current) of
        (Just observation, RetainedAuthorityJournalBound) -> observation
        _ -> UnconfirmedAuthorityRemoval
    _ -> pure UnconfirmedAuthorityRemoval
 where
  removalOperation = Aeson.withObject "Authority removal fence" (Aeson..: "kind_operation")

-- | Borrow the Authority's same custody lock for one known exact fence.
-- The caller must hold the matching kind lease and confirm archive settlement.
withBoundAuthorityRemoval
  :: BootstrapProjection -> String -> IO Bool -> (Fd -> IO Bool -> IO a) -> IO (Maybe a)
withBoundAuthorityRemoval bootstrap operation stable action = do
  observed <- withJournalCustodyLease (retainedAuthorityCustody bootstrap) $ \custody sameCustody -> do
    let stillSelected = do
          retained <- observeRetainedAuthorityJournal bootstrap
          held <- (&&) <$> stable <*> sameCustody
          pure (retained == RetainedAuthorityJournalBound && held)
    exact <- observeJournalRemovalFence custody (authorityRemovalRecord bootstrap operation)
    held <- stillSelected
    case exact of
      JournalRemovalFenceMatches | held -> Just <$> action custody stillSelected
      _ -> pure Nothing
  pure (join observed)

-- Recheck the originally fenced decision while borrowing its scope lease.
-- This read does not create or replace a checkpoint.
observeKindTeardownAdmissionUnderLease :: BootstrapProjection -> String -> IO Bool -> IO Bool
observeKindTeardownAdmissionUnderLease bootstrap operation stable = do
  before <- stable
  checkpoint <- observeKindTeardownAdmission bootstrap
  if before && checkpoint == KindIntentMatches operation
    then kindTeardownEligible bootstrap operation stable
    else pure False

kindTeardownEligible :: BootstrapProjection -> String -> IO Bool -> IO Bool
kindTeardownEligible bootstrap operation stable = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
  before <- stable
  retained <- observeRetainedAuthorityJournal bootstrap
  local <- pathPresence (takeDirectory (journalDirectory root))
  archive <- pathPresence (root </> "history" </> operation)
  owner <- observeKindOwnerFamilyIntent bootstrap
  after <- stable
  pure
    ( scopeEnvironment scope == Test
        && before
        && retained == RetainedAuthorityJournalAbsent
        && local == Right False
        && archive == Right False
        && owner == KindIntentMatches operation
        && after
    )

-- A dangling link or an unexpected file type is evidence of a path, not proof
-- that the Authority never existed. Observation errors must also fail closed.
pathPresence :: FilePath -> IO (Either IOException Bool)
pathPresence path = do
  result <- try (getSymbolicLinkStatus path)
  pure $ case result of
    Right _ -> Right True
    Left failure | isDoesNotExistError failure -> Right False
    Left failure -> Left failure

currentAdmissionObserved
  :: FilePath
  -> Text
  -> Maybe FilePath
  -> RetainedAuthorityJournal
  -> IO (AdmissionVerdict, AdmissionSource)
currentAdmissionObserved root clusterId selectedKubeconfig retained = do
  deployment <- case selectedKubeconfig of
    Just kubeconfig -> do
      observed <-
        run
          30
          "/usr/bin/kubectl"
          [ "--kubeconfig"
          , kubeconfig
          , "-n"
          , Text.unpack authorityNamespaceText
          , "get"
          , "service"
          , "lifecycle-authority"
          , "--ignore-not-found"
          , "-o"
          , "name"
          ]
          mempty
      pure $ case observed of
        Right (0, output, _) | words output == ["service/lifecycle-authority"] -> Right (Just kubeconfig)
        Right (0, output, _) | null (words output) -> Right Nothing
        _ -> Left "the Authority deployment could not be observed"
    Nothing -> pure (Right Nothing)
  case deployment of
    Right (Just kubeconfig) | retained == RetainedAuthorityJournalBound -> do
      answered <- admissionFromAuthority clusterId kubeconfig
      pure (admissionOutcome answered)
    Right (Just _) ->
      pure (admissionOutcome (Left "the deployed Authority has no confirmed retained journal binding"))
    Left detail -> pure (admissionOutcome (Left detail))
    Right Nothing
      | retained /= RetainedAuthorityJournalAbsent ->
          pure
            (admissionOutcome (Left "the retained Authority journal exists but the Authority is unavailable"))
    Right Nothing -> do
      local <- observeJournal root
      pure (classifyAdmission local, FromLocalControlJournal)

admissionOutcome :: Either String (AdmissionVerdict, Text) -> (AdmissionVerdict, AdmissionSource)
admissionOutcome answered = case answered of
  Right (verdict, observedAt) -> (verdict, FromAuthority observedAt)
  Left detail ->
    ( RecoveryRequired
        (RecoveryJournalUnobservable (Text.pack ("the deployed Authority could not be asked: " ++ detail)))
    , FromAuthority "not read"
    )

authorityNamespaceText :: Text
authorityNamespaceText = Text.pack authorityNamespace

-- | Ask the deployed Authority.
admissionFromAuthority :: Text -> FilePath -> IO (Either String (AdmissionVerdict, Text))
admissionFromAuthority clusterId kubeconfig = askAuthority kubeconfig (decodeAuthorityAdmission clusterId)

askAuthority :: FilePath -> (Char8.ByteString -> Either String answer) -> IO (Either String answer)
askAuthority kubeconfig decode = do
  minted <-
    run
      60
      "/usr/bin/kubectl"
      [ "--kubeconfig"
      , kubeconfig
      , "-n"
      , authorityNamespace
      , "create"
      , "token"
      , Text.unpack journalReadServiceAccount
      , "--audience"
      , Text.unpack journalReadAudience
      , "--duration"
      , "600s"
      ]
      mempty
  case minted of
    Right (0, token, _) -> do
      reserved <- reservePort
      case reserved of
        Left detail -> pure (Left detail)
        Right port ->
          bracket
            ( startBackgroundProcess
                Subprocess
                  { subprocessPath = "/usr/bin/kubectl"
                  , subprocessArguments =
                      [ "--kubeconfig"
                      , kubeconfig
                      , "-n"
                      , authorityNamespace
                      , "port-forward"
                      , "--address"
                      , "127.0.0.1"
                      , "service/lifecycle-authority"
                      , show port ++ ":journal-read"
                      ]
                  , subprocessEnvironment = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                  , subprocessWorkingDirectory = Nothing
                  }
            )
            (either (const (pure ())) stopBackgroundProcess)
            (askThroughForward decode port (filter (`notElem` ("\r\n " :: String)) token))
    Right (code, _, err) -> pure (Left ("a reader token could not be minted (exit " ++ show code ++ "): " ++ take 120 err))
    Left failure -> pure (Left failure)

askThroughForward
  :: (Char8.ByteString -> Either String answer)
  -> Int
  -> String
  -> Either AppError BackgroundProcess
  -> IO (Either String answer)
askThroughForward _ _ _ (Left _) = pure (Left "the port-forward to the Authority could not be started")
askThroughForward decode port token (Right _) = do
  manager <- newManager defaultManagerSettings
  askWithRetries manager decode port token (40 :: Int)

askWithRetries
  :: Manager
  -> (Char8.ByteString -> Either String answer)
  -> Int
  -> String
  -> Int
  -> IO (Either String answer)
askWithRetries manager decode port token remaining = do
  outcome <- try (ask manager decode port token)
  case outcome of
    Right (Right verdict) -> pure (Right verdict)
    Right (Left refusal) -> pure (Left refusal)
    Left (_ :: HttpException)
      | remaining <= 1 -> pure (Left "the journal read endpoint could not be reached")
      | otherwise -> threadDelay 250000 >> askWithRetries manager decode port token (remaining - 1)

ask
  :: Manager -> (Char8.ByteString -> Either String answer) -> Int -> String -> IO (Either String answer)
ask manager decode port token = do
  base <- parseRequest ("http://127.0.0.1:" ++ show port ++ "/v1/journal/admission")
  let request =
        base
          { requestHeaders = [("Authorization", Char8.pack ("Bearer " ++ token))]
          , responseTimeout = responseTimeoutMicro 8000000
          }
  response <- httpLbs request manager
  let code = statusCode (responseStatus response)
  pure $
    if code /= 200
      then Left ("the Authority answered HTTP " ++ show code)
      else decode (LazyByteString.toStrict (responseBody response))

decodeInitialization :: Text -> Char8.ByteString -> Either String JournalInitialization
decodeInitialization expected bytes = do
  (verdict, _) <- decodeAuthorityAdmission expected bytes
  response <- Aeson.eitherDecodeStrict' bytes
  let fields = Aeson.withObject "journal answer" (Aeson..:? "initialization")
      protocol = Aeson.withObject "journal initialization" $ \object ->
        (,) <$> (object .: "state") <*> (object .: "operation_id")
  record <- AesonTypes.parseEither fields response
  case (verdict, record) of
    (RecoveryRequired _, _) -> Right JournalInitializationUnconfirmed
    (_, Nothing) -> Right JournalInitializationLegacy
    (_, Just value) -> do
      (state, identifier) <- AesonTypes.parseEither protocol value
      case (state :: Text, verdict) of
        ("pending", AdmittedPending _)
          | validRootGeneration (Text.unpack identifier) ->
              Right (JournalInitializationArmed identifier)
        ("complete", _)
          | validRootGeneration (Text.unpack identifier) ->
              Right (JournalInitializationComplete identifier)
        _ -> Left "the Authority initialization state or identity is invalid"

decodeAuthorityAdmission :: Text -> Char8.ByteString -> Either String (AdmissionVerdict, Text)
decodeAuthorityAdmission expectedCluster bytes = case Aeson.decodeStrict bytes of
  Nothing -> Left "the Authority's answer could not be decoded"
  Just value -> case AesonTypes.parseMaybe answerFields value of
    Nothing -> Left "the Authority's answer lacks required journal metadata"
    Just (clusterId, verdict, detail, observedAt)
      | clusterId /= expectedCluster -> Left "the journal answer belongs to a different control cluster"
      | otherwise -> (,observedAt) <$> decideVerdict verdict detail

answerFields :: Aeson.Value -> AesonTypes.Parser (Text, Text, Text, Text)
answerFields =
  Aeson.withObject "answer" $ \object ->
    (,,,)
      <$> (object .: "cluster_id")
      <*> (object .: "verdict")
      <*> (object .: "detail")
      <*> (object .: "observed_at")

decideVerdict :: Text -> Text -> Either String AdmissionVerdict
decideVerdict verdict detail = case verdict of
  "never-admitted" -> Right NeverAdmitted
  "admitted-settled" -> Right AdmittedSettled
  "admitted-pending" -> Right (AdmittedPending [detail])
  "recovery-required" -> Right (RecoveryRequired (RecoveryJournalUnobservable detail))
  _ -> Left "the Authority answered an unknown verdict"

reservePort :: IO (Either String Int)
reservePort = do
  attempted <-
    try
      ( withSocketsDo $
          bracket
            (socket AF_INET Stream defaultProtocol)
            close
            ( \reserved -> do
                setSocketOption reserved ReuseAddr 1
                bind reserved (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
                address <- getSocketName reserved
                case address of
                  SockAddrInet port _ -> pure (fromIntegral port)
                  _ -> ioError (userError "reserved socket was not IPv4")
            )
      )
      :: IO (Either IOException Int)
  pure (either (Left . displayException) Right attempted)
