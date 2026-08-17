{-# LANGUAGE OverloadedStrings #-}

-- | Package-private implementation of the local RKE2 recovery observation.
-- Raw facts and the injectable boundary stay here so a caller cannot turn a
-- selected enum or a fake subprocess result into production evidence.
module Prodbox.Config.LocalRke2RecoveryState.Internal
  ( LocalRke2RecoveryState
  , LocalRke2RecoveryStateView (..)
  , LocalRke2RecoveryObservationSurface (..)
  , LocalRke2RecoveryObservationFailure (..)
  , LocalRke2RecoveryContradiction (..)
  , LocalRke2RecoveryStateError (..)
  , localRke2RecoveryStateView
  , withObservedLocalRke2RecoveryHealthyInternal
  , renderLocalRke2RecoveryStateError
  , observeLocalRke2RecoveryState
  , LocalRke2RecoveryStateFixtureRegression
  , fixedLocalRke2RecoveryStateFixtureRegression
  , localRke2RecoveryFixtureAcceptedViews
  , localRke2RecoveryFixtureDefinitiveCombinationCount
  , localRke2RecoveryFixtureContradictoryCombinationCount
  , localRke2RecoveryFixtureUnobservableCombinationCount
  , localRke2RecoveryFixtureServiceParserClosed
  , localRke2RecoveryFixtureApiParserClosed
  , localRke2RecoveryFixtureMixedMarkersRefused
  , localRke2RecoveryFixtureProductionBoundaryCanonical
  , localRke2RecoveryFixtureHealthyEliminatorClosed
  )
where

import Control.Exception (IOException, try)
import Data.Char (digitToInt, isDigit)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Error (AppError, errorMsg, fatalError)
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2InstallMarker
  , canonicalLocalRke2InstallMarkers
  , localRke2InstallMarkerPath
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (..))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, getSymbolicLinkStatus)

-- | The only recovery states that a complete observation may establish.
data LocalRke2RecoveryStateView
  = LocalRke2RecoveryHealthy
  | LocalRke2RecoveryStopped
  | LocalRke2RecoveryAbsent
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Opaque positive result.  This is deliberately a @data@ rather than a
-- newtype so representational coercion cannot manufacture one from the public
-- view enum.
data LocalRke2RecoveryState
  = ObservedLocalRke2RecoveryHealthy
  | ObservedLocalRke2RecoveryStopped
  | ObservedLocalRke2RecoveryAbsent
  deriving (Eq, Show)

data LocalRke2RecoveryObservationSurface
  = LocalRke2RecoveryInstallSurface
  | LocalRke2RecoveryServiceSurface
  | LocalRke2RecoveryApiSurface
  deriving (Bounded, Enum, Eq, Ord, Show)

data LocalRke2RecoveryObservationFailure = LocalRke2RecoveryObservationFailure
  { localRke2RecoveryObservationFailureSurface
      :: !LocalRke2RecoveryObservationSurface
  , localRke2RecoveryObservationFailureDetail :: !Text
  }
  deriving (Eq, Show)

-- | Closed reasons why individually definite facts cannot describe one of the
-- three valid substrate states.
data LocalRke2RecoveryContradiction
  = LocalRke2InstallMarkersIncomplete
      !(NonEmpty LocalRke2InstallMarker)
  | LocalRke2InstalledButSystemdUnitAbsent
  | LocalRke2InstallAbsentButSystemdUnitLoaded
  | LocalRke2ActiveServiceButApiUnreachable
  | LocalRke2InactiveServiceButApiReachable
  | LocalRke2InstallAbsentButApiReachable
  deriving (Eq, Ord, Show)

data LocalRke2RecoveryStateError
  = LocalRke2RecoveryStateUnobservable
      !(NonEmpty LocalRke2RecoveryObservationFailure)
  | LocalRke2RecoveryStateContradictory !LocalRke2RecoveryContradiction
  deriving (Eq, Show)

localRke2RecoveryStateView
  :: LocalRke2RecoveryState -> LocalRke2RecoveryStateView
localRke2RecoveryStateView state = case state of
  ObservedLocalRke2RecoveryHealthy -> LocalRke2RecoveryHealthy
  ObservedLocalRke2RecoveryStopped -> LocalRke2RecoveryStopped
  ObservedLocalRke2RecoveryAbsent -> LocalRke2RecoveryAbsent

-- | Package-private eliminator for the sole positive host fact that may be
-- committed as recovery-plane ClusterBase evidence.  The public view enum is
-- intentionally absent from this signature: callers cannot select Healthy
-- and turn that selection back into an observed state.
withObservedLocalRke2RecoveryHealthyInternal
  :: LocalRke2RecoveryState -> result -> Maybe result
withObservedLocalRke2RecoveryHealthyInternal state result = case state of
  ObservedLocalRke2RecoveryHealthy -> Just result
  ObservedLocalRke2RecoveryStopped -> Nothing
  ObservedLocalRke2RecoveryAbsent -> Nothing

renderLocalRke2RecoveryStateError :: LocalRke2RecoveryStateError -> Text
renderLocalRke2RecoveryStateError err = case err of
  LocalRke2RecoveryStateUnobservable failures ->
    "local RKE2 recovery state is unobservable: "
      <> Text.intercalate "; " (fmap renderObservationFailure (NonEmpty.toList failures))
  LocalRke2RecoveryStateContradictory contradiction ->
    "local RKE2 recovery observations contradict one another: "
      <> renderContradiction contradiction

renderObservationFailure :: LocalRke2RecoveryObservationFailure -> Text
renderObservationFailure failure =
  surfaceName (localRke2RecoveryObservationFailureSurface failure)
    <> ": "
    <> localRke2RecoveryObservationFailureDetail failure

surfaceName :: LocalRke2RecoveryObservationSurface -> Text
surfaceName surface = case surface of
  LocalRke2RecoveryInstallSurface -> "install markers"
  LocalRke2RecoveryServiceSurface -> "systemd service"
  LocalRke2RecoveryApiSurface -> "loopback Kubernetes API"

renderContradiction :: LocalRke2RecoveryContradiction -> Text
renderContradiction contradiction = case contradiction of
  LocalRke2InstallMarkersIncomplete missingMarkers ->
    "the canonical local RKE2 install is damaged; missing markers: "
      <> Text.intercalate
        ", "
        (fmap (Text.pack . localRke2InstallMarkerPath) (NonEmpty.toList missingMarkers))
  LocalRke2InstalledButSystemdUnitAbsent ->
    "install markers are present but systemd reports the unit absent"
  LocalRke2InstallAbsentButSystemdUnitLoaded ->
    "all install markers are absent but systemd reports a loaded unit"
  LocalRke2ActiveServiceButApiUnreachable ->
    "systemd reports an active service but the loopback API refused a connection"
  LocalRke2InactiveServiceButApiReachable ->
    "systemd reports an inactive service but the loopback API answered"
  LocalRke2InstallAbsentButApiReachable ->
    "all install markers are absent but the loopback API answered"

-- Raw observation facts.  Constructors never cross the hidden module.
data InstallFact
  = InstallDefinitelyPresent
  | InstallDefinitelyAbsent
  | InstallDefinitelyDamaged !(NonEmpty LocalRke2InstallMarker)
  | InstallUnobservable !Text
  deriving (Eq, Show)

data ServiceFact
  = ServiceDefinitelyActive
  | ServiceDefinitelyInactive
  | ServiceUnitDefinitelyAbsent
  | ServiceUnobservable !Text
  deriving (Eq, Show)

data ApiFact
  = ApiDefinitelyReachable
  | ApiDefinitelyUnreachable
  | ApiUnobservable !Text
  deriving (Eq, Show)

data LocalRke2RecoveryObservationBoundary m
  = LocalRke2RecoveryObservationBoundary
  { observeInstallFact :: m InstallFact
  , observeServiceFact :: m ServiceFact
  , observeApiFact :: m ApiFact
  }

-- | Read all three independent surfaces before classifying.  An unknown fact
-- never becomes absence, while an all-definite but impossible tuple becomes a
-- typed contradiction.
observeWithBoundary
  :: (Monad m)
  => LocalRke2RecoveryObservationBoundary m
  -> m (Either LocalRke2RecoveryStateError LocalRke2RecoveryState)
observeWithBoundary boundary = do
  install <- observeInstallFact boundary
  service <- observeServiceFact boundary
  api <- observeApiFact boundary
  pure (classifyRecoveryState install service api)

-- | Production observer.  Its marker universe, service unit, loopback URL,
-- commands, environment, and time/output bounds are all closed constants.
observeLocalRke2RecoveryState
  :: IO (Either LocalRke2RecoveryStateError LocalRke2RecoveryState)
observeLocalRke2RecoveryState =
  observeWithBoundary productionObservationBoundary

productionObservationBoundary :: LocalRke2RecoveryObservationBoundary IO
productionObservationBoundary =
  LocalRke2RecoveryObservationBoundary
    { observeInstallFact = observeProductionInstall
    , observeServiceFact =
        classifyServiceProcess
          <$> captureSubprocessBounded observationLimits serviceObservationProcess
    , observeApiFact =
        classifyApiProcess
          <$> captureSubprocessBounded observationLimits apiObservationProcess
    }

data MarkerFact
  = MarkerPresent
  | MarkerAbsent
  | MarkerUnobservable !LocalRke2InstallMarker !Text

observeProductionInstall :: IO InstallFact
observeProductionInstall = do
  facts <- traverse observeMarker canonicalLocalRke2InstallMarkers
  pure (classifyMarkerFacts (zip canonicalLocalRke2InstallMarkers facts))

classifyMarkerFacts
  :: [(LocalRke2InstallMarker, MarkerFact)] -> InstallFact
classifyMarkerFacts observations =
  case NonEmpty.nonEmpty failures of
    Just unresolved ->
      InstallUnobservable (Text.intercalate "; " (NonEmpty.toList unresolved))
    Nothing -> case (NonEmpty.nonEmpty presentMarkers, NonEmpty.nonEmpty absentMarkers) of
      (Just _, Nothing) -> InstallDefinitelyPresent
      (Nothing, Just _) -> InstallDefinitelyAbsent
      (Just _, Just missingMarkers) -> InstallDefinitelyDamaged missingMarkers
      (Nothing, Nothing) -> InstallUnobservable "the canonical install-marker set was empty"
 where
  failures =
    [ boundedDetail
        ( Text.pack (show observedMarker)
            <> ": "
            <> detail
        )
    | (_, MarkerUnobservable observedMarker detail) <- observations
    ]
  presentMarkers =
    [ marker
    | (marker, MarkerPresent) <- observations
    ]
  absentMarkers =
    [ marker
    | (marker, MarkerAbsent) <- observations
    ]

observeMarker :: LocalRke2InstallMarker -> IO MarkerFact
observeMarker marker = do
  observed <-
    try (getSymbolicLinkStatus (localRke2InstallMarkerPath marker))
      :: IO (Either IOException FileStatus)
  pure $ case observed of
    Right _ -> MarkerPresent
    Left err
      | isDoesNotExistError err -> MarkerAbsent
      | otherwise ->
          MarkerUnobservable marker (boundedDetail (Text.pack (show err)))

classifyRecoveryState
  :: InstallFact
  -> ServiceFact
  -> ApiFact
  -> Either LocalRke2RecoveryStateError LocalRke2RecoveryState
classifyRecoveryState install service api =
  case NonEmpty.nonEmpty (observationFailures install service api) of
    Just failures -> Left (LocalRke2RecoveryStateUnobservable failures)
    Nothing -> classifyDefinite install service api

observationFailures
  :: InstallFact
  -> ServiceFact
  -> ApiFact
  -> [LocalRke2RecoveryObservationFailure]
observationFailures install service api =
  installFailure install ++ serviceFailure service ++ apiFailure api
 where
  installFailure fact = case fact of
    InstallUnobservable detail ->
      [ LocalRke2RecoveryObservationFailure
          LocalRke2RecoveryInstallSurface
          detail
      ]
    InstallDefinitelyPresent -> []
    InstallDefinitelyAbsent -> []
    InstallDefinitelyDamaged _ -> []
  serviceFailure fact = case fact of
    ServiceUnobservable detail ->
      [ LocalRke2RecoveryObservationFailure
          LocalRke2RecoveryServiceSurface
          detail
      ]
    ServiceDefinitelyActive -> []
    ServiceDefinitelyInactive -> []
    ServiceUnitDefinitelyAbsent -> []
  apiFailure fact = case fact of
    ApiUnobservable detail ->
      [ LocalRke2RecoveryObservationFailure
          LocalRke2RecoveryApiSurface
          detail
      ]
    ApiDefinitelyReachable -> []
    ApiDefinitelyUnreachable -> []

classifyDefinite
  :: InstallFact
  -> ServiceFact
  -> ApiFact
  -> Either LocalRke2RecoveryStateError LocalRke2RecoveryState
classifyDefinite install service api = case (install, service, api) of
  (InstallDefinitelyDamaged missingMarkers, _, _) ->
    contradiction (LocalRke2InstallMarkersIncomplete missingMarkers)
  (InstallDefinitelyPresent, ServiceDefinitelyActive, ApiDefinitelyReachable) ->
    Right ObservedLocalRke2RecoveryHealthy
  (InstallDefinitelyPresent, ServiceDefinitelyInactive, ApiDefinitelyUnreachable) ->
    Right ObservedLocalRke2RecoveryStopped
  (InstallDefinitelyAbsent, ServiceUnitDefinitelyAbsent, ApiDefinitelyUnreachable) ->
    Right ObservedLocalRke2RecoveryAbsent
  (InstallDefinitelyPresent, ServiceUnitDefinitelyAbsent, _) ->
    contradiction LocalRke2InstalledButSystemdUnitAbsent
  (InstallDefinitelyAbsent, ServiceDefinitelyActive, _) ->
    contradiction LocalRke2InstallAbsentButSystemdUnitLoaded
  (InstallDefinitelyAbsent, ServiceDefinitelyInactive, _) ->
    contradiction LocalRke2InstallAbsentButSystemdUnitLoaded
  (_, ServiceDefinitelyActive, ApiDefinitelyUnreachable) ->
    contradiction LocalRke2ActiveServiceButApiUnreachable
  (_, ServiceDefinitelyInactive, ApiDefinitelyReachable) ->
    contradiction LocalRke2InactiveServiceButApiReachable
  (InstallDefinitelyAbsent, ServiceUnitDefinitelyAbsent, ApiDefinitelyReachable) ->
    contradiction LocalRke2InstallAbsentButApiReachable
  (InstallUnobservable _, _, _) -> internalUnobservable
  (_, ServiceUnobservable _, _) -> internalUnobservable
  (_, _, ApiUnobservable _) -> internalUnobservable
 where
  contradiction = Left . LocalRke2RecoveryStateContradictory
  internalUnobservable =
    Left
      ( LocalRke2RecoveryStateUnobservable
          ( LocalRke2RecoveryObservationFailure
              LocalRke2RecoveryInstallSurface
              "internal classifier received an unresolved fact"
              NonEmpty.:| []
          )
      )

classifyServiceProcess :: Either AppError ProcessOutput -> ServiceFact
classifyServiceProcess result = case result of
  Left err ->
    ServiceUnobservable
      ("systemd observation subprocess was unavailable: " <> errorMsg err)
  Right output ->
    case parseSystemdFields (processStdout output) of
      Right ("loaded", "active")
        | processExitCode output == ExitSuccess -> ServiceDefinitelyActive
      Right ("loaded", "inactive")
        | processExitCode output == ExitSuccess -> ServiceDefinitelyInactive
      Right ("not-found", "inactive")
        | processExitCode output `elem` [ExitSuccess, ExitFailure 1] ->
            ServiceUnitDefinitelyAbsent
      _ -> ServiceUnobservable (processFailureDetail "systemctl" output)

parseSystemdFields :: String -> Either Text (Text, Text)
parseSystemdFields output = do
  fields <- traverse parseField (filter (not . Text.null) normalizedLines)
  let indexed = Map.fromList fields
  if length fields /= 2 || Map.size indexed /= 2
    then Left "systemd returned duplicate or extra fields"
    else do
      loadState <- maybe (Left "systemd omitted LoadState") Right (Map.lookup "LoadState" indexed)
      activeState <- maybe (Left "systemd omitted ActiveState") Right (Map.lookup "ActiveState" indexed)
      pure (loadState, activeState)
 where
  normalizedLines = fmap Text.strip (Text.lines (Text.pack output))
  parseField line =
    case Text.breakOn "=" line of
      (name, valueWithEquals)
        | not (Text.null name)
            && not (Text.null valueWithEquals)
            && Text.count "=" line == 1 ->
            Right (name, Text.drop 1 valueWithEquals)
      _ -> Left "systemd returned malformed state fields"

classifyApiProcess :: Either AppError ProcessOutput -> ApiFact
classifyApiProcess result = case result of
  Left err ->
    ApiUnobservable
      ("loopback API observation subprocess was unavailable: " <> errorMsg err)
  Right output -> case processExitCode output of
    ExitSuccess ->
      case parseHttpStatus (Text.strip (Text.pack (processStdout output))) of
        Just _ -> ApiDefinitelyReachable
        Nothing -> ApiUnobservable (processFailureDetail "curl" output)
    ExitFailure 7
      | Text.strip (Text.pack (processStdout output)) == "000" ->
          ApiDefinitelyUnreachable
    ExitFailure _ -> ApiUnobservable (processFailureDetail "curl" output)

parseHttpStatus :: Text -> Maybe Int
parseHttpStatus status = case Text.unpack status of
  [hundreds, tens, ones]
    | all isDigit [hundreds, tens, ones] ->
        let code =
              digitToInt hundreds * 100
                + digitToInt tens * 10
                + digitToInt ones
         in if code >= 100 && code <= 599 then Just code else Nothing
  _ -> Nothing

processFailureDetail :: Text -> ProcessOutput -> Text
processFailureDetail command output =
  boundedDetail
    ( command
        <> " returned "
        <> Text.pack (show (processExitCode output))
        <> ": "
        <> Text.pack (processStderr output)
        <> " "
        <> Text.pack (processStdout output)
    )

boundedDetail :: Text -> Text
boundedDetail detail =
  let normalized = Text.unwords (Text.words detail)
   in Text.take
        2048
        (if Text.null normalized then "no diagnostic detail" else normalized)

observationLimits :: BoundedSubprocessLimits
observationLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 4096
    , boundedSubprocessMaximumStderrBytes = 4096
    , boundedSubprocessTimeoutMicros = 5 * 1_000_000
    }

productionObservationEnvironment :: [(String, String)]
productionObservationEnvironment =
  [ ("LC_ALL", "C")
  , ("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
  , ("NO_PROXY", "127.0.0.1,localhost")
  , ("no_proxy", "127.0.0.1,localhost")
  ]

serviceObservationProcess :: Subprocess
serviceObservationProcess =
  Subprocess
    { subprocessPath = "/usr/bin/systemctl"
    , subprocessArguments =
        [ "show"
        , "rke2-server.service"
        , "--property=LoadState"
        , "--property=ActiveState"
        , "--no-pager"
        ]
    , subprocessEnvironment = Just productionObservationEnvironment
    , subprocessWorkingDirectory = Just "/"
    }

apiObservationProcess :: Subprocess
apiObservationProcess =
  Subprocess
    { subprocessPath = "/usr/bin/curl"
    , subprocessArguments =
        [ "--disable"
        , "--silent"
        , "--show-error"
        , "--insecure"
        , "--connect-timeout"
        , "2"
        , "--max-time"
        , "5"
        , "--output"
        , "/dev/null"
        , "--write-out"
        , "%{http_code}"
        , "--noproxy"
        , "*"
        , "https://127.0.0.1:6443/readyz"
        ]
    , subprocessEnvironment = Just productionObservationEnvironment
    , subprocessWorkingDirectory = Just "/"
    }

-- | Fixed non-authorizing regression results.  No raw observation, injectable
-- boundary, classifier, or opaque positive state is exposed through this
-- value.
data LocalRke2RecoveryStateFixtureRegression
  = LocalRke2RecoveryStateFixtureRegression
  { localRke2RecoveryFixtureAcceptedViews :: ![LocalRke2RecoveryStateView]
  , localRke2RecoveryFixtureDefinitiveCombinationCount :: !Int
  , localRke2RecoveryFixtureContradictoryCombinationCount :: !Int
  , localRke2RecoveryFixtureUnobservableCombinationCount :: !Int
  , localRke2RecoveryFixtureServiceParserClosed :: !Bool
  , localRke2RecoveryFixtureApiParserClosed :: !Bool
  , localRke2RecoveryFixtureMixedMarkersRefused :: !Bool
  , localRke2RecoveryFixtureProductionBoundaryCanonical :: !Bool
  , localRke2RecoveryFixtureHealthyEliminatorClosed :: !Bool
  }
  deriving (Eq, Show)

fixedLocalRke2RecoveryStateFixtureRegression
  :: LocalRke2RecoveryStateFixtureRegression
fixedLocalRke2RecoveryStateFixtureRegression =
  LocalRke2RecoveryStateFixtureRegression
    { localRke2RecoveryFixtureAcceptedViews =
        [ localRke2RecoveryStateView state
        | Right state <- definitiveResults
        ]
    , localRke2RecoveryFixtureDefinitiveCombinationCount =
        length definitiveResults
    , localRke2RecoveryFixtureContradictoryCombinationCount =
        length
          [ ()
          | Left (LocalRke2RecoveryStateContradictory _) <- definitiveResults
          ]
    , localRke2RecoveryFixtureUnobservableCombinationCount =
        length
          [ ()
          | Left (LocalRke2RecoveryStateUnobservable _) <- unknownResults
          ]
    , localRke2RecoveryFixtureServiceParserClosed = serviceParserClosed
    , localRke2RecoveryFixtureApiParserClosed = apiParserClosed
    , localRke2RecoveryFixtureMixedMarkersRefused = mixedMarkersRefused
    , localRke2RecoveryFixtureProductionBoundaryCanonical =
        productionBoundaryCanonical
    , localRke2RecoveryFixtureHealthyEliminatorClosed =
        withObservedLocalRke2RecoveryHealthyInternal
          ObservedLocalRke2RecoveryHealthy
          True
          == Just True
          && withObservedLocalRke2RecoveryHealthyInternal
            ObservedLocalRke2RecoveryStopped
            True
            == Nothing
          && withObservedLocalRke2RecoveryHealthyInternal
            ObservedLocalRke2RecoveryAbsent
            True
            == Nothing
    }
 where
  definitiveResults =
    [ classifyRecoveryState install service api
    | install <- [InstallDefinitelyPresent, InstallDefinitelyAbsent]
    , service <-
        [ ServiceDefinitelyActive
        , ServiceDefinitelyInactive
        , ServiceUnitDefinitelyAbsent
        ]
    , api <- [ApiDefinitelyReachable, ApiDefinitelyUnreachable]
    ]
  unknownResults =
    [ classifyRecoveryState install service api
    | install <-
        [ InstallDefinitelyPresent
        , InstallDefinitelyAbsent
        , InstallUnobservable "fixture install unknown"
        ]
    , service <-
        [ ServiceDefinitelyActive
        , ServiceDefinitelyInactive
        , ServiceUnitDefinitelyAbsent
        , ServiceUnobservable "fixture service unknown"
        ]
    , api <-
        [ ApiDefinitelyReachable
        , ApiDefinitelyUnreachable
        , ApiUnobservable "fixture API unknown"
        ]
    , anyFactUnknown install service api
    ]

anyFactUnknown :: InstallFact -> ServiceFact -> ApiFact -> Bool
anyFactUnknown install service api = case (install, service, api) of
  (InstallUnobservable _, _, _) -> True
  (_, ServiceUnobservable _, _) -> True
  (_, _, ApiUnobservable _) -> True
  _ -> False

mixedMarkersRefused :: Bool
mixedMarkersRefused = case canonicalLocalRke2InstallMarkers of
  missingMarker : retainedMarkers ->
    case classifyMarkerFacts
      ( (missingMarker, MarkerAbsent)
          : [(marker, MarkerPresent) | marker <- retainedMarkers]
      ) of
      InstallDefinitelyDamaged missingMarkers ->
        all
          ( ==
              Left
                ( LocalRke2RecoveryStateContradictory
                    (LocalRke2InstallMarkersIncomplete (missingMarker NonEmpty.:| []))
                )
          )
          [ classifyRecoveryState
              (InstallDefinitelyDamaged missingMarkers)
              service
              api
          | service <-
              [ ServiceDefinitelyActive
              , ServiceDefinitelyInactive
              , ServiceUnitDefinitelyAbsent
              ]
          , api <- [ApiDefinitelyReachable, ApiDefinitelyUnreachable]
          ]
      _ -> False
  [] -> False

serviceParserClosed :: Bool
serviceParserClosed =
  and
    [ classifyServiceProcess
        (Right (processOutput ExitSuccess "LoadState=loaded\nActiveState=active\n" ""))
        == ServiceDefinitelyActive
    , classifyServiceProcess
        (Right (processOutput ExitSuccess "ActiveState=inactive\nLoadState=loaded\n" ""))
        == ServiceDefinitelyInactive
    , classifyServiceProcess
        (Right (processOutput (ExitFailure 1) "LoadState=not-found\nActiveState=inactive\n" ""))
        == ServiceUnitDefinitelyAbsent
    , isServiceUnobservable
        ( classifyServiceProcess
            (Right (processOutput ExitSuccess "LoadState=loaded\nActiveState=failed\n" ""))
        )
    , isServiceUnobservable
        ( classifyServiceProcess
            (Right (processOutput ExitSuccess "LoadState=loaded\nLoadState=loaded\nActiveState=active\n" ""))
        )
    , isServiceUnobservable
        (classifyServiceProcess (Left (fatalError "fixture systemctl unavailable")))
    ]

apiParserClosed :: Bool
apiParserClosed =
  and
    [ classifyApiProcess (Right (processOutput ExitSuccess "200" ""))
        == ApiDefinitelyReachable
    , classifyApiProcess (Right (processOutput ExitSuccess "503" ""))
        == ApiDefinitelyReachable
    , classifyApiProcess
        (Right (processOutput (ExitFailure 7) "000" "connection refused"))
        == ApiDefinitelyUnreachable
    , isApiUnobservable
        (classifyApiProcess (Right (processOutput (ExitFailure 28) "000" "timeout")))
    , isApiUnobservable
        (classifyApiProcess (Right (processOutput (ExitFailure 35) "000" "TLS failure")))
    , isApiUnobservable
        (classifyApiProcess (Right (processOutput ExitSuccess "000" "")))
    , isApiUnobservable
        (classifyApiProcess (Left (fatalError "fixture curl unavailable")))
    ]

isServiceUnobservable :: ServiceFact -> Bool
isServiceUnobservable fact = case fact of
  ServiceUnobservable _ -> True
  _ -> False

isApiUnobservable :: ApiFact -> Bool
isApiUnobservable fact = case fact of
  ApiUnobservable _ -> True
  _ -> False

processOutput :: ExitCode -> String -> String -> ProcessOutput
processOutput exitCode stdoutText stderrText =
  ProcessOutput
    { processExitCode = exitCode
    , processStdout = stdoutText
    , processStderr = stderrText
    }

productionBoundaryCanonical :: Bool
productionBoundaryCanonical =
  fmap localRke2InstallMarkerPath canonicalLocalRke2InstallMarkers
    == [ "/usr/local/bin/rke2"
       , "/usr/local/bin/rke2-killall.sh"
       , "/usr/local/bin/rke2-uninstall.sh"
       , "/var/lib/rancher/rke2"
       , "/etc/rancher/rke2"
       , "/etc/systemd/system/rke2-server.service"
       , "/etc/systemd/system/rke2-server.service.d"
       , "/etc/systemd/system/multi-user.target.wants/rke2-server.service"
       ]
    && subprocessPath serviceObservationProcess == "/usr/bin/systemctl"
    && "rke2-server.service" `elem` subprocessArguments serviceObservationProcess
    && subprocessPath apiObservationProcess == "/usr/bin/curl"
    && "https://127.0.0.1:6443/readyz" `elem` subprocessArguments apiObservationProcess
    && subprocessEnvironment serviceObservationProcess
      == Just productionObservationEnvironment
    && subprocessEnvironment apiObservationProcess
      == Just productionObservationEnvironment
