{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A destroy that converges, or says what stopped it.
--
-- The supported destroy used to be one bounded @pulumi destroy@ followed by
-- @stack rm@. A child an in-cluster controller made after the plan was confirmed
-- (a network interface the VPC CNI left behind, the security group EKS made for
-- the cluster, a load balancer the controller made) is in no checkpoint, so the
-- subnet delete that follows it ended in @DependencyViolation@, the provider
-- retried it for most of an hour, and the destroy ended on whatever error came
-- last. Nothing between the first failure and the end could clear the child, and
-- nothing at the end could say the field was empty.
--
-- The loop is four steps, each a value the caller supplies so the order runs
-- over a scripted world:
--
-- 1. A first Pulumi pass, bounded to a named share of the intent
--    ('Prodbox.ControlPlane.OperationBudget.firstPassSharePermille'). A pass cut
--    at its bound has not failed: the scratch backend keeps its state.
-- 2. If the pass failed, or finished while the field still holds something, a
--    repair: the registered families clear what their closed predicates admit
--    and wait for what an AWS service holds
--    ("Prodbox.Lifecycle.AwsNetworkDependents"). A pass that did not finish on
--    its own is first recovered from: a Pulumi stopped by a signal can leave the
--    lock its update held in the backend, and the final pass would stop on it.
-- 3. A final pass, which continues from the first pass's state.
-- 4. A reading of the field. Only an empty, fully answered field removes the
--    stack record; anything else is 'Blocked', names what remains, and keeps the
--    record so a rerun makes progress.
--
-- The repair runs after any failed first pass and not only after a recognised
-- one: it is read-only on everything outside its predicates, a destroy that
-- failed for a reason the repair cannot change is simply retried by the final
-- pass, and a failure text is the one thing a classifier would otherwise have to
-- get right.
module Prodbox.Lifecycle.AwsDestroyConverge
  ( DestroyPass (..)
  , PassResult (..)
  , FieldState (..)
  , ConvergeEffects (..)
  , ConvergeOutcome (..)
  , convergeDestroy
  , renderBlocked
  , reportBound
  )
where

import Data.Text (Text)
import Data.Text qualified as Text

-- | The two Pulumi passes of one destroy.
data DestroyPass
  = FirstPass
  | FinalPass
  deriving stock (Eq, Show)

-- | How one pass ended.
data PassResult
  = -- | The destroy finished: Pulumi believes the stack holds nothing.
    PassSucceeded
  | -- | The stack is not there: there was nothing for this pass to destroy.
    PassStackAbsent
  | -- | The pass failed or was cut at its bound; the rendered failure, cause
    -- first.
    PassFailed !Text
  deriving stock (Eq, Show)

-- | What reading the stack's field found.
data FieldState
  = FieldEmpty
  | -- | The field still holds something; a summary of it.
    FieldHolds !Text
  deriving stock (Eq, Show)

-- | What the loop needs from its world.
data ConvergeEffects m = ConvergeEffects
  { convergePass :: DestroyPass -> m PassResult
  , convergeRecover :: m [Text]
  -- ^ After a first pass that did not succeed: clear what a stopped Pulumi left
  -- in the backend so the final pass can start. Best effort; the notes say what
  -- it did.
  , convergeRepair :: m [Text]
  -- ^ Clear what the closed predicates admit and wait for what a service holds;
  -- the notes say what it did and what it could not.
  , convergeField :: m (Either Text FieldState)
  -- ^ Read the field. 'Left' is a field that could not be read, which is not an
  -- empty one.
  , convergeRemoveStack :: m (Either Text ())
  }

data ConvergeOutcome
  = Converged
  | -- | The stack record is kept; the text names what remains and the next safe
    -- command.
    Blocked !Text
  deriving stock (Eq, Show)

convergeDestroy :: (Monad m) => ConvergeEffects m -> m ConvergeOutcome
convergeDestroy effects = do
  first' <- convergePass effects FirstPass
  case first' of
    PassStackAbsent -> pure Converged
    PassSucceeded -> do
      field <- convergeField effects
      case field of
        Right FieldEmpty -> removeStack
        _ -> repairThenFinish False [firstPassNote "finished with the field not yet empty"]
    PassFailed detail -> repairThenFinish True [firstPassNote detail]
 where
  firstPassNote detail = "first pass: " <> Text.take passDetailBound detail
  removeStack = do
    removed <- convergeRemoveStack effects
    pure $ case removed of
      Right () -> Converged
      Left detail ->
        Blocked
          ( renderBlocked
              ["the field is empty, but removing the stack record failed: " <> Text.take noteBound detail]
              ""
          )
  repairThenFinish stopped earlier = do
    recoverNotes <- if stopped then convergeRecover effects else pure []
    repairNotes <- convergeRepair effects
    final <- convergePass effects FinalPass
    field <- convergeField effects
    let history =
          earlier
            <> map (("recover: " <>) . Text.take noteBound) recoverNotes
            <> map (("repair: " <>) . Text.take noteBound) repairNotes
    case (final, field) of
      (PassFailed detail, _) ->
        pure
          ( Blocked
              ( renderBlocked
                  (history <> ["final pass: " <> Text.take passDetailBound detail])
                  (fieldSummary field)
              )
          )
      (_, Right FieldEmpty) -> removeStack
      (_, _) ->
        pure
          ( Blocked
              ( renderBlocked
                  (history <> ["final pass: finished"])
                  (fieldSummary field)
              )
          )

fieldSummary :: Either Text FieldState -> Text
fieldSummary field = case field of
  Right FieldEmpty -> ""
  Right (FieldHolds summary) -> "the field still holds: " <> summary
  Left reason -> "the field could not be read: " <> reason

-- | The most of one pass's failure the report keeps. The cause is first in a
-- rendered failure, so the head carries it.
passDetailBound :: Int
passDetailBound = 600

-- | The most of one note the report keeps, so no one step's words crowd out the
-- others.
noteBound :: Int
noteBound = 400

-- | The most of the remaining field the report keeps.
remainingBound :: Int
remainingBound = 900

-- | The blocked report: what stopped it, what remains, and the next safe
-- command. Bounded so it fits where a failure detail goes. What is cut when the
-- history is long is the middle of the history: the heading, the remainder, the
-- instruction that tells the operator what to do next, and the first and last
-- steps are never the part that goes.
renderBlocked :: [Text] -> Text -> Text
renderBlocked history remaining =
  Text.intercalate " | " (fixedBefore <> [historyText | not (Text.null historyText)] <> [nextStep])
 where
  heading = "blocked: the destroy did not converge; the stack record is kept"
  nextStep =
    "next: rerun the destroy, which continues from this state; `prodbox aws audit` names what remains"
  remainingText = Text.take remainingBound remaining
  fixedBefore = [heading] <> [remainingText | not (Text.null remainingText)]
  fixedLength = sum (map Text.length (fixedBefore <> [nextStep]))
  -- Every part is joined by the three characters of the separator.
  room = reportBound - fixedLength - 3 * (length fixedBefore + 2)
  historyText = ellipsizeMiddle room (Text.intercalate " | " history)

-- | The text cut to the room there is, with a mark where it was cut. It is the
-- middle that goes: the first thing that happened and the last, the final pass's
-- cause, are the two a reader needs.
ellipsizeMiddle :: Int -> Text -> Text
ellipsizeMiddle room text
  | Text.length text <= room = text
  | room <= 5 = ""
  | otherwise = Text.take headRoom text <> "..." <> Text.takeEnd tailRoom text
 where
  headRoom = (room - 3) `div` 2
  tailRoom = room - 3 - headRoom

reportBound :: Int
reportBound = 3500
