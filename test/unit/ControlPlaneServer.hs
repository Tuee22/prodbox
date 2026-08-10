{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneServer (controlPlaneServerSuite) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (fromJust)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket
  ( Family (AF_UNIX)
  , ShutdownCmd (ShutdownSend)
  , Socket
  , SocketType (Stream)
  , close
  , defaultProtocol
  , shutdown
  , socketPair
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.CheckCode (controlPlaneReplyStatusViolations)
import Prodbox.ControlPlane.Capacity
  ( RejectionReason (RejectedDeadlineUnmeetable, RejectedSaturated)
  , serviceCapacityQueueCapacity
  , serviceCapacityRejectionThreshold
  , serviceCapacityUtilizationPpm
  , serviceCapacityWorkerCount
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , RemainingDuration (RemainingDuration)
  , RetryAfter (RetryAfter)
  , WorkEstimate (WorkEstimate)
  , deadlineAtOffset
  , monotonicInstantFromMicros
  )
import Prodbox.ControlPlane.ProjectionImportEndpoint (mkProjectionImportHandler)
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointHandler
  , PulumiCheckpointObservation (PulumiCheckpointMissing)
  , PulumiCheckpointPublicationResult (PulumiCheckpointPublicationUnavailable)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointRetirementResult (PulumiCheckpointRetirementUnavailable)
  , mkPulumiCheckpointHandler
  )
import Prodbox.ControlPlane.RoleInterpreters (lifecycleAuthorityInterpreter)
import Prodbox.ControlPlane.RoleReadiness (constantRoleReadinessSource)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
import Prodbox.ControlPlane.Runtime
  ( controlPlaneCapacityPlan
  , receiveControlPlaneRequest
  , refuseControlPlaneConnection
  , serveControlPlaneConnection
  )
import Prodbox.ControlPlane.Server
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (..)
  , allReplyStatuses
  , reasonPhraseForCode
  , replyStatusCode
  , replyStatusFromCode
  , replyStatusReason
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCommand (RequestLegacyRollback, VerifyShadow)
  , encodeMigrationCommand
  , mkMigrationDigest
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (..)
  , StoredMigration (..)
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( LegacyProjectionObservation (LegacyProjectionMissing)
  , LegacyProjectionSource (LegacyProjectionSource)
  , ProjectionImportTarget (..)
  , ProjectionTargetObservation (ProjectionTargetMissing)
  , ProjectionTargetWriteResult (ProjectionTargetWriteUnobservable)
  , mkProjectionImportCodecConfig
  )
import Prodbox.Lifecycle.CheckpointAuthority (mkTargetClusterSecretSink)
import Prodbox.Lifecycle.Lease (defaultSesLeasePolicy)
import Prodbox.Lifecycle.TargetCommitIntent (mkRegisteredTargetSet)
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import TestSupport

controlPlaneServerSuite :: SuiteBuilder ()
controlPlaneServerSuite =
  describe "Sprint 4.50 control-plane role server seam" $ do
    it "frames a request only after its fragmented header and exact body arrive" $ do
      inspectControlPlaneRequestFraming "POST /v1/migration/apply HTTP/1.1\r\nContent-Len"
        `shouldBe` Right ControlPlaneFramingIncomplete
      inspectControlPlaneRequestFraming "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nx"
        `shouldBe` Right ControlPlaneFramingIncomplete
      let complete = "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz"
      inspectControlPlaneRequestFraming complete
        `shouldBe` Right (ControlPlaneFramingComplete complete)
    it "reads fragmented headers and bodies from a socket pair without a fixed port" $
      withSocketsDo $
        bracket (socketPair AF_UNIX Stream defaultProtocol) closeSocketPair $ \(writer, reader) -> do
          let headerFragment = "POST /v1/migration/apply HTTP/1.1\r\nContent-Len"
              bodyFragment = "gth: 3\r\n\r\nxyz"
              complete = headerFragment <> bodyFragment
          void $
            forkIO $ do
              sendAll writer headerFragment
              threadDelay 10000
              sendAll writer bodyFragment
              shutdown writer ShutdownSend
          receiveControlPlaneRequest reader `shouldReturn` Right complete
    it "frames a header-only GET after the header terminator" $ do
      let request = "GET /healthz HTTP/1.1\r\nHost: lifecycle-authority\r\n\r\n"
      inspectControlPlaneRequestFraming request
        `shouldBe` Right (ControlPlaneFramingComplete request)
    it "accepts case-insensitive framing headers and optional whitespace" $ do
      let request = "POST /v1/migration/apply HTTP/1.1\r\ncOnTeNt-LeNgTh:\t 3 \t\r\n\r\nxyz"
      inspectControlPlaneRequestFraming request
        `shouldBe` Right (ControlPlaneFramingComplete request)
    it "rejects duplicate and invalid content lengths before dispatch" $ do
      inspectControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\ncontent-length: 3\r\n\r\nxyz"
        `shouldBe` Left ControlPlaneDuplicateContentLength
      fmap
        inspectControlPlaneRequestFraming
        [ "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        , "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 1x\r\n\r\n"
        , "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 1, 1\r\n\r\n"
        ]
        `shouldBe` replicate 3 (Left ControlPlaneInvalidContentLength)
    it "rejects an oversized declared body during header preflight" $
      inspectControlPlaneRequestFraming
        (declaredRequest "POST" "/v1/migration/apply" (controlPlaneMaximumBodyBytes + 1))
        `shouldBe` Left ControlPlaneBodyTooLarge
    it "admits the large ceiling only for the two typed checkpoint-bearing routes" $ do
      fmap
        inspectControlPlaneRequestFraming
        [ declaredRequest "POST" "/v1/authority/pulumi-checkpoint" controlPlaneMaximumLargeBodyBytes
        , declaredRequest "POST" "/v1/authority-backup/copy" controlPlaneMaximumLargeBodyBytes
        ]
        `shouldBe` replicate 2 (Right ControlPlaneFramingIncomplete)
      controlPlaneMaximumLargeBodyBytes `shouldSatisfy` (> 96 * 1024 * 1024)
    it "refuses oversized large-route declarations from the header alone" $ do
      fmap
        inspectControlPlaneRequestFraming
        [ declaredRequest
            "POST"
            "/v1/authority/pulumi-checkpoint"
            (controlPlaneMaximumLargeBodyBytes + 1)
        , declaredRequest
            "POST"
            "/v1/authority-backup/copy"
            (controlPlaneMaximumLargeBodyBytes + 1)
        ]
        `shouldBe` replicate 2 (Left ControlPlaneBodyTooLarge)
    it "keeps ordinary, wrong-method, observe, and unknown routes at one MiB" $ do
      fmap
        inspectControlPlaneRequestFraming
        [ declaredRequest "POST" "/v1/migration/apply" (controlPlaneMaximumBodyBytes + 1)
        , declaredRequest "GET" "/v1/authority/pulumi-checkpoint" (controlPlaneMaximumBodyBytes + 1)
        , declaredRequest "GET" "/v1/authority-backup/observe" (controlPlaneMaximumBodyBytes + 1)
        , declaredRequest "POST" "/v1/not-a-registered-route" (controlPlaneMaximumBodyBytes + 1)
        ]
        `shouldBe` replicate 4 (Left ControlPlaneBodyTooLarge)
    it "rejects a header beyond the 16 KiB framing bound" $
      inspectControlPlaneRequestFraming
        ( "GET /healthz HTTP/1.1\r\nX-Fill: "
            <> ByteString.replicate controlPlaneMaximumHeaderBytes 97
            <> "\r\n\r\n"
        )
        `shouldBe` Left ControlPlaneHeaderTooLarge
    it "rejects bytes past the declared body" $
      inspectControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz-extra"
        `shouldBe` Left ControlPlaneBodyPastDeclaredLength
    it "rejects unsupported or missing POST framing" $ do
      inspectControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nxyz\r\n0\r\n\r\n"
        `shouldBe` Left ControlPlaneUnsupportedTransferEncoding
      inspectControlPlaneRequestFraming "POST /v1/migration/apply HTTP/1.1\r\n\r\n"
        `shouldBe` Left ControlPlaneContentLengthRequired
    it "rejects connection close before a header or declared body completes" $ do
      finishControlPlaneRequestFraming "GET /healthz HTTP/1.1\r\nHost: authority"
        `shouldBe` Left ControlPlaneConnectionClosedBeforeComplete
      finishControlPlaneRequestFraming
        "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxy"
        `shouldBe` Left ControlPlaneConnectionClosedBeforeComplete
    it "parses method, request target, and body from a raw request" $ do
      let parsed = parseControlPlaneRequest "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz"
      fmap parsedRequestPath parsed `shouldBe` Just "/v1/migration/apply"
      fmap parsedRequestBody parsed `shouldBe` Just "xyz"
    it "treats a header-only probe as an empty-body request" $ do
      let parsed = parseControlPlaneRequest "GET /healthz HTTP/1.1"
      fmap parsedRequestPath parsed `shouldBe` Just "/healthz"
      fmap parsedRequestBody parsed `shouldBe` Just ""
    it "classifies liveness, readiness, owned, and unowned dispositions" $ do
      classifyControlPlaneRequest LifecycleAuthorityRuntime "GET /healthz HTTP/1.1\r\n\r\n"
        `shouldBe` DispositionLive
      classifyControlPlaneRequest LifecycleAuthorityRuntime "GET /readyz HTTP/1.1\r\n\r\n"
        `shouldBe` DispositionNotReady
      classifyControlPlaneRequest
        LifecycleAuthorityRuntime
        "POST /v1/migration/apply HTTP/1.1\r\n\r\nbody"
        `shouldBe` DispositionOwnedRoute LifecycleMigrationApply "body"
      classifyControlPlaneRequest LifecycleAuthorityRuntime "GET /nope HTTP/1.1\r\n\r\n"
        `shouldBe` DispositionNotOwned
    it "refuses a route owned by a different role" $
      classifyControlPlaneRequest ProviderWorkerRuntime "POST /v1/migration/apply HTTP/1.1\r\n\r\nbody"
        `shouldBe` DispositionNotOwned
    it "serves every disposition fail-closed until an interpreter is bound" $ do
      let serve =
            serveControlPlaneRequest
              fixtureRoleReadinessResolver
              (failClosedInterpreter :: RoleInterpreter IO)
              LifecycleAuthorityRuntime
      serve "GET /healthz HTTP/1.1\r\n\r\n" `shouldReturn` (ReplyOk, "live\n")
      serve "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (ReplyServiceUnavailable, "not-ready\n")
      serve "POST /v1/migration/apply HTTP/1.1\r\n\r\nbody"
        `shouldReturn` (ReplyServiceUnavailable, "interpreter-unavailable\n")
      serve "GET /nope HTTP/1.1\r\n\r\n" `shouldReturn` (ReplyNotFound, "route-not-owned\n")
    it "dispatches an owned migration request through the library-built interpreter" $ do
      interpreter <- boundLifecycleAuthorityInterpreter
      let serve = serveControlPlaneRequest fixtureRoleReadinessResolver interpreter LifecycleAuthorityRuntime
      serve "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (ReplyOk, "ready\n")
      accepted <- serve (migrationRequest (VerifyShadow digest))
      accepted `shouldBe` (ReplyOk, "migration-accepted")
      refused <- serve (migrationRequest RequestLegacyRollback)
      refused `shouldBe` (ReplyConflict, "migration-refused:legacy-rollback-forbidden")
    it "renders a bounded connection-close HTTP response" $
      renderHttpResponse ReplyOk "live\n"
        `shouldBe` "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\nlive\n"
    it "maps every emitted status code to a reason phrase" $ do
      -- Sprint 4.66: this case's NAME was true and its BODY was not. It listed
      -- six codes and called them "every emitted status", while the
      -- interpreters emit ten — so the four it omitted were exactly the four
      -- that rendered as `403 Status` on the wire. The list is now derived from
      -- the closed type instead of hand-written beside it.
      fmap (reasonPhraseForCode . replyStatusCode) allReplyStatuses
        `shouldBe` fmap replyStatusReason allReplyStatuses
      -- The four the old list omitted, named explicitly so a regression reads
      -- as the defect it would be rather than as a count changing.
      fmap reasonPhraseForCode [401, 403, 408, 410]
        `shouldBe` ["Unauthorized", "Forbidden", "Request Timeout", "Gone"]

    it "Sprint 4.66: the code and the reason are one table, not two" $ do
      -- `replyStatusFromCode` is derived from `replyStatusCode`, so the pair
      -- cannot drift the way `httpReasonPhrase` drifted from its producers.
      fmap (replyStatusFromCode . replyStatusCode) allReplyStatuses
        `shouldBe` fmap Just allReplyStatuses
      replyStatusFromCode 418 `shouldBe` Nothing
      -- An undefined status says so rather than claiming a phrase it lacks.
      reasonPhraseForCode 418 `shouldBe` "Unmapped Status"

    it "Sprint 4.67: renderHttpResponse takes a status, not a number" $ do
      -- The producer-side half of Sprint 4.66. `renderHttpResponse 418 body`
      -- used to type-check and put `HTTP/1.1 418 Unmapped Status` on the wire;
      -- there is no longer a way to say it. What remains testable is that the
      -- rendered line agrees with both projections of the value that produced
      -- it, for every constructor rather than for a sampled few.
      fmap statusLineOf allReplyStatuses
        `shouldBe` fmap
          ( \status ->
              "HTTP/1.1 "
                <> Char8.pack (show (replyStatusCode status))
                <> " "
                <> replyStatusReason status
          )
          allReplyStatuses

    it "Sprint 4.67: a producer stating a status as a number fails the build" $ do
      -- Sprint 4.66's rule admitted a literal the closed set defined. The
      -- producers now answer `ReplyStatus`, so the literal itself is the
      -- finding: an `Int`-typed reply seam is what let the renderer drift in
      -- the first place, and the gate exists to stop one being reopened.
      length
        ( controlPlaneReplyStatusViolations
            ("src/Prodbox/ControlPlane/Example.hs", "          pure (403, responseBody refusal)\n")
        )
        `shouldBe` 1
      length
        ( controlPlaneReplyStatusViolations
            ("src/Prodbox/ControlPlane/Example.hs", "          pure (418, responseBody refusal)\n")
        )
        `shouldBe` 1
      length
        ( controlPlaneReplyStatusViolations
            ("src/Prodbox/ControlPlane/Example.hs", "  SomethingTeapot -> 418\n")
        )
        `shouldBe` 1
      -- The migrated shape is what the namespace holds today and must stay
      -- clean, or the rule would be reporting the fix it asked for.
      controlPlaneReplyStatusViolations
        ("src/Prodbox/ControlPlane/Example.hs", "          pure (ReplyForbidden, responseBody refusal)\n")
        `shouldBe` []
      -- `CallerPrincipal` encodes caller identities as 100-103 through the very
      -- same `-> NNN` shape a status projection uses, so shape alone does NOT
      -- separate them. Measured, after a first version of this rule flagged
      -- them: the exemption is by path and is named rather than disguised as a
      -- cleverer matcher.
      controlPlaneReplyStatusViolations
        ("src/Prodbox/ControlPlane/CallerPrincipal.hs", "  CallerOperatorCli -> 100\n")
        `shouldBe` []
      -- The exemption is one path, not a shape: the same line anywhere else in
      -- the namespace is still a violation.
      length
        ( controlPlaneReplyStatusViolations
            ("src/Prodbox/ControlPlane/Example.hs", "  CallerOperatorCli -> 100\n")
        )
        `shouldBe` 1
      -- An IPv4 octet tuple is not a reply tuple. `LocalClient.hs` binds
      -- `(127, 0, 0, 1)` and the first version of this rule reported it as
      -- "HTTP status 127" during the sprint's own `dev check` run — found by
      -- running the gate over the repository rather than by reasoning about it.
      controlPlaneReplyStatusViolations
        ( "src/Prodbox/ControlPlane/LocalClient.hs"
        , "                bind reserved (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))\n"
        )
        `shouldBe` []
    it "Sprint 4.60: a throwing interpreter answers 500 rather than closing silently" $ do
      -- The production defect, end to end: `interpreterHandle` throwing used to
      -- close the socket with zero bytes, which the client reported as a
      -- transport failure naming nothing.
      answered <-
        serveOverSocketPair
          RoleInterpreter
            { interpreterReadiness = fixtureReadyRoleReadinessSource
            , interpreterHandle = \_ _ -> throwIO (userError "interpreter exploded")
            }
          "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 4\r\n\r\nbody"
      Char8.unpack answered `shouldContain` "HTTP/1.1 500 Internal Server Error"
      Char8.unpack answered `shouldContain` "internal-error"
    it "Sprint 4.60: a throwing readiness resolver answers 500, not a bare close" $ do
      answered <-
        serveOverSocketPair
          RoleInterpreter
            { interpreterReadiness =
                constantRoleReadinessSource (error "readiness cell is bottom")
            , interpreterHandle = \_ _ -> pure Nothing
            }
          "GET /readyz HTTP/1.1\r\n\r\n"
      Char8.unpack answered `shouldContain` "HTTP/1.1 500 Internal Server Error"
    it "Sprint 4.60: the framing-refusal 400 is unchanged" $ do
      answered <-
        serveOverSocketPair
          (failClosedInterpreter :: RoleInterpreter IO)
          "POST /v1/migration/apply HTTP/1.1\r\n\r\nno-content-length"
      Char8.unpack answered `shouldContain` "HTTP/1.1 400 Bad Request"

    it "Sprint 4.68: the control-plane capacity plan compiles" $ do
      -- The runtime treats a `Left` as a fail-closed start, which is only
      -- honest if something proves the authored inputs are not one. `dev check`
      -- is that proof at build time; this is the same proof at test time, and
      -- both exist because the alternative is a server that silently refuses to
      -- start.
      fmap serviceCapacityWorkerCount controlPlaneCapacityPlan `shouldBe` Right 4
      fmap serviceCapacityQueueCapacity controlPlaneCapacityPlan `shouldBe` Right 32
      -- The threshold is strictly below the carrier's capacity, so the decision
      -- refuses before the queue is physically full. The two bounds are
      -- redundant deliberately and in this direction.
      fmap serviceCapacityRejectionThreshold controlPlaneCapacityPlan `shouldBe` Right 24
      -- ρ = λS/c = 8 × 0.3 s / 4 = 0.6 against the 0.7 ceiling the authored
      -- headroom sets. Stated as a number rather than as a passing constructor,
      -- because a plan that merely validates says nothing about how much margin
      -- it validated with.
      fmap serviceCapacityUtilizationPpm controlPlaneCapacityPlan `shouldBe` Right 600000

    it "Sprint 4.68: a saturated accept path refuses 429 through the obligation" $ do
      -- The refusal is not a raw write. A connection the admission machine
      -- turns away has still been accepted and is still owed a reply, so it
      -- goes through the same `withResponseObligation` every served connection
      -- does — which is also why `Runtime.hs` still cannot import `sendAll`.
      saturated <-
        refuseOverSocketPair (RejectedSaturated (RetryAfter 300000))
      Char8.unpack saturated `shouldContain` "HTTP/1.1 429 Too Many Requests"
      Char8.unpack saturated `shouldContain` "control-plane-saturated"
      -- The second arm is unreachable under the committed inputs and is
      -- exercised anyway: it exists because the decision is total, and an arm
      -- nothing drives is an arm nobody has read.
      unmeetable <-
        refuseOverSocketPair
          (RejectedDeadlineUnmeetable (WorkEstimate 1) (RemainingDuration 0))
      Char8.unpack unmeetable `shouldContain` "HTTP/1.1 503 Service Unavailable"
      Char8.unpack unmeetable `shouldContain` "control-plane-deadline-unmeetable"

    it "Sprint 4.68: a connection past its deadline is answered 408, not served" $ do
      -- The whole point of enforcing the deadline INSIDE the handler. Were the
      -- timeout wrapped around `withResponseObligation`, this peer would read
      -- `503 shutting-down` — a cancellation reply naming the wrong cause — and
      -- a worker writing its own 408 afterwards would be a second reply on one
      -- connection.
      served <- newIORef (0 :: Int)
      answered <-
        serveOverSocketPairWithDeadline
          expiredDeadline
          RoleInterpreter
            { interpreterReadiness = fixtureReadyRoleReadinessSource
            , interpreterHandle = \_ _ -> do
                modifyIORef' served (+ 1)
                pure (Just (ReplyOk, "served\n"))
            }
          "POST /v1/migration/apply HTTP/1.1\r\nContent-Length: 4\r\n\r\nbody"
      Char8.unpack answered `shouldContain` "HTTP/1.1 408 Request Timeout"
      Char8.unpack answered `shouldContain` "request-deadline-exceeded"
      -- Expiry is checked before the read, so an expired request costs the
      -- interpreter nothing at all.
      readIORef served `shouldReturn` 0
 where
  digest = fromJust (mkMigrationDigest "server-v1")

-- | A deadline at monotonic instant zero: always in the past, because the
-- monotonic clock counts from boot. Deterministic without a sleep.
expiredDeadline :: Deadline
expiredDeadline = deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 0)

-- | A deadline far enough ahead that every pre-4.68 case stays untimed.
openDeadline :: IO Deadline
openDeadline = do
  now <- monotonicInstantFromMicros . fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec
  pure (deadlineAtOffset now (RemainingDuration (3600 * 1000 * 1000)))

declaredRequest :: ByteString -> ByteString -> Int -> ByteString
declaredRequest method path bodyBytes =
  method
    <> " "
    <> path
    <> " HTTP/1.1\r\nContent-Length: "
    <> Char8.pack (show bodyBytes)
    <> "\r\n\r\n"

closeSocketPair :: (Socket, Socket) -> IO ()
closeSocketPair (left, right) = close left >> close right

migrationRequest :: MigrationCommand -> ByteString
migrationRequest command =
  "POST /v1/migration/apply HTTP/1.1\r\n\r\n"
    <> LazyByteString.toStrict (encodeMigrationCommand command)

-- | Build a Lifecycle Authority interpreter through the library builder
-- ('Prodbox.ControlPlane.RoleInterpreters.lifecycleAuthorityInterpreter') over
-- an in-memory migration repository.  Caller-selected operation identities are
-- not composed on this legacy context-free builder.
boundLifecycleAuthorityInterpreter :: IO (RoleInterpreter IO)
boundLifecycleAuthorityInterpreter = do
  migrationRepository <- freshMigrationRepository
  let projectionConfig =
        either (error . show) id $
          mkProjectionImportCodecConfig
            defaultSesLeasePolicy
            ( either (error . show) id $
                mkRegisteredTargetSet
                  1
                  [ either (error . show) id $
                      mkTargetClusterSecretSink
                        "home"
                        "secret"
                        "keycloak/smtp"
                  ]
            )
            4096
      projectionSource :: LegacyProjectionSource IO Word
      projectionSource =
        LegacyProjectionSource (\_ -> pure LegacyProjectionMissing)
      projectionTarget :: ProjectionImportTarget IO Word
      projectionTarget =
        ProjectionImportTarget
          { observeImportedProjection = \_ -> pure ProjectionTargetMissing
          , initializeImportedProjection = \_ _ ->
              pure (ProjectionTargetWriteUnobservable "unexpected initialize")
          }
      projectionHandler =
        mkProjectionImportHandler
          4096
          4096
          projectionConfig
          migrationRepository
          projectionSource
          projectionTarget
  pure
    ( lifecycleAuthorityInterpreter
        4096
        fixtureReadyRoleReadinessSource
        "cluster-a"
        (pure (Right 123456))
        migrationRepository
        projectionHandler
        fixturePulumiCheckpointHandler
    )

fixturePulumiCheckpointHandler :: PulumiCheckpointHandler IO
fixturePulumiCheckpointHandler =
  mkPulumiCheckpointHandler
    PulumiCheckpointRepository
      { observeRegisteredPulumiCheckpoint = \_callerSlot _ -> pure PulumiCheckpointMissing
      , publishRegisteredPulumiCheckpoint = \_callerSlot _ _ _ ->
          pure (PulumiCheckpointPublicationUnavailable "fixture unavailable")
      , retireRegisteredPulumiCheckpoint = \_callerSlot _ _ ->
          pure (PulumiCheckpointRetirementUnavailable "fixture unavailable")
      }

freshMigrationRepository :: IO (MigrationRepository IO Word)
freshMigrationRepository = do
  stateRef <- newIORef Nothing
  revisionRef <- newIORef (0 :: Word)
  pure
    MigrationRepository
      { readMigrationState = Right <$> readIORef stateRef
      , compareAndSwapMigrationState = \expected bytes -> do
          observed <- readIORef stateRef
          if (storedMigrationRevision <$> observed) /= expected
            then pure (Right False)
            else do
              next <- atomicModifyIORef' revisionRef (\value -> (value + 1, value + 1))
              writeIORef stateRef (Just (StoredMigration next bytes))
              pure (Right True)
      }

-- | The rendered status line, up to but not including the CRLF.
statusLineOf :: ReplyStatus -> ByteString
statusLineOf status = Char8.takeWhile (/= '\r') (renderHttpResponse status "x")

-- | Sprint 4.60: drive one connection through the real production accept path
-- over a socket pair, and return every byte the peer saw. `serve` used to be a
-- `where`-closure under a `forever` loop bound to port 8600, so the refusal
-- path was unreachable from a test.
serveOverSocketPair :: RoleInterpreter IO -> ByteString -> IO ByteString
serveOverSocketPair interpreter request = do
  deadline <- openDeadline
  serveOverSocketPairWithDeadline deadline interpreter request

serveOverSocketPairWithDeadline
  :: Deadline -> RoleInterpreter IO -> ByteString -> IO ByteString
serveOverSocketPairWithDeadline deadline interpreter request = withSocketsDo $ do
  (client, peer) <- socketPair AF_UNIX Stream defaultProtocol
  void $ forkIO $ do
    sendAll peer request
    shutdown peer ShutdownSend
  void $ forkIO $ do
    _ <-
      try
        ( serveControlPlaneConnection
            LifecycleAuthorityRuntime
            interpreter
            deadline
            client
        )
        :: IO (Either SomeException ())
    close client
  answered <- drainSocket peer ByteString.empty
  close peer
  pure answered

-- | Drive one admission refusal over a socket pair and return the peer's bytes.
refuseOverSocketPair :: RejectionReason -> IO ByteString
refuseOverSocketPair reason = withSocketsDo $ do
  (client, peer) <- socketPair AF_UNIX Stream defaultProtocol
  void $ forkIO $ do
    _ <-
      try (refuseControlPlaneConnection LifecycleAuthorityRuntime reason client)
        :: IO (Either SomeException ())
    close client
  answered <- drainSocket peer ByteString.empty
  close peer
  pure answered

drainSocket :: Socket -> ByteString -> IO ByteString
drainSocket connection accumulated = do
  chunk <- recv connection 4096
  if ByteString.null chunk
    then pure accumulated
    else drainSocket connection (accumulated <> chunk)
