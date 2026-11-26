{-# LANGUAGE OverloadedStrings #-}

-- | Canonical non-secret request data for the future operation-family kind
-- controller. Decoding binds a pinned bootstrap projection to the original
-- key and clock window; it does not prove manager identity or admit an effect.
module Prodbox.Control.KindControllerRequest
  ( KindControllerRequest
  , KindControllerRequestError (..)
  , kindControllerOperationKey
  , kindProbeRecoveryKey
  , mkKindControllerRequest
  , encodeKindControllerRequest
  , decodeKindControllerRequest
  , decodeRetainedKindControllerRequest
  , kindRequestOperation
  , kindRequestExecutableDigest
  , kindRequestManagerDomain
  , kindRequestWindow
  , ProbeRecoveryRequest
  , mkProbeRecoveryRequest
  , encodeProbeRecoveryRequest
  , decodeProbeRecoveryRequest
  , probeRecoveryControllerRequest
  , probeRecoveryId
  , probeRecoveryNamespaceUid
  , ProbeAttemptVerifierRequest
  , mkProbeAttemptVerifierRequest
  , mkIsolatedProbeVerifierRequest
  , probeVerifierIsIsolated
  , encodeProbeAttemptVerifierRequest
  , decodeProbeAttemptVerifierRequest
  , probeVerifierRecoveryRequest
  , probeVerifierPriorId
  , ProbeSuccessorRequest
  , mkProbeSuccessorRequest
  , encodeProbeSuccessorRequest
  , decodeProbeSuccessorRequest
  , probeSuccessorVerifier
  , probeSuccessorPredecessorId
  , validProbeSuccessorChain
  ) where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeIdentifier
  , scopeRoot
  , validRootGeneration
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Subprocess.SystemdIdentity qualified as Identity

data KindControllerRequest = KindControllerRequest
  { kindRequestOperation :: !String
  , kindRequestExecutableDigest :: !String
  , kindRequestManagerDomain :: !Identity.HostManagerDomain
  , kindRequestWindow :: !Identity.HostExecutionWindow
  , requestScope :: !String
  , requestRoot :: !FilePath
  , requestGeneration :: !Text.Text
  , requestSocket :: !FilePath
  }
  deriving (Eq, Show)

data KindControllerRequestError
  = KindRequestInvalid
  | KindRequestTooLarge
  | KindRequestMalformed
  | KindRequestNonCanonical
  | KindRequestBindingMismatch
  deriving (Eq, Show)

-- Coordinates for a distinct cleanup family. A retained request is a locator,
-- not evidence that a submission happened or that either family retired.
data ProbeRecoveryRequest = ProbeRecoveryRequest
  { probeRecoveryControllerRequest :: !KindControllerRequest
  , probeRecoveryId :: !String
  , probeRecoveryNamespaceUid :: !String
  }
  deriving (Eq, Show)

mkProbeRecoveryRequest
  :: KindControllerRequest -> String -> String -> Either KindControllerRequestError ProbeRecoveryRequest
mkProbeRecoveryRequest request recovery uid
  | kindProbeRecoveryKey (kindRequestOperation request) recovery == Nothing
      || not (validNamespaceUid uid) =
      Left KindRequestInvalid
  | otherwise = Right (ProbeRecoveryRequest request recovery uid)

validNamespaceUid :: String -> Bool
validNamespaceUid value =
  length value == 36
    && and
      [ if index `elem` [8, 13, 18, 23] then c == '-' else c >= '0' && c <= '9' || c >= 'a' && c <= 'f'
      | (index, c) <- zip [0 :: Int ..] value
      ]

encodeProbeRecoveryRequest :: ProbeRecoveryRequest -> BS.ByteString
encodeProbeRecoveryRequest request =
  BL.toStrict . Aeson.encode $
    Aeson.object
      [ "version" .= (1 :: Int)
      , "controller_request"
          .= TextEncoding.decodeUtf8 (encodeKindControllerRequest (probeRecoveryControllerRequest request))
      , "recovery_id" .= probeRecoveryId request
      , "namespace_uid" .= probeRecoveryNamespaceUid request
      ]

decodeProbeRecoveryRequest
  :: BootstrapProjection
  -> String
  -> BS.ByteString
  -> Either KindControllerRequestError ProbeRecoveryRequest
decodeProbeRecoveryRequest bootstrap operation bytes = do
  if BS.length bytes > 16384 then Left KindRequestTooLarge else pure ()
  value <- either (const (Left KindRequestMalformed)) Right (Aeson.eitherDecodeStrict' bytes)
  (version, controller, recovery, uid) <-
    either (const (Left KindRequestMalformed)) Right $
      parseEither
        ( Aeson.withObject "probe recovery request" $ \o ->
            (,,,)
              <$> o .: "version"
              <*> o .: "controller_request"
              <*> o .: "recovery_id"
              <*> o .: "namespace_uid"
        )
        value
  if (version :: Int) /= 1 then Left KindRequestMalformed else pure ()
  original <-
    decodeRetainedKindControllerRequest bootstrap operation (TextEncoding.encodeUtf8 controller)
  request <- mkProbeRecoveryRequest original recovery uid
  if encodeProbeRecoveryRequest request == bytes then Right request else Left KindRequestNonCanonical

-- The verifier runs under its own recovery-style key and window; the prior
-- ID identifies the cleanup family whose uncertain attempt it will inspect.
data ProbeAttemptVerifierRequest = ProbeAttemptVerifierRequest
  { probeVerifierRecoveryRequest :: !ProbeRecoveryRequest
  , probeVerifierPriorId :: !String
  , probeVerifierIsIsolated :: !Bool
  }
  deriving (Eq, Show)

mkProbeAttemptVerifierRequest
  :: ProbeRecoveryRequest -> String -> Either KindControllerRequestError ProbeAttemptVerifierRequest
mkProbeAttemptVerifierRequest verifier prior
  | not (validRootGeneration prior)
      || prior == kindRequestOperation (probeRecoveryControllerRequest verifier)
      || prior == probeRecoveryId verifier =
      Left KindRequestInvalid
  | otherwise = Right (ProbeAttemptVerifierRequest verifier prior False)

mkIsolatedProbeVerifierRequest
  :: ProbeRecoveryRequest -> String -> Either KindControllerRequestError ProbeAttemptVerifierRequest
mkIsolatedProbeVerifierRequest verifier prior = do
  request <- mkProbeAttemptVerifierRequest verifier prior
  pure request {probeVerifierIsIsolated = True}

encodeProbeAttemptVerifierRequest :: ProbeAttemptVerifierRequest -> BS.ByteString
encodeProbeAttemptVerifierRequest request =
  BL.toStrict . Aeson.encode $
    Aeson.object
      [ "version" .= (if probeVerifierIsIsolated request then 2 else 1 :: Int)
      , "verifier_request"
          .= TextEncoding.decodeUtf8 (encodeProbeRecoveryRequest (probeVerifierRecoveryRequest request))
      , "prior_recovery_id" .= probeVerifierPriorId request
      ]

decodeProbeAttemptVerifierRequest
  :: BootstrapProjection
  -> String
  -> BS.ByteString
  -> Either KindControllerRequestError ProbeAttemptVerifierRequest
decodeProbeAttemptVerifierRequest bootstrap operation bytes = do
  if BS.length bytes > 16384 then Left KindRequestTooLarge else pure ()
  value <- either (const (Left KindRequestMalformed)) Right (Aeson.eitherDecodeStrict' bytes)
  (version, verifier, prior) <-
    either (const (Left KindRequestMalformed)) Right $
      parseEither
        ( Aeson.withObject "probe verifier request" $ \o ->
            (,,) <$> o .: "version" <*> o .: "verifier_request" <*> o .: "prior_recovery_id"
        )
        value
  if (version :: Int) `notElem` [1, 2] then Left KindRequestMalformed else pure ()
  nested <- decodeProbeRecoveryRequest bootstrap operation (TextEncoding.encodeUtf8 verifier)
  request <-
    (if version == 2 then mkIsolatedProbeVerifierRequest else mkProbeAttemptVerifierRequest)
      nested
      prior
  if encodeProbeAttemptVerifierRequest request == bytes
    then Right request
    else Left KindRequestNonCanonical

-- A successor retains the original cleanup identity as well as the exact
-- verifier it succeeds. It is only coordinates, never a retirement permit.
data ProbeSuccessorRequest = ProbeSuccessorRequest
  { probeSuccessorVerifier :: !ProbeAttemptVerifierRequest
  , probeSuccessorPredecessorId :: !String
  }
  deriving (Eq, Show)

mkProbeSuccessorRequest
  :: ProbeAttemptVerifierRequest -> String -> Either KindControllerRequestError ProbeSuccessorRequest
mkProbeSuccessorRequest verifier predecessor
  | not (probeVerifierIsIsolated verifier)
      || not (validRootGeneration predecessor)
      || predecessor == probeVerifierPriorId verifier
      || predecessor == probeRecoveryId coordinates
      || predecessor == kindRequestOperation (probeRecoveryControllerRequest coordinates) =
      Left KindRequestInvalid
  | otherwise = Right (ProbeSuccessorRequest verifier predecessor)
 where
  coordinates = probeVerifierRecoveryRequest verifier

encodeProbeSuccessorRequest :: ProbeSuccessorRequest -> BS.ByteString
encodeProbeSuccessorRequest request =
  BL.toStrict . Aeson.encode $
    Aeson.object
      [ "version" .= (1 :: Int)
      , "verifier_request"
          .= TextEncoding.decodeUtf8 (encodeProbeAttemptVerifierRequest (probeSuccessorVerifier request))
      , "predecessor_id" .= probeSuccessorPredecessorId request
      ]

decodeProbeSuccessorRequest
  :: BootstrapProjection
  -> String
  -> BS.ByteString
  -> Either KindControllerRequestError ProbeSuccessorRequest
decodeProbeSuccessorRequest bootstrap operation bytes = do
  if BS.length bytes > 32768 then Left KindRequestTooLarge else pure ()
  value <- either (const (Left KindRequestMalformed)) Right (Aeson.eitherDecodeStrict' bytes)
  (version, verifier, predecessor) <-
    either (const (Left KindRequestMalformed)) Right $
      parseEither
        ( Aeson.withObject "probe successor request" $ \o ->
            (,,) <$> o .: "version" <*> o .: "verifier_request" <*> o .: "predecessor_id"
        )
        value
  if (version :: Int) /= 1 then Left KindRequestMalformed else pure ()
  nested <- decodeProbeAttemptVerifierRequest bootstrap operation (TextEncoding.encodeUtf8 verifier)
  request <- mkProbeSuccessorRequest nested predecessor
  if encodeProbeSuccessorRequest request == bytes then Right request else Left KindRequestNonCanonical

-- Pure structural validation only: every recorded family still needs its own
-- independently held retirement and authenticated namespace observation.
validProbeSuccessorChain :: ProbeAttemptVerifierRequest -> [ProbeSuccessorRequest] -> Bool
validProbeSuccessorChain first successors =
  length successors <= 32 && go [firstId] firstId successors
 where
  firstCoordinates = probeVerifierRecoveryRequest first
  firstController = probeRecoveryControllerRequest firstCoordinates
  firstId = probeRecoveryId firstCoordinates
  operation = kindRequestOperation (probeRecoveryControllerRequest firstCoordinates)
  uid = probeRecoveryNamespaceUid firstCoordinates
  cleanup = probeVerifierPriorId first
  go _ _ [] = True
  go seen predecessor (entry : rest) =
    let verifier = probeSuccessorVerifier entry
        coordinates = probeVerifierRecoveryRequest verifier
        controller = probeRecoveryControllerRequest coordinates
        identity = probeRecoveryId coordinates
     in probeSuccessorPredecessorId entry == predecessor
          && kindRequestOperation controller == operation
          && requestScope controller == requestScope firstController
          && requestRoot controller == requestRoot firstController
          && requestGeneration controller == requestGeneration firstController
          && requestSocket controller == requestSocket firstController
          && kindRequestManagerDomain controller == kindRequestManagerDomain firstController
          && probeRecoveryNamespaceUid coordinates == uid
          && probeVerifierPriorId verifier == cleanup
          && identity `notElem` seen
          && go (identity : seen) identity rest

kindControllerOperationKey :: String -> Maybe Identity.HostExecutionKey
kindControllerOperationKey operation
  | validRootGeneration operation = Identity.hostExecutionKeyFromText (operation <> operation)
  | otherwise = Nothing

-- A cleanup worker has its own retained run identity and cannot reuse the
-- original node family's key. This only constructs coordinates; it does not
-- admit a recovery or establish settlement of either family.
kindProbeRecoveryKey :: String -> String -> Maybe Identity.HostExecutionKey
kindProbeRecoveryKey operation recovery
  | validRootGeneration operation && validRootGeneration recovery && operation /= recovery =
      Identity.hostExecutionKeyFromText (operation <> recovery)
  | otherwise = Nothing

mkKindControllerRequest
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> Either KindControllerRequestError KindControllerRequest
mkKindControllerRequest bootstrap operation digest domain window
  | scopeEnvironment scope /= Test || not (validRootGeneration operation) || not (validImageId digest) =
      Left KindRequestInvalid
  | otherwise =
      Right
        ( KindControllerRequest
            operation
            digest
            domain
            window
            (scopeIdentifier scope)
            (scopeRoot scope)
            (bootstrapRootGeneration bootstrap)
            (bootstrapRuntimeSocket bootstrap)
        )
 where
  scope = bootstrapScope bootstrap

encodeKindControllerRequest :: KindControllerRequest -> BS.ByteString
encodeKindControllerRequest request =
  BL.toStrict . Aeson.encode $
    Aeson.object
      [ "version" .= (1 :: Int)
      , "operation" .= kindRequestOperation request
      , "executable_sha256" .= kindRequestExecutableDigest request
      , "scope" .= requestScope request
      , "root" .= requestRoot request
      , "generation" .= requestGeneration request
      , "runtime_socket" .= requestSocket request
      , "boot_id" .= Identity.hostManagerBootId domain
      , "bus_id" .= Identity.hostManagerBusId domain
      , "manager_name" .= Identity.hostManagerUniqueName domain
      , "uid" .= Identity.hostManagerUserId domain
      , "pid" .= Identity.hostManagerProcessId domain
      , "start_ticks" .= Identity.hostManagerStartTicks domain
      , "window"
          .= map
            ($ kindRequestWindow request)
            [ Identity.hostExecutionOuterEnd
            , Identity.hostExecutionWorkEnd
            , Identity.hostExecutionHardEnd
            , Identity.hostExecutionStopEnd
            , Identity.hostExecutionFinishEnd
            ]
      ]
 where
  domain = kindRequestManagerDomain request

-- Expected key/window come from pinned arguments, scope coordinates from the
-- pinned configuration, and digest/domain from independently checked owners.
decodeKindControllerRequest
  :: BootstrapProjection
  -> Identity.HostExecutionKey
  -> Identity.HostExecutionWindow
  -> Identity.HostManagerDomain
  -> String
  -> BS.ByteString
  -> Either KindControllerRequestError KindControllerRequest
decodeKindControllerRequest bootstrap expectedKey expectedWindow expectedDomain expectedDigest bytes
  | BS.length bytes > 16384 = Left KindRequestTooLarge
  | otherwise = do
      value <- either (const (Left KindRequestMalformed)) Right (Aeson.eitherDecodeStrict' bytes)
      ( version
        , operation
        , digest
        , scope
        , root
        , generation
        , socket
        , boot
        , bus
        , name
        , uid
        , pid
        , ticks
        , clocks
        ) <-
        either (const (Left KindRequestMalformed)) Right $
          parseEither
            ( Aeson.withObject "kind controller request" $ \o ->
                (,,,,,,,,,,,,,)
                  <$> o .: "version"
                  <*> o .: "operation"
                  <*> o .: "executable_sha256"
                  <*> o .: "scope"
                  <*> o .: "root"
                  <*> o .: "generation"
                  <*> o .: "runtime_socket"
                  <*> o .: "boot_id"
                  <*> o .: "bus_id"
                  <*> o .: "manager_name"
                  <*> o .: "uid"
                  <*> o .: "pid"
                  <*> o .: "start_ticks"
                  <*> o .: "window"
            )
            value
      if (version :: Int) /= 1 then Left KindRequestMalformed else pure ()
      domain <-
        maybe (Left KindRequestMalformed) Right (Identity.hostManagerDomain boot bus name uid pid ticks)
      window <- case (clocks :: [Word64]) of
        [outer, work, hard, stop, finish] ->
          maybe (Left KindRequestMalformed) Right (Identity.hostExecutionWindow outer work hard stop finish)
        _ -> Left KindRequestMalformed
      request <- mkKindControllerRequest bootstrap operation digest domain window
      if (scope, root, generation, socket)
        /= (requestScope request, requestRoot request, requestGeneration request, requestSocket request)
        || kindControllerOperationKey operation /= Just expectedKey
        || window /= expectedWindow
        || domain /= expectedDomain
        || digest /= expectedDigest
        then Left KindRequestBindingMismatch
        else pure ()
      if encodeKindControllerRequest request /= bytes then Left KindRequestNonCanonical else Right request

-- Recover the original coordinates from a retained request. They remain
-- claims until independently checked against the manager and submission.
decodeRetainedKindControllerRequest
  :: BootstrapProjection
  -> String
  -> BS.ByteString
  -> Either KindControllerRequestError KindControllerRequest
decodeRetainedKindControllerRequest bootstrap operation bytes = do
  if BS.length bytes > 16384 then Left KindRequestTooLarge else pure ()
  key <- maybe (Left KindRequestInvalid) Right (kindControllerOperationKey operation)
  value <- either (const (Left KindRequestMalformed)) Right (Aeson.eitherDecodeStrict' bytes)
  (digest, boot, bus, name, uid, pid, ticks, clocks) <-
    either (const (Left KindRequestMalformed)) Right $
      parseEither
        ( Aeson.withObject "retained kind request" $ \o ->
            (,,,,,,,)
              <$> o .: "executable_sha256"
              <*> o .: "boot_id"
              <*> o .: "bus_id"
              <*> o .: "manager_name"
              <*> o .: "uid"
              <*> o .: "pid"
              <*> o .: "start_ticks"
              <*> o .: "window"
        )
        value
  domain <-
    maybe (Left KindRequestMalformed) Right (Identity.hostManagerDomain boot bus name uid pid ticks)
  window <- case (clocks :: [Word64]) of
    [outer, work, hard, stop, finish] ->
      maybe (Left KindRequestMalformed) Right (Identity.hostExecutionWindow outer work hard stop finish)
    _ -> Left KindRequestMalformed
  decodeKindControllerRequest bootstrap key window domain digest bytes
