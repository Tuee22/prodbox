-- | Sprint 7.46: where a registry readiness probe runs from, and what it says.
--
-- The home registry is probed from the operator host through its NodePort on
-- the loopback address. The EKS registry cannot be: the host has no network
-- path into the EKS nodes, so the same loopback address answers for the HOME
-- registry, and an AWS run that probed it proved the wrong registry (a false
-- witness, not a failure that hides). The EKS probe therefore runs inside the
-- registry's own pod, through the Kubernetes API the run already holds
-- credentials for, against the process that has to reach the storage backend.
--
-- Everything here is pure: the command a vantage runs, and the reading of what
-- it wrote. The caller owns running it, so a case can supply a fake runner and
-- assert what an AWS run asked of which cluster.
module Prodbox.Lib.RegistryProbe
  ( RegistryProbeVantage (..)
  , registryProbeVantageFor
  , RegistryProbeRequest (..)
  , RegistryProbeTarget (..)
  , registryProbeCommand
  , RegistryStorageEdgeObservation (..)
  , interpretRegistryProbe
  , parseRegistryStorageEdgeResponse
  , parseInPodRegistryResponse
  )
where

import Data.Char (isDigit, isSpace, toLower)
import Data.List (dropWhileEnd, intercalate, isPrefixOf)
import Prodbox.Substrate (Substrate (..))
import System.Exit (ExitCode (..))

-- | The place a probe runs from.
data RegistryProbeVantage
  = -- | The operator host, through the registry's NodePort. The home registry.
    RegistryProbeFromHost
  | -- | Inside the registry Deployment's own container, on the cluster the
    -- process's @KUBECONFIG@ selects. The EKS registry.
    RegistryProbeFromRegistryPod
  deriving (Eq, Show)

-- | The vantage a substrate's registry is probed from. Total, and the only
-- place the choice is made, so an AWS step cannot reach the host's loopback
-- by omission.
registryProbeVantageFor :: Substrate -> RegistryProbeVantage
registryProbeVantageFor substrate = case substrate of
  SubstrateHomeLocal -> RegistryProbeFromHost
  SubstrateAws -> RegistryProbeFromRegistryPod

-- | What a probe asks of the registry.
data RegistryProbeRequest
  = -- | @GET <path>@: the front door, answered without touching storage.
    RegistryProbeStatus String
  | -- | @POST /v2/<repository>/blobs/uploads/@: open an upload session, which the
    -- registry can only create by writing through to its storage backend.
    RegistryProbeUploadSession String
  deriving (Eq, Show)

-- | The coordinates of the registry under probe.
data RegistryProbeTarget = RegistryProbeTarget
  { registryProbeHostEndpoint :: String
  -- ^ @host:port@ the operator host reaches the registry at.
  , registryProbeNamespace :: String
  , registryProbeDeployment :: String
  , registryProbeContainer :: String
  , registryProbeContainerPort :: Int
  -- ^ The port the registry listens on inside its container.
  }
  deriving (Eq, Show)

-- | The tool and arguments that run a request from a vantage.
--
-- The host arguments are the ones the home reconcile has always run. The pod
-- ones execute a raw HTTP/1.0 request against the container's own loopback with
-- @printf@ and @nc@, so the response arrives exactly as the registry wrote it:
-- status line, then headers, with no client between that interprets the status.
-- The header this probe exists for is the one a @202@ carries,
-- @Docker-Upload-UUID@, the receipt of the write to the storage backend. Both
-- tools were run against the @registry:2@ image (Alpine 3.18, BusyBox 1.36.1,
-- distribution 2.8.3): @nc@ wrote the whole response with CRLF line ends, and
-- @wget -S@ printed the same headers too; @nc@ is used because it does not depend
-- on how a given BusyBox release treats a status other than 200. The script
-- always ends in @true@, so a non-zero exit from @kubectl@ means the exec itself
-- failed (no pod, no container, no API); a registry that answered with an error
-- status, and a connection that was refused, are read from what the script wrote.
registryProbeCommand
  :: RegistryProbeTarget
  -> RegistryProbeVantage
  -> RegistryProbeRequest
  -> (FilePath, [String])
registryProbeCommand target vantage request = case vantage of
  RegistryProbeFromHost -> ("curl", hostArguments)
  RegistryProbeFromRegistryPod -> ("kubectl", podArguments)
 where
  hostArguments = case request of
    RegistryProbeStatus path ->
      [ "-sS"
      , "--max-time"
      , "5"
      , "-o"
      , "/dev/null"
      , "-w"
      , "%{http_code}"
      , "http://" ++ registryProbeHostEndpoint target ++ path
      ]
    RegistryProbeUploadSession repository ->
      [ "-sS"
      , "--max-time"
      , "10"
      , "-X"
      , "POST"
      , "-o"
      , "/dev/null"
      , "-D"
      , "-"
      , "-w"
      , "\n%{http_code}"
      , "http://" ++ registryProbeHostEndpoint target ++ uploadPath repository
      ]

  podArguments =
    [ "exec"
    , "--namespace"
    , registryProbeNamespace target
    , "deployment/" ++ registryProbeDeployment target
    , "--container"
    , registryProbeContainer target
    , "--"
    , "/bin/sh"
    , "-c"
    , podScript
    ]

  podScript = case request of
    RegistryProbeStatus path -> rawHttp 5 ("GET " ++ path) []
    RegistryProbeUploadSession repository ->
      rawHttp 10 ("POST " ++ uploadPath repository) ["Content-Length: 0"]

  -- The request line and headers are one @printf@ format; @\r\n@ is the format's
  -- own escape, so no carriage return ever travels through the command line.
  rawHttp seconds requestLine extraHeaders =
    "printf '"
      ++ requestLine
      ++ " HTTP/1.0\\r\\n"
      ++ concatMap (++ "\\r\\n") ("Host: 127.0.0.1" : extraHeaders)
      ++ "\\r\\n' | nc -w "
      ++ show (seconds :: Int)
      ++ " 127.0.0.1 "
      ++ show (registryProbeContainerPort target)
      ++ " 2>&1; true"

  uploadPath repository = "/v2/" ++ repository ++ "/blobs/uploads/"

-- | What one probe observed: the HTTP status the registry answered with, and the
-- upload session it named. The session is the receipt of the write-through to
-- the storage backend; a front-door probe names none.
data RegistryStorageEdgeObservation = RegistryStorageEdgeObservation
  { registryProbeStatus :: String
  , registryProbeUploadSession :: String
  }
  deriving (Eq, Show)

-- | Read what a probe's process wrote. A failed process is the failure detail,
-- stderr then stdout; a successful one is parsed for the vantage and request
-- that ran.
interpretRegistryProbe
  :: RegistryProbeVantage
  -> RegistryProbeRequest
  -> ExitCode
  -> String
  -> String
  -> Either String RegistryStorageEdgeObservation
interpretRegistryProbe vantage request exitCode standardOutput standardError =
  case exitCode of
    ExitFailure _ -> Left (failureDetail standardOutput standardError)
    ExitSuccess -> case (vantage, request) of
      (RegistryProbeFromHost, RegistryProbeStatus _) ->
        Right (RegistryStorageEdgeObservation (trim standardOutput) "")
      (RegistryProbeFromHost, RegistryProbeUploadSession _) ->
        Right (parseRegistryStorageEdgeResponse standardOutput)
      (RegistryProbeFromRegistryPod, _) -> parseInPodRegistryResponse standardOutput

failureDetail :: String -> String -> String
failureDetail standardOutput standardError =
  case filter (not . null) [trimNewlines standardError, trimNewlines standardOutput] of
    [] -> "subprocess exited without output"
    rendered -> intercalate " | " rendered
 where
  trimNewlines = dropWhileEnd (`elem` ("\r\n" :: String))

-- | Split a @curl -D - -w "\n%{http_code}"@ response into the status the probe
-- asked for and the upload session the registry named. Pure, so the parse is
-- exercised without a live registry.
parseRegistryStorageEdgeResponse :: String -> RegistryStorageEdgeObservation
parseRegistryStorageEdgeResponse raw =
  RegistryStorageEdgeObservation
    { registryProbeStatus = status
    , registryProbeUploadSession = uploadSession responseLines
    }
 where
  responseLines = map trim (lines raw)
  nonEmpty = [entry | entry <- responseLines, not (null entry)]
  status = case reverse nonEmpty of
    (final : _) -> final
    [] -> ""

-- | Read the response @nc@ wrote inside the registry container: the status line
-- and headers, then the body, folded with @nc@'s own diagnostics. Leading
-- whitespace is tolerated, because a transcript that has been through a pager or
-- an indenting tool is still a transcript. The last status line is the final
-- response; output with none means no answer arrived (the tool is absent, the
-- connection was refused, the registry never replied), and that is reported with
-- what was written rather than as a status.
parseInPodRegistryResponse :: String -> Either String RegistryStorageEdgeObservation
parseInPodRegistryResponse transcript =
  case reverse [code | entry <- entries, Just code <- [httpStatusCode entry]] of
    [] ->
      Left
        ( "the probe inside the registry pod produced no HTTP response: "
            ++ take 240 (unwords (words transcript))
        )
    final : _ ->
      Right
        RegistryStorageEdgeObservation
          { registryProbeStatus = final
          , registryProbeUploadSession = uploadSession entries
          }
 where
  entries = map trim (lines (filter (/= '\r') transcript))

-- | The three-digit code of an HTTP status line (@HTTP/1.1 202 Accepted@).
httpStatusCode :: String -> Maybe String
httpStatusCode entry = case words entry of
  protocol : code : _
    | "HTTP/" `isPrefixOf` protocol && length code == 3 && all isDigit code -> Just code
  _ -> Nothing

-- | The registry names the session it created in @Docker-Upload-UUID@ and names
-- where to continue it in @Location@. Either identifies the write the registry
-- performed; the UUID is preferred deterministically because it is the
-- identifier the registry itself allocated rather than a URL it composed.
uploadSession :: [String] -> String
uploadSession entries =
  case headerValues "docker-upload-uuid" ++ headerValues "location" of
    value : _ -> value
    [] -> ""
 where
  headerValues wanted =
    [ value
    | entry <- entries
    , (name, ':' : rest) <- [break (== ':') entry]
    , map toLower (trim name) == wanted
    , let value = trim rest
    , not (null value)
    ]

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
