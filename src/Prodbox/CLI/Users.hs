{-# LANGUAGE OverloadedStrings #-}

-- | Dispatcher for the `prodbox users {invite,list,revoke}` operator surface.
module Prodbox.CLI.Users
  ( runUsersCommand
  )
where

import Data.Text qualified as Text
import Prodbox.CLI.Command
  ( PlanOptions
  , UsersCommand (..)
  , UsersListStatus (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Error (fatalError)
import Prodbox.Settings (ValidatedSettings, validateAndLoadSettings)
import Prodbox.UsersAdmin
  ( UserSummary (..)
  , UserVerificationStatus (..)
  , inviteUser
  , listUsers
  , revokeUser
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

runUsersCommand :: FilePath -> UsersCommand -> IO ExitCode
runUsersCommand repoRoot command =
  case command of
    UsersInvite email maybeRole planOptions ->
      withSettings repoRoot $ \settings ->
        runPlanWithOptions
          planOptions
          (buildPlan id (renderUsersPlan ("invite " ++ email)))
          (\_ -> runInvite repoRoot settings email maybeRole)
    UsersList status ->
      withSettings repoRoot (\settings -> runList repoRoot settings status)
    UsersRevoke ident hardDelete planOptions ->
      withSettings repoRoot $ \settings ->
        runPlanWithOptions
          planOptions
          (buildPlan id (renderUsersPlan ("revoke " ++ ident)))
          (\_ -> runRevoke repoRoot settings ident hardDelete)

withSettings :: FilePath -> (ValidatedSettings -> IO ExitCode) -> IO ExitCode
withSettings repoRoot action = do
  result <- validateAndLoadSettings repoRoot
  case result of
    Left err -> failWith err
    Right settings -> action settings

runInvite :: FilePath -> ValidatedSettings -> String -> Maybe String -> IO ExitCode
runInvite repoRoot settings email maybeRole = do
  outcome <- inviteUser repoRoot settings email maybeRole
  case outcome of
    Left err -> failWith err
    Right summary -> do
      writeOutput (renderInviteReport summary maybeRole)
      pure ExitSuccess

runList :: FilePath -> ValidatedSettings -> UsersListStatus -> IO ExitCode
runList repoRoot settings status = do
  outcome <- listUsers repoRoot settings status
  case outcome of
    Left err -> failWith err
    Right summaries -> do
      writeOutput (renderListReport status summaries)
      pure ExitSuccess

runRevoke :: FilePath -> ValidatedSettings -> String -> Bool -> IO ExitCode
runRevoke repoRoot settings ident hardDelete = do
  outcome <- revokeUser repoRoot settings ident hardDelete
  case outcome of
    Left err -> failWith err
    Right () -> do
      writeOutputLine
        ("USER_REVOKED=" ++ ident ++ if hardDelete then " (deleted)" else " (disabled)")
      pure ExitSuccess

renderUsersPlan :: String -> String
renderUsersPlan action =
  unlines
    [ "USERS_PLAN"
    , "ACTION=" ++ action
    ]

renderInviteReport :: UserSummary -> Maybe String -> String
renderInviteReport summary maybeRole =
  unlines
    [ "USER_ID=" ++ Text.unpack (userSummaryId summary)
    , "USERNAME=" ++ Text.unpack (userSummaryUsername summary)
    , "EMAIL=" ++ Text.unpack (userSummaryEmail summary)
    , "EMAIL_VERIFIED=false"
    , "REQUIRED_ACTIONS=VERIFY_EMAIL"
    , "INVITE_ROLE=" ++ maybe "" id maybeRole
    ]

renderListReport :: UsersListStatus -> [UserSummary] -> String
renderListReport status summaries =
  unlines
    ( ("USERS_LIST_FILTER=" ++ renderStatus status)
        : ("USERS_COUNT=" ++ show (length summaries))
        : concatMap renderRow summaries
    )
 where
  renderRow summary =
    [ "USER_ID=" ++ Text.unpack (userSummaryId summary)
    , "EMAIL=" ++ Text.unpack (userSummaryEmail summary)
    , "EMAIL_VERIFIED=" ++ case userSummaryVerification summary of
        UserVerified -> "true"
        UserUnverified -> "false"
    , "LAST_LOGIN=" ++ maybe "" Text.unpack (userSummaryLastLogin summary)
    ]
  renderStatus UsersAll = "all"
  renderStatus UsersVerified = "verified"
  renderStatus UsersUnverified = "unverified"

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

_planOptionsPlaceholder :: PlanOptions -> PlanOptions
_planOptionsPlaceholder = id
