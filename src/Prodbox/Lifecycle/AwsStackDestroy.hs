{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The destroy of one registered stack that has a VPC, as a converging loop over
-- the Pulumi and AWS runners it is given.
--
-- "Prodbox.Lifecycle.AwsDestroyConverge" is the order of the steps and
-- "Prodbox.Lifecycle.AwsNetworkDependents" is the rule for what may be cleared.
-- This module is the composition: it reads what the stack recorded before
-- anything is destroyed, decides which VPC a repair may act in and whether the
-- repair has anything to do yet, runs the two passes with the bounds it is
-- handed, and reads the field with the audit's own enumeration, so the loop and
-- the operator's @aws audit@ read one thing.
--
-- The runners are arguments. The Provider supplies the real children; a test
-- supplies a scripted account whose subnets refuse to delete while an interface
-- uses them.
module Prodbox.Lifecycle.AwsStackDestroy
  ( PulumiRun
  , pulumiDestroyPass
  , pulumiRemoveStack
  , pulumiCancelStack
  , StackDestroyWorld (..)
  , stackDestroy
  , stackDestroyEffects
  , RecordedVpc (..)
  , VpcChoice (..)
  , chooseVpc
  , recordedVpcOf
  , fieldStateOf
  , loopOwnsClass
  , withinSession
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.OperationBudget (readTailMicros, sessionWindowMicros)
import Prodbox.ControlPlane.ProviderFailureSummary
  ( renderCommandFailure
  , transcriptReportsMissingStack
  )
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditField (auditStackField, locateTaggedVpcs, probeStackOwners)
import Prodbox.Lifecycle.AwsDestroyConverge
import Prodbox.Lifecycle.AwsNativeStackFamily (AwsNativeStackFamilyRunner (..))
import Prodbox.Lifecycle.AwsNetworkDependents
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment (..), reserveWaitWindow)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderNativeStackFamilyRef
  , ProviderStackConfig
  , providerNativeStackFamilyStackRef
  , providerStackRefText
  )
import Prodbox.Lifecycle.Teardown.Registry (awsNetworkFamiliesForStack)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

-- | One Pulumi child as the loop sees it: the arguments in, the transcript out.
-- The runner is also what bounds a child; the loop holds no clock of its own.
type PulumiRun m = [String] -> m ProcessOutput

-- | One destroy pass after the backend login: a stack that is not there has
-- nothing to destroy; otherwise destroy it, refreshing first and continuing past
-- a resource error so one stuck resource does not hide what else is left.
pulumiDestroyPass :: (Monad m) => PulumiRun m -> String -> m PassResult
pulumiDestroyPass run stack = do
  selected <- run ["stack", "select", "--stack", stack, "--non-interactive"]
  if missingStack selected
    then pure PassStackAbsent
    else case processExitCode selected of
      ExitFailure _ -> pure (PassFailed (failureDetail selected))
      ExitSuccess -> do
        destroyed <-
          run
            [ "destroy"
            , "--stack"
            , stack
            , "--yes"
            , "--skip-preview"
            , "--non-interactive"
            , "--refresh"
            , "--continue-on-error"
            ]
        pure $ case processExitCode destroyed of
          ExitSuccess -> PassSucceeded
          ExitFailure _ -> PassFailed (failureDetail destroyed)

-- | Remove the stack record. It follows only a destroy that emptied the field,
-- so a stack that still holds resources keeps its record.
pulumiRemoveStack :: (Monad m) => PulumiRun m -> String -> m (Either Text ())
pulumiRemoveStack run stack = do
  removed <- run ["stack", "rm", "--stack", stack, "--yes", "--non-interactive"]
  pure $ case processExitCode removed of
    ExitSuccess -> Right ()
    ExitFailure _ -> Left (failureDetail removed)

-- | Clear what a stopped update left in the scratch backend. A Pulumi that is
-- stopped by SIGKILL never releases the lock its update held, and the next
-- operation on the backend stops on it in half a second; @pulumi cancel@ removes
-- the lock, and with nothing to cancel it still exits zero (both measured on
-- Pulumi 3.228.0). Best effort: what it says is narrated, and whether the final
-- pass can start is the final pass's to find out.
pulumiCancelStack :: (Monad m) => PulumiRun m -> String -> m [Text]
pulumiCancelStack run stack = do
  cancelled <- run ["cancel", "--stack", stack, "--yes", "--non-interactive"]
  pure $ case processExitCode cancelled of
    ExitSuccess -> ["pulumi cancel cleared any lock the stopped pass held"]
    ExitFailure _ -> ["pulumi cancel did not complete: " <> Text.take 300 (failureDetail cancelled)]

failureDetail :: ProcessOutput -> Text
failureDetail output =
  renderCommandFailure (Text.pack (processStderr output)) (Text.pack (processStdout output))

missingStack :: ProcessOutput -> Bool
missingStack output =
  transcriptReportsMissingStack
    (Text.pack (processStderr output) <> " " <> Text.pack (processStdout output))

-- | Everything the loop needs from the world outside it.
data StackDestroyWorld m = StackDestroyWorld
  { worldStackName :: !String
  , worldPulumi :: DestroyPass -> PulumiRun m
  -- ^ The runner for a pass: the first is bounded to its share, the final to the
  -- window the session has left less what the reading after it needs.
  , worldPulumiShort :: PulumiRun m
  -- ^ The runner for the short commands around the passes (reading the outputs,
  -- cancelling, removing the record). They are bounded by the session and by
  -- nothing reserved after them, so a destroy that finishes late can still have
  -- its record removed.
  , worldAws :: AwsNativeStackFamilyRunner m
  , worldWaits :: AwsWaitEnvironment m
  , worldFinalPassReserveMicros :: !Natural
  -- ^ What the repair's waits leave the final pass and the reading after it.
  , worldRef :: !ProviderNativeStackFamilyRef
  , worldConfig :: !ProviderStackConfig
  , worldCluster :: !(Maybe Text)
  -- ^ The EKS cluster the stack owns, if it owns one.
  , worldLoadBalancers :: !(Maybe (AwsWaitEnvironment m -> m (Either Text ())))
  -- ^ The registered load balancer family's reaper, for a stack that has one. It
  -- waits, so it is handed the wait environment the repair keeps the final pass's
  -- reserve out of.
  }

-- | Destroy the stack, converging or naming what stopped it.
stackDestroy :: (Monad m) => StackDestroyWorld m -> m ConvergeOutcome
stackDestroy world = stackDestroyEffects world >>= convergeDestroy

-- | Read what the stack recorded, and build the steps the loop runs. The VPC the
-- stack recorded is read before any pass: the first pass can remove it.
stackDestroyEffects :: (Monad m) => StackDestroyWorld m -> m (ConvergeEffects m)
stackDestroyEffects world = do
  firstRead <- readRecordedVpc (worldPulumiShort world) (worldStackName world)
  -- One failed read of the outputs would otherwise refuse the repair for the
  -- whole run, and a rerun costs the first pass again.
  recorded <- case firstRead of
    RecordedVpcUnreadable _ -> readRecordedVpc (worldPulumiShort world) (worldStackName world)
    _ -> pure firstRead
  pure
    ConvergeEffects
      { convergePass = \pass -> pulumiDestroyPass (worldPulumi world pass) (worldStackName world)
      , convergeRecover = pulumiCancelStack (worldPulumiShort world) (worldStackName world)
      , convergeRepair = repair world recorded
      , convergeField = readField world
      , convergeRemoveStack = pulumiRemoveStack (worldPulumiShort world) (worldStackName world)
      }

-- | What the stack's outputs say about its VPC.
data RecordedVpc
  = RecordedVpc !Text
  | -- | The outputs hold none: the stack is not there, or was never created far
    -- enough to have one.
    NoRecordedVpc
  | -- | The outputs could not be read, which is not the same as holding none.
    RecordedVpcUnreadable !Text
  deriving stock (Eq, Show)

readRecordedVpc :: (Monad m) => PulumiRun m -> String -> m RecordedVpc
readRecordedVpc run stack = do
  selected <- run ["stack", "select", "--stack", stack, "--non-interactive"]
  if missingStack selected
    then pure NoRecordedVpc
    else case processExitCode selected of
      ExitFailure _ -> pure (RecordedVpcUnreadable (Text.take 300 (failureDetail selected)))
      ExitSuccess -> do
        output <- run ["stack", "output", "--stack", stack, "--json"]
        pure $ case processExitCode output of
          ExitFailure _ -> RecordedVpcUnreadable (Text.take 300 (failureDetail output))
          ExitSuccess -> recordedVpcOf (processStdout output)

-- | The VPC a stack's outputs record, if they record one.
recordedVpcOf :: String -> RecordedVpc
recordedVpcOf payload =
  case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack payload)) of
    Right (Object outputs) -> case KeyMap.lookup (Key.fromText "vpc_id") outputs of
      Just (String vpc) -> RecordedVpc vpc
      _ -> NoRecordedVpc
    Right _ -> RecordedVpcUnreadable "the stack outputs were not a JSON object"
    Left _ -> RecordedVpcUnreadable "the stack outputs were not JSON"

-- | Which VPC a repair may act in. The VPC the stack recorded must be one that
-- carries the stack's exact name and managed-by tags: either alone is a guess
-- about a shared account, and a repair that acts on a guess is the
-- over-deletion this is built to refuse. Other VPCs may carry the same tags (a
-- leftover of an earlier run); the recorded one is the stack's own. A stack that
-- recorded none (an interrupted create) falls back to the one VPC its tags name,
-- and a recorded value that could not be read does not: it is refused.
data VpcChoice
  = UseVpc !Text
  | -- | No VPC exists, so there is nothing to clear.
    NoVpc
  | RefuseVpc !Text
  deriving stock (Eq, Show)

chooseVpc :: RecordedVpc -> Either Text [Text] -> VpcChoice
chooseVpc recorded located = case recorded of
  RecordedVpcUnreadable detail ->
    RefuseVpc ("the stack's recorded VPC could not be read: " <> detail)
  _ -> case located of
    Left detail -> RefuseVpc ("the VPC could not be located: " <> detail)
    Right [] -> case recorded of
      RecordedVpc own ->
        RefuseVpc
          ( "the stack records "
              <> own
              <> " but no VPC carries the stack's name and managed-by tags (it may already be gone)"
          )
      _ -> NoVpc
    -- A VPC the stack recorded and its tags name is the stack's, whatever else
    -- carries the same tags (a leftover of an earlier run of the same stack): the
    -- repair acts there and nowhere else. Without a record, only one tagged VPC
    -- is a VPC to act in.
    Right tagged -> case recorded of
      RecordedVpc own
        | own `elem` tagged -> UseVpc own
        | otherwise ->
            RefuseVpc
              ( "the stack records "
                  <> own
                  <> " but the VPCs carrying its tags are "
                  <> Text.intercalate ", " tagged
              )
      _ -> case tagged of
        [only] -> UseVpc only
        several ->
          RefuseVpc
            ( "more than one VPC carries the stack's name and managed-by tags, and the stack records none: "
                <> Text.intercalate ", " several
            )

-- | The classes the destroy is answerable for. A leaked per-run volume is the
-- volume reaper's to clear, in a step of its own that follows the destroy, so a
-- destroy that waited on it would hold the stack record in front of the step
-- that clears it; the closing inventory of the destroy verb still reports it.
loopOwnsClass :: AuditClass -> Bool
loopOwnsClass class' = class' /= AuditEbsVolume

-- | The AWS runner, refusing to start a read the session has no time to finish.
-- Every read the destroy makes outside a mutation goes through it, so that when
-- the window is nearly gone the reads stop and the classes not yet read are
-- gaps, and the report that says so is returned inside the intent: past the
-- intent's hard stop the operation ends in a timeout in its place. Each read is
-- bounded on its own and the Provider runs them one at a time under a small CPU
-- envelope, so how many fit in what is left is not something to assume.
withinSession
  :: (Monad m)
  => AwsWaitEnvironment m
  -> Natural
  -> AwsNativeStackFamilyRunner m
  -> AwsNativeStackFamilyRunner m
withinSession environment tailMicros runner =
  AwsNativeStackFamilyRunner $ \arguments -> do
    clock <- awsWaitNowMicros environment
    case clock of
      Left detail -> pure (refused ("the clock could not be read: " <> detail))
      Right now -> case sessionWindowMicros (awsWaitSessionExpiresAtMicros environment) now of
        Right window
          | window > tailMicros -> runAwsNativeStackFamilyCommand runner arguments
        _ -> pure (refused "the session has no time left for another read")
 where
  refused detail = ProcessOutput (ExitFailure 124) "" (Text.unpack detail)

-- | The reads the destroy makes outside a mutation.
guardedAws :: (Monad m) => StackDestroyWorld m -> AwsNativeStackFamilyRunner m
guardedAws world = withinSession (worldWaits world) readTailMicros (worldAws world)

repair :: (Monad m) => StackDestroyWorld m -> RecordedVpc -> m [Text]
repair world recorded =
  case auditStackOfRef (providerStackRefText (providerNativeStackFamilyStackRef (worldRef world))) of
    Nothing -> pure ["nothing was cleared: the audit does not know this stack"]
    Just stack -> do
      -- Where to act is decided by the stack's own tags and its recorded output,
      -- apart from every other source.
      located <- locateTaggedVpcs (guardedAws world) stack
      owners <- ownersTwice stack (either (const []) id located)
      case owners of
        Left detail ->
          pure
            [ "nothing was cleared: whether the cluster and its instances are gone could not be read: "
                <> Text.take 300 detail
            ]
        Right found@(_ : _) ->
          pure
            [ "nothing was cleared: "
                <> Text.intercalate ", " found
                <> " still exist, so what they hold is released when the final pass deletes them"
            ]
        Right [] -> do
          loadBalancerNotes <-
            maybe (pure []) (fmap loadBalancerNote . ($ reserved)) (worldLoadBalancers world)
          dependentNotes <- case chooseVpc recorded located of
            RefuseVpc reason -> pure ["network dependents were not touched: " <> reason]
            NoVpc -> pure ["no VPC exists, so there are no network dependents"]
            UseVpc vpc -> clearIn vpc
          pure (loadBalancerNotes <> dependentNotes)
 where
  reserved = reserveWaitWindow (worldFinalPassReserveMicros world) (worldWaits world)
  -- A read that failed once is read again before it decides: not knowing whether
  -- the cluster is gone costs the run its repair, and a rerun costs the first
  -- pass again.
  ownersTwice stack vpcs = do
    firstTry <- probeStackOwners (guardedAws world) stack vpcs
    case firstTry of
      Left _ -> probeStackOwners (guardedAws world) stack vpcs
      Right _ -> pure firstTry
  loadBalancerNote result = case result of
    Right () -> ["load balancer family cleared"]
    Left detail -> ["load balancer family: " <> Text.take 300 detail]
  clearIn vpc = case mkDependentsTarget vpc (worldCluster world) of
    Left reason -> pure ["network dependents were not touched: " <> reason]
    Right target ->
      describeRepair
        <$> clearNetworkFamilies
          (awsNetworkFamiliesForStack (Text.pack (worldStackName world)))
          (runAwsNativeStackFamilyCommand (worldAws world))
          reserved
          target
  describeRepair result = case result of
    Left detail -> ["network dependents could not be listed: " <> Text.take 300 detail]
    Right done ->
      [ "network dependents: deleted "
          <> countOf (repairDeletedInterfaces done)
          <> " interface(s) and "
          <> countOf (repairDeletedGroups done)
          <> " group(s)"
      ]
        <> map (Text.take 300) (repairNotes done)
        <> [ "still there after the repair: " <> Text.take 700 (renderDependents (repairRemaining done))
           | not (null (repairRemaining done))
           ]
  countOf = Text.pack . show . length

-- | Read the field with the audit's enumeration. The positive control is set
-- aside: the destroy's request carries no bucket to look for, and the operator's
-- closing inventory, which does, follows the verb.
readField :: (Monad m) => StackDestroyWorld m -> m (Either Text FieldState)
readField world = do
  field <- auditStackField (guardedAws world) (worldRef world) (worldConfig world)
  pure $ do
    (stack, answers) <- field
    observation <- first (Text.pack . show) (mkAuditObservation stack answers AuditControlSeen)
    fieldStateOf observation

-- | Whether the field is empty: rows are a refutation and stand over gaps; a gap
-- with no row is a field that could not be read, never an empty one. Only the
-- classes the destroy answers for are judged ('loopOwnsClass').
fieldStateOf :: AuditObservation -> Either Text FieldState
fieldStateOf observation
  | not (null held) = Right (FieldHolds (Text.take 700 (Text.intercalate ", " held)))
  | not (null gaps) =
      Left
        ( Text.take
            700
            ( Text.intercalate
                "; "
                [auditClassLabel class' <> " (" <> Text.take 80 gap <> ")" | (class', gap) <- gaps]
            )
        )
  | otherwise = Right FieldEmpty
 where
  answers =
    [ (class', answer)
    | (class', answer) <- Map.toList (auditObservationAnswers observation)
    , loopOwnsClass class'
    ]
  held =
    [ auditClassLabel class'
        <> " x"
        <> Text.pack (show total)
        <> maybeIdentities answer
    | (class', answer) <- answers
    , let total = fromIntegral (length (auditAnswerRows answer)) + auditAnswerOmitted answer :: Natural
    , total > 0
    ]
  gaps = [(class', gap) | (class', answer) <- answers, Just gap <- [auditAnswerGap answer]]
  maybeIdentities answer = case map auditRowIdentity (take 3 (auditAnswerRows answer)) of
    [] -> ""
    identities -> " (" <> Text.intercalate ", " identities <> ")"
