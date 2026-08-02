{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Closed authenticated client for the Lifecycle Authority cleanup-run
-- namespace. The wire command contains only logical run identities; the
-- physical Model-B and backup coordinates remain server-owned.
module Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClient (..)
  , CleanupRunClientError (..)
  , cleanupRunClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (CleanupRunCompact, CleanupRunScan)
  , cleanupRunMaximumBytes
  , decodeCleanupRunScanResponse
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleCleanupRunRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Test.CleanupRun
  ( CleanupRun
  , CleanupRunCodecError
  , CleanupRunReport
  , decodeCleanupRun
  , decodeCleanupRunReport
  )

data CleanupRunClient m = CleanupRunClient
  { executeCleanupRunCommand
      :: CleanupRunCommand
      -> m (Either CleanupRunClientError (Maybe CleanupRun))
  , scanNonterminalCleanupRuns
      :: m (Either CleanupRunClientError [Text])
  , compactTerminalCleanupRun
      :: Text
      -> Natural
      -> Natural
      -> m (Either CleanupRunClientError CleanupRunReport)
  }

data CleanupRunClientError
  = CleanupRunClientTransportFailed !AuthenticatedClientError
  | CleanupRunClientHttpStatus !Int !Text
  | CleanupRunClientResponseInvalid !CleanupRunCodecError
  | CleanupRunClientScanResponseInvalid !Text
  deriving stock (Eq, Show)

cleanupRunClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CleanupRunClient IO
cleanupRunClient transport =
  CleanupRunClient
    { executeCleanupRunCommand = execute
    , scanNonterminalCleanupRuns = scan
    , compactTerminalCleanupRun = compact
    }
 where
  execute command = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleCleanupRunRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest command))
    pure $ do
      ControlPlaneResponse status body <-
        first CleanupRunClientTransportFailed attempted
      case status of
        200 ->
          Just
            <$> first
              CleanupRunClientResponseInvalid
              (decodeCleanupRun cleanupRunMaximumBytes body)
        404 -> Right Nothing
        _ ->
          Left
            ( CleanupRunClientHttpStatus
                status
                (TextEncoding.decodeUtf8Lenient body)
            )
  scan = do
    attempted <- call CleanupRunScan
    pure $ do
      ControlPlaneResponse status body <- first CleanupRunClientTransportFailed attempted
      if status /= 200
        then Left (CleanupRunClientHttpStatus status (TextEncoding.decodeUtf8Lenient body))
        else first CleanupRunClientScanResponseInvalid (decodeCleanupRunScanResponse body)

  compact runId now retention = do
    attempted <- call (CleanupRunCompact runId now retention)
    pure $ do
      ControlPlaneResponse status body <- first CleanupRunClientTransportFailed attempted
      if status /= 200
        then Left (CleanupRunClientHttpStatus status (TextEncoding.decodeUtf8Lenient body))
        else first CleanupRunClientResponseInvalid (decodeCleanupRunReport cleanupRunMaximumBytes body)

  call command =
    callAuthenticatedClientTransport
      transport
      LifecycleCleanupRunRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest command))
