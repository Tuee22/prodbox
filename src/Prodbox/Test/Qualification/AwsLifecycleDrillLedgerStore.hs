{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The AWS lifecycle drill ledger's one file, and the only code that writes it.
--
-- The file lives under @.test-data/@, which git ignores, so appending a record
-- never changes the scoped source identity it records. A read verifies the whole
-- chain and refuses a broken file; nothing repairs a ledger in place. Deleting
-- the file abandons the count and restarts it at zero. An append names the tip
-- it expects, so two writers cannot both extend one history.
module Prodbox.Test.Qualification.AwsLifecycleDrillLedgerStore
  ( DrillStoreError (..)
  , renderDrillStoreError
  , drillLedgerPath
  , readDrillLedger
  , appendDrillRecordAtTip
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Test.Qualification.AwsLifecycleDrillLedger
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (AppendMode), hFlush, withBinaryFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFileMode)

data DrillStoreError
  = DrillStoreUnreadable !FilePath !String
  | DrillStoreRefused !Text
  | DrillStoreMalformedRecord
  | DrillStoreTipChanged
  | DrillStoreWriteFailed !FilePath !String
  deriving (Eq, Show)

renderDrillStoreError :: DrillStoreError -> String
renderDrillStoreError err = case err of
  DrillStoreUnreadable path detail -> "could not read the drill ledger " ++ path ++ ": " ++ detail
  DrillStoreRefused detail ->
    "the drill ledger is refused: "
      ++ Text.unpack detail
      ++ ". It is never repaired in place; delete the file only to abandon the count."
  DrillStoreMalformedRecord -> "the drill record cannot be carried by the ledger format"
  DrillStoreTipChanged -> "the drill ledger changed since it was read; read it again"
  DrillStoreWriteFailed path detail -> "could not append to the drill ledger " ++ path ++ ": " ++ detail

drillLedgerPath :: FilePath -> FilePath
drillLedgerPath repoRoot =
  repoRoot </> ".test-data" </> "qualification" </> "aws-lifecycle-drills.ledger"

-- | The verified ledger, or the empty one when the file does not exist. An
-- unreadable file is an error and never an empty ledger.
readDrillLedger :: FilePath -> IO (Either DrillStoreError DrillLedger)
readDrillLedger path = do
  bytes <- try (ByteString.readFile path)
  pure $ case bytes of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right emptyDrillLedger
      | otherwise -> Left (DrillStoreUnreadable path (show err))
    Right content -> case TextEncoding.decodeUtf8' content of
      Left err -> Left (DrillStoreRefused (Text.pack (show err)))
      Right text -> either (Left . DrillStoreRefused) Right (parseDrillLedger text)

-- | Append one record if the file's tip is still the one the caller read, then
-- read it back and require the new tip to be the one computed.
appendDrillRecordAtTip
  :: FilePath -> Text -> DrillRecord -> IO (Either DrillStoreError DrillLedger)
appendDrillRecordAtTip path expectedTip record
  | not (drillRecordWellFormed record) = pure (Left DrillStoreMalformedRecord)
  | otherwise = do
      current <- readDrillLedger path
      case current of
        Left err -> pure (Left err)
        Right ledger
          | drillLedgerTip ledger /= expectedTip -> pure (Left DrillStoreTipChanged)
          | otherwise -> do
              let next = appendDrillRecord record ledger
                  newest = Text.lines (renderDrillLedger next)
              written <- try $ do
                createDirectoryIfMissing True (takeDirectory path)
                withBinaryFile path AppendMode $ \handle -> do
                  ByteString.hPut
                    handle
                    ( TextEncoding.encodeUtf8
                        (Text.unlines (drop (length (Text.lines (renderDrillLedger ledger))) newest))
                    )
                  hFlush handle
                setFileMode path 0o600
              case written of
                Left (err :: IOException) -> pure (Left (DrillStoreWriteFailed path (show err)))
                Right () -> do
                  readBack <- readDrillLedger path
                  pure $ case readBack of
                    Right confirmed
                      | drillLedgerTip confirmed == drillLedgerTip next -> Right confirmed
                    Right _ -> Left (DrillStoreWriteFailed path "read-back disagrees with the appended entry")
                    Left err -> Left err
