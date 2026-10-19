{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one place a Provider operation's AWS session lifetime is decided.
--
-- The session used to be a literal 900 seconds, chosen to satisfy the STS
-- floor, while the operation it served could run for thirty minutes. A destroy
-- that retried one dependency error past the fifteenth minute then failed on an
-- expired session, and the credential error hid the dependency error that
-- caused it. The lifetime is now derived from the signed intent deadline, kept
-- under the role's declared maximum, and carried as an expiry that every long
-- child is bounded by.
--
-- Times are microseconds of Authority time (UTC); durations are seconds, as
-- STS requires.
--
-- The same algebra decides how long an operation may /wait/. Every @aws@ child
-- the Provider starts is killed at 'awsCliChildBoundMicros', so a wait that
-- polls for minutes cannot be one child: it is a loop of short describe calls,
-- and each loop is bounded by a named 'WaitBudget' here. A wait that is not
-- named in 'WaitFact' has no budget and cannot be started, and the budgets of
-- every operation that waits are checked, in the unit suite, to fit inside the
-- intent's lifetime with room left for the operation's own mutations.
module Prodbox.ControlPlane.OperationBudget
  ( SessionWindowRefusal (..)
  , sessionMinimumSeconds
  , sessionGraceSeconds
  , declaredRoleMaximumSeconds
  , planSessionDuration
  , sessionWindowMicros
  , childLimitMicros
  , renderSessionWindowRefusal
  , awsCliChildBoundMicros
  , WaitFact (..)
  , renderWaitFact
  , WaitBudget (..)
  , waitBudgetFor
  , waitCeilingMicros
  , waitDeadlineMicros
  , WaitingOperation (..)
  , operationWaitFacts
  , serialWaitSharePermille
  , operationLeadPermille
  , operationIsWindowed
  , waitOperationReservePermille
  , firstPassSharePermille
  , finalPassReservePermille
  , destroyOverheadPermille
  , firstPassCeilingMicros
  , finalPassReserveMicros
  , verdictReserveMicros
  , readTailMicros
  , shortCommandCeilingMicros
  , passLimitMicros
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | The floor STS enforces on @DurationSeconds@.
sessionMinimumSeconds :: Natural
sessionMinimumSeconds = 900

-- | How long past the intent deadline the session must still be valid, for the
-- read-back that follows the last mutation.
sessionGraceSeconds :: Natural
sessionGraceSeconds = 300

-- | The role's @MaxSessionDuration@ as this repository declares it: the AWS
-- default. Until the role is converged to a value prodbox owns, requests are
-- clamped here.
declaredRoleMaximumSeconds :: Natural
declaredRoleMaximumSeconds = 3600

microsPerSecond :: Natural
microsPerSecond = 1000000

-- | The @DurationSeconds@ to request for an operation that must finish by its
-- intent deadline: the time remaining plus the grace, never below the STS floor
-- and never above the role maximum (which must itself be at least the floor).
planSessionDuration
  :: Natural
  -- ^ the role maximum, in seconds
  -> Natural
  -- ^ now, in microseconds
  -> Natural
  -- ^ the intent deadline, in microseconds
  -> Natural
planSessionDuration roleMaximum nowMicros deadlineMicros =
  max sessionMinimumSeconds (min roleMaximum (remainingSeconds + sessionGraceSeconds))
 where
  remainingSeconds =
    (monus deadlineMicros nowMicros + microsPerSecond - 1) `div` microsPerSecond

-- | Why a session cannot start work.
data SessionWindowRefusal
  = -- | The session expires, in microseconds, no later than the read-back grace
    -- after now.
    SessionWindowExceeded !Natural !Natural
  deriving stock (Eq, Show)

-- | The microseconds a session can still be used for, once the read-back grace
-- is reserved. A session with nothing usable left must not start work.
sessionWindowMicros
  :: Natural
  -- ^ the session's expiry, in microseconds
  -> Natural
  -- ^ now, in microseconds
  -> Either SessionWindowRefusal Natural
sessionWindowMicros expiresAtMicros nowMicros
  | expiresAtMicros > nowMicros + graceMicros =
      Right (expiresAtMicros - nowMicros - graceMicros)
  | otherwise = Left (SessionWindowExceeded expiresAtMicros nowMicros)
 where
  graceMicros = sessionGraceSeconds * microsPerSecond

-- | A child's wall-clock bound: the child maximum, or the window left in the
-- session, whichever is smaller. The session can then never expire under a
-- running child.
childLimitMicros :: Natural -> Natural -> Natural
childLimitMicros = min

renderSessionWindowRefusal :: SessionWindowRefusal -> Text
renderSessionWindowRefusal (SessionWindowExceeded expiresAtMicros nowMicros) =
  "SessionWindowExceeded: the AWS session expires at "
    <> Text.pack (show expiresAtMicros)
    <> " microseconds and it is now "
    <> Text.pack (show nowMicros)
    <> ", inside the "
    <> Text.pack (show sessionGraceSeconds)
    <> " seconds reserved for read-back; no capability was started"

-- | The wall-clock bound on every @aws@ child the Provider starts. The bounded
-- runner enforces it; a wait's per-poll child maximum may not exceed it.
awsCliChildBoundMicros :: Natural
awsCliChildBoundMicros = 30 * microsPerSecond

-- | A fact an operation waits for. The set is closed: a wait that is not named
-- here has no budget.
data WaitFact
  = AddonAbsent
  | NodeGroupAbsent
  | ClusterAbsent
  | InstancesTerminated
  | VolumesAvailable
  | SecurityGroupDeletable
  | -- | The interfaces an AWS service holds on the account's behalf (a load
    -- balancer's, the control plane's) have released.
    InterfacesReleased
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The fact as an operator reads it in a timeout.
renderWaitFact :: WaitFact -> Text
renderWaitFact fact = case fact of
  AddonAbsent -> "EKS add-on absent"
  NodeGroupAbsent -> "EKS node group absent"
  ClusterAbsent -> "EKS cluster absent"
  InstancesTerminated -> "EC2 instances terminated"
  VolumesAvailable -> "EBS volumes available"
  SecurityGroupDeletable -> "security group deletable"
  InterfacesReleased -> "requester-managed interfaces released"

-- | What one wait may consume.
--
-- __Authored, not measured.__ The shares below are generous first values for
-- operations whose release times no recording yet states; the first live
-- recordings tighten them. An expired budget is a typed timeout that names the
-- fact, so a share that is too small is reported, not hidden.
data WaitBudget = WaitBudget
  { waitBudgetFact :: !WaitFact
  , waitBudgetPollIntervalMicros :: !Natural
  -- ^ The pause between two polls.
  , waitBudgetChildMaximumMicros :: !Natural
  -- ^ The longest child one poll may issue.
  , waitBudgetSharePermille :: !Natural
  -- ^ The part, in thousandths, of the intent's lifetime the wait may consume.
  }
  deriving stock (Eq, Show)

waitBudgetFor :: WaitFact -> WaitBudget
waitBudgetFor fact = case fact of
  AddonAbsent -> budget 10 100
  NodeGroupAbsent -> budget 15 250
  ClusterAbsent -> budget 15 300
  InstancesTerminated -> budget 10 150
  VolumesAvailable -> budget 5 100
  SecurityGroupDeletable -> budget 10 300
  InterfacesReleased -> budget 15 200
 where
  budget intervalSeconds sharePermille =
    WaitBudget
      { waitBudgetFact = fact
      , waitBudgetPollIntervalMicros = intervalSeconds * microsPerSecond
      , waitBudgetChildMaximumMicros = 20 * microsPerSecond
      , waitBudgetSharePermille = sharePermille
      }

-- | The longest a wait may run, given the intent's lifetime.
waitCeilingMicros :: Natural -> WaitBudget -> Natural
waitCeilingMicros lifetimeMicros budget =
  lifetimeMicros * waitBudgetSharePermille budget `div` 1000

-- | The instant a wait that starts now must give up: its ceiling, or the window
-- the session has left, whichever is nearer. The session can then never expire
-- under a wait, whatever the ceiling says.
waitDeadlineMicros
  :: Natural
  -- ^ the intent's lifetime, in microseconds
  -> WaitBudget
  -> Natural
  -- ^ now, in microseconds
  -> Natural
  -- ^ the usable session window left, from 'sessionWindowMicros'
  -> Natural
waitDeadlineMicros lifetimeMicros budget nowMicros windowMicros =
  nowMicros + min (waitCeilingMicros lifetimeMicros budget) windowMicros

-- | The Provider operations that wait, as the registry names them. One
-- operation is one signed intent, so one lifetime.
data WaitingOperation
  = -- | Reaping the registered EKS stack family, whose shared EC2 chain can also
    -- wait for instances.
    ReapEksNativeFamily
  | ReapAwsTestNativeFamily
  | EnsureRetainedVolumes
  | ReapLoadBalancerControllerFamily
  | -- | Destroying a registered stack that has a VPC: the repair between the
    -- two Pulumi passes clears what a load balancer controller held, waits for
    -- the interfaces a service releases, and deletes the cluster's group.
    DestroyAwsStack
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The waits an operation may run, in the order it runs them.
operationWaitFacts :: WaitingOperation -> [WaitFact]
operationWaitFacts operation = case operation of
  ReapEksNativeFamily ->
    [ AddonAbsent
    , NodeGroupAbsent
    , ClusterAbsent
    , InstancesTerminated
    , -- The children a cluster's controllers left in the VPC are cleared once the
      -- instances are gone ('Prodbox.Lifecycle.AwsNetworkDependents').
      InterfacesReleased
    , SecurityGroupDeletable
    ]
  ReapAwsTestNativeFamily -> [InstancesTerminated, InterfacesReleased, SecurityGroupDeletable]
  EnsureRetainedVolumes -> [VolumesAvailable]
  ReapLoadBalancerControllerFamily -> [SecurityGroupDeletable]
  DestroyAwsStack -> [SecurityGroupDeletable, InterfacesReleased, SecurityGroupDeletable]

-- | The sum of the shares an operation's waits may consume one after another.
serialWaitSharePermille :: WaitingOperation -> Natural
serialWaitSharePermille =
  sum . map (waitBudgetSharePermille . waitBudgetFor) . operationWaitFacts

-- | The part of the intent's lifetime an operation spends before its first wait
-- can begin: the bounded Pulumi pass that the destroy of a stack with a VPC runs
-- first.
operationLeadPermille :: WaitingOperation -> Natural
operationLeadPermille operation = case operation of
  DestroyAwsStack -> firstPassSharePermille
  _ -> 0

-- | Whether an operation's waits cannot all be spent: what precedes them, their
-- ceilings in sequence, and the reserve add up to more than the lifetime.
--
-- A budget is a ceiling and not an allotment. Every wait also ends at the nearer
-- of its ceiling and the window the session has left ('waitDeadlineMicros'), so
-- a windowed operation's later waits can be left with less than their ceiling, or
-- with none, and say so in a typed timeout that names the fact. The first wait
-- to need time takes it. The destroy's repair, and only it, ends its waits a
-- further 'finalPassReservePermille' before the session does, which keeps that
-- part of the window for the repair's remaining calls, the final pass, and the
-- reading; the manifest route's reaper takes no such reserve, because nothing but
-- the chain's own mutations follows its waits.
operationIsWindowed :: WaitingOperation -> Bool
operationIsWindowed operation =
  operationLeadPermille operation
    + serialWaitSharePermille operation
    + waitOperationReservePermille
    > 1000

-- | The part of the intent's lifetime no wait may take: the operation's own
-- mutations, its observations, and the response that follows the last one.
waitOperationReservePermille :: Natural
waitOperationReservePermille = 200

-- | The longest the first Pulumi destroy pass may run, in thousandths of the
-- intent's lifetime.
--
-- It is bounded because the AWS provider retries a subnet delete on a
-- @DependencyViolation@ for many minutes: an unbounded first pass would spend the
-- whole intent on one error, and an earlier destroy expired exactly that way. A
-- pass that is cut at the bound has not failed; the scratch backend keeps its
-- state, so the final pass continues from it and @--refresh@ reconciles what the
-- stop left unrecorded. The first clean destroy on record took twelve and a half
-- minutes, a little over 400; this is authored, not measured.
firstPassSharePermille :: Natural
firstPassSharePermille = 450

-- | What the repair's waits and the first pass can never take: the final pass
-- and the verdict that follows it, in thousandths of the intent's lifetime. The
-- repair's waits end that much before the session does. What is left after the
-- last wait is the repair's own serial calls (a few listings and deletes, each a
-- child of its own), then the final pass, bounded by what remains less the
-- reading's reserve and the kill grace, then the reading. The reserve is sized
-- for the calls and the final pass of a destroy whose long deletions the first
-- pass has done; it is authored, not measured, and a destroy that needs more
-- ends 'Blocked' and is run again.
finalPassReservePermille :: Natural
finalPassReservePermille = 300

-- | What the destroy's own admission, session, and listings take, in thousandths:
-- the first pass and the final pass's reserve must leave it.
destroyOverheadPermille :: Natural
destroyOverheadPermille = 100

-- | What the final pass leaves the reading of the field that follows it and the
-- stack record's removal: about thirty serial listings, each a short call that
-- is bounded on its own and not by a shared deadline, then the commit. The final
-- pass is cut this much (and its kill grace) before the session ends, so the
-- typed report can still be returned. A call costs five to seven seconds under
-- the Provider's CPU envelope (measured; decision D10 of the Development Plan),
-- so the thirty take about four minutes: the reserve holds the whole reading when
-- the final pass is quick, and about ten reads when the pass spends its limit (no
-- read begins inside the read tail). The reads it cannot make are gaps, and a
-- field with a gap is blocked, never empty.
verdictReserveMicros :: Natural
verdictReserveMicros = 120 * microsPerSecond

-- | What the commit and the observation after the last read need: no read of the
-- field is begun inside it, so that the report is returned before the intent's
-- hard stop. A read that would begin inside it is refused, and the classes not
-- yet read are gaps.
readTailMicros :: Natural
readTailMicros = 40 * microsPerSecond

-- | The longest one of the quick Pulumi commands around the passes (reading the
-- outputs, cancelling, removing the record) may run. They reserve nothing, so a
-- destroy that finishes late can still have its record removed; this ceiling
-- keeps a hung one from spending the intent before a typed report.
shortCommandCeilingMicros :: Natural
shortCommandCeilingMicros = 60 * microsPerSecond

-- | The bound for a Pulumi pass, given the window the session has left: that
-- window less what is reserved for the work after the pass, held under the pass's
-- ceiling and the child maximum. 'Nothing' when the reserve leaves nothing, so a
-- session with no room starts no pass.
passLimitMicros
  :: Natural
  -- ^ the pass's ceiling
  -> Natural
  -- ^ what is reserved for the work after it
  -> Natural
  -- ^ the longest a Pulumi child may run
  -> Natural
  -- ^ the window the session has left
  -> Maybe Natural
passLimitMicros ceilingMicros reserveMicros childMaximumMicros windowMicros
  | limit == 0 = Nothing
  | otherwise = Just limit
 where
  limit = min (monus windowMicros reserveMicros) (min ceilingMicros childMaximumMicros)

firstPassCeilingMicros :: Natural -> Natural
firstPassCeilingMicros lifetimeMicros = lifetimeMicros * firstPassSharePermille `div` 1000

finalPassReserveMicros :: Natural -> Natural
finalPassReserveMicros lifetimeMicros = lifetimeMicros * finalPassReservePermille `div` 1000

monus :: Natural -> Natural -> Natural
monus larger smaller
  | larger > smaller = larger - smaller
  | otherwise = 0
