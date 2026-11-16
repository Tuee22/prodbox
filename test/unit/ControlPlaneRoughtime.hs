{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRoughtime (controlPlaneRoughtimeSuite) where

import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (cancelWith, waitCatch, withAsync)
import Control.Exception (AsyncException (ThreadKilled), bracket, fromException)
import Data.ByteString qualified as ByteString
import Data.Either (isRight)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word16)
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , Socket
  , SocketType (Datagram)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , socket
  , tupleToHostAddress
  )
import Network.Socket.ByteString qualified as Socket
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.RetainedClock
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (AuthorityTimeTrusted)
  , RawClockReading (ClockUnavailable)
  , mkClockSkewBound
  )
import Prodbox.ControlPlane.Deadline (Deadline, RemainingDuration (..), deadlineAtOffset)
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.Roughtime
import Prodbox.ControlPlane.Roughtime.Udp (queryRoughtimeUdp)
import Prodbox.ControlPlane.SignedTimeBounds
import Prodbox.ControlPlane.SignedTimeSystemClock (sampleBoottime)
import RoughtimeSignerFixture (fixtureRoot, signedReply)
import System.Timeout (timeout)
import TestSupport

limit :: Natural -> IO Deadline
limit duration = (`deadlineAtOffset` RemainingDuration duration) <$> realMonotonicNow

elapsedSample :: IO ElapsedClockSample
elapsedSample = pure (elapsedClockSampleFromMicros 100)

movement :: TimeScaleMovementBound
movement = TimeScaleMovementBound 0 0 0

expectReadingError :: RoughtimeError -> Either RoughtimeError RoughtimeReading -> IO ()
expectReadingError expected result = case result of
  Left observed -> observed `shouldBe` expected
  Right _ -> expectationFailure "expected the signed exchange to fail"

withUdpServer :: (Socket -> Word16 -> IO result) -> IO result
withUdpServer action = bracket (socket AF_INET Datagram defaultProtocol) close $ \server -> do
  bind server (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  address <- getSocketName server
  case address of
    SockAddrInet port _ -> action server (fromIntegral port)
    _ -> ioError (userError "unexpected UDP test address")

serveOnce :: Socket -> (ByteString.ByteString -> ByteString.ByteString) -> IO ()
serveOnce server makeReply = do
  (request, peer) <- Socket.recvFrom server 2048
  _ <- Socket.sendTo server (makeReply request) peer
  pure ()

queryLocalUdp :: Natural -> Word16 -> IO (Either RoughtimeError RoughtimeReading)
queryLocalUdp duration port = do
  deadline <- limit duration
  queryRoughtimeUdp elapsedSample deadline fixtureRoot 0 movement "127.0.0.1" port

controlPlaneRoughtimeSuite :: SuiteBuilder ()
controlPlaneRoughtimeSuite = describe "RFC 10049 signed exchange" $ do
  it "admits a signed fixture through retained CAS and read-back" $ do
    deadline <- limit 5000000
    signed <- queryRoughtimeOnce sampleBoottime deadline fixtureRoot 0 movement (pure . signedReply)
    case signed of
      Left failure -> expectationFailure (show failure)
      Right reading -> do
        state <- newIORef (RetainedClockSnapshot 1 0)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> Just <$> readIORef state
                , casRetainedClock = \_ expected proposed -> do
                    current <- readIORef state
                    if current == expected
                      then writeIORef state proposed >> pure RetainedClockCasApplied
                      else pure RetainedClockCasConflict
                }
            elapsed = RetainedElapsedClock sampleBoottime 0 movement
            skew = either (error . show) id (mkClockSkewBound 10000000)
            source = do
              interval <- readRoughtimeReading reading
              pure $ case interval of
                Left _ -> ClockUnavailable "signed fixture unavailable"
                Right value ->
                  either (const (ClockUnavailable "invalid interval")) id (rawClockReadingFromSignedInterval value)
        admitted <- observeRetainedClock deadline skew elapsed source store
        observation <- readRetainedClockReading admitted
        case observation of
          AuthorityTimeTrusted _ _ -> pure ()
          other -> expectationFailure (show other)
        snapshot <- readIORef state
        retainedClockRevision snapshot `shouldBe` 2
  it "verifies a signed response over a native UDP socket" $
    withUdpServer $ \server port ->
      withAsync (serveOnce server signedReply) $ \_ -> do
        result <- queryLocalUdp 2000000 port
        case result of
          Left failure -> expectationFailure (show failure)
          Right reading -> do
            interval <- readRoughtimeReading reading
            interval `shouldBe` Right (SignedTimeInterval 1799999997000000 1800000003000002)
  it "refuses an oversized UDP datagram" $
    withUdpServer $ \server port ->
      withAsync (serveOnce server (const (ByteString.replicate 2048 0))) $ \_ -> do
        result <- queryLocalUdp 2000000 port
        expectReadingError RoughtimeInvalidResponse result
  it "bounds a silent UDP peer and refuses an invalid endpoint" $
    withUdpServer $ \_ port -> do
      silent <- queryLocalUdp 300000 port
      expectReadingError RoughtimeExpired silent
      invalid <- queryLocalUdp 2000000 0
      expectReadingError RoughtimeUnavailable invalid
  it "propagates cancellation after a UDP request is received" $
    withUdpServer $ \server port -> do
      received <- newEmptyMVar
      withAsync (Socket.recvFrom server 2048 >> putMVar received ()) $ \_ ->
        withAsync (queryLocalUdp 2000000 port) $ \worker -> do
          observed <- timeout 1500000 (takeMVar received)
          observed `shouldBe` Just ()
          cancelWith worker ThreadKilled
          result <- waitCatch worker
          case result of
            Left exception -> fromException exception `shouldBe` Just ThreadKilled
            Right _ -> expectationFailure "UDP cancellation was swallowed"
  it "verifies a fresh request and a nonempty Merkle proof" $ do
    deadline <- limit 2000000
    result <- queryRoughtimeOnce elapsedSample deadline fixtureRoot 0 movement (pure . signedReply)
    case result of
      Left failure -> expectationFailure (show failure)
      Right reading -> do
        interval <- readRoughtimeReading reading
        interval `shouldBe` Right (SignedTimeInterval 1799999997000000 1800000003000002)
  it "ages the original sample and refuses a regressed sample" $ do
    sampleRef <- newIORef (elapsedClockSampleFromMicros 100)
    let source = readIORef sampleRef
    deadline <- limit 2000000
    result <- queryRoughtimeOnce source deadline fixtureRoot 0 movement (pure . signedReply)
    case result of
      Left failure -> expectationFailure (show failure)
      Right reading -> do
        writeIORef sampleRef (elapsedClockSampleFromMicros 200)
        interval <- readRoughtimeReading reading
        interval `shouldBe` Right (SignedTimeInterval 1799999997000000 1800000003000102)
        writeIORef sampleRef (elapsedClockSampleFromMicros 99)
        regressed <- readRoughtimeReading reading
        regressed `shouldBe` Left RoughtimeInvalidInterval
  it "refuses to reuse a signed reading after its original deadline" $ do
    deadline <- limit 300000
    result <- queryRoughtimeOnce elapsedSample deadline fixtureRoot 0 movement (pure . signedReply)
    case result of
      Left failure -> expectationFailure (show failure)
      Right reading -> do
        threadDelay 400000
        interval <- readRoughtimeReading reading
        interval `shouldBe` Left RoughtimeExpired
  it "bounds re-sampling and classifies clock I/O failure" $ do
    sourceRef <- newIORef elapsedSample
    let source = readIORef sourceRef >>= id
    deadline <- limit 2000000
    result <- queryRoughtimeOnce source deadline fixtureRoot 0 movement (pure . signedReply)
    case result of
      Left failure -> expectationFailure (show failure)
      Right reading -> do
        writeIORef sourceRef (ioError (userError "clock unavailable"))
        unavailable <- readRoughtimeReading reading
        unavailable `shouldBe` Left RoughtimeUnavailable
    shortDeadline <- limit 300000
    writeIORef sourceRef elapsedSample
    shortResult <-
      queryRoughtimeOnce source shortDeadline fixtureRoot 0 movement (pure . signedReply)
    case shortResult of
      Left failure -> expectationFailure (show failure)
      Right reading -> do
        writeIORef sourceRef (threadDelay 1500000 >> elapsedSample)
        timedOut <- readRoughtimeReading reading
        timedOut `shouldBe` Left RoughtimeExpired
  it "refuses a previously signed response for a fresh request" $ do
    saved <- newIORef Nothing
    firstDeadline <- limit 2000000
    first <- queryRoughtimeOnce elapsedSample firstDeadline fixtureRoot 0 movement $ \request -> do
      let reply = signedReply request
      writeIORef saved (Just reply)
      pure reply
    first `shouldSatisfy` isRight
    old <- readIORef saved
    secondDeadline <- limit 2000000
    second <- queryRoughtimeOnce elapsedSample secondDeadline fixtureRoot 0 movement $ \_ ->
      maybe (ioError (userError "missing fixture reply")) pure old
    expectReadingError RoughtimeInvalidResponse second
  it "refuses a wrong server key, a changed packet, and an invalid key length" $ do
    deadline <- limit 2000000
    wrong <-
      queryRoughtimeOnce
        elapsedSample
        deadline
        (ByteString.replicate 32 0)
        0
        movement
        (pure . signedReply)
    expectReadingError RoughtimeInvalidResponse wrong
    deadline2 <- limit 2000000
    altered <-
      queryRoughtimeOnce
        elapsedSample
        deadline2
        fixtureRoot
        0
        movement
        (pure . ByteString.init . signedReply)
    expectReadingError RoughtimeInvalidResponse altered
    called <- newIORef False
    deadline3 <- limit 2000000
    invalid <- queryRoughtimeOnce elapsedSample deadline3 (ByteString.replicate 31 0) 0 movement $ \_ -> do
      writeIORef called True
      pure ByteString.empty
    expectReadingError RoughtimeInvalidRoot invalid
    readIORef called >>= (`shouldBe` False)
  it "bounds an interruptible exchange and classifies I/O failure" $ do
    deadline <- limit 300000
    timedOut <- queryRoughtimeOnce elapsedSample deadline fixtureRoot 0 movement $ \_ -> do
      threadDelay 1500000
      pure ByteString.empty
    expectReadingError RoughtimeExpired timedOut
    deadline2 <- limit 2000000
    unavailable <- queryRoughtimeOnce elapsedSample deadline2 fixtureRoot 0 movement $ \_ ->
      ioError (userError "offline")
    expectReadingError RoughtimeUnavailable unavailable
  it "propagates cancellation of an in-flight exchange" $ do
    deadline <- limit 2000000
    started <- newEmptyMVar
    done <- newEmptyMVar
    worker <-
      forkFinally
        ( queryRoughtimeOnce elapsedSample deadline fixtureRoot 0 movement $ \_ -> do
            putMVar started ()
            threadDelay 1500000
            pure ByteString.empty
        )
        (putMVar done)
    takeMVar started
    killThread worker
    result <- takeMVar done
    case result of
      Left exception -> fromException exception `shouldBe` Just ThreadKilled
      Right _ -> expectationFailure "cancellation was swallowed"
