{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 2.134 witness for 'Prodbox.Supervision.SupervisedChild'.
--
-- Three properties are asserted here, and a fourth is asserted by the fact that
-- this module compiles at all:
--
--   * FAULT INJECTION. A child that dies raises in the parent, whether it dies
--     before the parent has done anything or while the parent is already
--     blocked. This is the property the repaired sites needed and did not have:
--     each discarded its handle, so its child could die and leave the parent
--     running on an assumption that had stopped being true. Removing the @link@
--     from 'Prodbox.Supervision.withSupervisedChild' turns every case here into
--     a hang cut short by its own timeout.
--   * SCOPE. The child's lifetime is exactly the body, so a returning body
--     reclaims it. This is what makes the combinator a drop-in for the
--     @bracket … (mapM_ cancel)@ shape the control-plane request pool used.
--   * ROSTER PARITY. 'Prodbox.Supervision.withSupervisedChildren' links every
--     member, not only the first or the last, so the roster and the observed set
--     are the same list.
--   * COMPILE WITNESS. Neither of these typechecks, and uncommenting either
--     fails the build:
--
--     > unsupervised action = SupervisedChild <$> Async.async action
--
--     > adopt handle = SupervisedChild handle
--
--     The constructor is private, so the only values of the type are the ones
--     'Prodbox.Supervision.withSupervisedChild' and
--     'Prodbox.Supervision.withSupervisedChildren' produce, and both link before
--     the value exists. "Spawned but unobserved" is therefore unconstructible
--     rather than merely refused, and that the repaired sites compile is the
--     positive half of the same proof.
module SupervisionWitness
  ( supervisionWitnessSuite
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  )
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (forM_, forever, unless)
import Data.List (isInfixOf)
import Numeric.Natural (Natural)
import Prodbox.Supervision
  ( cancelSupervisedChild
  , waitSupervisedChild
  , waitSupervisedChildCatch
  , withSupervisedChild
  , withSupervisedChildren
  )
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import System.Timeout (timeout)
import TestSupport

supervisionWitnessSuite :: SuiteBuilder ()
supervisionWitnessSuite =
  describe "Sprint 2.134 supervised-child witness" $ do
    it "raises a child's death in a parent that is doing nothing else" $ do
      -- The exact shape of the repaired defects: the parent waits for ever on
      -- something the dead child was supposed to deliver. With the handle
      -- discarded this never returns; with it linked, the child's exception
      -- arrives instead.
      settled <-
        timeout
          witnessMicros
          ( try
              ( withSupervisedChild
                  (throwIO (userError "child died"))
                  (\_ -> forever (threadDelay 10_000))
              )
              :: IO (Either SomeException ())
          )
      settled `shouldSatisfy` observedChildDeath

    it "raises a child's death that happens long after the body started" $ do
      started <- newEmptyMVar
      settled <-
        timeout
          witnessMicros
          ( try
              ( withSupervisedChild
                  (takeMVar started >> throwIO (userError "child died later"))
                  ( \_ -> do
                      putMVar started ()
                      forever (threadDelay 10_000)
                  )
              )
              :: IO (Either SomeException ())
          )
      settled `shouldSatisfy` observedChildDeath

    it "reclaims the child when the body returns" $ do
      running <- newEmptyMVar
      unwound <- newTVarIO (0 :: Natural)
      answer <-
        withSupervisedChild
          ( ( putMVar running ()
                >> forever (threadDelay 10_000)
            )
              `finally` atomically (modifyTVar' unwound (+ 1))
          )
          ( \_ -> do
              -- Wait for the child to actually be running: a body that returns
              -- before its child is scheduled proves nothing about reclamation.
              takeMVar running
              pure ("body answer" :: String)
          )
      answer `shouldBe` "body answer"
      -- The scope is closed by the time the combinator returns, so the child has
      -- already unwound rather than being left running behind the caller.
      readTVarIO unwound `shouldReturn` 1

    it "joins a child that returns normally" $ do
      answer <-
        withSupervisedChild (pure ("child answer" :: String)) waitSupervisedChild
      answer `shouldBe` "child answer"

    it "returns a cancelled child's outcome rather than raising it" $ do
      outcome <-
        withSupervisedChild
          (forever (threadDelay 10_000))
          ( \child -> do
              cancelSupervisedChild child
              waitSupervisedChildCatch child
          )
      outcome `shouldSatisfy` either (const True) (const False)

    it "links every member of a child set, not only the first" $
      -- A roster that links its head and forgets its tail is exactly the
      -- silent-decay shape the control-plane request pool had: several servers
      -- spawned, one death, no observation, and an accept loop that carries on
      -- enqueueing into a pool that has shrunk.
      forM_ [0 .. 2 :: Int] $ \dying -> do
        admitted <- newTVarIO (0 :: Natural)
        let member index
              | index == dying = do
                  atomically $ do
                    ready <- readTVar admitted
                    unless (ready == 1) retry
                  throwIO (userError ("member " ++ show index ++ " died"))
              | otherwise = forever (threadDelay 10_000)
        settled <-
          timeout
            witnessMicros
            ( try
                ( withSupervisedChildren
                    (map member [0 .. 2])
                    ( \children -> do
                        length children `shouldBe` 3
                        atomically (modifyTVar' admitted (+ 1))
                        forever (threadDelay 10_000)
                    )
                )
                :: IO (Either SomeException ())
            )
        settled `shouldSatisfy` observedChildDeath

    it "spawns every repaired long-lived child through the constructor" $ do
      -- The combinator's property reaches a site only if the site uses it. The
      -- repo-wide spawned-handle gate is the negative half, refusing a
      -- discarded handle anywhere under src/; this is the positive half, naming
      -- the exact modules Sprint 2.134 converted so a silent revert to a raw
      -- spawn with a correct-looking disposition still fails.
      repoRoot <- getCurrentDirectory
      forM_ repairedSupervisionSites $ \relativePath -> do
        contents <- readFile (repoRoot </> relativePath)
        contents `shouldContain` "Prodbox.Supervision"
        contents `shouldContain` "withSupervisedChild"

-- | The long-lived children Sprint 2.134 converted onto the constructor.
--
-- The Bootstrap Broker's request pool is deliberately absent: its handles
-- outlive the call that spawns them and are joined through the server handle, so
-- it is repaired by making the manager wait on the pool rather than by changing
-- how it spawns. That repair carries its own proof in
-- @BootstrapBrokerServerSafety@.
repairedSupervisionSites :: [FilePath]
repairedSupervisionSites =
  [ "src/Prodbox/Bootstrap/Broker.hs"
  , "src/Prodbox/ControlPlane/Runtime.hs"
  , "src/Prodbox/Gateway/Daemon.hs"
  , "src/Prodbox/Gateway/PortForward.hs"
  , "src/Prodbox/Workload.hs"
  ]

-- | Sprints 7.39 and 7.40 removed two of the seven from this list rather than
-- changing them.
--
-- Both had a supervised token writer because the bearer credential was served
-- through a FIFO: `Prodbox.Lifecycle.Teardown.EphemeralKubectl` authored one and
-- `Prodbox.Infra.AwsEksTestStack` restated it. The credential is now a private
-- file, written and read back before the client exists, and the second statement
-- of it is gone — so neither module has a long-lived child left to supervise.
-- That is a stronger outcome than supervising one, and the reason these two are
-- absent rather than a reason the list is stale: a spawn reintroduced at either
-- site is refused by the repo-wide spawned-handle gate, which is the half of
-- this proof that does not need a list.

-- | A parent that observed its child's death: the combinator returned, within
-- the bound, carrying the child's exception.
--
-- 'Nothing' is the pre-repair behaviour — the parent still blocked on something
-- a dead child will never deliver — and a 'Right' means the body returned as if
-- nothing had happened.
observedChildDeath :: Maybe (Either SomeException ()) -> Bool
observedChildDeath settled = case settled of
  Nothing -> False
  Just (Right ()) -> False
  Just (Left failure) -> "died" `isInfixOf` show failure

witnessMicros :: Int
witnessMicros = 2_000_000
