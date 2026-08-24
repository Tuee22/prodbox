{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Explicit host authentication for Lifecycle Authority clients.
--
-- The host chooses either the operator or test-harness identity.  That choice
-- fixes the Kubernetes ServiceAccount, Vault Kubernetes-auth role, and Transit
-- signing key as one closed tuple.  A fresh home-cluster TokenRequest is minted
-- through the explicitly resolved home kubeconfig; no ambient kube context,
-- shared profile, root token, exported private key, or default caller exists.
module Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (..)
  , LifecycleAuthorityAuthentication
  , LifecycleAuthorityAuthenticationError (..)
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , lifecycleAuthorityManifestSignerDigest
  , withLifecycleAuthorityAuthenticatedTransport
  , withProviderWorkerAuthenticatedTransport
  , withTargetSecretAgentAuthenticatedTransport
  , withSelectedTargetSecretAgentAuthenticatedTransport
  , withAuthorityBackupAuthenticatedTransport
  , withTlsRetentionAuthenticatedTransport
  , externalCallerServiceAccount
  , externalCallerServiceAccountReadArguments
  , externalCallerTokenEligibilityArguments
  , externalCallerTokenRequestArguments
  , validateExternalCallerServiceAccountReadBack
  , ServiceAccountObservationFailure (..)
  , classifyServiceAccountObservation
  , serviceAccountObservationAuthorityReached
  , renderServiceAccountObservationFailure
  , ExternalCallerTokenError (..)
  , externalCallerTokenAuthorityReached
  , externalCallerTokenAuthorityRefusedAuthorization
  , externalCallerTokenSessionError
  , renderExternalCallerTokenError
  )
where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Config.Basics
  ( UnencryptedBasics
      ( basicsClusterId
      , basicsVaultAddress
      )
  )
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , AuthenticatedTransportBoundsError
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  , harnessControlPlaneVaultRole
  , operatorControlPlaneVaultRole
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerTestHarness)
  )
import Prodbox.ControlPlane.Coordinate
  ( CoordinateError
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.LocalClient
  ( LocalAuthorityBackupError
  , LocalLifecycleAuthorityError
  , LocalProviderWorkerError
  , LocalTargetSecretAgentError
  , LocalTlsRetentionError
  , withLocalAuthorityBackupAuthenticatedTransport
  , withLocalLifecycleAuthorityAuthenticatedTransport
  , withLocalProviderWorkerAuthenticatedTransport
  , withLocalTargetSecretAgentAuthenticatedTransport
  , withLocalTlsRetentionAuthenticatedTransport
  , withTargetSecretAgentAuthenticatedTransportUsingEnvironment
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( readRetainedAuthorityEpoch
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
import Prodbox.Infra.MinioBackend (resolveLocalKubeconfig)
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  , vaultAuthorityManifestSigner
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyDigest)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , LeaseValueError
  , authorityDurationFromMicros
  )
import Prodbox.Runtime.Role
  ( RuntimeRole
      ( AuthorityBackupRuntime
      , LifecycleAuthorityRuntime
      , ProviderWorkerRuntime
      , TargetSecretAgentRuntime
      , TlsRetentionRuntime
      )
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import Prodbox.Vault.Client
  ( VaultAddress (VaultAddress)
  , VaultKubernetesLoginResult (..)
  , vaultKubernetesLoginWithLease
  )
import Prodbox.Vault.Session
  ( LoginLease (..)
  , VaultSessionError (VaultSessionForbidden, VaultSessionUnavailable)
  , httpErrorToSessionError
  , newVaultSession
  , realSessionClock
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

data ExternalLifecycleAuthorityCaller
  = LifecycleAuthorityOperator
  | LifecycleAuthorityTestHarness
  deriving stock (Eq, Show)

-- | Opaque, caller-bound client authentication.  The only production
-- constructor is 'withHostLifecycleAuthorityAuthentication'.
data LifecycleAuthorityAuthentication = LifecycleAuthorityAuthentication
  { lifecycleAuthenticationBounds :: !AuthenticatedTransportBounds
  , lifecycleAuthenticationProviders :: !(AuthenticatedClientProviders IO)
  , lifecycleAuthenticationManifestSignerDigest :: !FrameDigest
  }

data LifecycleAuthorityAuthenticationError
  = LifecycleAuthorityHomeKubeconfigUnavailable !String
  | LifecycleAuthorityHomeIdentityUnavailable !String
  | LifecycleAuthorityScopeInvalid !CoordinateError
  | LifecycleAuthorityTransportBoundsInvalid !AuthenticatedTransportBoundsError
  | LifecycleAuthorityRequestLifetimeInvalid !LeaseValueError
  | LifecycleAuthoritySigningCapabilityUnavailable !Text
  | LifecycleAuthorityManifestSignerUnavailable !Text
  | LifecycleAuthorityLocalTransportUnavailable !LocalLifecycleAuthorityError
  | ProviderWorkerLocalTransportUnavailable !LocalProviderWorkerError
  | TargetSecretAgentLocalTransportUnavailable !LocalTargetSecretAgentError
  | AuthorityBackupLocalTransportUnavailable !LocalAuthorityBackupError
  | TlsRetentionLocalTransportUnavailable !LocalTlsRetentionError
  deriving stock (Eq, Show)

renderLifecycleAuthorityAuthenticationError
  :: LifecycleAuthorityAuthenticationError -> String
renderLifecycleAuthorityAuthenticationError err = case err of
  LifecycleAuthorityHomeKubeconfigUnavailable detail ->
    "resolve home kubeconfig for Lifecycle Authority authentication: " ++ detail
  LifecycleAuthorityHomeIdentityUnavailable detail ->
    "resolve explicit Lifecycle Authority caller identity: " ++ detail
  LifecycleAuthorityScopeInvalid detail ->
    "validate Lifecycle Authority scope: " ++ show detail
  LifecycleAuthorityTransportBoundsInvalid detail ->
    "validate Lifecycle Authority transport bounds: " ++ show detail
  LifecycleAuthorityRequestLifetimeInvalid detail ->
    "validate Lifecycle Authority request lifetime: " ++ show detail
  LifecycleAuthoritySigningCapabilityUnavailable detail ->
    "resolve caller-bound Lifecycle Authority Transit signer: " ++ Text.unpack detail
  LifecycleAuthorityManifestSignerUnavailable detail ->
    "resolve pinned Authority decommission manifest signer: " ++ Text.unpack detail
  LifecycleAuthorityLocalTransportUnavailable detail ->
    "open caller-bound Lifecycle Authority transport: " ++ show detail
  ProviderWorkerLocalTransportUnavailable detail ->
    "open caller-bound Provider Worker transport: " ++ show detail
  TargetSecretAgentLocalTransportUnavailable detail ->
    "open caller-bound Target Secret Agent transport: " ++ show detail
  AuthorityBackupLocalTransportUnavailable detail ->
    "open caller-bound Authority Backup transport: " ++ show detail
  TlsRetentionLocalTransportUnavailable detail ->
    "open caller-bound TLS Retention transport: " ++ show detail

withHostLifecycleAuthorityAuthentication
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> (LifecycleAuthorityAuthentication -> IO value)
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withHostLifecycleAuthorityAuthentication caller repoRoot action = do
  kubeconfigResult <- resolveLocalKubeconfig
  basicsResult <- loadUnencryptedBasics repoRoot
  case (kubeconfigResult, basicsResult, lifecycleAuthenticationConstants) of
    (Left detail, _, _) ->
      pure (Left (LifecycleAuthorityHomeKubeconfigUnavailable detail))
    (_, Left detail, _) ->
      pure (Left (LifecycleAuthorityHomeIdentityUnavailable detail))
    (_, _, Left err) -> pure (Left err)
    (Right kubeconfig, Right basics, Right (bounds, lifetime)) ->
      case mapLeft LifecycleAuthorityScopeInvalid (mkAuthorityScope (basicsClusterId basics)) of
        Left err -> pure (Left err)
        Right scope -> do
          environment <- homeKubectlEnvironment kubeconfig
          let address = VaultAddress (basicsVaultAddress basics)
          session <-
            newVaultSession
              address
              realSessionClock
              (externalCallerLogin address environment repoRoot caller)
          signerResult <-
            resolveTransitRequestSigningCapability
              session
              (externalCallerPrincipal caller)
              (controlPlaneSigningKeyRefFor (externalCallerPrincipal caller))
          case signerResult of
            Left detail ->
              pure
                ( Left
                    (LifecycleAuthoritySigningCapabilityUnavailable detail)
                )
            Right signer ->
              do
                manifestSignerResult <-
                  readAuthorityManifestPublicKey
                    (vaultAuthorityManifestSigner session)
                case manifestSignerResult of
                  Left detail ->
                    pure
                      ( Left
                          (LifecycleAuthorityManifestSignerUnavailable detail)
                      )
                  Right (_, publicKey) ->
                    action
                      LifecycleAuthorityAuthentication
                        { lifecycleAuthenticationBounds = bounds
                        , lifecycleAuthenticationProviders =
                            transitAuthenticatedClientProviders
                              signer
                              (pure (Right scope))
                              (readRetainedAuthorityEpoch session)
                              lifetime
                        , lifecycleAuthenticationManifestSignerDigest =
                            manifestPublicKeyDigest publicKey
                        }
                      >>= pure . Right

lifecycleAuthorityManifestSignerDigest
  :: LifecycleAuthorityAuthentication
  -> FrameDigest
lifecycleAuthorityManifestSignerDigest =
  lifecycleAuthenticationManifestSignerDigest

lifecycleAuthenticationConstants
  :: Either
       LifecycleAuthorityAuthenticationError
       (AuthenticatedTransportBounds, AuthorityDuration)
lifecycleAuthenticationConstants = do
  bounds <-
    mapLeft
      LifecycleAuthorityTransportBoundsInvalid
      ( mkAuthenticatedTransportBounds
          lifecycleAuthorityFrameMaximumBytes
          lifecycleAuthorityMetadataMaximumBytes
          lifecycleAuthorityEnvelopeMaximumBytes
      )
  lifetime <-
    mapLeft
      LifecycleAuthorityRequestLifetimeInvalid
      (authorityDurationFromMicros lifecycleAuthorityRequestLifetimeMicros)
  Right (bounds, lifetime)

withLifecycleAuthorityAuthenticatedTransport
  :: LifecycleAuthorityAuthentication
  -> ( AuthenticatedClientTransport 'LifecycleAuthorityRuntime
       -> IO value
     )
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withLifecycleAuthorityAuthenticatedTransport authentication action = do
  result <-
    withLocalLifecycleAuthorityAuthenticatedTransport
      (lifecycleAuthenticationBounds authentication)
      (lifecycleAuthenticationProviders authentication)
      action
  pure
    ( mapLeft
        LifecycleAuthorityLocalTransportUnavailable
        result
    )

withTargetSecretAgentAuthenticatedTransport
  :: LifecycleAuthorityAuthentication
  -> ( AuthenticatedClientTransport 'TargetSecretAgentRuntime
       -> IO value
     )
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withTargetSecretAgentAuthenticatedTransport authentication action = do
  result <-
    withLocalTargetSecretAgentAuthenticatedTransport
      (lifecycleAuthenticationBounds authentication)
      (lifecycleAuthenticationProviders authentication)
      action
  pure
    ( mapLeft
        TargetSecretAgentLocalTransportUnavailable
        result
    )

-- | Open the Target Agent selected by an explicit, already-bracketed
-- Kubernetes environment.  Retained-home traffic continues to use
-- 'withTargetSecretAgentAuthenticatedTransport'; this variant prevents an AWS
-- selection from being silently redirected to home.
withSelectedTargetSecretAgentAuthenticatedTransport
  :: LifecycleAuthorityAuthentication
  -> [(String, String)]
  -> ( AuthenticatedClientTransport 'TargetSecretAgentRuntime
       -> IO value
     )
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withSelectedTargetSecretAgentAuthenticatedTransport authentication environment action = do
  result <-
    withTargetSecretAgentAuthenticatedTransportUsingEnvironment
      environment
      (lifecycleAuthenticationBounds authentication)
      (lifecycleAuthenticationProviders authentication)
      action
  pure
    ( mapLeft
        TargetSecretAgentLocalTransportUnavailable
        result
    )

withProviderWorkerAuthenticatedTransport
  :: LifecycleAuthorityAuthentication
  -> ( AuthenticatedClientTransport 'ProviderWorkerRuntime
       -> IO value
     )
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withProviderWorkerAuthenticatedTransport authentication action = do
  result <-
    withLocalProviderWorkerAuthenticatedTransport
      (lifecycleAuthenticationBounds authentication)
      (lifecycleAuthenticationProviders authentication)
      action
  pure
    ( mapLeft
        ProviderWorkerLocalTransportUnavailable
        result
    )

withAuthorityBackupAuthenticatedTransport
  :: LifecycleAuthorityAuthentication
  -> ( AuthenticatedClientTransport 'AuthorityBackupRuntime
       -> IO value
     )
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withAuthorityBackupAuthenticatedTransport authentication action = do
  result <-
    withLocalAuthorityBackupAuthenticatedTransport
      (lifecycleAuthenticationBounds authentication)
      (lifecycleAuthenticationProviders authentication)
      action
  pure
    ( mapLeft
        AuthorityBackupLocalTransportUnavailable
        result
    )

withTlsRetentionAuthenticatedTransport
  :: LifecycleAuthorityAuthentication
  -> ( AuthenticatedClientTransport 'TlsRetentionRuntime
       -> IO value
     )
  -> IO (Either LifecycleAuthorityAuthenticationError value)
withTlsRetentionAuthenticatedTransport authentication action = do
  result <-
    withLocalTlsRetentionAuthenticatedTransport
      (lifecycleAuthenticationBounds authentication)
      (lifecycleAuthenticationProviders authentication)
      action
  pure
    ( mapLeft
        TlsRetentionLocalTransportUnavailable
        result
    )

externalCallerLogin
  :: VaultAddress
  -> [(String, String)]
  -> FilePath
  -> ExternalLifecycleAuthorityCaller
  -> IO (Either VaultSessionError LoginLease)
externalCallerLogin address environment repoRoot caller = do
  tokenResult <- mintExternalCallerToken environment repoRoot caller
  case tokenResult of
    Left failure -> pure (Left (externalCallerTokenSessionError caller failure))
    Right jwt -> do
      loginResult <-
        vaultKubernetesLoginWithLease
          address
          "kubernetes"
          (externalCallerVaultRole caller)
          jwt
      pure $ case loginResult of
        Left err -> Left (httpErrorToSessionError err)
        Right lease ->
          Right
            LoginLease
              { loginLeaseToken = vaultLoginToken lease
              , loginLeaseSeconds = vaultLoginLeaseSeconds lease
              , loginLeaseRenewable = vaultLoginRenewable lease
              }

mintExternalCallerToken
  :: [(String, String)]
  -> FilePath
  -> ExternalLifecycleAuthorityCaller
  -> IO (Either ExternalCallerTokenError Text)
mintExternalCallerToken environment repoRoot caller = do
  serviceAccountReadBack <-
    captureSubprocessBounded
      tokenRequestLimits
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments = externalCallerServiceAccountReadArguments caller
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  case classifyServiceAccountObservation caller serviceAccountReadBack of
    Left failure -> pure (Left (ExternalCallerServiceAccountUnobservable failure))
    Right () -> do
      eligibility <-
        captureSubprocessBounded
          tokenRequestLimits
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = externalCallerTokenEligibilityArguments caller
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Just repoRoot
            }
      case classifyTokenEligibility eligibility of
        Left err -> pure (Left err)
        Right () -> do
          tokenRequest <-
            captureSubprocessBounded
              tokenRequestLimits
              Subprocess
                { subprocessPath = "kubectl"
                , subprocessArguments = externalCallerTokenRequestArguments caller
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just repoRoot
                }
          pure (classifyTokenRequest tokenRequest)

-- | Sprint 4.84: the distinguishable causes of a failed external-caller
-- ServiceAccount observation.
--
-- Every non-zero @kubectl@ result used to become the single sentence
-- @\"external caller ServiceAccount is not observable\"@ with @processStderr@
-- discarded, so five different facts — the API server was never reached, the
-- caller's credentials were refused, the caller is authenticated but not
-- permitted to read the object, no usable kube context was resolved, and the
-- object is genuinely absent — arrived downstream as one value. They are not
-- interchangeable for recovery: absence is a fact about the cluster's
-- contents, while the other four are facts about whether the cluster was
-- observed at all, and only the first can ever legitimately enter an absence
-- decision.
--
-- The classification is deliberately conservative. Anything that does not
-- match a recognized diagnostic stays 'ServiceAccountObservationUnclassified'
-- carrying the exit code and the exact captured stderr, so an unrecognized
-- failure is preserved rather than rounded to the nearest known cause.
data ServiceAccountObservationFailure
  = -- | The @kubectl@ subprocess could not be started or bounded at all. No
    -- observation authority was reached.
    ServiceAccountObservationSubprocessUnavailable
  | -- | The Kubernetes API server was not reached: connection refused, no
    -- route, DNS failure, or timeout.
    ServiceAccountObservationApiUnreachable !String
  | -- | No usable kube context: the kubeconfig is missing, unreadable, or
    -- names a context that does not exist.
    ServiceAccountObservationContextUnavailable !String
  | -- | The API server was reached and refused the caller's identity.
    ServiceAccountObservationUnauthenticated !String
  | -- | The API server was reached and authenticated the caller, but the
    -- caller may not read this object. Says nothing about whether it exists.
    ServiceAccountObservationForbidden !String
  | -- | The API server was reached and reports the ServiceAccount absent.
    -- This is the only arm that is a fact about cluster contents.
    ServiceAccountObservationAbsent
  | -- | Reached and returned, but the read-back did not match the exact
    -- namespace\/name\/non-automount identity.
    ServiceAccountObservationIdentityMismatch !String
  | -- | A non-zero exit whose diagnostic matched nothing above. The exit code
    -- and exact stderr are preserved rather than discarded.
    ServiceAccountObservationUnclassified !Int !String
  deriving stock (Eq, Show)

-- | Whether the Kubernetes API — the observation authority for this boundary —
-- was actually reached. Only a reached authority can report absence.
serviceAccountObservationAuthorityReached
  :: ServiceAccountObservationFailure -> Bool
serviceAccountObservationAuthorityReached failure = case failure of
  ServiceAccountObservationSubprocessUnavailable -> False
  ServiceAccountObservationApiUnreachable {} -> False
  ServiceAccountObservationContextUnavailable {} -> False
  ServiceAccountObservationUnauthenticated {} -> True
  ServiceAccountObservationForbidden {} -> True
  ServiceAccountObservationAbsent -> True
  ServiceAccountObservationIdentityMismatch {} -> True
  ServiceAccountObservationUnclassified {} -> False

renderServiceAccountObservationFailure
  :: ExternalLifecycleAuthorityCaller
  -> ServiceAccountObservationFailure
  -> String
renderServiceAccountObservationFailure caller failure =
  case failure of
    ServiceAccountObservationSubprocessUnavailable ->
      "read back external caller ServiceAccount: subprocess unavailable"
    ServiceAccountObservationApiUnreachable detail ->
      prefix "the Kubernetes API was not reached" detail
    ServiceAccountObservationContextUnavailable detail ->
      prefix "no usable kube context was resolved" detail
    ServiceAccountObservationUnauthenticated detail ->
      prefix "the Kubernetes API refused the caller's credentials" detail
    ServiceAccountObservationForbidden detail ->
      prefix
        ( "the Kubernetes API authenticated the caller but forbids reading "
            ++ "this ServiceAccount, so its presence is unobserved"
        )
        detail
    ServiceAccountObservationAbsent ->
      subject ++ " is absent (the Kubernetes API reported NotFound)"
    ServiceAccountObservationIdentityMismatch detail -> detail
    ServiceAccountObservationUnclassified code detail ->
      prefix
        ("kubectl exited " ++ show code ++ " with an unrecognized diagnostic")
        detail
 where
  subject =
    "external caller ServiceAccount "
      ++ externalCallerNamespace caller
      ++ "/"
      ++ Text.unpack (externalCallerServiceAccount caller)
  prefix headline detail =
    subject
      ++ " is not observable: "
      ++ headline
      ++ if null (trim detail) then "" else ": " ++ trim detail
  trim = Text.unpack . Text.strip . Text.pack

-- | Sprint 4.84 (pure). Classify one captured @kubectl get serviceaccount@
-- result. Total over the exit code and the captured diagnostic; never
-- discards stderr.
classifyServiceAccountObservation
  :: ExternalLifecycleAuthorityCaller
  -> Either err ProcessOutput
  -> Either ServiceAccountObservationFailure ()
classifyServiceAccountObservation caller captured = do
  output <- mapLeft (const ServiceAccountObservationSubprocessUnavailable) captured
  case processExitCode output of
    ExitSuccess ->
      mapLeft ServiceAccountObservationIdentityMismatch $
        validateExternalCallerServiceAccountReadBack caller (processStdout output)
    ExitFailure code ->
      Left (classifyKubectlDiagnostic code (processStderr output))

-- | The diagnostic classifier. Matching is on lowercased substrings of the
-- captured stderr because @kubectl@'s exit code alone is @1@ for every one of
-- these causes.
classifyKubectlDiagnostic :: Int -> String -> ServiceAccountObservationFailure
classifyKubectlDiagnostic code diagnostic
  | anyOf notFoundMarkers = ServiceAccountObservationAbsent
  | anyOf forbiddenMarkers = ServiceAccountObservationForbidden diagnostic
  | anyOf unauthenticatedMarkers = ServiceAccountObservationUnauthenticated diagnostic
  | anyOf contextMarkers = ServiceAccountObservationContextUnavailable diagnostic
  | anyOf unreachableMarkers = ServiceAccountObservationApiUnreachable diagnostic
  | otherwise = ServiceAccountObservationUnclassified code diagnostic
 where
  lowered = Text.toLower (Text.pack diagnostic)
  anyOf = any (`Text.isInfixOf` lowered)
  notFoundMarkers = ["not found", "notfound"]
  forbiddenMarkers = ["is forbidden", "forbidden:", "cannot get resource"]
  unauthenticatedMarkers =
    [ "unauthorized"
    , "invalid bearer token"
    , "the server has asked for the client to provide credentials"
    ]
  contextMarkers =
    [ "no configuration has been provided"
    , "context was not found"
    , "current-context is not set"
    , "error loading config file"
    , "stat /"
    ]
  unreachableMarkers =
    [ "connection refused"
    , "the connection to the server"
    , "no route to host"
    , "i/o timeout"
    , "context deadline exceeded"
    , "no such host"
    , "server could not find the requested resource"
    , "unable to connect to the server"
    , "eof"
    ]

-- | Sprint 4.84: why an external caller could not mint its Kubernetes token.
--
-- The classifier above produced a typed 'ServiceAccountObservationFailure' and
-- then a rendering adapter immediately flattened it to one @String@, so the
-- distinction it exists to draw died at the call site rather than reaching the
-- caller. This type is what carries it out: the ServiceAccount arm holds the
-- classification whole, and the two later @kubectl@ boundaries separate a
-- subprocess that never started from an API that answered and refused.
--
-- The distinction is load-bearing for exactly one reason, and it is the same
-- reason throughout this phase: an authority that never answered and an
-- authority that answered \"no\" are different facts. Reporting the second as
-- the first tells an operator to retry something that will never succeed.
data ExternalCallerTokenError
  = -- | The ServiceAccount read-back failed. Carries the classified cause,
    -- including whether the Kubernetes API was reached at all.
    ExternalCallerServiceAccountUnobservable !ServiceAccountObservationFailure
  | -- | The self-@TokenRequest@ RBAC check could not be started or bounded.
    ExternalCallerTokenEligibilitySubprocessUnavailable
  | -- | The API answered and the caller may not create this token.
    ExternalCallerTokenEligibilityRefused
  | -- | The @TokenRequest@ subprocess could not be started or bounded.
    ExternalCallerTokenRequestSubprocessUnavailable
  | -- | The API answered and refused the @TokenRequest@.
    ExternalCallerTokenRequestRefused
  | -- | The API answered with a token that is empty or carries control or
    -- whitespace characters, so it is not a usable bearer credential.
    ExternalCallerTokenMalformed
  deriving stock (Eq, Show)

-- | Whether the Kubernetes API answered at all.
externalCallerTokenAuthorityReached :: ExternalCallerTokenError -> Bool
externalCallerTokenAuthorityReached failure = case failure of
  ExternalCallerServiceAccountUnobservable detail ->
    serviceAccountObservationAuthorityReached detail
  ExternalCallerTokenEligibilitySubprocessUnavailable -> False
  ExternalCallerTokenEligibilityRefused -> True
  ExternalCallerTokenRequestSubprocessUnavailable -> False
  ExternalCallerTokenRequestRefused -> True
  ExternalCallerTokenMalformed -> True

-- | Whether the Kubernetes API answered and refused this caller\'s
-- /authorization/, as distinct from answering with some other fact.
--
-- This is strictly narrower than 'externalCallerTokenAuthorityReached': an
-- absent ServiceAccount and a mismatched read-back are both answers, and
-- neither is a denial. Only the arms here are permanent for the presented
-- identity, and only they may be reported as a denial rather than as an
-- unavailability.
externalCallerTokenAuthorityRefusedAuthorization
  :: ExternalCallerTokenError -> Bool
externalCallerTokenAuthorityRefusedAuthorization failure = case failure of
  ExternalCallerServiceAccountUnobservable detail -> case detail of
    ServiceAccountObservationUnauthenticated {} -> True
    ServiceAccountObservationForbidden {} -> True
    ServiceAccountObservationSubprocessUnavailable -> False
    ServiceAccountObservationApiUnreachable {} -> False
    ServiceAccountObservationContextUnavailable {} -> False
    ServiceAccountObservationAbsent -> False
    ServiceAccountObservationIdentityMismatch {} -> False
    ServiceAccountObservationUnclassified {} -> False
  ExternalCallerTokenEligibilitySubprocessUnavailable -> False
  ExternalCallerTokenEligibilityRefused -> True
  ExternalCallerTokenRequestSubprocessUnavailable -> False
  ExternalCallerTokenRequestRefused -> True
  ExternalCallerTokenMalformed -> False

-- | Lower the typed failure to the session error the login path reports.
--
-- Every arm previously became 'VaultSessionUnavailable', so an RBAC denial
-- — permanent for the presented identity — was indistinguishable from a
-- transient transport failure. 'VaultSessionForbidden' is that boundary\'s
-- existing denial class; the mapping is derived from
-- 'externalCallerTokenAuthorityRefusedAuthorization' rather than restated, so
-- a new arm cannot classify one way here and the other way there.
externalCallerTokenSessionError
  :: ExternalLifecycleAuthorityCaller
  -> ExternalCallerTokenError
  -> VaultSessionError
externalCallerTokenSessionError caller failure
  | externalCallerTokenAuthorityRefusedAuthorization failure =
      VaultSessionForbidden rendered
  | otherwise = VaultSessionUnavailable rendered
 where
  rendered = renderExternalCallerTokenError caller failure

renderExternalCallerTokenError
  :: ExternalLifecycleAuthorityCaller -> ExternalCallerTokenError -> String
renderExternalCallerTokenError caller failure = case failure of
  ExternalCallerServiceAccountUnobservable detail ->
    renderServiceAccountObservationFailure caller detail
  ExternalCallerTokenEligibilitySubprocessUnavailable ->
    "check external caller self-TokenRequest RBAC: subprocess unavailable"
  ExternalCallerTokenEligibilityRefused ->
    "external caller self-TokenRequest RBAC is unavailable: "
      ++ Text.unpack (externalCallerServiceAccount caller)
  ExternalCallerTokenRequestSubprocessUnavailable ->
    "create external caller TokenRequest: subprocess unavailable"
  ExternalCallerTokenRequestRefused ->
    "Kubernetes TokenRequest refused for the explicit "
      ++ show caller
      ++ " identity"
  ExternalCallerTokenMalformed ->
    "Kubernetes TokenRequest returned an invalid caller token"

-- | Sprint 4.84 (pure). Classify the self-@TokenRequest@ RBAC check.
classifyTokenEligibility
  :: Either err ProcessOutput -> Either ExternalCallerTokenError ()
classifyTokenEligibility captured = do
  output <-
    mapLeft
      (const ExternalCallerTokenEligibilitySubprocessUnavailable)
      captured
  case (processExitCode output, Text.strip (Text.pack (processStdout output))) of
    (ExitSuccess, "yes") -> Right ()
    _ -> Left ExternalCallerTokenEligibilityRefused

-- | Sprint 4.84 (pure). Classify the @TokenRequest@ result.
classifyTokenRequest
  :: Either err ProcessOutput -> Either ExternalCallerTokenError Text
classifyTokenRequest captured = do
  output <-
    mapLeft (const ExternalCallerTokenRequestSubprocessUnavailable) captured
  case processExitCode output of
    ExitFailure _ -> Left ExternalCallerTokenRequestRefused
    ExitSuccess -> Right ()
  let token = Text.strip (Text.pack (processStdout output))
  if Text.null token
    || Text.any (\character -> isControl character || isSpace character) token
    then Left ExternalCallerTokenMalformed
    else Right token

-- | The chart-installed ServiceAccount is the same closed identity used for
-- the caller's Vault Kubernetes-auth role.
externalCallerServiceAccount :: ExternalLifecycleAuthorityCaller -> Text
externalCallerServiceAccount = externalCallerVaultRole

externalCallerServiceAccountReadArguments
  :: ExternalLifecycleAuthorityCaller -> [String]
externalCallerServiceAccountReadArguments caller =
  [ "get"
  , "serviceaccount"
  , Text.unpack (externalCallerServiceAccount caller)
  , "--namespace"
  , externalCallerNamespace caller
  , "-o"
  , "jsonpath={.metadata.namespace}{'\\n'}{.metadata.name}{'\\n'}{.automountServiceAccountToken}{'\\n'}"
  ]

externalCallerTokenEligibilityArguments
  :: ExternalLifecycleAuthorityCaller -> [String]
externalCallerTokenEligibilityArguments caller =
  [ "auth"
  , "can-i"
  , "create"
  , "serviceaccounts/" ++ Text.unpack (externalCallerServiceAccount caller)
  , "--subresource=token"
  , "--namespace"
  , externalCallerNamespace caller
  , "--as=" ++ externalCallerKubernetesSubject caller
  ]

externalCallerTokenRequestArguments
  :: ExternalLifecycleAuthorityCaller -> [String]
externalCallerTokenRequestArguments caller =
  [ "create"
  , "token"
  , Text.unpack (externalCallerServiceAccount caller)
  , "--namespace"
  , externalCallerNamespace caller
  , "--duration=" ++ externalCallerTokenDuration caller
  , "--as=" ++ externalCallerKubernetesSubject caller
  ]

validateExternalCallerServiceAccountReadBack
  :: ExternalLifecycleAuthorityCaller -> String -> Either String ()
validateExternalCallerServiceAccountReadBack caller raw =
  if lines raw == expected
    then Right ()
    else
      Left
        ( "external caller ServiceAccount read-back did not match the exact "
            ++ "namespace/name/non-automount identity for "
            ++ show caller
        )
 where
  expected =
    [ externalCallerNamespace caller
    , Text.unpack (externalCallerServiceAccount caller)
    , "false"
    ]

externalCallerKubernetesSubject :: ExternalLifecycleAuthorityCaller -> String
externalCallerKubernetesSubject caller =
  "system:serviceaccount:"
    ++ externalCallerNamespace caller
    ++ ":"
    ++ Text.unpack (externalCallerServiceAccount caller)

externalCallerTokenDuration :: ExternalLifecycleAuthorityCaller -> String
externalCallerTokenDuration caller = case caller of
  LifecycleAuthorityOperator -> "5m"
  LifecycleAuthorityTestHarness -> "15m"

externalCallerPrincipal :: ExternalLifecycleAuthorityCaller -> CallerPrincipal
externalCallerPrincipal caller = case caller of
  LifecycleAuthorityOperator -> CallerOperatorCli
  LifecycleAuthorityTestHarness -> CallerTestHarness

externalCallerVaultRole :: ExternalLifecycleAuthorityCaller -> Text
externalCallerVaultRole caller = case caller of
  LifecycleAuthorityOperator -> operatorControlPlaneVaultRole
  LifecycleAuthorityTestHarness -> harnessControlPlaneVaultRole

externalCallerNamespace :: ExternalLifecycleAuthorityCaller -> String
externalCallerNamespace caller = case caller of
  LifecycleAuthorityOperator -> "bootstrap-broker"
  LifecycleAuthorityTestHarness -> "gateway"

tokenRequestLimits :: BoundedSubprocessLimits
tokenRequestLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 16 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 1000000
    }

lifecycleAuthorityFrameMaximumBytes :: Int
lifecycleAuthorityFrameMaximumBytes = 100 * 1024 * 1024

lifecycleAuthorityMetadataMaximumBytes :: Int
lifecycleAuthorityMetadataMaximumBytes = 1024

lifecycleAuthorityEnvelopeMaximumBytes :: Int
lifecycleAuthorityEnvelopeMaximumBytes = lifecycleAuthorityFrameMaximumBytes - 4096

lifecycleAuthorityRequestLifetimeMicros :: Natural
lifecycleAuthorityRequestLifetimeMicros = 5 * 60 * 1000000

homeKubectlEnvironment :: FilePath -> IO [(String, String)]
homeKubectlEnvironment kubeconfig = do
  environment <- getEnvironment
  pure
    ( ("KUBECONFIG", kubeconfig)
        : filter ((/= "KUBECONFIG") . fst) environment
    )

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
