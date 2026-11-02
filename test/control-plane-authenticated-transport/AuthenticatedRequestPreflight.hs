{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AuthenticatedRequestPreflight (authenticatedRequestPreflightTests) where

import AuthenticatedRequestFixture
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft, isRight)
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.CallerPrincipal
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.Runtime.Role
import Test.Tasty
import Test.Tasty.HUnit

context :: WireContext
context = wireContext CallerOperatorCli 1 1 32

bounds :: Int -> Int -> Int -> AuthenticatedTransportBounds
bounds frame metadata envelope = must (mkAuthenticatedTransportBounds frame metadata envelope)

roomy :: AuthenticatedTransportBounds
roomy = bounds 4194304 4096 4194304

refusedBeforeSigning
  :: String -> AuthenticatedTransportBounds -> Bytes.ByteString -> Bool -> TestTree
refusedBeforeSigning label selected body noProviders = testCase label $ do
  (result, events, frames) <- captureWire selected context False body
  assertBool "the packet must be refused" (isLeft result)
  assertBool "a rejected frame entered the signing capability" ("signature" `notElem` events)
  frames @?= []
  if noProviders
    then events @?= []
    else events @?= ["signer", "scope", "epoch", "deadline", "nonce"]

authenticatedRequestPreflightTests :: TestTree
authenticatedRequestPreflightTests =
  testGroup
    "authenticated request bounds precede signing"
    [ testGroup
        "rejection never signs or sends the request"
        [ refusedBeforeSigning "raw body cannot fit the frame" (bounds 1 256 65000) "body" True
        , refusedBeforeSigning "raw body cannot fit the envelope" (bounds 65536 256 1) "body" True
        , refusedBeforeSigning "metadata is too small" (bounds 65536 1 65000) "body" False
        , refusedBeforeSigning "envelope overhead is charged" (bounds 65536 256 1) "x" False
        , refusedBeforeSigning "outer frame overhead is charged" (bounds 1 256 65000) "x" False
        , testCase "the exact encoded envelope boundary is charged before signing" $ do
            let body = "bounded-body"
                signed =
                  must
                    ( signControlPlaneRequest
                        (wireSigner context)
                        LifecycleProviderDispatch
                        LifecycleAuthorityRuntime
                        (wireScope context)
                        (wireEpoch context)
                        (wireDeadline context)
                        (wireNonce context)
                        body
                    )
                size = fromIntegral (Lazy.length (encodeSignedControlPlaneRequest signed))
            (result, events, frames) <- captureWire (bounds 65536 256 (size - 1)) context False body
            assertBool "the envelope must be refused" (isLeft result)
            assertBool "an overflowing envelope was signed" ("signature" `notElem` events)
            frames @?= []
        , testCase "the exact outer-frame boundary is charged before signing" $ do
            let body = "bounded-body"
            (_, _, reference) <- captureWire roomy context False body
            encoded <- case reference of [value] -> pure value; _ -> assertFailure "reference frame missing"
            (result, events, frames) <-
              captureWire (bounds (Bytes.length encoded - 1) 256 65000) context False body
            assertBool "the frame must be refused" (isLeft result)
            assertBool "an overflowing frame was signed" ("signature" `notElem` events)
            frames @?= []
        ]
    , testGroup
        "accepted frames retain canonical bytes and server verification"
        [ testCase (show size) $ do
            let body = Bytes.replicate size 17
            (result, events, frames) <- captureWire roomy context False body
            assertBool "accepted request failed" (isRight result)
            length (filter (== "signature") events) @?= 1
            case frames of
              [encoded] -> do
                verifyCapturedWire roomy context encoded >>= (@?= Right body)
                Just (frameDigest encoded) @?= lookup size acceptedFrameDigests
              _ -> assertFailure "exactly one HTTP frame was required"
        | size <- [0, 1, 23, 24, 255, 256, 65535, 65536, 2097152]
        ]
    , testCase "a fitting frame still verifies its returned signature before HTTP" $ do
        (result, events, frames) <- captureWire roomy context True "body"
        assertBool "invalid signature accepted" (isLeft result)
        length (filter (== "signature") events) @?= 1
        frames @?= []
    ]

-- Preserved accepted bytes from the matched superseded implementation.
acceptedFrameDigests :: [(Int, String)]
acceptedFrameDigests =
  [ (0, "a3013ea04da0e7f1ccbc2298917f0109c7f283e8358ac6275394312ee9ff6933")
  , (1, "845c09b767bb6098be6ac914d42e23e101a057d98842b10de3ef07f18403637c")
  , (23, "8a57bffc1ce1a5ac3bb0bee0890cb52720326ef94d140f5b0339c7c5b990b784")
  , (24, "ce5c486218ed392c56523964e9baa710e834b24eb94cfbad797c57a42c0f539d")
  , (255, "2d2080bcacafb4f6942d5fe3b10a8ff9c7065601cfae6bcbea428e83983efdd7")
  , (256, "65226f067d9ec94dc68aa8d51935995a3c16adf42f6367e419e62728cbbf5795")
  , (65535, "508787484be00f6dd1b8d69d1109c8ab599888331044cf1f0fff6b185a8a8028")
  , (65536, "4e043e443246773f12976f73226ed16e858025c0735cd3c507c81340797a6e69")
  , (2097152, "b206946e56e9d9362b89ac373ee92e827e12c38e47f77c1ad74356edc9fad9bf")
  ]
