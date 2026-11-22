-- | Refuse a reconcile whose declared host ports are already listening. This
-- is the port half of the disjoint-scope condition: a sibling scope (or any
-- other listener) holding one of the plan's API, HTTP or HTTPS host ports would
-- make the node create fail after the image, network and volume effects, so it
-- is observed first. The observation reads the kernel's listening-socket
-- tables; an unreadable table is a refusal, not absence.
module Prodbox.Control.HostPorts
  ( hostPortRefusal
  , listeningPorts
  , dockerNameRefusal
  ) where

import Control.Exception (IOException, try)
import Data.ByteString.Char8 qualified as ByteString8
import Data.Char (isHexDigit)
import Data.List (nub, sort)
import Numeric (readHex)
import Prodbox.Control.DockerIdentity (readDocker)

-- | The first declared port that is listening, or an explanation.
hostPortRefusal :: [Int] -> IO (Maybe String)
hostPortRefusal declared = do
  listening <- listeningPorts
  pure $ case listening of
    Nothing -> Just "the host listening-socket tables are unreadable; occupied ports cannot be ruled out"
    Just ports -> case filter (`elem` ports) declared of
      [] -> Nothing
      busy -> Just ("declared host port already listening: " ++ unwords (map show (nub (sort busy))))

listeningPorts :: IO (Maybe [Int])
listeningPorts = do
  v4 <- table "/proc/net/tcp"
  v6 <- table "/proc/net/tcp6"
  pure ((++) <$> v4 <*> v6)
 where
  table path = do
    contents <- try (ByteString8.readFile path) :: IO (Either IOException ByteString8.ByteString)
    pure (either (const Nothing) (Just . concatMap entry . drop 1 . ByteString8.lines) contents)
  entry line = case ByteString8.words line of
    (_ : local : _ : state : _)
      | state == ByteString8.pack "0A" -> maybe [] pure (portOf (ByteString8.unpack local))
    _ -> []
  portOf local = case break (== ':') local of
    (_, ':' : hexPort) | not (null hexPort) && all isHexDigit hexPort -> case readHex hexPort of
      [(value, "")] -> Just value
      _ -> Nothing
    _ -> Nothing

-- | Docker resources already carrying this scope's cluster name. A new
-- operation starts only after the previous one's records were archived, which
-- requires its resources to be removed, so a container, network or volume of
-- this name at admission belongs to something else (a sibling scope with the
-- same deployment identity, or residue): refuse before any effect. An
-- unobservable listing is a refusal, not absence.
dockerNameRefusal :: FilePath -> String -> IO (Maybe String)
dockerNameRefusal socket clusterName = do
  containers <-
    readDocker socket ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ clusterName]
  networks <- readDocker socket ["network", "ls", "-q", "--filter", "name=^" ++ clusterName ++ "$"]
  volumes <- readDocker socket ["volume", "ls", "-q", "--filter", "name=" ++ clusterName]
  pure $ case (containers, networks, volumes) of
    (Just c, Just n, Just v)
      | null (words (c ++ n ++ v)) -> Nothing
      | otherwise ->
          Just
            ( "Docker resources named for "
                ++ clusterName
                ++ " already exist ("
                ++ unwords
                  ( [show (length (words c)) ++ " container(s)" | not (null (words c))]
                      ++ [show (length (words n)) ++ " network(s)" | not (null (words n))]
                      ++ [show (length (words v)) ++ " volume(s)" | not (null (words v))]
                  )
                ++ "); they are not recorded as this scope's"
            )
    _ -> Just "the Docker inventory is unobservable; existing resources of this name cannot be ruled out"
