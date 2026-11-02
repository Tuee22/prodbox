{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AuthenticatedRequestFootprint (authenticatedRequestFootprintTests) where

import AuthenticatedRequestFixture
import Codec.CBOR.Read qualified as CborRead
import Codec.CBOR.Term qualified as Term
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isRight)
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.CallerPrincipal
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.Runtime.Role
import Test.Tasty
import Test.Tasty.HUnit

roomy :: AuthenticatedTransportBounds
roomy = must (mkAuthenticatedTransportBounds 4194304 4096 4194304)

capability :: WireContext -> RequestSigningCapability IO
capability = localRequestSigningCapability . wireSigner

footprint :: WireContext -> Bytes.ByteString -> AuthenticatedRequestFootprint
footprint context body =
  must
    ( authenticatedRequestFootprint
        roomy
        (capability context)
        LifecycleProviderDispatch
        LifecycleAuthorityRuntime
        (wireScope context)
        (wireEpoch context)
        (wireDeadline context)
        (wireNonce context)
        (fromIntegral (Bytes.length body))
    )

checkActualFrame :: WireContext -> Bytes.ByteString -> IO ()
checkActualFrame context body = do
  let sizes = footprint context body
  (result, _, frames, claims) <- captureWireDetailed roomy context False body
  assertBool "fitting request was refused" (isRight result)
  encoded <- case frames of [value] -> pure value; _ -> assertFailure "one request required"
  signed <- case claims of [value] -> pure value; _ -> assertFailure "one signature required"
  (trailing, term) <-
    either
      (assertFailure . show)
      pure
      (CborRead.deserialiseFromBytes Term.decodeTerm (Lazy.fromStrict encoded))
  trailing @?= Lazy.empty
  outer <- case term of Term.TList values -> pure values; _ -> assertFailure "canonical frame is not a list"
  (metadata, envelope) <- case [value | Term.TBytes value <- outer] of
    [first, second] -> pure (first, second)
    _ -> assertFailure "the frame must have exactly its metadata and envelope byte fields"
  authenticatedSigningClaimsBytes sizes @?= fromIntegral (Bytes.length signed)
  authenticatedMetadataBytes sizes @?= fromIntegral (Bytes.length metadata)
  authenticatedEnvelopeBytes sizes @?= fromIntegral (Bytes.length envelope)
  authenticatedRequestFrameBytes sizes @?= fromIntegral (Bytes.length encoded)
  verifyCapturedWire roomy context encoded >>= (@?= Right body)

authenticatedRequestFootprintTests :: TestTree
authenticatedRequestFootprintTests =
  testGroup
    "canonical request footprint"
    [ testGroup
        "every route and principal retains the actual signed-envelope size"
        [ testCase (show route <> "/" <> show principal) $ do
            let context = wireContext principal 1 1 32
                body = Bytes.replicate 23 17
                role = controlPlaneRouteRole route
                sizes =
                  must
                    ( requestSigningFootprint
                        (capability context)
                        route
                        role
                        (wireScope context)
                        (wireEpoch context)
                        (wireDeadline context)
                        (wireNonce context)
                        (fromIntegral (Bytes.length body))
                    )
                signed =
                  must
                    ( signControlPlaneRequest
                        (wireSigner context)
                        route
                        role
                        (wireScope context)
                        (wireEpoch context)
                        (wireDeadline context)
                        (wireNonce context)
                        body
                    )
            requestSigningEnvelopeEncodedBytes sizes
              @?= fromIntegral (Lazy.length (encodeSignedControlPlaneRequest signed))
        | route <- allControlPlaneRoutes
        , principal <- allCallerPrincipals
        ]
    , testGroup
        "body/header transitions and the full two-MiB body"
        [ testCase
            (show count)
            (checkActualFrame (wireContext CallerOperatorCli 1 1 32) (Bytes.replicate count 17))
        | count <- [0, 1, 23, 24, 255, 256, 65535, 65536, 2097152]
        ]
    , testGroup
        "nonce and natural-number metadata widths"
        [ testCase
            (show (nonceBytes, value))
            (checkActualFrame (wireContext CallerOperatorCli value value nonceBytes) "body")
        | nonceBytes <- [16, 23, 24, 64]
        , value <- [1, 23, 24, 255, 256, 2 ^ (64 :: Int) - 1, 2 ^ (64 :: Int), 2 ^ (512 :: Int)]
        ]
    , testCase "an exact full-body budget admits once and each one-byte shortage refuses before signing" $ do
        let context = wireContext CallerOperatorCli 1 1 64
            body = Bytes.replicate 2097152 17
            sizes = footprint context body
            frame = fromIntegral (authenticatedRequestFrameBytes sizes)
            metadata = fromIntegral (authenticatedMetadataBytes sizes)
            envelope = fromIntegral (authenticatedEnvelopeBytes sizes)
            exact = must (mkAuthenticatedTransportBounds frame metadata envelope)
        (result, events, frames) <- captureWire exact context False body
        assertBool "the exact budget did not fit" (isRight result)
        length (filter (== "signature") events) @?= 1
        length frames @?= 1
        forM_
          [(frame - 1, metadata, envelope), (frame, metadata - 1, envelope), (frame, metadata, envelope - 1)]
          $ \(a, b, c) -> do
            let tooSmall = must (mkAuthenticatedTransportBounds a b c)
            (rejected, seen, sent) <- captureWire tooSmall context False body
            assertBool "a one-byte shortage reached a signature" ("signature" `notElem` seen)
            sent @?= []
            case rejected of
              Left AuthenticatedClientFrameFailed {} -> pure ()
              _ -> assertFailure "missing frame refusal"
    , testCase "a machine-word body size is measured without allocating or wrapping it" $ do
        let context = wireContext CallerOperatorCli 1 1 32
            count = maxBound :: Word
            sizes =
              must
                ( requestSigningFootprint
                    (capability context)
                    LifecycleProviderDispatch
                    LifecycleAuthorityRuntime
                    (wireScope context)
                    (wireEpoch context)
                    (wireDeadline context)
                    (wireNonce context)
                    count
                )
        assertBool
          "the complete size wrapped its body"
          (requestSigningEnvelopeEncodedBytes sizes > fromIntegral count)
        case authenticatedRequestFootprint
          roomy
          (capability context)
          LifecycleProviderDispatch
          LifecycleAuthorityRuntime
          (wireScope context)
          (wireEpoch context)
          (wireDeadline context)
          (wireNonce context)
          count of
          Left (AuthenticatedClientFrameFailed (AuthenticatedPredictedEnvelopeTooLarge actual _)) ->
            actual @?= requestSigningEnvelopeEncodedBytes sizes
          _ -> assertFailure "out-of-range length escaped the envelope guard"
    ]
