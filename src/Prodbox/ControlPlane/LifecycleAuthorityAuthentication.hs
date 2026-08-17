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
  )
where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Config.Basics (UnencryptedBasics (basicsClusterId))
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
  ( VaultAddress
  , VaultKubernetesLoginResult (..)
  , vaultKubernetesLoginWithLease
  )
import Prodbox.Vault.Host (resolveHostVaultAddress)
import Prodbox.Vault.Session
  ( LoginLease (..)
  , VaultSessionError (VaultSessionUnavailable)
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
          address <- resolveHostVaultAddress
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
    Left detail -> pure (Left (VaultSessionUnavailable detail))
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
  -> IO (Either String Text)
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
  case validateServiceAccountProcess caller serviceAccountReadBack of
    Left err -> pure (Left err)
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
      case validateTokenEligibility caller eligibility of
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
          pure (validateTokenRequest caller tokenRequest)

validateServiceAccountProcess
  :: ExternalLifecycleAuthorityCaller
  -> Either err ProcessOutput
  -> Either String ()
validateServiceAccountProcess caller captured = do
  output <-
    mapLeft (const "read back external caller ServiceAccount: subprocess unavailable") captured
  case processExitCode output of
    ExitFailure _ ->
      Left
        ( "external caller ServiceAccount is not observable: "
            ++ Text.unpack (externalCallerServiceAccount caller)
        )
    ExitSuccess ->
      validateExternalCallerServiceAccountReadBack caller (processStdout output)

validateTokenEligibility
  :: ExternalLifecycleAuthorityCaller
  -> Either err ProcessOutput
  -> Either String ()
validateTokenEligibility caller captured = do
  output <-
    mapLeft (const "check external caller self-TokenRequest RBAC: subprocess unavailable") captured
  case (processExitCode output, Text.strip (Text.pack (processStdout output))) of
    (ExitSuccess, "yes") -> Right ()
    _ ->
      Left
        ( "external caller self-TokenRequest RBAC is unavailable: "
            ++ Text.unpack (externalCallerServiceAccount caller)
        )

validateTokenRequest
  :: ExternalLifecycleAuthorityCaller
  -> Either err ProcessOutput
  -> Either String Text
validateTokenRequest caller captured = do
  output <- mapLeft (const "create external caller TokenRequest: subprocess unavailable") captured
  case processExitCode output of
    ExitFailure _ ->
      Left
        ( "Kubernetes TokenRequest refused for the explicit "
            ++ show caller
            ++ " identity"
        )
    ExitSuccess -> Right ()
  let token = Text.strip (Text.pack (processStdout output))
  if Text.null token
    || Text.any (\character -> isControl character || isSpace character) token
    then Left "Kubernetes TokenRequest returned an invalid caller token"
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
