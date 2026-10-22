{-# LANGUAGE OverloadedStrings #-}

module KeycloakInviteHttp (keycloakInviteHttpSuite) where

import Data.ByteString.Char8 qualified as BS8
import Data.Either (isLeft)
import Data.IORef
import Prodbox.Error (fatalError)
import Prodbox.Keycloak.InviteHttp
import Prodbox.Subprocess
import System.Exit
import TestSupport

keycloakInviteHttpSuite :: SuiteBuilder ()
keycloakInviteHttpSuite = describe "Sprint 5.53 confidential invite KeycloakInviteHttp" $ do
  it "puts URL and form only on bounded stdin, not argv or rendered request" $ do
    calls <- newIORef (0 :: Int)
    let request = must (mkInviteHttpRequest host link (Just passwordForm))
        runner limits input spec = do
          modifyIORef' calls (+ 1)
          unwords (subprocessArguments spec) `shouldNotContain` link
          unwords (subprocessArguments spec) `shouldNotContain` passwordForm
          BS8.unpack input `shouldContain` link
          BS8.unpack input `shouldContain` passwordForm
          boundedSubprocessMaximumInputBytes limits `shouldBe` 65536
          boundedSubprocessTimeoutMicros limits `shouldBe` 30000000
          take 1 (subprocessArguments spec) `shouldBe` ["--disable"]
          pure (Right (ProcessOutput ExitSuccess "" ""))
    show request `shouldBe` "<invite-http-request>"
    runInviteHttpWith runner "." "/tmp/cookies" "/tmp/body" request `shouldReturn` Right ()
    readIORef calls `shouldReturn` 1
  it "never includes child stdout, stderr, request, or process error in a failure" $ do
    let request = must (mkInviteHttpRequest host link Nothing)
        runner _ _ _ = pure (Right (ProcessOutput (ExitFailure 22) link passwordForm))
        failed _ _ _ = pure (Left (fatalError "fixture-one-time-secret"))
    runInviteHttpWith runner "." "/tmp/cookies" "/tmp/body" request
      `shouldReturn` Left "invite HTTP request failed"
    runInviteHttpWith failed "." "/tmp/cookies" "/tmp/body" request
      `shouldReturn` Left "invite HTTP request did not complete within its process bounds"
  it "refuses plaintext, foreign authority, credentials, non-HTTPS ports, and injected config lines" $
    mapM_
      (\url -> mkInviteHttpRequest host url Nothing `shouldSatisfy` isLeft)
      [ "http://auth.example.test/a"
      , "https://evil.example.test/a"
      , "https://auth.example.test.evil/a"
      , "https://user@auth.example.test/a"
      , "https://auth.example.test:8443/a"
      , "https://auth.example.test?x=/a"
      , "https://auth.example.test/a\nurl = evil"
      ]
  it "accepts only the configured public host with its default HTTPS port" $ do
    mkInviteHttpRequest host "https://AUTH.example.test:443/path" Nothing `shouldSatisfy` (not . isLeft)
    mkInviteHttpRequest "*" link Nothing `shouldSatisfy` isLeft
  it "refuses a request beyond its stdin bound or a control-bearing form" $ do
    mkInviteHttpRequest host link (Just (replicate 65536 'a')) `shouldSatisfy` isLeft
    mkInviteHttpRequest host link (Just "password=a\nurl=evil") `shouldSatisfy` isLeft
  it "treats an at-prefixed form as literal data rather than a host-file request" $ do
    let request = must (mkInviteHttpRequest host link (Just "@/fixture-private-file"))
        runner _ input _ = do
          BS8.unpack input `shouldContain` "data-raw = \"@/fixture-private-file\""
          BS8.unpack input `shouldNotContain` "data-binary"
          pure (Right (ProcessOutput ExitSuccess "" ""))
    runInviteHttpWith runner "." "/tmp/cookies" "/tmp/body" request `shouldReturn` Right ()
  it "escapes quote and backslash inside curl's quoted config fields" $ do
    let request = must (mkInviteHttpRequest host link (Just "password=quote\"slash\\"))
        runner _ input _ = do
          BS8.unpack input `shouldContain` "data-raw = \"password=quote\\\"slash\\\\\""
          pure (Right (ProcessOutput ExitSuccess "" ""))
    runInviteHttpWith runner "." "/tmp/cookies" "/tmp/body" request `shouldReturn` Right ()

host, link, passwordForm :: String
host = "auth.example.test"
link = "https://auth.example.test/realms/prodbox/login-actions/action-token?key=fixture-one-time-secret"
passwordForm = "password=fixture-invite-password"
must :: (Show e) => Either e a -> a
must = either (error . show) id
