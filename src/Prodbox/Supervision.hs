-- | Sprint 2.134: the only constructor for a long-lived child thread.
--
-- [Chaos Hardening Doctrine](../../documents/engineering/chaos_hardening_doctrine.md)
-- rule R6 already said that discarding a cancellation or join result "recreates
-- unstructured ownership behind a structured API and is forbidden". Nothing
-- enforced it, and five long-lived threads under @src\/@ discarded their handle:
-- each could die silently and leave its parent running on stale assumptions.
--
-- The repository already contained the answer, in one module:
-- @withSupervisedWorkers@ in "Prodbox.Gateway.Daemon" linked every handle it
-- spawned. What it could not do was stop a sixth site from being written, because
-- it was a convention plus a single-file import scan rather than a type.
--
-- This module lifts that convention into a type. 'SupervisedChild' is opaque and
-- its constructor is private, so the __only__ way to obtain one is
-- 'withSupervisedChild' or 'withSupervisedChildren', and both link the underlying
-- handle to the calling thread __before__ the value exists. "Spawned but
-- unobserved" is therefore not a representable state rather than merely a
-- discouraged one: a child that dies raises in its parent instead of leaving the
-- parent to continue on an assumption that stopped being true.
--
-- The scope is deliberately the __long-lived__ child. A bounded, immediately
-- joined helper — the two stream readers in "Prodbox.Subprocess", say — is
-- already observed by the @wait@ that follows it, and the repo-wide
-- @spawnedHandleDispositionViolations@ gate in "Prodbox.CheckCode" admits that
-- shape. What neither admits is a handle nobody looks at again.
module Prodbox.Supervision
  ( -- * The child
    SupervisedChild

    -- * Constructors — every one of them links
  , withSupervisedChild
  , withSupervisedChildren

    -- * Disposition
  , waitSupervisedChild
  , waitSupervisedChildCatch
  , cancelSupervisedChild
  )
where

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Exception (SomeException)

-- | A long-lived child whose parent is already observing it.
--
-- The constructor is private. Every value of this type was produced by a
-- combinator that linked the handle first, so possessing one is itself the
-- evidence that the child's death reaches its parent.
newtype SupervisedChild result = SupervisedChild (Async result)

-- | Spawn one long-lived child, link it, and run the body with it in scope.
--
-- The child's lifetime is exactly the body: a returning or failing body cancels
-- it, and a failing child raises in this thread rather than being swallowed.
withSupervisedChild
  :: IO result
  -> (SupervisedChild result -> IO answer)
  -> IO answer
withSupervisedChild action body =
  Async.withAsync action $ \handle -> do
    Async.link handle
    body (SupervisedChild handle)

-- | Spawn a fixed set of long-lived children under one body.
--
-- Each child is linked as it is spawned, so the roster and the observed set are
-- the same list by construction — the property @withSupervisedWorkers@'s roster
-- comment states, generalised off its single module.
withSupervisedChildren
  :: [IO result]
  -> ([SupervisedChild result] -> IO answer)
  -> IO answer
withSupervisedChildren actions body = go [] actions
 where
  go acquired [] = body (reverse acquired)
  go acquired (action : remaining) =
    withSupervisedChild action (\child -> go (child : acquired) remaining)

-- | Join a supervised child, re-raising its exception.
waitSupervisedChild :: SupervisedChild result -> IO result
waitSupervisedChild (SupervisedChild handle) = Async.wait handle

-- | Join a supervised child, returning its exception instead of raising it.
waitSupervisedChildCatch
  :: SupervisedChild result
  -> IO (Either SomeException result)
waitSupervisedChildCatch (SupervisedChild handle) = Async.waitCatch handle

-- | Cancel a supervised child and wait for it to finish unwinding.
cancelSupervisedChild :: SupervisedChild result -> IO ()
cancelSupervisedChild (SupervisedChild handle) = Async.cancel handle
