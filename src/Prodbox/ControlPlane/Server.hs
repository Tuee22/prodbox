{-# LANGUAGE OverloadedStrings #-}

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
  ( ParsedControlPlaneRequest (..)
  , parseControlPlaneRequest
  , ControlPlaneDisposition (..)
  , classifyControlPlaneRequest
  , RoleInterpreter (..)
  , failClosedInterpreter
  , serveControlPlaneRequest
  , renderHttpResponse
  , httpReasonPhrase
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlaneGet, ControlPlanePost)
  , ControlPlaneRoute
  , decodeRoleRoute
  )
import Prodbox.Runtime.Role (RuntimeRole)

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
-- follows the first CRLFCRLF; a single bounded @recv@ is sufficient for the small
-- control-plane command bodies, and a truncated body simply fails the downstream
-- bounded command codec rather than corrupting state.
parseControlPlaneRequest :: ByteString -> Maybe ParsedControlPlaneRequest
parseControlPlaneRequest raw = do
  let (headerSection, body) = splitOnHeaderTerminator raw
  requestLine <- firstLine headerSection
  case Char8.words requestLine of
    (method : target : _) ->
      Just
        ParsedControlPlaneRequest
          { parsedRequestMethod = decodeMethod method
          , parsedRequestPath = Char8.unpack target
          , parsedRequestBody = body
          }
    _ -> Nothing
 where
  decodeMethod method
    | method == "GET" = Just ControlPlaneGet
    | method == "POST" = Just ControlPlanePost
    | otherwise = Nothing

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
data RoleInterpreter m = RoleInterpreter
  { interpreterReadyz :: m Bool
  , interpreterHandle :: ControlPlaneRoute -> ByteString -> m (Maybe (Int, ByteString))
  }

-- | The default interpreter: liveness serves, readiness is false, and no owned
-- route is bound. Installed until a role supplies a production interpreter.
failClosedInterpreter :: (Applicative m) => RoleInterpreter m
failClosedInterpreter =
  RoleInterpreter
    { interpreterReadyz = pure False
    , interpreterHandle = \_ _ -> pure Nothing
    }

-- | Serve one request against a role's interpreter, returning the HTTP status and
-- body. Monad-generic so a pure/fake interpreter drives every arm in a unit test.
serveControlPlaneRequest
  :: (Monad m)
  => RoleInterpreter m
  -> RuntimeRole
  -> ByteString
  -> m (Int, ByteString)
serveControlPlaneRequest interpreter role raw =
  case classifyControlPlaneRequest role raw of
    DispositionLive -> pure (200, "live\n")
    DispositionNotReady -> do
      ready <- interpreterReadyz interpreter
      pure (if ready then (200, "ready\n") else (503, "not-ready\n"))
    DispositionNotOwned -> pure (404, "route-not-owned\n")
    DispositionOwnedRoute route body -> do
      handled <- interpreterHandle interpreter route body
      pure (maybe (503, "interpreter-unavailable\n") id handled)

-- | Render a bounded @Connection: close@ HTTP/1.1 response with an explicit
-- content length.
renderHttpResponse :: Int -> ByteString -> ByteString
renderHttpResponse status body =
  ByteString.concat
    [ "HTTP/1.1 "
    , Char8.pack (show status)
    , " "
    , httpReasonPhrase status
    , "\r\nConnection: close\r\nContent-Length: "
    , Char8.pack (show (ByteString.length body))
    , "\r\n\r\n"
    , body
    ]

-- | Total reason phrase for the closed set of status codes the role servers emit.
httpReasonPhrase :: Int -> ByteString
httpReasonPhrase status = case status of
  200 -> "OK"
  400 -> "Bad Request"
  404 -> "Not Found"
  409 -> "Conflict"
  500 -> "Internal Server Error"
  503 -> "Service Unavailable"
  _ -> "Status"
