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
  , admissionFromAuthority
  , currentAdmission
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, bracket, displayException, try)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client
  ( Manager
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
import Prodbox.Control.AuthorityDeploy (authorityNamespace)
import Prodbox.Control.JournalStore (observeJournal)
import Prodbox.Control.ServiceSupport (run)
import Prodbox.ControlPlane.AuthorityJournalReadServer
  ( journalReadAudience
  , journalReadServiceAccount
  )
import Prodbox.Error (AppError)
import Prodbox.Lifecycle.AdmissionHistory
  ( AdmissionVerdict (..)
  , RecoveryReason (..)
  , classifyAdmission
  )
import Prodbox.Subprocess
  ( BackgroundProcess
  , Subprocess (..)
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getSymbolicLinkStatus)

data AdmissionSource
  = -- | The time at which the Authority read its journal.
    FromAuthority !Text
  | FromLocalControlJournal
  deriving (Eq, Show)

-- | The verdict and where it came from.
currentAdmission :: FilePath -> IO (AdmissionVerdict, AdmissionSource)
currentAdmission root = do
  let kubeconfig = root </> "control" </> "kubeconfig"
  kubeconfigPresence <- pathPresence kubeconfig
  retainedPresence <- pathPresence (root </> "authority-journal")
  case (kubeconfigPresence, retainedPresence) of
    (Right present, Right retained) -> currentAdmissionObserved root kubeconfig present retained
    _ ->
      pure
        (admissionOutcome (Left "the control identity or retained Authority state could not be observed"))

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
  :: FilePath -> FilePath -> Bool -> Bool -> IO (AdmissionVerdict, AdmissionSource)
currentAdmissionObserved root kubeconfig present retained = do
  deployment <-
    if present
      then do
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
          Right (0, output, _) -> Right (not (null (words output)))
          _ -> Left "the Authority deployment could not be observed"
      else pure (Right False)
  case deployment of
    Right True -> do
      answered <- admissionFromAuthority kubeconfig
      pure (admissionOutcome answered)
    Left detail -> pure (admissionOutcome (Left detail))
    Right False
      | retained ->
          pure
            (admissionOutcome (Left "the retained Authority journal exists but the Authority is unavailable"))
    Right False -> do
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
admissionFromAuthority :: FilePath -> IO (Either String (AdmissionVerdict, Text))
admissionFromAuthority kubeconfig = do
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
            (askThroughForward port (filter (`notElem` ("\r\n " :: String)) token))
    Right (code, _, err) -> pure (Left ("a reader token could not be minted (exit " ++ show code ++ "): " ++ take 120 err))
    Left failure -> pure (Left failure)

askThroughForward
  :: Int
  -> String
  -> Either AppError BackgroundProcess
  -> IO (Either String (AdmissionVerdict, Text))
askThroughForward _ _ (Left _) = pure (Left "the port-forward to the Authority could not be started")
askThroughForward port token (Right _) = do
  manager <- newManager defaultManagerSettings
  askWithRetries manager port token (40 :: Int)

askWithRetries :: Manager -> Int -> String -> Int -> IO (Either String (AdmissionVerdict, Text))
askWithRetries manager port token remaining = do
  outcome <-
    try (ask manager port token) :: IO (Either SomeException (Either String (AdmissionVerdict, Text)))
  case outcome of
    Right (Right verdict) -> pure (Right verdict)
    Right (Left refusal) -> pure (Left refusal)
    Left failure
      | remaining <= 1 -> pure (Left (displayException failure))
      | otherwise -> threadDelay 250000 >> askWithRetries manager port token (remaining - 1)

ask :: Manager -> Int -> String -> IO (Either String (AdmissionVerdict, Text))
ask manager port token = do
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
      else parseAnswer (LazyByteString.toStrict (responseBody response))

parseAnswer :: Char8.ByteString -> Either String (AdmissionVerdict, Text)
parseAnswer bytes = case Aeson.decodeStrict bytes of
  Nothing -> Left "the Authority's answer could not be decoded"
  Just value -> case AesonTypes.parseMaybe answerFields value of
    Nothing -> Left "the Authority's answer has no verdict"
    Just (verdict, detail, observedAt) -> (,observedAt) <$> decideVerdict verdict detail

answerFields :: Aeson.Value -> AesonTypes.Parser (Text, Text, Text)
answerFields =
  Aeson.withObject "answer" $ \object ->
    (,,)
      <$> (object .: "verdict")
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
