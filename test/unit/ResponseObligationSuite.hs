{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.60: an accepted connection is answered, or the attempt fails
-- loudly. These cases are the behavioural half — the type-level half is that
-- the handler returns @reply@, not @()@.
module ResponseObligationSuite (responseObligationSuite) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, throwIO, toException, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.IORef (modifyIORef', newIORef, readIORef)
import Network.Socket
  ( Family (AF_UNIX)
  , Socket
  , SocketType (Stream)
  , close
  , defaultProtocol
  , socketPair
  , withSocketsDo
  )
import Network.Socket.ByteString (recv)
import Prodbox.CheckCode (responseObligationViolations)
import Prodbox.ControlPlane.Server (renderHttpResponse)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Http.ResponseObligation
import System.Timeout (timeout)
import TestSupport

responseObligationSuite :: SuiteBuilder ()
responseObligationSuite =
  describe "Sprint 4.60 response obligation" $ do
    it "answers a throwing handler with a complete 500 instead of zero bytes" $ do
      -- The defect, negated: before this, the exception escaped before any byte
      -- was written and the peer saw a bare close.
      answered <- runObligation (throwIO (userError "interpreter exploded"))
      Char8.unpack answered `shouldContain` "HTTP/1.1 500 Internal Server Error"
      Char8.unpack answered `shouldContain` "internal-error"
      declaredLengthMatches answered `shouldBe` True

    it "answers a bottom inside the reply body, not only a throwing handler" $ do
      -- `renderHttpResponse` forces the body to compute Content-Length, so the
      -- thunk is evaluated somewhere regardless; this proves it is evaluated
      -- inside the guarded region rather than past it.
      answered <- runObligation (pure (ReplyOk, error "bad body"))
      Char8.unpack answered `shouldContain` "HTTP/1.1 500 Internal Server Error"

    it "falls back to the last-resort reply when the refusal renderer itself bottoms" $ do
      let brokenObligation =
            mkResponseObligation
              (uncurry renderHttpResponse)
              (\_ -> error "refusal renderer is broken")
              (\_ -> pure ())
              responseWriteBudgetMicrosDefault
      answered <- runWith brokenObligation (throwIO (userError "boom"))
      answered `shouldBe` lastResortInternalError

    it "Sprint 4.65: a refusal is observed with its structured reason" $ do
      -- Sprint 4.60 made the reply obligatory and left the reason nowhere: the
      -- production body deliberately carries no exception text, so a `500` was
      -- the whole surviving record of a handler failure.
      seen <- newIORef ([] :: [String])
      let observing =
            mkResponseObligation
              (uncurry renderHttpResponse)
              refusalReply
              (\refusal -> modifyIORef' seen (++ [renderResponseRefusalReason refusal]))
              responseWriteBudgetMicrosDefault
      answered <- runWith observing (throwIO (userError "interpreter exploded"))
      Char8.unpack answered `shouldContain` "HTTP/1.1 500 Internal Server Error"
      -- The wire still says nothing about why; the observer says everything.
      Char8.unpack answered `shouldNotContain` "interpreter exploded"
      recorded <- readIORef seen
      length recorded `shouldBe` 1
      concat recorded `shouldContain` "handler-failed"
      concat recorded `shouldContain` "interpreter exploded"

    it "Sprint 4.65: a broken observer costs the reason, never the reply" $ do
      -- The observer is caller-supplied code on the one path whose entire
      -- purpose is that nothing prevents the reply. A throw must be swallowed.
      let throwingObserver =
            mkResponseObligation
              (uncurry renderHttpResponse)
              refusalReply
              (\_ -> throwIO (userError "logger is broken"))
              responseWriteBudgetMicrosDefault
      answered <- runWith throwingObserver (throwIO (userError "interpreter exploded"))
      Char8.unpack answered `shouldContain` "HTTP/1.1 500 Internal Server Error"
      Char8.unpack answered `shouldContain` "internal-error"
      declaredLengthMatches answered `shouldBe` True

    it "Sprint 4.65: the recorded reason is bounded" $ do
      -- An exception's rendering can quote its input, so an unbounded reason is
      -- an unbounded write to the log stream from the request path.
      let reason =
            renderResponseRefusalReason
              (ResponseHandlerFailed (toException (userError (replicate 4096 'x'))))
      length reason `shouldSatisfy` (<= 512 + length ("handler-failed: " :: String))

    it "keeps the last-resort reply self-consistent" $
      -- It is a hand-written literal, so its declared length is the one thing
      -- that can silently rot.
      declaredLengthMatches lastResortInternalError `shouldBe` True

    it "answers a normal reply byte-exactly as renderHttpResponse would" $ do
      answered <- runObligation (pure (ReplyOk, "live\n"))
      answered `shouldBe` renderHttpResponse ReplyOk "live\n"

    it "does not throw when the peer closed first" $ do
      outcome <- withSocketsDo $ do
        (writer, reader) <- socketPair AF_UNIX Stream defaultProtocol
        close reader
        result <-
          try (withResponseObligation testObligation writer (pure (ReplyOk, "live\n")))
            :: IO (Either SomeException ())
        close writer
        pure result
      case outcome of
        Right () -> pure ()
        Left err -> expectationFailure ("expected a silent give-up, got: " <> show err)

    it "does not convert a timeout into a reply, so an enclosing deadline still fires" $ do
      -- `System.Timeout.Timeout` is an asynchronous exception. Converting it to
      -- a 500 would send a reply AND make this `timeout` return `Just ()`,
      -- defeating any deadline composed around the obligation.
      elapsed <- withSocketsDo $ do
        (writer, reader) <- socketPair AF_UNIX Stream defaultProtocol
        result <-
          timeout
            50000
            ( withResponseObligation
                testObligation
                writer
                (threadDelay 5000000 >> pure (ReplyOk, "never\n"))
            )
        close writer
        close reader
        pure result
      elapsed `shouldBe` Nothing

    it "refuses a governed server that brings the raw socket write into scope" $ do
      let helper = helperModule
          governed extra =
            [ ("src/Prodbox/Http/ResponseObligation.hs", Just helper)
            , ("src/Prodbox/ControlPlane/Runtime.hs", Just (serverModule extra))
            ]
      responseObligationViolations (governed "import Network.Socket.ByteString (recv)\n")
        `shouldBe` []
      length
        (responseObligationViolations (governed "import Network.Socket.ByteString (recv, sendAll)\n"))
        `shouldBe` 1
      length
        (responseObligationViolations (governed "import Network.Socket.ByteString (send)\n"))
        `shouldBe` 1
      -- A qualified alias reaches every write name at once, so it is refused
      -- even though no write name appears on the line.
      length
        ( responseObligationViolations
            (governed "import Network.Socket.ByteString qualified as SocketBS\n")
        )
        `shouldBe` 1
      -- A lookalike identifier is not a raw write.
      responseObligationViolations
        (governed "import Network.Socket.ByteString (recv)\n-- sendAllPending is fine\n")
        `shouldBe` []

    it "refuses a helper or a server that stops being what the gate protects" $ do
      let server = serverModule "import Network.Socket.ByteString (recv)\n"
          pair helper =
            [ ("src/Prodbox/Http/ResponseObligation.hs", Just helper)
            , ("src/Prodbox/ControlPlane/Runtime.hs", Just server)
            ]
      -- A wrapped signature still counts as a definition: the gate must survive
      -- the formatter reflowing the module it protects.
      responseObligationViolations (pair helperModule) `shouldBe` []
      length
        (responseObligationViolations (pair (dropLineContaining "withResponseObligation" helperModule)))
        `shouldSatisfy` (>= 1)
      length
        (responseObligationViolations (pair (dropLineContaining "data ResponseRefusal" helperModule)))
        `shouldBe` 1
      -- A server that no longer routes through the helper would leave the gate
      -- passing vacuously.
      length
        ( responseObligationViolations
            [ ("src/Prodbox/Http/ResponseObligation.hs", Just helperModule)
            , ("src/Prodbox/ControlPlane/Runtime.hs", Just "import Network.Socket.ByteString (recv)\n")
            ]
        )
        `shouldBe` 1
      length
        ( responseObligationViolations
            [("src/Prodbox/Http/ResponseObligation.hs", Nothing)]
        )
        `shouldBe` 1

-- | The helper module as it actually stands, formatter-wrapped signatures and
-- all.
helperModule :: String
helperModule =
  unlines
    [ "data ResponseRefusal"
    , "  = ResponseHandlerFailed !SomeException"
    , "  | ResponseCancelled !SomeException"
    , ""
    , "mkResponseObligation"
    , "  :: (reply -> ByteString)"
    , "  -> (ResponseRefusal -> reply)"
    , "  -> (ResponseRefusal -> IO ())"
    , "  -> Int"
    , "  -> ResponseObligation reply"
    , "mkResponseObligation render refusal observe budgetMicros ="
    , "  ResponseObligation"
    , ""
    , "withResponseObligation"
    , "  :: ResponseObligation reply"
    , "  -> Socket"
    , "  -> IO reply"
    , "  -> IO ()"
    , "withResponseObligation obligation client handler ="
    , "  mask $ \\restore -> do"
    ]

serverModule :: String -> String
serverModule importLine =
  importLine
    <> unlines
      [ "serveControlPlaneConnection activeRole interpreter client ="
      , "  withResponseObligation controlPlaneResponseObligation client $ do"
      ]

dropLineContaining :: String -> String -> String
dropLineContaining needle = unlines . filter (not . isInfixOfSimple needle) . lines

isInfixOfSimple :: String -> String -> Bool
isInfixOfSimple needle haystack =
  any (startsWith needle) (suffixes haystack)
 where
  suffixes value = case value of
    [] -> [[]]
    _ : rest -> value : suffixes rest
  startsWith [] _ = True
  startsWith _ [] = False
  startsWith (x : xs) (y : ys) = x == y && startsWith xs ys

testObligation :: ResponseObligation (ReplyStatus, ByteString)
testObligation =
  mkResponseObligation
    (uncurry renderHttpResponse)
    refusalReply
    (\_ -> pure ())
    responseWriteBudgetMicrosDefault

refusalReply :: ResponseRefusal -> (ReplyStatus, ByteString)
refusalReply refusal = case refusal of
  ResponseHandlerFailed _ -> (ReplyInternalError, "internal-error\n")
  ResponseCancelled _ -> (ReplyServiceUnavailable, "shutting-down\n")

runObligation :: IO (ReplyStatus, ByteString) -> IO ByteString
runObligation = runWith testObligation

-- | Drive one obligation over a socket pair and return every byte the peer saw.
runWith
  :: ResponseObligation (ReplyStatus, ByteString) -> IO (ReplyStatus, ByteString) -> IO ByteString
runWith obligation handler = withSocketsDo $ do
  (writer, reader) <- socketPair AF_UNIX Stream defaultProtocol
  void $ forkIO $ do
    _ <- try (withResponseObligation obligation writer handler) :: IO (Either SomeException ())
    close writer
  answered <- drain reader ByteString.empty
  close reader
  pure answered

drain :: Socket -> ByteString -> IO ByteString
drain connection accumulated = do
  chunk <- recv connection 4096
  if ByteString.null chunk
    then pure accumulated
    else drain connection (accumulated <> chunk)

-- | Does the response's declared @Content-Length@ equal its actual body length?
declaredLengthMatches :: ByteString -> Bool
declaredLengthMatches response =
  case breakOnBlankLine response of
    Nothing -> False
    Just (headerSection, body) ->
      case declaredContentLength headerSection of
        Nothing -> False
        Just declared -> declared == ByteString.length body

breakOnBlankLine :: ByteString -> Maybe (ByteString, ByteString)
breakOnBlankLine response =
  case ByteString.breakSubstring "\r\n\r\n" response of
    (headerSection, rest)
      | ByteString.null rest -> Nothing
      | otherwise -> Just (headerSection, ByteString.drop 4 rest)

declaredContentLength :: ByteString -> Maybe Int
declaredContentLength headerSection =
  case [ Char8.unpack (Char8.dropWhile (== ' ') (Char8.drop 15 headerLine))
       | headerLine <- Char8.lines headerSection
       , "Content-Length:" `ByteString.isPrefixOf` headerLine
       ] of
    [value] -> parseDecimal (takeWhile (/= '\r') value)
    _ -> Nothing

parseDecimal :: String -> Maybe Int
parseDecimal value = case reads value of
  [(parsed, "")] -> Just parsed
  _ -> Nothing
