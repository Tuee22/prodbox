{-# LANGUAGE ImportQualifiedPost #-}

-- | Descriptor-bound input loading for the future kind family dispatcher.
-- A decoded request is not a manager, process-placement or lifecycle permit.
module Prodbox.Control.KindControllerInput
  ( KindControllerInputError (..)
  , KindControllerInputOutcome (..)
  , withPinnedKindControllerInput
  , withPinnedKindProbeRecoveryInput
  , withPinnedKindProbeVerifierInput
  , withPinnedKindProbeSuccessorInput
  , isKindProbeSuccessorArguments
  , KindProbeFamilyRequest (..)
  , withPinnedKindProbeFamilyInput
  ) where

import Data.ByteString qualified as ByteString
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.BootstrapProjection qualified as Bootstrap
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Posix.User (getEffectiveUserID)

data KindControllerInputError
  = KindInputOwnerRefused !Family.HostOperationError
  | KindInputInvalidUtf8
  | KindInputBootstrapRefused !Bootstrap.BootstrapProjectionError
  | KindInputBootstrapMissing
  | KindInputRequestRefused !Request.KindControllerRequestError
  deriving (Eq, Show)

data KindControllerInputOutcome value
  = KindInputRefused !KindControllerInputError
  | KindInputCompleted !value
  | KindInputChangedAfter !value !Family.HostOperationError
  deriving (Eq, Show)

data KindProbeFamilyRequest
  = KindProbeCleanupRequest !Request.ProbeRecoveryRequest
  | KindProbeVerifierRequest !Request.ProbeAttemptVerifierRequest
  | KindProbeSuccessorRequest !Request.ProbeSuccessorRequest
  deriving (Eq, Show)

isKindProbeSuccessorArguments :: Arguments.HostControllerArguments -> IO Bool
isKindProbeSuccessorArguments arguments = do
  uid <- getEffectiveUserID
  let directory =
        Publication.hostControllerPublishedDirectory
          Identity.KindProbeSuccessorController
          uid
          (Arguments.controllerOperationKey arguments)
  pure
    ( Arguments.controllerConfigurationPath arguments
        == directory ++ "/" ++ Publication.hostControllerConfigurationName
        && Arguments.controllerRequestPath arguments
          == directory ++ "/" ++ Publication.hostControllerRequestName
    )

-- The expected domain must be supplied by an independently verified owner;
-- the executable digest comes from the held executable descriptor itself.
-- The live input recheck can be passed into later owned boundaries;
-- retaining it past this callback only returns ControllerInputsClosed.
withPinnedKindControllerInput
  :: Arguments.HostControllerArguments
  -> Identity.HostManagerDomain
  -> ( Bootstrap.BootstrapProjection
       -> Request.KindControllerRequest
       -> Family.HostControllerProgram
       -> IO (Either Family.HostOperationError ())
       -> IO value
     )
  -> IO (KindControllerInputOutcome value)
withPinnedKindControllerInput arguments domain action = do
  withPinnedKindInput
    arguments
    ( \kind projection digest bytes ->
        if kind /= Identity.KindController
          then Left Request.KindRequestBindingMismatch
          else
            Request.decodeKindControllerRequest
              projection
              (Arguments.controllerOperationKey arguments)
              (Arguments.controllerOriginalWindow arguments)
              domain
              digest
              bytes
    )
    action

-- Recovery input uses the same held descriptors and independently supplied
-- manager, but must bind the distinct cleanup key and the recovery window.
withPinnedKindProbeRecoveryInput
  :: Arguments.HostControllerArguments
  -> Identity.HostManagerDomain
  -> ( Bootstrap.BootstrapProjection
       -> Request.ProbeRecoveryRequest
       -> Family.HostControllerProgram
       -> IO (Either Family.HostOperationError ())
       -> IO value
     )
  -> IO (KindControllerInputOutcome value)
withPinnedKindProbeRecoveryInput arguments domain action =
  withPinnedKindInput arguments decode action
 where
  operation = take 32 (Identity.hostExecutionKeyText (Arguments.controllerOperationKey arguments))
  decode kind projection digest bytes = do
    if kind == Identity.KindController then pure () else Left Request.KindRequestBindingMismatch
    recovery <- Request.decodeProbeRecoveryRequest projection operation bytes
    bindProbeCoordinates arguments domain digest recovery
    pure recovery

withPinnedKindProbeVerifierInput
  :: Arguments.HostControllerArguments
  -> Identity.HostManagerDomain
  -> ( Bootstrap.BootstrapProjection
       -> Request.ProbeAttemptVerifierRequest
       -> Family.HostControllerProgram
       -> IO (Either Family.HostOperationError ())
       -> IO value
     )
  -> IO (KindControllerInputOutcome value)
withPinnedKindProbeVerifierInput arguments domain action = withPinnedKindInput arguments decode action
 where
  operation = take 32 (Identity.hostExecutionKeyText (Arguments.controllerOperationKey arguments))
  decode kind projection digest bytes = do
    verifier <- Request.decodeProbeAttemptVerifierRequest projection operation bytes
    if kind
      == ( if Request.probeVerifierIsIsolated verifier
             then Identity.KindProbeVerifierController
             else Identity.KindController
         )
      then pure ()
      else Left Request.KindRequestBindingMismatch
    bindProbeCoordinates arguments domain digest (Request.probeVerifierRecoveryRequest verifier)
    pure verifier

withPinnedKindProbeSuccessorInput
  :: Arguments.HostControllerArguments
  -> Identity.HostManagerDomain
  -> ( Bootstrap.BootstrapProjection
       -> Request.ProbeSuccessorRequest
       -> Family.HostControllerProgram
       -> IO (Either Family.HostOperationError ())
       -> IO value
     )
  -> IO (KindControllerInputOutcome value)
withPinnedKindProbeSuccessorInput arguments domain action = withPinnedKindInput arguments decode action
 where
  operation = take 32 (Identity.hostExecutionKeyText (Arguments.controllerOperationKey arguments))
  decode kind projection digest bytes = do
    if kind == Identity.KindProbeSuccessorController
      then pure ()
      else Left Request.KindRequestBindingMismatch
    successor <- Request.decodeProbeSuccessorRequest projection operation bytes
    bindProbeCoordinates
      arguments
      domain
      digest
      (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
    pure successor

-- Cleanup and verifier keys have the same shape. Select between them only
-- after decoding the canonical bytes held by the same pinned owner.
withPinnedKindProbeFamilyInput
  :: Arguments.HostControllerArguments
  -> Identity.HostManagerDomain
  -> ( Bootstrap.BootstrapProjection
       -> KindProbeFamilyRequest
       -> Family.HostControllerProgram
       -> IO (Either Family.HostOperationError ())
       -> IO value
     )
  -> IO (KindControllerInputOutcome value)
withPinnedKindProbeFamilyInput arguments domain action = withPinnedKindInput arguments decode action
 where
  operation = take 32 (Identity.hostExecutionKeyText (Arguments.controllerOperationKey arguments))
  decode Identity.KindProbeSuccessorController projection digest bytes = do
    successor <- Request.decodeProbeSuccessorRequest projection operation bytes
    bindProbeCoordinates
      arguments
      domain
      digest
      (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
    pure (KindProbeSuccessorRequest successor)
  decode kind projection digest bytes = case Request.decodeProbeRecoveryRequest projection operation bytes of
    Right recovery -> do
      if kind == Identity.KindController then pure () else Left Request.KindRequestBindingMismatch
      bindProbeCoordinates arguments domain digest recovery
      pure (KindProbeCleanupRequest recovery)
    Left _ -> do
      verifier <- Request.decodeProbeAttemptVerifierRequest projection operation bytes
      if kind
        == ( if Request.probeVerifierIsIsolated verifier
               then Identity.KindProbeVerifierController
               else Identity.KindController
           )
        then pure ()
        else Left Request.KindRequestBindingMismatch
      bindProbeCoordinates arguments domain digest (Request.probeVerifierRecoveryRequest verifier)
      pure (KindProbeVerifierRequest verifier)

bindProbeCoordinates
  :: Arguments.HostControllerArguments
  -> Identity.HostManagerDomain
  -> String
  -> Request.ProbeRecoveryRequest
  -> Either Request.KindControllerRequestError ()
bindProbeCoordinates arguments domain digest recovery =
  let request = Request.probeRecoveryControllerRequest recovery
      operation = Request.kindRequestOperation request
   in if Request.kindProbeRecoveryKey operation (Request.probeRecoveryId recovery)
        /= Just (Arguments.controllerOperationKey arguments)
        || Request.kindRequestWindow request /= Arguments.controllerOriginalWindow arguments
        || Request.kindRequestManagerDomain request /= domain
        || Request.kindRequestExecutableDigest request /= digest
        then Left Request.KindRequestBindingMismatch
        else Right ()

withPinnedKindInput
  :: Arguments.HostControllerArguments
  -> ( Identity.HostControllerKind
       -> Bootstrap.BootstrapProjection
       -> String
       -> ByteString.ByteString
       -> Either Request.KindControllerRequestError request
     )
  -> ( Bootstrap.BootstrapProjection
       -> request
       -> Family.HostControllerProgram
       -> IO (Either Family.HostOperationError ())
       -> IO value
     )
  -> IO (KindControllerInputOutcome value)
withPinnedKindInput arguments decode action = do
  uid <- getEffectiveUserID
  let verifierDirectory =
        Publication.hostControllerPublishedDirectory
          Identity.KindProbeVerifierController
          uid
          (Arguments.controllerOperationKey arguments)
      successorDirectory =
        Publication.hostControllerPublishedDirectory
          Identity.KindProbeSuccessorController
          uid
          (Arguments.controllerOperationKey arguments)
      matches directory =
        Arguments.controllerConfigurationPath arguments
          == directory ++ "/" ++ Publication.hostControllerConfigurationName
          && Arguments.controllerRequestPath arguments
            == directory ++ "/" ++ Publication.hostControllerRequestName
      kind
        | matches verifierDirectory = Identity.KindProbeVerifierController
        | matches successorDirectory = Identity.KindProbeSuccessorController
        | otherwise = Identity.KindController
  result <-
    Family.withPinnedHostControllerProgram
      kind
      (Identity.hostExecutionWorkEnd window)
      (Arguments.controllerInputFingerprint arguments)
      configuration
      (Arguments.controllerRequestPath arguments)
      (use kind)
  pure $ either (KindInputRefused . KindInputOwnerRefused) id result
 where
  configuration = Arguments.controllerConfigurationPath arguments
  window = Arguments.controllerOriginalWindow arguments
  use kind inputs = do
    executable <- Family.hashHostControllerProgramExecutable inputs
    case executable of
      Left failure -> pure (KindInputRefused (KindInputOwnerRefused failure))
      Right actual -> readInputs kind inputs actual
  readInputs kind inputs executableDigest = do
    bytes <- Family.readHostControllerProgramInputs inputs
    case bytes of
      Left failure -> pure (KindInputRefused (KindInputOwnerRefused failure))
      Right held -> case TextEncoding.decodeUtf8' (Family.hostControllerConfigurationBytes held) of
        Left _ -> pure (KindInputRefused KindInputInvalidUtf8)
        Right source -> do
          parsed <- Bootstrap.decodeOptionalBootstrapSource configuration source
          case parsed of
            Left failure -> pure (KindInputRefused (KindInputBootstrapRefused failure))
            Right Nothing -> pure (KindInputRefused KindInputBootstrapMissing)
            Right (Just projection) -> case decode kind projection executableDigest (Family.hostControllerRequestBytes held) of
              Left failure -> pure (KindInputRefused (KindInputRequestRefused failure))
              Right request -> do
                before <- Family.verifyHostControllerProgramInputs inputs
                case before of
                  Left failure -> pure (KindInputRefused (KindInputOwnerRefused failure))
                  Right () -> do
                    value <- action projection request inputs (Family.verifyHostControllerProgramInputs inputs)
                    after <- Family.verifyHostControllerProgramInputs inputs
                    pure $ either (KindInputChangedAfter value) (const (KindInputCompleted value)) after
