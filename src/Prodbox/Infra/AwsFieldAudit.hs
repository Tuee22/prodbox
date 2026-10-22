{-# LANGUAGE OverloadedStrings #-}

-- | The host side of the provider-enumerated audit: ask the Provider, through
-- the Lifecycle Authority, to take an inventory of one stack's declared field,
-- and say what it found.
--
-- The audit is the instrument that makes a completion claim about AWS and not
-- about bookkeeping. The destroy verbs bracket their work with one so that the
-- field they report at the end is compared with the field they found at the
-- start, and a destroy that leaves residue, or that could not take its closing
-- inventory, exits non-zero. The create verbs report the field and gate nothing:
-- after a create the field legitimately holds the new stack.
--
-- Raw identifiers are printed here, to standard output, and kept nowhere else.
module Prodbox.Infra.AwsFieldAudit
  ( FieldAudit (..)
  , FieldSink (..)
  , takeFieldAudit
  , renderFieldAuditReport
  , withFieldDiff
  , withFieldDiffVia
  , printFieldAfterCreate
  , runAwsFieldAudit
  , worstAuditExit
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthentication
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchAuthenticatedProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding (..), decodeAwsAuditEvidence)
import Prodbox.Lifecycle.AwsAuditField (auditReadOnlyScript)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveAwsAudit)
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderAuditControl
  , mkProviderAuditTarget
  , mkProviderStackRef
  )
import Prodbox.Settings
  ( ValidatedCoordinates (..)
  , ValidatedSettings (..)
  , validateAndLoadSettings
  )
import Prodbox.Settings.Coordinate (awsRegionText, s3BucketNameText)
import System.Exit (ExitCode (..))

-- | One inventory, with the account and region the Provider says it audited.
data FieldAudit = FieldAudit
  { fieldAuditStack :: !AuditStack
  , fieldAuditBinding :: !AuditBinding
  , fieldAuditObservation :: !AuditObservation
  }

-- | Take one stack's inventory through an authenticated Authority session.
takeFieldAudit
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> AuditStack
  -> IO (Either Text FieldAudit)
takeFieldAudit authentication repoRoot stack = do
  intent <- auditIntent repoRoot stack
  case intent of
    Left detail -> pure (Left detail)
    Right request -> do
      dispatched <-
        dispatchAuthenticatedProviderIntentFresh
          authentication
          ("operator-aws-audit-" <> auditStackLabel stack)
          request
      pure $ case dispatched of
        Left err -> Left (Text.pack (renderProviderCallerError err))
        Right evidence ->
          (\(binding, observation) -> FieldAudit stack binding observation)
            <$> decodeAwsAuditEvidence stack evidence

-- | The request an audit of the stack makes: the stack, a configuration the
-- audit does not read (a loopback operator CIDR, as the adoption lane's
-- observations carry), and the state bucket as the positive control.
auditIntent :: FilePath -> AuditStack -> IO (Either Text ProviderIntent)
auditIntent repoRoot stack = do
  settings <- validateAndLoadSettings repoRoot
  pure $ do
    loaded <- either (Left . Text.pack) Right settings
    bucket <- stateBucket loaded
    stackRef <- first' (mkProviderStackRef (auditStackLabel stack))
    target <- first' (mkProviderAuditTarget stackRef Nothing)
    config <- stackConfig stack
    control <- first' (mkProviderAuditControl bucket (stateBucketRegion loaded))
    Right (ObserveAwsAudit target config control)
 where
  first' = either (Left . Text.pack . show) Right

-- | The audit's positive control: the retained state bucket the repository
-- authors.
stateBucket :: ValidatedSettings -> Either Text Text
stateBucket settings =
  maybe
    (Left "pulumi_state_backend.bucket_name is not authored, so the audit has no positive control")
    (Right . s3BucketNameText)
    (coordinatePulumiBackendBucket (validatedCoordinates settings))

-- | The region the retained state bucket lives in, when the repository authors
-- one. The tagging catalog answers per region, so the control is looked for
-- where the bucket is, which need not be where the session is.
stateBucketRegion :: ValidatedSettings -> Maybe Text
stateBucketRegion settings =
  awsRegionText <$> coordinatePulumiBackendRegion (validatedCoordinates settings)

stackConfig :: AuditStack -> Either Text ProviderStackConfig
stackConfig stack = case stack of
  AuditAwsEks -> either (Left . Text.pack . show) Right (mkAwsEksProviderStackConfig "127.0.0.1/32")
  AuditAwsTest -> either (Left . Text.pack . show) Right (mkAwsTestProviderStackConfig "127.0.0.1/32")
  AuditAwsEksSubzone -> Left "the per-run subzone is audited by its hosted-zone id, which only the stack records"

-- | The operator's report for one inventory: the account and region it covers,
-- then the verdict, the counts, the rows and the control.
renderFieldAuditReport :: FieldAudit -> [Text]
renderFieldAuditReport audit =
  [ "AWS_FIELD "
      <> auditStackLabel (fieldAuditStack audit)
      <> " account="
      <> auditBindingAccount (fieldAuditBinding audit)
      <> " region="
      <> auditBindingRegion (fieldAuditBinding audit)
  ]
    <> renderAuditReport observation (auditVerdict observation)
 where
  observation = fieldAuditObservation audit

-- | Where a report goes: standard output for the inventory and the diff, the
-- diagnostic stream for what could not be taken.
data FieldSink = FieldSink
  { fieldSinkOutput :: Text -> IO ()
  , fieldSinkDiagnostic :: Text -> IO ()
  }

terminalSink :: FieldSink
terminalSink =
  FieldSink
    { fieldSinkOutput = writeOutputLine . Text.unpack
    , fieldSinkDiagnostic = writeDiagnosticLine . Text.unpack
    }

-- | Run an action and bracket it with the field's inventories.
withFieldDiff
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> AuditStack
  -> IO ExitCode
  -> IO ExitCode
withFieldDiff authentication repoRoot stack =
  withFieldDiffVia terminalSink stack (takeFieldAudit authentication repoRoot stack)

-- | The bracket over the inventory it is given.
--
-- The baseline is narration: failing to take one never stops the action,
-- because the action is the destroy and the destroy is the point. The closing
-- inventory decides the exit status. A closing inventory that cannot be taken
-- is unobservable, which is a non-zero exit, because completion is a claim the
-- command may only make from an inventory.
withFieldDiffVia
  :: FieldSink
  -> AuditStack
  -> IO (Either Text FieldAudit)
  -> IO ExitCode
  -> IO ExitCode
withFieldDiffVia sink stack takeInventory action = do
  baseline <- takeInventory
  case baseline of
    Left detail ->
      fieldSinkDiagnostic
        sink
        ("AWS_FIELD " <> auditStackLabel stack <> " baseline unavailable: " <> detail)
    Right audit -> mapM_ (fieldSinkOutput sink) (take 1 (renderFieldAuditReport audit))
  actionExit <- action
  final <- takeInventory
  case final of
    Left detail -> do
      fieldSinkDiagnostic
        sink
        ( "AWS_FIELD "
            <> auditStackLabel stack
            <> " verdict=Unobservable (the closing inventory could not be taken: "
            <> detail
            <> ")"
        )
      pure (firstFailure actionExit (ExitFailure 5))
    Right audit -> do
      let observation = fieldAuditObservation audit
          verdict = auditVerdict observation
          comparison = case baseline of
            Right before ->
              renderAuditDiff
                observation
                verdict
                (diffAuditObservations (fieldAuditObservation before) observation)
            -- With no baseline there is nothing to say left, remained or
            -- appeared; the closing inventory stands on its own.
            Left _ ->
              [ "AWS_FIELD_DIFF "
                  <> auditStackLabel stack
                  <> " verdict="
                  <> auditVerdictLabel verdict
                  <> " (no baseline was taken, so nothing is compared)"
              ]
      mapM_ (fieldSinkOutput sink) (comparison <> renderFieldAuditReport audit)
      pure (firstFailure actionExit (auditExitCode verdict))

-- | After a create the field legitimately holds the new stack, so the
-- inventory is reported and gates nothing: an inventory that cannot be taken is
-- a diagnostic and not a failed create.
printFieldAfterCreate
  :: LifecycleAuthorityAuthentication -> FilePath -> AuditStack -> IO ()
printFieldAfterCreate authentication repoRoot stack = do
  taken <- takeFieldAudit authentication repoRoot stack
  case taken of
    Left detail ->
      fieldSinkDiagnostic
        terminalSink
        ("AWS_FIELD " <> auditStackLabel stack <> " inventory unavailable: " <> detail)
    Right audit -> mapM_ (fieldSinkOutput terminalSink) (renderFieldAuditReport audit)

-- | The status several inventories earn together. A row is a refutation and
-- stands whatever else went unanswered, so residue (4) outranks an inventory
-- that could not be taken (5); either outranks success.
worstAuditExit :: [ExitCode] -> ExitCode
worstAuditExit exits
  | ExitFailure 4 `elem` exits = ExitFailure 4
  | otherwise = case [code | ExitFailure code <- exits] of
      [] -> ExitSuccess
      codes -> ExitFailure (maximum codes)

-- | @prodbox aws audit@: the inventory of each selected stack, or the reads as
-- a read-only script.
runAwsFieldAudit :: FilePath -> [AuditStack] -> Bool -> IO ExitCode
runAwsFieldAudit repoRoot stacks emitScript
  | emitScript = do
      -- The configuration is read through the Authority, which is the thing that
      -- may be down: the script then asks for the bucket instead of guessing it.
      settings <- validateAndLoadSettings repoRoot
      let loaded = either (const Nothing) Just settings
          bucket = loaded >>= either (const Nothing) Just . stateBucket
          region = loaded >>= stateBucketRegion
      mapM_
        (mapM_ (writeOutputLine . Text.unpack) . (\stack -> auditReadOnlyScript stack bucket region))
        stacks
      pure ExitSuccess
  | otherwise = do
      authenticated <-
        withHostLifecycleAuthorityAuthentication LifecycleAuthorityOperator repoRoot $
          \authentication -> mapM (inventory authentication) stacks
      case authenticated of
        Left err -> do
          writeDiagnosticLine (renderLifecycleAuthorityAuthenticationError err)
          pure (ExitFailure 5)
        Right exits -> pure (worstAuditExit exits)
 where
  inventory authentication stack = do
    taken <- takeFieldAudit authentication repoRoot stack
    case taken of
      Left detail -> do
        writeDiagnosticLine
          ( "AWS_FIELD "
              <> Text.unpack (auditStackLabel stack)
              <> " verdict=Unobservable (the inventory could not be taken: "
              <> Text.unpack detail
              <> ")"
          )
        pure (ExitFailure 5)
      Right audit -> do
        mapM_ (writeOutputLine . Text.unpack) (renderFieldAuditReport audit)
        pure (auditExitCode (auditVerdict (fieldAuditObservation audit)))

-- | The first failure of two statuses.
firstFailure :: ExitCode -> ExitCode -> ExitCode
firstFailure first second = case first of
  ExitSuccess -> second
  _ -> first
