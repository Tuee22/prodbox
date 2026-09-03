{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Sprint 4.50: the pure request/dispatch/response seam shared by every
-- standing control-plane role server.
--
-- The raw-socket loop in 'Prodbox.ControlPlane.Runtime' owns only the accept /
-- recv / send I/O; the classification of a request into a typed disposition, the
-- dispatch of an owned route to a role interpreter, and the rendering of the HTTP
-- response are pure (or monad-generic over the interpreter) and therefore
-- exercised without a socket. A role installs a 'RoleInterpreter'; until it binds
-- a route the shared 'failClosedInterpreter' keeps liveness served while readiness
-- and every owned operation fail closed — the exact behaviour the pre-interpreter
-- server had, now reachable through a typed dispatch point rather than an ad-hoc
-- byte prefix match.
module Prodbox.ControlPlane.Server
  ( controlPlaneMaximumHeaderBytes
  , controlPlaneMaximumBodyBytes
  , controlPlaneMaximumLifecycleInputBodyBytes
  , controlPlaneMaximumLargeBodyBytes
  , ControlPlaneFramingError (..)
  , ControlPlaneFramingProgress (..)
  , inspectControlPlaneRequestFraming
  , finishControlPlaneRequestFraming
  , ParsedControlPlaneRequest (..)
  , parseControlPlaneRequest
  , ControlPlaneDisposition (..)
  , classifyControlPlaneRequest
  , RoleInterpreter (..)
  , RoleReadinessResolver (..)
  , mkRoleReadinessResolver
  , failClosedInterpreter
  , serveControlPlaneRequest
  , renderHttpResponse
  )
where

import Control.Concurrent.STM (STM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Char (isAlphaNum, isDigit, toLower)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , RoleReadinessState
  , computeRoleReadiness
  , constantRoleReadinessSource
  , roleReadinessIsReady
  , roleReadinessSnapshot
  , unobservedRoleReadinessFacts
  )
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (..)
  , replyStatusCode
  , replyStatusReason
  )

import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlaneGet, ControlPlanePost)
  , ControlPlaneRoute (..)
  , allControlPlaneRoutes
  , controlPlaneRouteMethod
  , controlPlaneRoutePath
  , decodeRoleRoute
  )
import Prodbox.Readiness.ObservationSchedule (ObservationSchedule)
import Prodbox.Runtime.Role (RuntimeRole)

-- | The complete request header, including its terminating CRLFCRLF, is bounded
-- before any body bytes are accumulated.
controlPlaneMaximumHeaderBytes :: Int
controlPlaneMaximumHeaderBytes = 16 * 1024

-- | The ordinary one-MiB request ceiling admits the bounded aggregate and TLS
-- protocols while still rejecting an oversized declared body during header
-- preflight. Individual payload constructors impose tighter component bounds
-- before storage.
controlPlaneMaximumBodyBytes :: Int
controlPlaneMaximumBodyBytes = 1024 * 1024

-- | The two immutable lifecycle-input protocols carry at most one 32-KiB
-- canonical value plus its exact identity and authenticated envelope.  Keep
-- their socket preflight materially below the ordinary one-MiB ceiling.
controlPlaneMaximumLifecycleInputBodyBytes :: Int
controlPlaneMaximumLifecycleInputBodyBytes = 256 * 1024

-- | The two checkpoint-bearing routes admit a 96-MiB ciphertext inside the
-- canonical request, signature, and authentication envelopes.  The route is
-- identified from the closed typed topology before body bytes are accumulated;
-- every other (including unknown) request retains the ordinary one-MiB ceiling.
controlPlaneMaximumLargeBodyBytes :: Int
controlPlaneMaximumLargeBodyBytes = 100 * 1024 * 1024

-- | Fail-closed framing refusals detected before route classification or role
-- dispatch. The socket boundary deliberately supports only a single,
-- Content-Length-framed request followed by connection close.
data ControlPlaneFramingError
  = ControlPlaneHeaderTooLarge
  | ControlPlaneMalformedHeader
  | ControlPlaneDuplicateContentLength
  | ControlPlaneInvalidContentLength
  | ControlPlaneBodyTooLarge
  | ControlPlaneBodyPastDeclaredLength
  | ControlPlaneContentLengthRequired
  | ControlPlaneUnsupportedTransferEncoding
  | ControlPlaneConnectionClosedBeforeComplete
  deriving (Eq, Show)

-- | Pure incremental framing result over all bytes received so far.
data ControlPlaneFramingProgress
  = ControlPlaneFramingIncomplete
  | ControlPlaneFramingComplete !ByteString
  deriving (Eq, Show)

-- | Inspect an accumulated request without performing I/O. Headers must end
-- within the fixed 16 KiB budget. POST requests require one exact decimal
-- @Content-Length@; GET requests without that header are framed as empty-body
-- requests. Transfer-Encoding and ambiguous/malformed lengths are unsupported.
-- A complete result contains exactly the bytes safe to pass to the existing
-- pure parser/classifier seam.
inspectControlPlaneRequestFraming
  :: ByteString
  -> Either ControlPlaneFramingError ControlPlaneFramingProgress
inspectControlPlaneRequestFraming raw =
  case breakOnSubstring "\r\n\r\n" raw of
    Nothing
      | ByteString.length raw >= controlPlaneMaximumHeaderBytes ->
          Left ControlPlaneHeaderTooLarge
      | otherwise -> Right ControlPlaneFramingIncomplete
    Just (headerSection, terminatorAndBody)
      | ByteString.length headerSection + 4 > controlPlaneMaximumHeaderBytes ->
          Left ControlPlaneHeaderTooLarge
      | otherwise -> do
          declaredBodyBytes <- framingBodyLength headerSection
          let body = ByteString.drop 4 terminatorAndBody
              observedBodyBytes = ByteString.length body
          case compare observedBodyBytes declaredBodyBytes of
            LT -> Right ControlPlaneFramingIncomplete
            EQ -> Right (ControlPlaneFramingComplete raw)
            GT -> Left ControlPlaneBodyPastDeclaredLength

-- | Resolve end-of-stream against the same pure framing rules. An EOF while
-- either the header terminator or declared body is incomplete is a framing
-- refusal, never a truncated request passed to an interpreter.
finishControlPlaneRequestFraming
  :: ByteString
  -> Either ControlPlaneFramingError ByteString
finishControlPlaneRequestFraming raw = do
  progress <- inspectControlPlaneRequestFraming raw
  case progress of
    ControlPlaneFramingIncomplete ->
      Left ControlPlaneConnectionClosedBeforeComplete
    ControlPlaneFramingComplete request -> Right request

framingBodyLength :: ByteString -> Either ControlPlaneFramingError Int
framingBodyLength headerSection = do
  headers <- parseFramingHeaders headerSection
  if any ((== "transfer-encoding") . fst) headers
    then Left ControlPlaneUnsupportedTransferEncoding
    else do
      let contentLengths = [value | (name, value) <- headers, name == "content-length"]
      case contentLengths of
        []
          | requestMethod headerSection == Just "POST" ->
              Left ControlPlaneContentLengthRequired
          | otherwise -> Right 0
        [value] -> parseContentLength (framingMaximumBodyBytes headerSection) value
        _ -> Left ControlPlaneDuplicateContentLength

framingMaximumBodyBytes :: ByteString -> Int
framingMaximumBodyBytes headerSection =
  case framingRequestRoute headerSection of
    Just route -> controlPlaneRouteMaximumBodyBytes route
    Nothing -> controlPlaneMaximumBodyBytes

framingRequestRoute :: ByteString -> Maybe ControlPlaneRoute
framingRequestRoute headerSection = do
  line <- firstLine headerSection
  (method, path) <- case Char8.words line of
    methodBytes : pathBytes : _ -> do
      decodedMethod <- decodeControlPlaneMethod methodBytes
      pure (decodedMethod, Char8.unpack pathBytes)
    _ -> Nothing
  exactlyOne
    [ route
    | route <- allControlPlaneRoutes
    , controlPlaneRouteMethod route == method
    , controlPlaneRoutePath route == path
    ]
 where
  exactlyOne matches = case matches of
    [route] -> Just route
    _ -> Nothing

controlPlaneRouteMaximumBodyBytes :: ControlPlaneRoute -> Int
controlPlaneRouteMaximumBodyBytes route = case route of
  LifecyclePulumiCheckpoint -> controlPlaneMaximumLargeBodyBytes
  AuthorityBackupCopy -> controlPlaneMaximumLargeBodyBytes
  LifecycleConfigProposeCas -> controlPlaneMaximumLargeBodyBytes
  TargetTlsRestore -> controlPlaneMaximumLargeBodyBytes
  LifecycleAuthorityControl -> controlPlaneMaximumBodyBytes
  LifecycleMigrationApply -> controlPlaneMaximumBodyBytes
  LifecycleProjectionImport -> controlPlaneMaximumBodyBytes
  LifecycleAuthorityObserve -> controlPlaneMaximumBodyBytes
  LifecycleAuthorityBackupExport -> controlPlaneMaximumBodyBytes
  LifecycleAuthorityDecommissionExport -> controlPlaneMaximumBodyBytes
  LifecycleAuthorityDecommissionStop -> controlPlaneMaximumBodyBytes
  LifecycleRetainedSesLease -> controlPlaneMaximumBodyBytes
  LifecycleOperationSubmit -> controlPlaneMaximumBodyBytes
  LifecycleOperationObserve -> controlPlaneMaximumBodyBytes
  LifecycleConfigObserve -> controlPlaneMaximumBodyBytes
  LifecycleExternalMaterialIngress -> controlPlaneMaximumBodyBytes
  LifecycleFederationRegister -> controlPlaneMaximumLargeBodyBytes
  LifecycleAdminAction -> controlPlaneMaximumBodyBytes
  LifecycleAwsAdminProvisioner -> controlPlaneMaximumBodyBytes
  LifecycleProviderDispatch -> controlPlaneMaximumBodyBytes
  ProviderWorkApply -> controlPlaneMaximumBodyBytes
  ProviderWorkObserve -> controlPlaneMaximumBodyBytes
  AuthorityBackupObserve -> controlPlaneMaximumBodyBytes
  TlsRetentionStore -> controlPlaneMaximumBodyBytes
  TlsRetentionRestore -> controlPlaneMaximumBodyBytes
  TargetMaterialObserve -> controlPlaneMaximumBodyBytes
  TargetSecretDecommissionInventory -> controlPlaneMaximumBodyBytes
  TargetSecretDecommissionTombstone -> controlPlaneMaximumBodyBytes
  TargetSecretDecommissionCustodyTombstone -> controlPlaneMaximumBodyBytes
  TargetTlsPrepareExchange -> controlPlaneMaximumBodyBytes
  TargetTlsRetain -> controlPlaneMaximumBodyBytes
  TargetTlsHomeWrap -> controlPlaneMaximumBodyBytes
  TargetTlsHomeRewrap -> controlPlaneMaximumBodyBytes
  TargetTlsVerifySource -> controlPlaneMaximumBodyBytes
  LifecycleTlsRetentionObserve -> controlPlaneMaximumBodyBytes
  LifecycleTlsRetentionPromote -> controlPlaneMaximumBodyBytes
  LifecycleTlsRetentionWorkflow -> controlPlaneMaximumBodyBytes
  LifecycleAdminActionExecution -> controlPlaneMaximumBodyBytes
  TargetSecretAdminActionGenerationTombstone -> controlPlaneMaximumBodyBytes
  TargetSecretAdminActionCustodyTombstone -> controlPlaneMaximumBodyBytes
  TargetChildCustodyCommit -> controlPlaneMaximumBodyBytes
  TargetChildRecoveryPrepare -> controlPlaneMaximumBodyBytes
  TargetChildRecoveryObserve -> controlPlaneMaximumBodyBytes
  LifecycleBootstrapHandoffAccept -> controlPlaneMaximumBodyBytes
  LifecycleBootstrapHandoffObserve -> controlPlaneMaximumBodyBytes
  LifecycleTargetIntentIssue -> controlPlaneMaximumBodyBytes
  TargetSecretTrustInstall -> controlPlaneMaximumBodyBytes
  LifecycleRetainedMaterialDelivery -> controlPlaneMaximumBodyBytes
  TargetRetainedMaterialRewrap -> controlPlaneMaximumBodyBytes
  LifecycleCleanupRun -> controlPlaneMaximumLargeBodyBytes
  LifecycleEksDrainIntent -> controlPlaneMaximumLargeBodyBytes
  LifecycleEksDrainReadBackReceipt -> controlPlaneMaximumLargeBodyBytes
  LifecycleAwsStackReader -> controlPlaneMaximumLargeBodyBytes
  LifecycleAwsStackCreationBinding ->
    controlPlaneMaximumLifecycleInputBodyBytes
  LifecycleOwnershipManifest -> controlPlaneMaximumLifecycleInputBodyBytes
  LifecycleRecoveryPlane -> controlPlaneMaximumLifecycleInputBodyBytes
  LifecycleLocalRke2HostObservation ->
    controlPlaneMaximumLifecycleInputBodyBytes
  LifecycleCascadeRetainedSlot ->
    controlPlaneMaximumLifecycleInputBodyBytes
  LifecycleControllerOwner -> controlPlaneMaximumLifecycleInputBodyBytes

parseFramingHeaders
  :: ByteString
  -> Either ControlPlaneFramingError [(String, ByteString)]
parseFramingHeaders headerSection =
  case fmap stripTrailingCarriageReturn (Char8.split '\n' headerSection) of
    [] -> Left ControlPlaneMalformedHeader
    requestLine : headerLines
      | ByteString.null requestLine -> Left ControlPlaneMalformedHeader
      | otherwise -> traverse parseHeaderLine headerLines

parseHeaderLine
  :: ByteString
  -> Either ControlPlaneFramingError (String, ByteString)
parseHeaderLine line =
  let (rawName, colonAndValue) = Char8.break (== ':') line
      name = fmap toLower (Char8.unpack rawName)
   in if ByteString.null colonAndValue || null name || not (all isHeaderNameCharacter name)
        then Left ControlPlaneMalformedHeader
        else Right (name, trimOptionalWhitespace (ByteString.drop 1 colonAndValue))

isHeaderNameCharacter :: Char -> Bool
isHeaderNameCharacter character =
  isAlphaNum character || character `elem` ("!#$%&'*+-.^_`|~" :: String)

parseContentLength :: Int -> ByteString -> Either ControlPlaneFramingError Int
parseContentLength maximumBodyBytes rawValue
  | ByteString.null rawValue = Left ControlPlaneInvalidContentLength
  | not (Char8.all isDigit rawValue) = Left ControlPlaneInvalidContentLength
  | parsed > toInteger maximumBodyBytes = Left ControlPlaneBodyTooLarge
  | otherwise = Right (fromInteger parsed)
 where
  parsed = foldl' step 0 (Char8.unpack rawValue)
  step total digit = total * 10 + toInteger (fromEnum digit - fromEnum '0')

requestMethod :: ByteString -> Maybe ByteString
requestMethod headerSection = do
  line <- firstLine headerSection
  case Char8.words line of
    method : _ -> Just method
    [] -> Nothing

decodeControlPlaneMethod :: ByteString -> Maybe ControlPlaneMethod
decodeControlPlaneMethod method
  | method == "GET" = Just ControlPlaneGet
  | method == "POST" = Just ControlPlanePost
  | otherwise = Nothing

stripTrailingCarriageReturn :: ByteString -> ByteString
stripTrailingCarriageReturn value =
  case ByteString.unsnoc value of
    Just (before, 13) -> before
    _ -> value

trimOptionalWhitespace :: ByteString -> ByteString
trimOptionalWhitespace = Char8.dropWhileEnd isOptionalWhitespace . Char8.dropWhile isOptionalWhitespace
 where
  isOptionalWhitespace character = character == ' ' || character == '\t'

-- | A minimally parsed HTTP request: the decoded method (only the two methods the
-- closed route topology uses are recognised), the request-target token, and the
-- body after the header terminator. A request the server cannot parse yields
-- 'Nothing' and is treated as an unowned route.
data ParsedControlPlaneRequest = ParsedControlPlaneRequest
  { parsedRequestMethod :: !(Maybe ControlPlaneMethod)
  , parsedRequestPath :: !String
  , parsedRequestBody :: !ByteString
  }
  deriving (Eq, Show)

-- | Parse the request line (method + target) and the body. The body is whatever
-- follows the first CRLFCRLF. The production socket boundary calls
-- 'inspectControlPlaneRequestFraming' first, so this deliberately small parser
-- only receives a complete, exactly framed request there.
parseControlPlaneRequest :: ByteString -> Maybe ParsedControlPlaneRequest
parseControlPlaneRequest raw = do
  let (headerSection, body) = splitOnHeaderTerminator raw
  requestLine <- firstLine headerSection
  case Char8.words requestLine of
    (method : target : _) ->
      Just
        ParsedControlPlaneRequest
          { parsedRequestMethod = decodeControlPlaneMethod method
          , parsedRequestPath = Char8.unpack target
          , parsedRequestBody = body
          }
    _ -> Nothing

-- | Split on the first @\\r\\n\\r\\n@. If the terminator is absent (a header-only
-- probe such as @GET /healthz@ that a client may send without the blank line) the
-- whole input is the header section and the body is empty.
splitOnHeaderTerminator :: ByteString -> (ByteString, ByteString)
splitOnHeaderTerminator raw =
  case breakOnSubstring "\r\n\r\n" raw of
    Just (before, after) -> (before, ByteString.drop 4 after)
    Nothing -> (raw, ByteString.empty)

firstLine :: ByteString -> Maybe ByteString
firstLine section =
  case breakOnSubstring "\r\n" section of
    Just (before, _) -> Just before
    Nothing
      | ByteString.null section -> Nothing
      | otherwise -> Just section

-- | Return the input split around the first occurrence of @needle@ (the needle is
-- consumed into neither side by the caller). 'Nothing' when @needle@ is absent.
breakOnSubstring :: ByteString -> ByteString -> Maybe (ByteString, ByteString)
breakOnSubstring needle haystack =
  let (before, rest) = ByteString.breakSubstring needle haystack
   in if ByteString.null rest && not (needle `ByteString.isPrefixOf` haystack)
        then Nothing
        else Just (before, rest)

-- | The typed disposition of a request against a role's owned routes.
data ControlPlaneDisposition
  = -- | @GET /healthz@ — the process is serving.
    DispositionLive
  | -- | @GET /readyz@ — resolved against the interpreter's readiness probe.
    DispositionNotReady
  | -- | A method/path owned by this role, with its request body.
    DispositionOwnedRoute !ControlPlaneRoute !ByteString
  | -- | Not a route this role owns (including a route owned by a different role).
    DispositionNotOwned
  deriving (Eq, Show)

classifyControlPlaneRequest :: RuntimeRole -> ByteString -> ControlPlaneDisposition
classifyControlPlaneRequest role raw =
  case parseControlPlaneRequest raw of
    Nothing -> DispositionNotOwned
    Just request ->
      case (parsedRequestMethod request, parsedRequestPath request) of
        (Just ControlPlaneGet, "/healthz") -> DispositionLive
        (Just ControlPlaneGet, "/readyz") -> DispositionNotReady
        (Just method, path) ->
          case decodeRoleRoute role method path of
            Just route -> DispositionOwnedRoute route (parsedRequestBody request)
            Nothing -> DispositionNotOwned
        (Nothing, _) -> DispositionNotOwned

-- | A role's installed handlers. @interpreterHandle@ returns 'Nothing' for an
-- owned-but-unbound route (served as @503 interpreter-unavailable@) and
-- @Just (status, body)@ once the role binds a production handler.
--
-- Sprint 4.67: the status is a 'ReplyStatus', not an @Int@. Sprint 4.66 closed
-- the set at the /renderer/ and left every producer answering a raw @Int@,
-- which is why a @dev check@ text rule had to stand in for the type. A status
-- outside the closed set is now a @-Werror@ error at the producer rather than a
-- lint finding about it.
--
-- Sprint 4.55: readiness is a 'RoleReadinessSource' — cached facts readable in
-- one @STM@ transaction — and not an @m Bool@. The old field let a role put a
-- signed S3 @LIST@, a Vault read, or an @aws sts get-caller-identity@
-- subprocess on a @timeoutSeconds: 1@ kubelet probe path, and five roles did.
-- @STM@ has no @IO@, so that no longer type-checks.
data RoleInterpreter m = RoleInterpreter
  { interpreterReadiness :: !RoleReadinessSource
  , interpreterHandle :: ControlPlaneRoute -> ByteString -> m (Maybe (ReplyStatus, ByteString))
  }

-- | The default interpreter: liveness serves, readiness has observed nothing
-- and therefore fails closed, and no owned route is bound. Installed until a
-- role supplies a production interpreter.
failClosedInterpreter :: (Applicative m) => RoleInterpreter m
failClosedInterpreter =
  RoleInterpreter
    { interpreterReadiness =
        constantRoleReadinessSource (unobservedRoleReadinessFacts "role-interpreter")
    , interpreterHandle = \_ _ -> pure Nothing
    }

-- | How the request path turns a readiness source into a verdict: read the
-- monotonic clock and the latched facts, then fold. Injected so that the server
-- itself names no clock and no transaction runner, and a test can drive the
-- staleness arm deterministically.
newtype RoleReadinessResolver m = RoleReadinessResolver
  { resolveRoleReadinessSource :: RoleReadinessSource -> m RoleReadinessState
  }

-- | Build a resolver from a monotonic clock and a way to run one transaction.
mkRoleReadinessResolver
  :: (Monad m)
  => ObservationSchedule
  -> m Natural
  -> (forall a. STM a -> m a)
  -> RoleReadinessResolver m
mkRoleReadinessResolver schedule clock runTransaction =
  RoleReadinessResolver
    { resolveRoleReadinessSource = \source -> do
        now <- clock
        facts <- runTransaction (roleReadinessSnapshot source)
        pure (computeRoleReadiness schedule now facts)
    }

-- | Serve one request against a role's interpreter, returning the HTTP status and
-- body. Monad-generic so a pure/fake interpreter drives every arm in a unit test.
serveControlPlaneRequest
  :: (Monad m)
  => RoleReadinessResolver m
  -> RoleInterpreter m
  -> RuntimeRole
  -> ByteString
  -> m (ReplyStatus, ByteString)
serveControlPlaneRequest resolver interpreter role raw =
  case classifyControlPlaneRequest role raw of
    DispositionLive -> pure (ReplyOk, "live\n")
    DispositionNotReady -> do
      state <- resolveRoleReadinessSource resolver (interpreterReadiness interpreter)
      pure
        ( if roleReadinessIsReady state
            then (ReplyOk, "ready\n")
            else (ReplyServiceUnavailable, "not-ready\n")
        )
    DispositionNotOwned -> pure (ReplyNotFound, "route-not-owned\n")
    DispositionOwnedRoute route body -> do
      handled <- interpreterHandle interpreter route body
      pure (maybe (ReplyServiceUnavailable, "interpreter-unavailable\n") id handled)

-- | Render a bounded @Connection: close@ HTTP/1.1 response with an explicit
-- content length.
--
-- Sprint 4.67: the status argument is a 'ReplyStatus'. Sprint 4.66 made the
-- renderer total over a raw @Int@ by mapping an unknown code to
-- @Unmapped Status@; the code that reached it is now a closed constructor, so
-- the unmapped arm is unreachable from this call rather than merely unused by
-- it. The code and the reason are the two projections of one value and cannot
-- name different statuses.
renderHttpResponse :: ReplyStatus -> ByteString -> ByteString
renderHttpResponse status body =
  ByteString.concat
    [ "HTTP/1.1 "
    , Char8.pack (show (replyStatusCode status))
    , " "
    , replyStatusReason status
    , "\r\nConnection: close\r\nContent-Length: "
    , Char8.pack (show (ByteString.length body))
    , "\r\n\r\n"
    , body
    ]
