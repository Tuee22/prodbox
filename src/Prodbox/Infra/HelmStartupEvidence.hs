{-# LANGUAGE OverloadedStrings #-}

-- | Failed-release observations are diagnostics, never repair authority. Raw
-- log/Pod bytes stay private and ephemeral; only closed producer causes escape.
module Prodbox.Infra.HelmStartupEvidence
  ( StartupTarget
  , startupTarget
  , startupTargetNamespace
  , startupTargetRelease
  , StartupPod
  , startupPodName
  , startupPodNamespace
  , startupPodContainer
  , StartupLogKind (..)
  , StartupReadFailure (..)
  , StartupScopeFailure (..)
  , StartupCapture (..)
  , StartupCause (..)
  , StartupEvidence (..)
  , StartupEvidenceEffects (..)
  , observeStartupEvidence
  , decodeStartupCauses
  , renderStartupEvidence
  ) where

import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.!=), (.:), (.:?))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isAsciiLower)
import Data.List (find, intercalate, nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.Runtime
  ( LifecycleAuthorityStartupCause
  , TargetSecretAgentStartupCause
  , TlsRetentionStartupCause
  , allLifecycleAuthorityStartupCauses
  , allTargetSecretAgentStartupCauses
  , allTlsRetentionStartupCauses
  , renderLifecycleAuthorityStartupCause
  , renderTargetSecretAgentStartupCause
  , renderTlsRetentionStartupCause
  )
import Prodbox.Runtime.Role (RuntimeRole (..), allRuntimeRoles, runtimeRoleName)

-- Constructors are private so external data cannot manufacture an attributed
-- log request. Selection and every closing observation validate this scope.
data StartupTarget = StartupTarget RuntimeRole String String
  deriving (Eq, Show)
data StartupPod = StartupPod StartupTarget String String Int String
  deriving (Eq, Show)

data StartupLogKind = CurrentStartupLog | PreviousStartupLog
  deriving (Eq, Show)
data StartupReadFailure = StartupReadUnavailable | StartupReadDeadlineElapsed
  deriving (Eq, Show)
data StartupScopeFailure
  = StartupPodMissing
  | StartupPodsAmbiguous
  | StartupPodMalformed
  | StartupPodForeign
  | StartupContainerNotSole
  | StartupContainerNotStarted
  deriving (Eq, Show)
data StartupCause
  = AuthorityStartupCause LifecycleAuthorityStartupCause
  | TargetAgentStartupCause TargetSecretAgentStartupCause
  | RetentionStartupCause TlsRetentionStartupCause
  deriving (Eq, Show)
data StartupCapture
  = StartupCaptured [StartupCause]
  | StartupUnclassified
  | StartupCaptureUnavailable StartupReadFailure
  | StartupAttributionChanged
  | StartupPreviousNotApplicable
  deriving (Eq, Show)
data StartupEvidence
  = StartupInventoryUnavailable StartupReadFailure
  | StartupInventoryRefused StartupScopeFailure
  | StartupEvidence StartupTarget StartupCapture StartupCapture
  deriving (Eq, Show)
data StartupEvidenceEffects m = StartupEvidenceEffects
  { readStartupPodInventory :: StartupTarget -> m (Either StartupReadFailure ByteString)
  , readStartupPod :: StartupPod -> m (Either StartupReadFailure ByteString)
  , readStartupLog :: StartupPod -> StartupLogKind -> m (Either StartupReadFailure ByteString)
  }

startupTarget :: String -> String -> Maybe StartupTarget
startupTarget release namespace = do
  role <-
    lookup release [(runtimeRoleName role, role) | role <- allRuntimeRoles, role /= GatewayRuntime]
  if validName namespace then Just (StartupTarget role release namespace) else Nothing

startupTargetNamespace :: StartupTarget -> String
startupTargetNamespace (StartupTarget _ _ namespace) = namespace
startupTargetRelease :: StartupTarget -> String
startupTargetRelease (StartupTarget _ release _) = release
startupPodName :: StartupPod -> String
startupPodName (StartupPod _ name _ _ _) = name
startupPodNamespace :: StartupPod -> String
startupPodNamespace (StartupPod target _ _ _ _) = startupTargetNamespace target
startupPodContainer :: StartupPod -> String
startupPodContainer (StartupPod (StartupTarget role _ _) _ _ _ _) = runtimeRoleName role

observeStartupEvidence
  :: (Monad m) => StartupEvidenceEffects m -> StartupTarget -> m StartupEvidence
observeStartupEvidence effects target = do
  inventory <- readStartupPodInventory effects target
  case inventory of
    Left cause -> pure (StartupInventoryUnavailable cause)
    Right bytes -> case decodeInventory target bytes of
      Left cause -> pure (StartupInventoryRefused cause)
      Right pod@(StartupPod _ _ _ restarts _) -> do
        current <- capture pod CurrentStartupLog
        previous <- case current of
          StartupCaptureUnavailable StartupReadDeadlineElapsed -> pure current
          _ | restarts == 0 -> pure StartupPreviousNotApplicable
          _ -> capture pod PreviousStartupLog
        pure (StartupEvidence target current previous)
 where
  capture pod kind = do
    before <- readStartupPod effects pod
    case before of
      Left cause -> pure (StartupCaptureUnavailable cause)
      Right bytes | decodeExactPod target bytes /= Right pod -> pure StartupAttributionChanged
      Right _ -> do
        output <- readStartupLog effects pod kind
        case output of
          Left cause -> pure (StartupCaptureUnavailable cause)
          Right bytes -> do
            after <- readStartupPod effects pod
            pure $ case after of
              Left cause -> StartupCaptureUnavailable cause
              Right observed | decodeExactPod target observed /= Right pod -> StartupAttributionChanged
              Right _ -> case decodeStartupCauses target bytes of
                [] -> StartupUnclassified
                causes -> StartupCaptured causes

-- Only the fixed producer event/role/cause tuple participates. Other JSON
-- fields and non-JSON output are never rendered, persisted, or hashed.
decodeStartupCauses :: StartupTarget -> ByteString -> [StartupCause]
decodeStartupCauses (StartupTarget role _ _) bytes
  | BS.length bytes > 64 * 1024 = []
  | otherwise =
      nub
        [ cause
        | line <- BS8.lines bytes
        , Right event <- [eitherDecodeStrict' line]
        , Just cause <- [classify event]
        ]
 where
  classify (StartupEvent event severity observedRole cause)
    | severity /= "error" || observedRole /= Text.pack (runtimeRoleName role) = Nothing
    | otherwise = case role of
        LifecycleAuthorityRuntime
          | event == "lifecycle_authority_startup_refused" ->
              AuthorityStartupCause
                <$> find ((== cause) . renderLifecycleAuthorityStartupCause) allLifecycleAuthorityStartupCauses
        TargetSecretAgentRuntime
          | event == "target_secret_agent_startup_refused" ->
              TargetAgentStartupCause
                <$> find ((== cause) . renderTargetSecretAgentStartupCause) allTargetSecretAgentStartupCauses
        TlsRetentionRuntime
          | event == "tls_retention_startup_refused" ->
              RetentionStartupCause
                <$> find ((== cause) . renderTlsRetentionStartupCause) allTlsRetentionStartupCauses
        BootstrapBroker -> Nothing
        GatewayRuntime -> Nothing
        LifecycleAuthorityRuntime -> Nothing
        ProviderWorkerRuntime -> Nothing
        AuthorityBackupRuntime -> Nothing
        TlsRetentionRuntime -> Nothing
        TargetSecretAgentRuntime -> Nothing

data StartupEvent = StartupEvent Text Text Text Text
instance FromJSON StartupEvent where
  parseJSON = withObject "startup event" $ \root ->
    StartupEvent
      <$> root .: "event"
      <*> root .: "severity"
      <*> root .: "field_role"
      <*> root .: "field_cause"

data PodWire = PodWire String String String (Map String String) [String] [(String, Int, String)]
instance FromJSON PodWire where
  parseJSON = withObject "startup Pod" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    status <- root .:? "status"
    containers <- spec .: "containers" >>= mapM (withObject "container" (.: "name"))
    statuses <- case status of
      Nothing -> pure []
      Just value ->
        withObject "status" (\fields -> fields .:? "containerStatuses" .!= [] >>= mapM parseStatus) value
    PodWire
      <$> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"
      <*> (metadata .:? "labels" .!= Map.empty)
      <*> pure containers
      <*> pure statuses
   where
    parseStatus = withObject "container status" $ \fields ->
      (,,) <$> fields .: "name" <*> fields .: "restartCount" <*> (fields .:? "containerID" .!= "")
newtype PodInventory = PodInventory [PodWire]
instance FromJSON PodInventory where
  parseJSON = withObject "startup Pod inventory" $ \root -> PodInventory <$> root .: "items"

decodeInventory :: StartupTarget -> ByteString -> Either StartupScopeFailure StartupPod
decodeInventory target bytes
  | BS.length bytes > 128 * 1024 = Left StartupPodMalformed
  | otherwise = case eitherDecodeStrict' bytes of
      Left _ -> Left StartupPodMalformed
      Right (PodInventory []) -> Left StartupPodMissing
      Right (PodInventory [pod]) -> validatePod target pod
      Right (PodInventory _) -> Left StartupPodsAmbiguous

decodeExactPod :: StartupTarget -> ByteString -> Either StartupScopeFailure StartupPod
decodeExactPod target bytes
  | BS.length bytes > 128 * 1024 = Left StartupPodMalformed
  | otherwise = case eitherDecodeStrict' bytes of
      Left _ -> Left StartupPodMalformed
      Right pod -> validatePod target pod

validatePod :: StartupTarget -> PodWire -> Either StartupScopeFailure StartupPod
validatePod target@(StartupTarget role release namespace) (PodWire name observedNamespace uid labels containers statuses)
  | not (validName name) || not (validUid uid) = Left StartupPodMalformed
  | observedNamespace /= namespace || Map.lookup "app.kubernetes.io/instance" labels /= Just release =
      Left StartupPodForeign
  | containers /= [runtimeRoleName role] = Left StartupContainerNotSole
  | otherwise = case statuses of
      [(container, restarts, identity)]
        | container == runtimeRoleName role && restarts >= 0 && validContainerId identity ->
            Right (StartupPod target name uid restarts identity)
      _ -> Left StartupContainerNotStarted

validName :: String -> Bool
validName [] = False
validName (first : rest) = length rest < 253 && edge first && all allowed rest && finalAllowed
 where
  allowed c = edge c || c `elem` ("-." :: String)
  edge c = isAsciiLower c || (c >= '0' && c <= '9')
  finalAllowed = case reverse rest of
    [] -> True
    final : _ -> edge final
validUid :: String -> Bool
validUid uid = map length (splitHyphen uid) == [8, 4, 4, 4, 12] && all (all hex) (splitHyphen uid)
 where
  hex c = c `elem` ("0123456789abcdef" :: String)
  splitHyphen [] = [""]
  splitHyphen text =
    let (part, rest) = break (== '-') text
     in part : case rest of [] -> []; _ : following -> splitHyphen following
validContainerId :: String -> Bool
validContainerId identity = case break (== ':') identity of
  (runtime, ':' : '/' : '/' : digest) ->
    runtime `elem` ["containerd", "docker", "cri-o"]
      && length digest == 64
      && all (`elem` ("0123456789abcdef" :: String)) digest
  _ -> False

renderStartupEvidence :: StartupEvidence -> String
renderStartupEvidence evidence = case evidence of
  StartupInventoryUnavailable cause -> "startup-evidence/inventory/" ++ show cause
  StartupInventoryRefused cause -> "startup-evidence/inventory/" ++ show cause
  StartupEvidence (StartupTarget role _ _) current previous ->
    "startup-evidence/"
      ++ runtimeRoleName role
      ++ "/current="
      ++ renderCapture current
      ++ "/previous="
      ++ renderCapture previous
 where
  renderCapture capture = case capture of
    StartupCaptured causes -> intercalate "," (map renderCause causes)
    StartupUnclassified -> "unclassified"
    StartupCaptureUnavailable cause -> show cause
    StartupAttributionChanged -> "attribution-changed"
    StartupPreviousNotApplicable -> "not-applicable"
  renderCause cause = Text.unpack $ case cause of
    AuthorityStartupCause value -> renderLifecycleAuthorityStartupCause value
    TargetAgentStartupCause value -> renderTargetSecretAgentStartupCause value
    RetentionStartupCause value -> renderTlsRetentionStartupCause value
