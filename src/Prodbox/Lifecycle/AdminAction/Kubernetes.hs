{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic one-shot Job intent and Pod attestation for Admin Actions.
-- Kubernetes receives only permit metadata; elevated credentials arrive later
-- over the attested Pod's stdin and cannot be rendered into this manifest.
module Prodbox.Lifecycle.AdminAction.Kubernetes
  ( AdminActionJobIntent
  , AdminActionJobIntentError (..)
  , RawAdminActionPodObservation (..)
  , AdminActionAttestationError (..)
  , mkAdminActionJobIntent
  , adminActionIntentCore
  , adminActionIntentJobName
  , adminActionIntentImageReference
  , adminActionIntentActiveDeadlineSeconds
  , adminActionIntentHeartbeat
  , attestAdminActionPod
  , renderAdminActionJob
  , adminActionRunnerNamespace
  , adminActionRunnerHeartbeatMaximumAgeMicros
  )
where

import Codec.Serialise (Serialise)
import Data.Char (isAlphaNum, isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionPodObservation (..)
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionPermitCore
  , adminActionJobNameFor
  , adminActionPermitAction
  , adminActionPermitDeadline
  , adminActionPermitImageDigest
  , adminActionPermitOperationId
  , adminActionRunnerServiceAccount
  )
import Prodbox.Lifecycle.Authority.AdminAction (AdminAction (..))
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )

data AdminActionJobIntent = AdminActionJobIntent
  { internalAdminActionIntentCore :: !AdminActionPermitCore
  , internalAdminActionIntentJobName :: !Text
  , internalAdminActionIntentImageReference :: !Text
  , internalAdminActionIntentActiveDeadlineSeconds :: !Natural
  , internalAdminActionIntentHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionJobIntentError
  = AdminActionJobImageReferenceInvalid
  | AdminActionJobDeadlineExpired
  | AdminActionJobDeadlineTooLong
  deriving stock (Eq, Show)

data RawAdminActionPodObservation = RawAdminActionPodObservation
  { observedAdminActionJobName :: !Text
  , observedAdminActionJobUid :: !Text
  , observedAdminActionPodName :: !Text
  , observedAdminActionPodUid :: !Text
  , observedAdminActionImageDigest :: !Text
  , observedAdminActionServiceAccount :: !Text
  , observedAdminActionServiceAccountUid :: !Text
  , observedAdminActionOperationId :: !Text
  , observedAdminActionAction :: !Text
  , observedAdminActionDeadlineMicros :: !Natural
  , observedAdminActionHeartbeatMicros :: !Natural
  , observedAdminActionPhase :: !Text
  , observedAdminActionContainerReady :: !Bool
  , observedAdminActionRestartCount :: !Natural
  , observedAdminActionDeletionTimestamp :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionAttestationError
  = AdminActionAttestationExpired
  | AdminActionAttestationJobMismatch
  | AdminActionAttestationPodIdentityInvalid
  | AdminActionAttestationImageMismatch
  | AdminActionAttestationServiceAccountMismatch
  | AdminActionAttestationPermitMetadataMismatch
  | AdminActionAttestationHeartbeatInvalid
  | AdminActionAttestationPodNotReady
  | AdminActionAttestationPodRestarted
  | AdminActionAttestationPodDeleting
  deriving stock (Eq, Show)

adminActionRunnerNamespace :: Text
adminActionRunnerNamespace = "admin-action-runner"

adminActionRunnerHeartbeatMaximumAgeMicros :: Natural
adminActionRunnerHeartbeatMaximumAgeMicros = 30 * 1000000

mkAdminActionJobIntent
  :: AuthorityTime
  -> Natural
  -> AdminActionPermitCore
  -> Text
  -> Either AdminActionJobIntentError AdminActionJobIntent
mkAdminActionJobIntent now maximumLifetimeSeconds core imageReference = do
  validateImageReference core imageReference
  let nowMicros = authorityTimeMicros now
      deadlineMicros = authorityTimeMicros (adminActionPermitDeadline core)
  if deadlineMicros <= nowMicros
    then Left AdminActionJobDeadlineExpired
    else do
      let remainingMicros = deadlineMicros - nowMicros
          seconds = max 1 ((remainingMicros + 999999) `div` 1000000)
      if seconds > maximumLifetimeSeconds
        then Left AdminActionJobDeadlineTooLong
        else
          Right
            AdminActionJobIntent
              { internalAdminActionIntentCore = core
              , internalAdminActionIntentJobName = adminActionJobNameFor core
              , internalAdminActionIntentImageReference = imageReference
              , internalAdminActionIntentActiveDeadlineSeconds = seconds
              , internalAdminActionIntentHeartbeatMicros = nowMicros
              }

adminActionIntentCore :: AdminActionJobIntent -> AdminActionPermitCore
adminActionIntentCore = internalAdminActionIntentCore

adminActionIntentJobName :: AdminActionJobIntent -> Text
adminActionIntentJobName = internalAdminActionIntentJobName

adminActionIntentImageReference :: AdminActionJobIntent -> Text
adminActionIntentImageReference = internalAdminActionIntentImageReference

adminActionIntentActiveDeadlineSeconds :: AdminActionJobIntent -> Natural
adminActionIntentActiveDeadlineSeconds = internalAdminActionIntentActiveDeadlineSeconds

adminActionIntentHeartbeat :: AdminActionJobIntent -> AuthorityTime
adminActionIntentHeartbeat =
  authorityTimeFromMicros . internalAdminActionIntentHeartbeatMicros

attestAdminActionPod
  :: AuthorityTime
  -> AdminActionJobIntent
  -> RawAdminActionPodObservation
  -> Either AdminActionAttestationError AdminActionPodObservation
attestAdminActionPod now intent observed = do
  let core = adminActionIntentCore intent
      nowMicros = authorityTimeMicros now
      deadlineMicros = authorityTimeMicros (adminActionPermitDeadline core)
      heartbeat = observedAdminActionHeartbeatMicros observed
  if nowMicros >= deadlineMicros
    then Left AdminActionAttestationExpired
    else Right ()
  if observedAdminActionJobName observed == adminActionIntentJobName intent
    then Right ()
    else Left AdminActionAttestationJobMismatch
  if validIdentity (observedAdminActionJobUid observed)
    && validIdentity (observedAdminActionPodName observed)
    && validIdentity (observedAdminActionPodUid observed)
    then Right ()
    else Left AdminActionAttestationPodIdentityInvalid
  if observedAdminActionImageDigest observed == adminActionPermitImageDigest core
    then Right ()
    else Left AdminActionAttestationImageMismatch
  if observedAdminActionServiceAccount observed == adminActionRunnerServiceAccount
    then Right ()
    else Left AdminActionAttestationServiceAccountMismatch
  if validIdentity (observedAdminActionServiceAccountUid observed)
    then Right ()
    else Left AdminActionAttestationPodIdentityInvalid
  if observedAdminActionOperationId observed == adminActionPermitOperationId core
    && observedAdminActionAction observed == adminActionToken (adminActionPermitAction core)
    && observedAdminActionDeadlineMicros observed == deadlineMicros
    then Right ()
    else Left AdminActionAttestationPermitMetadataMismatch
  if heartbeat > 0
    && heartbeat <= nowMicros
    && nowMicros - heartbeat <= adminActionRunnerHeartbeatMaximumAgeMicros
    then Right ()
    else Left AdminActionAttestationHeartbeatInvalid
  if observedAdminActionPhase observed == "Running" && observedAdminActionContainerReady observed
    then Right ()
    else Left AdminActionAttestationPodNotReady
  if observedAdminActionRestartCount observed == 0
    then Right ()
    else Left AdminActionAttestationPodRestarted
  case observedAdminActionDeletionTimestamp observed of
    Nothing -> Right ()
    Just _ -> Left AdminActionAttestationPodDeleting
  pure
    AdminActionPodObservation
      { adminActionObservedJobName = observedAdminActionJobName observed
      , adminActionObservedJobUid = observedAdminActionJobUid observed
      , adminActionObservedPodName = observedAdminActionPodName observed
      , adminActionObservedPodUid = observedAdminActionPodUid observed
      , adminActionObservedImageDigest = observedAdminActionImageDigest observed
      , adminActionObservedServiceAccount = observedAdminActionServiceAccount observed
      , adminActionObservedServiceAccountUid = observedAdminActionServiceAccountUid observed
      , adminActionObservedHeartbeatMicros = heartbeat
      }

renderAdminActionJob :: AdminActionJobIntent -> Text
renderAdminActionJob intent =
  Text.unlines
    [ "apiVersion: batch/v1"
    , "kind: Job"
    , "metadata:"
    , "  name: " <> adminActionIntentJobName intent
    , "  namespace: " <> adminActionRunnerNamespace
    , "  labels:"
    , "    app.kubernetes.io/name: prodbox-admin-action-runner"
    , "    prodbox.dev/operation-id: " <> adminActionPermitOperationId core
    , "  annotations:"
    , "    admin.prodbox.dev/action: " <> adminActionToken (adminActionPermitAction core)
    , "    admin.prodbox.dev/deadline-micros: "
        <> naturalText (authorityTimeMicros (adminActionPermitDeadline core))
    , "    admin.prodbox.dev/host-heartbeat-micros: "
        <> naturalText (authorityTimeMicros (adminActionIntentHeartbeat intent))
    , "    admin.prodbox.dev/image-digest: " <> adminActionPermitImageDigest core
    , "spec:"
    , "  backoffLimit: 0"
    , "  activeDeadlineSeconds: " <> naturalText (adminActionIntentActiveDeadlineSeconds intent)
    , "  ttlSecondsAfterFinished: 60"
    , "  template:"
    , "    metadata:"
    , "      labels:"
    , "        app.kubernetes.io/name: prodbox-admin-action-runner"
    , "        prodbox.dev/operation-id: " <> adminActionPermitOperationId core
    , "      annotations:"
    , "        admin.prodbox.dev/action: " <> adminActionToken (adminActionPermitAction core)
    , "        admin.prodbox.dev/deadline-micros: "
        <> naturalText (authorityTimeMicros (adminActionPermitDeadline core))
    , "        admin.prodbox.dev/host-heartbeat-micros: "
        <> naturalText (authorityTimeMicros (adminActionIntentHeartbeat intent))
    , "        admin.prodbox.dev/image-digest: " <> adminActionPermitImageDigest core
    , "    spec:"
    , "      restartPolicy: Never"
    , "      automountServiceAccountToken: false"
    , "      serviceAccountName: " <> adminActionRunnerServiceAccount
    , "      enableServiceLinks: false"
    , "      containers:"
    , "        - name: admin-action-runner"
    , "          image: " <> adminActionIntentImageReference intent
    , "          imagePullPolicy: IfNotPresent"
    , "          stdin: true"
    , "          stdinOnce: true"
    , "          args:"
    , "            - admin-action"
    , "            - run"
    , "            - --action"
    , "            - " <> adminActionToken (adminActionPermitAction core)
    , "            - --operation-id"
    , "            - " <> adminActionPermitOperationId core
    , "            - --deadline-micros"
    , "            - " <> naturalText (authorityTimeMicros (adminActionPermitDeadline core))
    , "            - --pod-name-file"
    , "            - /var/run/prodbox/pod/name"
    , "            - --pod-uid-file"
    , "            - /var/run/prodbox/pod/uid"
    , "            - --service-account-token-file"
    , "            - /var/run/secrets/prodbox-vault/token"
    , "          securityContext:"
    , "            allowPrivilegeEscalation: false"
    , "            capabilities:"
    , "              drop: [\"ALL\"]"
    , "            readOnlyRootFilesystem: true"
    , "            runAsNonRoot: true"
    , "            seccompProfile:"
    , "              type: RuntimeDefault"
    , "          volumeMounts:"
    , "            - name: pod-identity"
    , "              mountPath: /var/run/prodbox/pod"
    , "              readOnly: true"
    , "            - name: vault-token"
    , "              mountPath: /var/run/secrets/prodbox-vault"
    , "              readOnly: true"
    , "            - name: memory"
    , "              mountPath: /run/prodbox"
    , "      volumes:"
    , "        - name: pod-identity"
    , "          downwardAPI:"
    , "            items:"
    , "              - path: name"
    , "                fieldRef:"
    , "                  fieldPath: metadata.name"
    , "              - path: uid"
    , "                fieldRef:"
    , "                  fieldPath: metadata.uid"
    , "        - name: vault-token"
    , "          projected:"
    , "            defaultMode: 256"
    , "            sources:"
    , "              - serviceAccountToken:"
    , "                  path: token"
    , "                  audience: vault"
    , "                  expirationSeconds: 600"
    , "        - name: memory"
    , "          emptyDir:"
    , "            medium: Memory"
    , "            sizeLimit: 16Mi"
    ]
 where
  core = adminActionIntentCore intent

validateImageReference
  :: AdminActionPermitCore
  -> Text
  -> Either AdminActionJobIntentError ()
validateImageReference _core reference
  | Text.null reference = invalid
  | Text.length reference > 512 = invalid
  | Text.any (\character -> isControl character || isSpace character) reference = invalid
  | not (Text.all validImageCharacter reference) = invalid
  | "@" `Text.isInfixOf` reference = invalid
  | not (hasDeclaredTag reference) = invalid
  | otherwise = Right ()
 where
  invalid = Left AdminActionJobImageReferenceInvalid
  validImageCharacter character =
    isAlphaNum character || character `elem` ("._/:@-" :: String)
  hasDeclaredTag value =
    let (_, finalComponent) = Text.breakOnEnd "/" value
     in ":" `Text.isInfixOf` finalComponent

validIdentity :: Text -> Bool
validIdentity value =
  not (Text.null value)
    && Text.length value <= 256
    && not (Text.any (\character -> isControl character || isSpace character) value)

adminActionToken :: AdminAction -> Text
adminActionToken action = case action of
  DestroyAwsSes -> "destroy-aws-ses"
  MigrateLegacyBackend -> "migrate-legacy-backend"
  ReconcileQuota -> "reconcile-quota"

naturalText :: Natural -> Text
naturalText = Text.pack . show
