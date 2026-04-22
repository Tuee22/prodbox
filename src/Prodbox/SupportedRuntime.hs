{-# LANGUAGE OverloadedStrings #-}

module Prodbox.SupportedRuntime
    ( SupportedRuntimeContext (..),
      removeDeletePendingAwsResources,
      removeFqdnFromHostsText,
      removePublicHostHostsOverride,
    )
where

import Control.Exception
    ( IOException,
      displayException,
      try,
    )
import Data.Aeson
    ( Value (..),
    )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Char (toLower)
import Data.List (intercalate)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Prodbox.Settings
    ( ConfigFile (..),
      DomainSection (..),
      ValidatedSettings (..),
      validateAndLoadSettings,
    )
import System.Directory
    ( Permissions,
      getPermissions,
      writable,
    )
import System.Exit
    ( ExitCode (..),
    )
import System.Process
    ( proc,
      readCreateProcessWithExitCode,
    )

data SupportedRuntimeContext = SupportedRuntimeContext
    { supportedRuntimeRepoRoot :: FilePath,
      supportedRuntimeHelperEnvironment :: [(String, String)]
    }

removePublicHostHostsOverride :: SupportedRuntimeContext -> IO (Either String String)
removePublicHostHostsOverride context = do
    settingsResult <- loadValidatedSettings context
    case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
            let fqdn = preferredPublicHostFqdn (validatedConfig settings)
                hostsPath = "/etc/hosts"
            originalTextResult <- try (readFile hostsPath) :: IO (Either IOException String)
            case originalTextResult of
                Left err -> pure (Left ("failed to read " ++ hostsPath ++ ": " ++ displayException err))
                Right originalText -> do
                    let (updatedText, removedEntries) = removeFqdnFromHostsText originalText fqdn
                    if removedEntries == 0
                        then pure (Right ("No /etc/hosts override found for " ++ fqdn))
                        else do
                            writeResult <- writeHostsFile hostsPath updatedText
                            case writeResult of
                                Left err -> pure (Left err)
                                Right () -> do
                                    postWriteResult <- try (readFile hostsPath) :: IO (Either IOException String)
                                    case postWriteResult of
                                        Left err -> pure (Left ("failed to re-read " ++ hostsPath ++ ": " ++ displayException err))
                                        Right postWriteText -> do
                                            let (_, remainingEntries) = removeFqdnFromHostsText postWriteText fqdn
                                            if remainingEntries == 0
                                                then pure (Right ("Removed " ++ show removedEntries ++ " /etc/hosts override entrie(s) for " ++ fqdn))
                                                else pure (Left (hostsPath ++ " still contains unsupported override for " ++ fqdn))

removeFqdnFromHostsText :: String -> String -> (String, Int)
removeFqdnFromHostsText hostsText fqdn =
    case map toLowerAscii (trimSpaces fqdn) of
        "" -> (hostsText, 0)
        target ->
            let (updatedLines, removedEntries) = foldr (collectLine target) ([], 0) (lines hostsText)
             in (renderHostsText updatedLines (endsWithNewline hostsText), removedEntries)
  where
    collectLine :: String -> String -> ([String], Int) -> ([String], Int)
    collectLine target rawLine (updatedLines, removedEntries) =
        let (body, commentPart) = splitComment rawLine
            tokens = words body
         in case tokens of
                [] -> (rawLine : updatedLines, removedEntries)
                [_] -> (rawLine : updatedLines, removedEntries)
                ipAddress : names ->
                    let keptNames = filter ((/= target) . map toLowerAscii) names
                        removedHere = length names - length keptNames
                     in if removedHere == 0
                            then (rawLine : updatedLines, removedEntries)
                            else
                                case keptNames of
                                    [] ->
                                        case trimSpaces commentPart of
                                            "" -> (updatedLines, removedEntries + removedHere)
                                            strippedComment -> (("# " ++ strippedComment) : updatedLines, removedEntries + removedHere)
                                    _ ->
                                        let rebuilt = ipAddress ++ " " ++ unwords keptNames
                                            rendered =
                                                case trimSpaces commentPart of
                                                    "" -> rebuilt
                                                    strippedComment -> rebuilt ++ "  # " ++ strippedComment
                                         in (rendered : updatedLines, removedEntries + removedHere)

removeDeletePendingAwsResources :: Value -> Either String (Value, Int)
removeDeletePendingAwsResources exportedValue =
    case exportedValue of
        Object rootObject ->
            case KeyMap.lookup (Key.fromString "deployment") rootObject of
                Just (Object deploymentObject) ->
                    case KeyMap.lookup (Key.fromString "resources") deploymentObject of
                        Just (Array resources) ->
                            let (keptResources, removedCount) = Vector.foldr collectResource ([], 0) resources
                                updatedDeployment =
                                    Object
                                        ( KeyMap.insert
                                            (Key.fromString "resources")
                                            (Array (Vector.fromList (reverse keptResources)))
                                            deploymentObject
                                        )
                                updatedRoot =
                                    Object
                                        (KeyMap.insert (Key.fromString "deployment") updatedDeployment rootObject)
                             in Right (updatedRoot, removedCount)
                        _ -> Left unexpectedPulumiExportShape
                _ -> Left unexpectedPulumiExportShape
        _ -> Left unexpectedPulumiExportShape
  where
    collectResource :: Value -> ([Value], Int) -> ([Value], Int)
    collectResource value (keptResources, removedCount) =
        case value of
            Object resourceObject
                | isDeletePendingAwsResource resourceObject -> (keptResources, removedCount + 1)
            _ -> (value : keptResources, removedCount)

unexpectedPulumiExportShape :: String
unexpectedPulumiExportShape = "pulumi stack export returned deployment resources in an unexpected shape"

loadValidatedSettings :: SupportedRuntimeContext -> IO (Either String ValidatedSettings)
loadValidatedSettings context = validateAndLoadSettings (supportedRuntimeRepoRoot context)

preferredPublicHostFqdn :: ConfigFile -> String
preferredPublicHostFqdn config =
    case vscode_fqdn (domain config) of
        Just value -> Text.unpack value
        Nothing -> Text.unpack (demo_fqdn (domain config))

writeHostsFile :: FilePath -> String -> IO (Either String ())
writeHostsFile hostsPath updatedText = do
    permissionsResult <- try (getPermissions hostsPath) :: IO (Either IOException Permissions)
    case permissionsResult of
        Left err -> pure (Left ("failed to read permissions for " ++ hostsPath ++ ": " ++ displayException err))
        Right permissions ->
            if writable permissions
                then do
                    writeResult <- try (writeFile hostsPath updatedText) :: IO (Either IOException ())
                    pure $
                        case writeResult of
                            Left err -> Left ("failed to rewrite " ++ hostsPath ++ ": " ++ displayException err)
                            Right () -> Right ()
                else do
                    sudoResult <-
                        try
                            ( readCreateProcessWithExitCode
                                (proc "sudo" ["tee", hostsPath])
                                updatedText
                            ) :: IO (Either IOException (ExitCode, String, String))
                    pure $
                        case sudoResult of
                            Left err -> Left ("failed to rewrite " ++ hostsPath ++ ": " ++ displayException err)
                            Right (exitCode, stdoutText, stderrText) ->
                                case exitCode of
                                    ExitSuccess -> Right ()
                                    ExitFailure code ->
                                        Left
                                            ( "failed to rewrite "
                                                ++ hostsPath
                                                ++ ": exit code "
                                                ++ show code
                                                ++ suffixFromTexts stdoutText stderrText
                                            )

isDeletePendingAwsResource :: KeyMap.KeyMap Value -> Bool
isDeletePendingAwsResource resourceObject =
    case (KeyMap.lookup (Key.fromString "delete") resourceObject, KeyMap.lookup (Key.fromString "type") resourceObject) of
        (Just (Bool True), Just (String resourceType)) ->
            resourceType == "pulumi:providers:aws" || "aws:" `Text.isPrefixOf` resourceType
        _ -> False

splitComment :: String -> (String, String)
splitComment rawLine =
    case break (== '#') rawLine of
        (body, []) -> (body, "")
        (body, _ : comment) -> (body, comment)

renderHostsText :: [String] -> Bool -> String
renderHostsText updatedLines hadTrailingNewline =
    case updatedLines of
        [] -> if hadTrailingNewline then "\n" else ""
        _ ->
            let rendered = unlines updatedLines
             in if hadTrailingNewline then rendered else trimTrailingNewlines rendered

endsWithNewline :: String -> Bool
endsWithNewline rawText = not (null rawText) && last rawText == '\n'

trimSpaces :: String -> String
trimSpaces = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

trimTrailingNewlines :: String -> String
trimTrailingNewlines = reverse . dropWhile (== '\n') . reverse

toLowerAscii :: Char -> Char
toLowerAscii = toLower

suffixFromTexts :: String -> String -> String
suffixFromTexts stdoutText stderrText =
    case filter (/= "") [trimTrailingNewlines stderrText, trimTrailingNewlines stdoutText] of
        [] -> ""
        rendered -> ": " ++ intercalate " | " rendered
