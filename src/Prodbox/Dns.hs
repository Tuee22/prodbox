{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Dns
  ( changeRoute53ARecordSetInZone
  , configuredPublicHostFqdns
  , fetchPublicIp
  , preferredApiHostFqdn
  , preferredIdentityHostFqdn
  , preferredPublicHostFqdn
  , preferredWebsocketHostFqdn
  , queryRoute53Record
  , queryRoute53ARecordValuesInZone
  , queryRoute53RecordInZone
  , renderDnsStatusReport
  , runDnsCommand
  )
where

import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.AwsEnvironment
  ( awsCliSubprocessEnvironment
  )
import Prodbox.CLI.Command (DnsCommand (..))
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.Error (fatalError)
import Prodbox.Http.Client
  ( defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import Prodbox.PublicEdge
  ( publicFqdn
  , sharedPublicHostFqdns
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( ConfigFile (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , resolveAwsCredentialsRefFromHostVault
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
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
  result <- httpGetText defaultHttpConfig "https://api.ipify.org"
  pure $ case result of
    Left err -> Left ("public IP lookup failed: " ++ renderHttpError err)
    Right body -> case words body of
      (value : _) -> Right value
      [] -> Left "public IP lookup returned an empty response"

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
  valuesResult <- queryRoute53ARecordValuesInZone repoRoot settings hostedZoneId fqdn
  pure $ case valuesResult of
    Left err -> Left err
    Right [] -> Right Nothing
    Right (firstValue : _) -> Right (Just firstValue)

queryRoute53ARecordValuesInZone
  :: FilePath
  -> ValidatedSettings
  -> Text
  -> String
  -> IO (Either String [String])
queryRoute53ARecordValuesInZone repoRoot settings hostedZoneId fqdn = do
  environmentResult <- awsCliEnvironment repoRoot config
  case environmentResult of
    Left err -> pure (Left err)
    Right environment -> do
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
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Just repoRoot
            }
      pure $
        case outputResult of
          Failure err -> Left ("failed to start `aws route53 list-resource-record-sets`: " ++ err)
          Success output ->
            case processExitCode output of
              ExitSuccess -> parseRoute53RecordValues fqdn (processStdout output)
              ExitFailure _ -> Left ("aws route53 list-resource-record-sets failed: " ++ outputDetail output)
 where
  config = validatedConfig settings

changeRoute53ARecordSetInZone
  :: FilePath
  -> ValidatedSettings
  -> Text
  -> String
  -> [String]
  -> Int
  -> IO (Either String ())
changeRoute53ARecordSetInZone repoRoot settings hostedZoneId fqdn recordValues ttlValue
  | null recordValues = pure (Left ("refusing to write empty Route 53 A record set for " ++ fqdn))
  | otherwise = do
      environmentResult <- awsCliEnvironment repoRoot config
      case environmentResult of
        Left err -> pure (Left err)
        Right environment -> do
          changeResult <-
            captureSubprocessResult
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments =
                    [ "route53"
                    , "change-resource-record-sets"
                    , "--hosted-zone-id"
                    , Text.unpack hostedZoneId
                    , "--change-batch"
                    , BL8.unpack (encode (route53AChangeBatch "UPSERT" fqdn recordValues ttlValue))
                    , "--query"
                    , "ChangeInfo.Id"
                    , "--output"
                    , "text"
                    ]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just repoRoot
                }
          case changeResult of
            Failure err -> pure (Left ("failed to start `aws route53 change-resource-record-sets`: " ++ err))
            Success changeOutput ->
              case processExitCode changeOutput of
                ExitFailure _ -> pure (Left ("aws route53 change-resource-record-sets failed: " ++ outputDetail changeOutput))
                ExitSuccess -> do
                  waitResult <-
                    captureSubprocessResult
                      Subprocess
                        { subprocessPath = "aws"
                        , subprocessArguments =
                            [ "route53"
                            , "wait"
                            , "resource-record-sets-changed"
                            , "--id"
                            , trim (processStdout changeOutput)
                            ]
                        , subprocessEnvironment = Just environment
                        , subprocessWorkingDirectory = Just repoRoot
                        }
                  pure $ case waitResult of
                    Failure err -> Left ("failed to start `aws route53 wait resource-record-sets-changed`: " ++ err)
                    Success waitOutput ->
                      case processExitCode waitOutput of
                        ExitSuccess -> Right ()
                        ExitFailure _ -> Left ("aws route53 wait resource-record-sets-changed failed: " ++ outputDetail waitOutput)
 where
  config = validatedConfig settings

route53AChangeBatch :: String -> String -> [String] -> Int -> Value
route53AChangeBatch action fqdn recordValues ttlValue =
  object
    [ "Changes"
        .= [ object
               [ "Action" .= action
               , "ResourceRecordSet"
                   .= object
                     [ "Name" .= ensureTrailingDot fqdn
                     , "Type" .= ("A" :: String)
                     , "TTL" .= ttlValue
                     , "ResourceRecords" .= map (\value -> object ["Value" .= value]) recordValues
                     ]
               ]
           ]
    ]

parseRoute53RecordValues :: String -> String -> Either String [String]
parseRoute53RecordValues fqdn stdoutText = do
  payload <- eitherDecode (BL8.pack stdoutText) :: Either String Value
  pure (recordIpsForFqdn (ensureTrailingDot fqdn) payload)

recordIpsForFqdn :: String -> Value -> [String]
recordIpsForFqdn fqdn payload =
  case payload of
    Object obj ->
      case KeyMap.lookup "ResourceRecordSets" obj of
        Just (Array records) -> findRecordIps fqdn (Vector.toList records)
        _ -> []
    _ -> []

findRecordIps :: String -> [Value] -> [String]
findRecordIps _ [] = []
findRecordIps fqdn (value : remaining) =
  case value of
    Object obj ->
      let nameMatches = KeyMap.lookup "Name" obj == Just (String (Text.pack fqdn))
          typeMatches = KeyMap.lookup "Type" obj == Just (String "A")
       in if nameMatches && typeMatches
            then recordIps obj
            else findRecordIps fqdn remaining
    _ -> findRecordIps fqdn remaining

recordIps :: KeyMap.KeyMap Value -> [String]
recordIps obj =
  case KeyMap.lookup "ResourceRecords" obj of
    Just (Array records) -> mapMaybeValue recordValue (Vector.toList records)
    _ -> []

recordValue :: Value -> Maybe String
recordValue value =
  case value of
    Object recordObj ->
      case KeyMap.lookup "Value" recordObj of
        Just (String recordText) -> Just (Text.unpack recordText)
        _ -> Nothing
    _ -> Nothing

mapMaybeValue :: (a -> Maybe b) -> [a] -> [b]
mapMaybeValue _ [] = []
mapMaybeValue f (value : remaining) =
  case f value of
    Nothing -> mapMaybeValue f remaining
    Just result -> result : mapMaybeValue f remaining

ensureTrailingDot :: String -> String
ensureTrailingDot value = if null value || last value == '.' then value else value ++ "."

-- | Route 53 subprocesses run through the single PATH/HOME/LANG-preserving
-- 'awsCliSubprocessEnvironment' builder so the bare @aws@ binary resolves on
-- hosts where @aws@ lives outside the default exec @PATH@. Sprint 1.30 fixed
-- the prior empty-base (`isolatedAwsEnvironment`) that dropped @PATH@.
awsCliEnvironment :: FilePath -> ConfigFile -> IO (Either String [(String, String)])
awsCliEnvironment repoRoot config = do
  credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
  case credentialsResult of
    Left err -> pure (Left ("load operational AWS credentials from Vault: " ++ err))
    Right credentials -> Right <$> awsCliSubprocessEnvironment credentials

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
