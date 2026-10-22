{-# LANGUAGE OverloadedStrings #-}

-- | Linux process observations for one child started in a fresh POSIX session.
-- Session membership survives a parent's exit and a child's process-group
-- change. Recorded start times prevent a reused PID from acquiring authority.
module Prodbox.Subprocess.OwnedProcessTree
  ( OwnedProcessRoot
  , OwnedProcessIdentity
  , ProcessStat (..)
  , parseProcessStat
  , recordOwnedProcessRoot
  , snapshotOwnedProcessTree
  , stopOwnedProcessDescendants
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.List (nub)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (listDirectory)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Posix.Types (ProcessID)
import Text.Read (readMaybe)

data ProcessStat = ProcessStat
  { statPid :: !ProcessID
  , statParent :: !ProcessID
  , statSession :: !ProcessID
  , statStart :: !Integer
  , statState :: !Text
  }
  deriving (Eq, Show)

data OwnedProcessRoot = OwnedProcessRoot !ProcessID !Integer

data OwnedProcessIdentity = OwnedProcessIdentity !ProcessID !Integer
  deriving (Eq)

-- | A command name may contain spaces and parentheses. Only the closing
-- parenthesis before the numeric fields determines their positions.
parseProcessStat :: Text -> Maybe ProcessStat
parseProcessStat input = do
  pid <- readText (fst (Text.breakOn " (" input))
  let fields = Text.words (snd (Text.breakOnEnd ") " input))
  case fields of
    state : parent : _group : session : _ -> do
      parentPid <- readText parent
      sessionPid <- readText session
      start <- readText =<< listToMaybe (drop 19 fields)
      if pid > 0 && start >= 0 && Text.length state == 1
        then Just (ProcessStat pid parentPid sessionPid start state)
        else Nothing
    _ -> Nothing
 where
  readText :: (Read a) => Text -> Maybe a
  readText = readMaybe . Text.unpack

recordOwnedProcessRoot :: ProcessID -> IO (Maybe OwnedProcessRoot)
recordOwnedProcessRoot pid = do
  observed <- readStat pid
  pure $ case observed of
    Right (Just row) | statSession row == pid -> Just (OwnedProcessRoot pid (statStart row))
    _ -> Nothing

snapshotOwnedProcessTree :: OwnedProcessRoot -> IO (Either Text [OwnedProcessIdentity])
snapshotOwnedProcessTree (OwnedProcessRoot root started) = do
  leader <- readStat root
  case leader of
    Left detail -> pure (Left detail)
    Right (Just row) | statStart row /= started -> pure (Right [])
    _ -> do
      listed <- try (listDirectory "/proc") :: IO (Either IOException [FilePath])
      case listed of
        Left _ -> pure (Left "cannot enumerate the owned subprocess session")
        Right names -> do
          rows <- forM (mapMaybe readMaybe names) readStat
          let observed = [row | Right (Just row) <- rows]
              descendants = closeDescendants [root] observed
          pure
            ( Right
                [ OwnedProcessIdentity (statPid row) (statStart row)
                | row <- observed
                , statPid row /= root
                , statSession row == root || statPid row `elem` descendants
                ]
            )
 where
  closeDescendants known rows =
    let next = nub (known ++ [statPid row | row <- rows, statParent row `elem` known])
     in if next == known then known else closeDescendants next rows

-- | Recheck every PID before signalling it. Refresh the session after the
-- leader exits so separately grouped plugins and late children remain owned.
-- A bounded failure is returned rather than claiming every child stopped.
stopOwnedProcessDescendants
  :: Int -> OwnedProcessRoot -> [OwnedProcessIdentity] -> IO (Either Text ())
stopOwnedProcessDescendants budget root recorded = do
  now <- getMonotonicTimeNSec
  loop (now + fromIntegral (max 0 budget) * 1000) recorded
 where
  loop deadline known = do
    fresh <- snapshotOwnedProcessTree root
    case fresh of
      Left detail -> pure (Left detail)
      Right current -> do
        let identities = nub (known ++ current)
        outcomes <- traverse stopOne identities
        case [detail | Left detail <- outcomes] of
          detail : _ -> pure (Left detail)
          [] -> do
            living <- traverse stillRunning identities
            case sequence living of
              Left detail -> pure (Left detail)
              Right statuses
                | not (or statuses) -> pure (Right ())
                | otherwise -> do
                    now <- getMonotonicTimeNSec
                    if now >= deadline
                      then pure (Left "owned subprocess descendants did not stop within the kill-confirmation bound")
                      else threadDelay 50000 >> loop deadline identities
  stopOne identity@(OwnedProcessIdentity pid _) = do
    running <- stillRunning identity
    case running of
      Left detail -> pure (Left detail)
      Right False -> pure (Right ())
      Right True -> do
        signalled <- try (signalProcess sigKILL pid) :: IO (Either IOException ())
        pure $ case signalled of
          Right () -> Right ()
          Left err | isDoesNotExistError err -> Right ()
          Left _ -> Left "cannot stop an owned subprocess descendant"

stillRunning :: OwnedProcessIdentity -> IO (Either Text Bool)
stillRunning (OwnedProcessIdentity pid started) = do
  observed <- readStat pid
  pure $
    fmap (maybe False (\row -> statStart row == started && statState row `notElem` ["Z", "X"])) observed

readStat :: ProcessID -> IO (Either Text (Maybe ProcessStat))
readStat pid = do
  contents <- try (TextIO.readFile ("/proc/" ++ show pid ++ "/stat")) :: IO (Either IOException Text)
  pure $ case contents of
    Left err | isDoesNotExistError err -> Right Nothing
    Left _ -> Left "cannot observe an owned subprocess identity"
    Right value -> case parseProcessStat value of
      Just row | statPid row == pid -> Right (Just row)
      _ -> Left "owned subprocess identity has an unreadable proc stat"
