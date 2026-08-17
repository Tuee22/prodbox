{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Ephemeral host interpreter for one exact EKS drain session.  The bearer
-- is exposed only through a 0600 FIFO inside a private temporary directory;
-- it never enters argv, the process environment, a reusable kubeconfig, or
-- durable cleanup evidence.  The live Kubernetes UID is read before mutation
-- and bound together with the independently observed provider ARN.
module Prodbox.Lifecycle.Teardown.EksDrainRuntime
  ( EksDrainRuntimeResult (..)
  , EksDrainRuntimeError (..)
  , runEksDrainWithProjection
  , runEksDrainWithProjectionUsing
  )
where

import Control.Concurrent.Async (withAsync)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forever)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  , eksClientAuthBearerToken
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  )
import Prodbox.Lifecycle.CleanupRun (CleanupOperationId)
import Prodbox.Lifecycle.K8sDrain
  ( DrainResult
  , DrainTimeout
  , drainAwsAffectingK8sResources
  , observeK8sClusterUid
  , prepareK8sDrainEnvWithKubectl
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksObservationPurpose (ObserveEksForDecision)
  , VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createNamedPipe
  , ownerReadMode
  , ownerWriteMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

data EksDrainRuntimeResult = EksDrainRuntimeResult
  { eksDrainRuntimeSession :: !EksDrainSession
  , eksDrainRuntimeKubernetesIdentity :: !EksKubernetesIdentityObservation
  , eksDrainRuntimeDrainResult :: !DrainResult
  }
  deriving (Eq, Show)

data EksDrainRuntimeError
  = EksDrainRuntimeExactObservationInvalid !EksDrainSessionError
  | EksDrainRuntimeTargetPreparationFailed !String
  | EksDrainRuntimeIdentityRefused
      !EksKubernetesIdentityObservation
      !EksDrainSessionError
  | EksDrainRuntimeIoFailed !String
  deriving (Eq, Show)

runEksDrainWithProjection
  :: [(String, String)]
  -> Maybe FilePath
  -> Integer
  -> Integer
  -> CleanupOperationId
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksClientAuthProjection
  -> DrainTimeout
  -> IO (Either EksDrainRuntimeError EksDrainRuntimeResult)
runEksDrainWithProjection = runEksDrainWithProjectionUsing "kubectl"

-- | Test seam for the executable only.  The target arguments and ephemeral
-- credential material remain owned by this interpreter.
runEksDrainWithProjectionUsing
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> Integer
  -> Integer
  -> CleanupOperationId
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksClientAuthProjection
  -> DrainTimeout
  -> IO (Either EksDrainRuntimeError EksDrainRuntimeResult)
runEksDrainWithProjectionUsing kubectl environment workingDirectory now deadline operationId scope verified projection timeout =
  case eksClusterArnFromExactObservation scope exact of
    Left err -> pure (Left (EksDrainRuntimeExactObservationInvalid err))
    Right clusterArn -> do
      attempted <-
        try
          ( withSystemTempDirectory "prodbox-eks-drain-" $ \directory -> do
              let kubeconfigPath = directory </> "kubeconfig.json"
                  tokenFifoPath = directory </> "bearer-token"
                  privateMode = ownerReadMode `unionFileModes` ownerWriteMode
              createNamedPipe tokenFifoPath privateMode
              writePrivateFile
                kubeconfigPath
                ( LazyByteString.toStrict
                    (encode (eksDrainKubeconfig projection tokenFifoPath))
                )
              prepared <-
                prepareK8sDrainEnvWithKubectl
                  kubectl
                  kubeconfigPath
                  environment
                  workingDirectory
              case prepared of
                Left detail -> pure (Left (EksDrainRuntimeTargetPreparationFailed detail))
                Right drainEnvironment ->
                  withAsync
                    ( forever
                        ( ByteString.writeFile
                            tokenFifoPath
                            (TextEncoding.encodeUtf8 (eksClientAuthBearerToken projection))
                        )
                    )
                    ( \_ -> do
                        uidResult <- observeK8sClusterUid drainEnvironment
                        let identity = case uidResult of
                              Right uid ->
                                eksKubernetesIdentityObservationFor
                                  scope
                                  (exactObservationRevision exact)
                                  (eksClusterArnText clusterArn)
                                  (EksKubernetesIdentityPresent (Text.pack uid))
                                  projection
                              Left detail ->
                                eksKubernetesIdentityObservationFor
                                  scope
                                  (exactObservationRevision exact)
                                  (eksClusterArnText clusterArn)
                                  ( EksKubernetesIdentityUnobservable
                                      (ObservationFailure (Text.pack detail))
                                  )
                                  projection
                        case mkEksDrainSession
                          now
                          deadline
                          operationId
                          scope
                          verified
                          identity
                          projection of
                          Left err ->
                            pure (Left (EksDrainRuntimeIdentityRefused identity err))
                          Right session ->
                            case validateEksDrainSession
                              now
                              operationId
                              scope
                              verified
                              identity
                              session of
                              Left err ->
                                pure (Left (EksDrainRuntimeIdentityRefused identity err))
                              Right () -> do
                                result <-
                                  drainAwsAffectingK8sResources
                                    drainEnvironment
                                    timeout
                                pure
                                  ( Right
                                      EksDrainRuntimeResult
                                        { eksDrainRuntimeSession = session
                                        , eksDrainRuntimeKubernetesIdentity = identity
                                        , eksDrainRuntimeDrainResult = result
                                        }
                                  )
                    )
          )
          :: IO
               ( Either
                   IOException
                   (Either EksDrainRuntimeError EksDrainRuntimeResult)
               )
      pure $ case attempted of
        Left err -> Left (EksDrainRuntimeIoFailed (show err))
        Right result -> result
 where
  exact = verifiedAwsEksExactObservation verified

eksDrainKubeconfig :: EksClientAuthProjection -> FilePath -> Value
eksDrainKubeconfig projection tokenFifoPath =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Config" :: String)
    , "current-context" .= ("prodbox-eks" :: String)
    , "clusters"
        .= [ object
               [ "name" .= eksClientAuthClusterName projection
               , "cluster"
                   .= object
                     [ "server" .= eksClientAuthEndpoint projection
                     , "certificate-authority-data"
                         .= eksClientAuthCertificateAuthorityData projection
                     ]
               ]
           ]
    , "users"
        .= [ object
               [ "name" .= ("prodbox-provider" :: String)
               , "user" .= object ["tokenFile" .= tokenFifoPath]
               ]
           ]
    , "contexts"
        .= [ object
               [ "name" .= ("prodbox-eks" :: String)
               , "context"
                   .= object
                     [ "cluster" .= eksClientAuthClusterName projection
                     , "user" .= ("prodbox-provider" :: String)
                     ]
               ]
           ]
    ]

writePrivateFile :: FilePath -> ByteString -> IO ()
writePrivateFile path bytes =
  bracket
    ( openFd
        path
        WriteOnly
        defaultFileFlags
          { exclusive = True
          , creat = Just (ownerReadMode `unionFileModes` ownerWriteMode)
          , nofollow = True
          , cloexec = True
          }
    )
    closeFd
    ( \fd -> do
        writeAll fd bytes
        fileSynchronise fd
    )

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixByteString.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then ioError (userError "short write while creating the ephemeral EKS kubeconfig")
    else writeAll fd (ByteString.drop count bytes)
