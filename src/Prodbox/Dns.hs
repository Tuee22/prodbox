{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Dns
  ( configuredPublicHostFqdns
  , fetchPublicIp
  , preferredApiHostFqdn
  , preferredIdentityHostFqdn
  , preferredPublicHostFqdn
  , preferredWebsocketHostFqdn
  , queryRoute53Record
  , queryRoute53RecordInZone
  , renderDnsStatusReport
  , runDnsCommand
  )
where

import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.AwsEnvironment
  ( isolatedAwsEnvironment
  )
import Prodbox.CLI.Command (DnsCommand (..))
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.Error (fatalError)
import Prodbox.PublicEdge
  ( publicFqdn
  , sharedPublicHostFqdns
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( Credentials (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Directory (findExecutable)
import System.Exit
  ( ExitCode (..)
  )

runDnsCommand :: FilePath -> DnsCommand -> IO ExitCode
runDnsCommand repoRoot command =
  case command of
    DnsCheck -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err -> failWith err
        Right settings -> do
          publicIpResult <- fetchPublicIp
          case publicIpResult of
            Left err -> failWith err
            Right publicIp -> do
              recordResult <- queryRoute53Record repoRoot settings (publicFqdn settings)
              case recordResult of
                Left err -> failWith err
                Right currentRecordIp -> do
                  writeOutput (renderDnsStatusReport settings publicIp currentRecordIp)
                  pure ExitSuccess

renderDnsStatusReport :: ValidatedSettings -> String -> Maybe String -> String
renderDnsStatusReport settings publicIp currentRecordIp =
  unlines
    [ "DNS status"
    , "FQDN=" ++ publicFqdn settings
    , "PUBLIC_IP=" ++ publicIp
    , "ROUTE53_A_RECORD=" ++ maybe "<missing>" id currentRecordIp
    , "STATUS=" ++ status
    ]
 where
  status
    | currentRecordIp == Just publicIp = "in-sync"
    | currentRecordIp == Nothing = "record-missing"
    | otherwise = "mismatch"

preferredPublicHostFqdn :: ValidatedSettings -> String
preferredPublicHostFqdn = publicFqdn

preferredIdentityHostFqdn :: ValidatedSettings -> String
preferredIdentityHostFqdn = publicFqdn

preferredApiHostFqdn :: ValidatedSettings -> String
preferredApiHostFqdn = publicFqdn

preferredWebsocketHostFqdn :: ValidatedSettings -> String
preferredWebsocketHostFqdn = publicFqdn

configuredPublicHostFqdns :: ValidatedSettings -> [String]
configuredPublicHostFqdns settings = nub (sharedPublicHostFqdns settings)

fetchPublicIp :: IO (Either String String)
fetchPublicIp = do
  curlExists <- findExecutable "curl"
  case curlExists of
    Nothing -> pure (Left "`dns check` requires `curl` to resolve the current public IP.")
    Just _ -> do
      outputResult <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "curl"
            , subprocessArguments = ["-fsSL", "https://api.ipify.org"]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Nothing
            }
      pure $
        case outputResult of
          Failure err -> Left ("failed to start `curl -fsSL https://api.ipify.org`: " ++ err)
          Success output ->
            case processExitCode output of
              ExitSuccess ->
                case words (processStdout output) of
                  (value : _) -> Right value
                  [] -> Left "public IP lookup returned an empty response"
              ExitFailure _ ->
                Left ("public IP lookup failed: " ++ outputDetail output)

queryRoute53Record :: FilePath -> ValidatedSettings -> String -> IO (Either String (Maybe String))
queryRoute53Record repoRoot settings fqdn =
  queryRoute53RecordInZone repoRoot settings (zone_id (route53 (validatedConfig settings))) fqdn

-- | Query a Route 53 hosted zone for an A record by FQDN. The hosted
-- zone is named explicitly so substrate-aware callers
-- (`prodbox host public-edge --substrate aws`) can target the
-- AWS-substrate subzone instead of the home substrate's zone. The
-- subprocess environment still authenticates with the operational
-- `aws.*` credentials from `prodbox-config.dhall` because every supported
-- Route 53 read on the supported path runs through that block.
queryRoute53RecordInZone
  :: FilePath
  -> ValidatedSettings
  -> Text
  -> String
  -> IO (Either String (Maybe String))
queryRoute53RecordInZone repoRoot settings hostedZoneId fqdn = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "route53"
            , "list-resource-record-sets"
            , "--hosted-zone-id"
            , Text.unpack hostedZoneId
            , "--output"
            , "json"
            ]
        , subprocessEnvironment = Just (awsCliEnvironment (aws config))
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case outputResult of
      Failure err -> Left ("failed to start `aws route53 list-resource-record-sets`: " ++ err)
      Success output ->
        case processExitCode output of
          ExitSuccess -> parseRoute53Record fqdn (processStdout output)
          ExitFailure _ -> Left ("aws route53 list-resource-record-sets failed: " ++ outputDetail output)
 where
  config = validatedConfig settings

parseRoute53Record :: String -> String -> Either String (Maybe String)
parseRoute53Record fqdn stdoutText = do
  payload <- eitherDecode (BL8.pack stdoutText) :: Either String Value
  pure (recordIpForFqdn (ensureTrailingDot fqdn) payload)

recordIpForFqdn :: String -> Value -> Maybe String
recordIpForFqdn fqdn payload =
  case payload of
    Object obj -> do
      Array records <- KeyMap.lookup "ResourceRecordSets" obj
      findRecordIp fqdn (Vector.toList records)
    _ -> Nothing

findRecordIp :: String -> [Value] -> Maybe String
findRecordIp _ [] = Nothing
findRecordIp fqdn (value : remaining) =
  case value of
    Object obj ->
      let nameMatches = KeyMap.lookup "Name" obj == Just (String (Text.pack fqdn))
          typeMatches = KeyMap.lookup "Type" obj == Just (String "A")
       in if nameMatches && typeMatches
            then firstRecordIp obj
            else findRecordIp fqdn remaining
    _ -> findRecordIp fqdn remaining

firstRecordIp :: KeyMap.KeyMap Value -> Maybe String
firstRecordIp obj = do
  Array records <- KeyMap.lookup "ResourceRecords" obj
  firstValue <- case Vector.toList records of
    [] -> Nothing
    (record : _) -> Just record
  case firstValue of
    Object recordObj ->
      case KeyMap.lookup "Value" recordObj of
        Just (String value) -> Just (Text.unpack value)
        _ -> Nothing
    _ -> Nothing

ensureTrailingDot :: String -> String
ensureTrailingDot value = if null value || last value == '.' then value else value ++ "."

awsCliEnvironment :: Credentials -> [(String, String)]
awsCliEnvironment = isolatedAwsEnvironment

outputDetail :: ProcessOutput -> String
outputDetail output =
  case (trim (processStderr output), trim (processStdout output)) of
    (stderrText, _) | stderrText /= "" -> stderrText
    ("", stdoutText) | stdoutText /= "" -> stdoutText
    _ -> "subprocess exited without output"

trim :: String -> String
trim = f . f
 where
  f = reverse . dropWhile (`elem` [' ', '\n', '\r', '\t'])

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
