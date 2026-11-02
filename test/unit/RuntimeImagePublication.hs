{-# LANGUAGE OverloadedStrings #-}

module RuntimeImagePublication (runtimeImagePublicationSuite) where

import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Infra.RuntimeImagePublication
import TestSupport

runtimeImagePublicationSuite :: SuiteBuilder ()
runtimeImagePublicationSuite =
  describe "HOME-RUNTIME-CRI-REFERENCE-PUBLICATION-2026-10-24" $ do
    it "keeps config-only import below runtime admission until an exact repository readback" $ do
      decideRuntimeImageReference expected configOnly `shouldBe` RuntimeReferenceNeedsFetch
      decideRuntimeImageReference expected ready `shouldSatisfy` isReady

    forM_
      [ ("foreign config", observation digestB [tag] [manifest], RuntimeCRIConfigMismatch)
      , ("missing tag", observation digestA [] [manifest], RuntimeCRITagBindingMismatch)
      ,
        ( "foreign tag"
        , observation digestA [repository ++ ":other"] [manifest]
        , RuntimeCRITagBindingMismatch
        )
      ,
        ( "foreign manifest"
        , observation digestA [tag] [repository ++ "@" ++ digestC]
        , RuntimeCRIReferenceMismatch
        )
      ,
        ( "ambiguous references"
        , observation digestA [tag] [manifest, repository ++ "@" ++ digestC]
        , RuntimeCRIReferenceAmbiguous
        )
      ,
        ( "malformed matching reference"
        , observation digestA [tag] [repository ++ "@private-invalid"]
        , RuntimeCRIMalformed
        )
      ]
      $ \(name, observed, cause) ->
        it ("refuses " ++ name ++ " without admitting a worker") $
          decideRuntimeImageReference expected observed `shouldBe` RuntimeReferenceRefused cause

    it "ignores unrelated repositories and admits duplicate observations of the same exact reference" $ do
      decideRuntimeImageReference
        expected
        (observation digestA [tag] [manifest, manifest, "other.invalid/image@" ++ digestC])
        `shouldSatisfy` isReady

    forM_
      [ ("missing manifest", tag, "[]", manifestBody, RuntimeManifestMissing)
      ,
        ( "ambiguous manifest"
        , tag
        , show [manifest, repository ++ "@" ++ digestC]
        , manifestBody
        , RuntimeManifestAmbiguous
        )
      ,
        ( "malformed manifest inventory"
        , tag
        , "private-body"
        , manifestBody
        , RuntimeManifestObservationInvalid
        )
      , ("null manifest inventory", tag, "null", manifestBody, RuntimeManifestObservationInvalid)
      ,
        ( "malformed matching digest"
        , tag
        , show [repository ++ "@private-invalid"]
        , manifestBody
        , RuntimeManifestObservationInvalid
        )
      , ("foreign image", "other.invalid/image:tag", show [manifest], manifestBody, RuntimeImageTagInvalid)
      , ("empty tag", repository ++ ":", show [manifest], manifestBody, RuntimeImageTagInvalid)
      ,
        ( "invalid tag start"
        , repository ++ ":-invalid"
        , show [manifest]
        , manifestBody
        , RuntimeImageTagInvalid
        )
      ,
        ( "invalid config pointer"
        , tag
        , show [manifest]
        , manifestFor "private-config"
        , RuntimeManifestConfigInvalid
        )
      , ("unreadable descriptor", tag, show [manifest], "private-body", RuntimeManifestBodyInvalid)
      ,
        ( "wrong descriptor digest"
        , tag
        , show [repository ++ "@" ++ digestB]
        , manifestBody
        , RuntimeManifestDigestMismatch
        )
      ]
      $ \(name, reference, manifests, body, cause) ->
        it ("rejects expectation " ++ name ++ " before effects") $
          decodeRuntimeImageExpectation reference manifests body `shouldBe` Left cause

    it "obtains config identity from the verified manifest rather than a Docker-local token" $ do
      runtimeImageConfigDigest expected `shouldBe` digestA
      runtimeImageManifestReference expected `shouldBe` manifest
      decodeRuntimeRegistryReference tag (show [manifest]) `shouldSatisfy` isRight

    forM_
      [ ("opaque body", "private-body")
      , ("missing status", "{}")
      , ("null status", "{\"status\":null}")
      , ("invalid config", "{\"status\":{\"id\":\"private\",\"repoTags\":[],\"repoDigests\":[]}}")
      ]
      $ \(name, body) ->
        it ("never interprets " ++ name ++ " as absent references") $
          decodeRuntimeImageObservation body `shouldBe` Left RuntimeCRIMalformed

    it "admits an already current image without another fetch" $ do
      (result, events) <- runFixture [Right ready] [] RuntimeManifestFetched
      result `shouldSatisfy` isRight
      events `shouldBe` [ImageRead BeforeManifestRegistration]

    forM_ [RuntimeManifestFetched, RuntimeManifestFetchExited 1, RuntimeManifestFetchUnobservable] $ \reply ->
      it ("requires closing proof after " ++ show reply) $ do
        (result, events) <- runFixture [Right configOnly] [Right ready] reply
        result `shouldSatisfy` isRight
        events
          `shouldBe` [ImageRead BeforeManifestRegistration, ManifestFetch, ImageRead AfterManifestRegistration]

    it "waits through a delayed CRI reference event without a second fetch" $ do
      (result, events) <-
        runFixture [Right configOnly] [Right configOnly, Right ready] RuntimeManifestFetched
      result `shouldSatisfy` isRight
      events
        `shouldBe` [ ImageRead BeforeManifestRegistration
                   , ManifestFetch
                   , ImageRead AfterManifestRegistration
                   , ReadRetry
                   , ImageRead AfterManifestRegistration
                   ]

    it "never admits from fetch acknowledgement without a closing reference" $ do
      (result, events) <-
        runFixture [Right configOnly] (replicate 3 (Right configOnly)) RuntimeManifestFetched
      result
        `shouldBe` Left (RuntimeRegistrationNotProven RuntimeManifestFetched RuntimeCRIReferenceNotVisible)
      length [() | ManifestFetch <- events] `shouldBe` 1
      length [() | ImageRead AfterManifestRegistration <- events] `shouldBe` 3

    forM_ [RuntimeCRIUnavailable, RuntimeCRIDeadlineElapsed, RuntimeCRIMalformed] $ \cause ->
      it ("preserves unresolved closing " ++ show cause) $ do
        (result, events) <-
          runFixture [Right configOnly] (replicate 3 (Left cause)) RuntimeManifestFetchUnobservable
        result `shouldBe` Left (RuntimeRegistrationNotProven RuntimeManifestFetchUnobservable cause)
        length [() | ManifestFetch <- events] `shouldBe` 1

    forM_
      [ (Left RuntimeCRIUnavailable, RuntimeCRIUnavailable)
      , (Left RuntimeCRIMalformed, RuntimeCRIMalformed)
      , (Right (observation digestB [tag] [manifest]), RuntimeCRIConfigMismatch)
      , (Right (observation digestA [] [manifest]), RuntimeCRITagBindingMismatch)
      , (Right (observation digestA [tag] [repository ++ "@" ++ digestC]), RuntimeCRIReferenceMismatch)
      ]
      $ \(sample, cause) ->
        it ("refuses initial " ++ show cause ++ " without fetching") $ do
          (result, events) <- runFixture (replicate 3 sample) [] RuntimeManifestFetched
          result `shouldBe` Left (RuntimeObservationRefused BeforeManifestRegistration cause)
          [() | ManifestFetch <- events] `shouldBe` []
          length events `shouldBe` 5

    it "stops on an exhausted parent deadline without another delay or fetch" $ do
      (result, events) <- runFixture [Left RuntimeCRIDeadlineElapsed] [] RuntimeManifestFetched
      result
        `shouldBe` Left (RuntimeObservationRefused BeforeManifestRegistration RuntimeCRIDeadlineElapsed)
      events `shouldBe` [ImageRead BeforeManifestRegistration]

    it "restores observable initial state within the same finite read window" $ do
      (result, events) <-
        runFixture [Left RuntimeCRIUnavailable, Right configOnly] [Right ready] RuntimeManifestFetched
      result `shouldSatisfy` isRight
      events
        `shouldBe` [ ImageRead BeforeManifestRegistration
                   , ReadRetry
                   , ImageRead BeforeManifestRegistration
                   , ManifestFetch
                   , ImageRead AfterManifestRegistration
                   ]

    it "refuses a foreign closing config even after a successful fetch" $ do
      (result, _) <-
        runFixture
          [Right configOnly]
          (replicate 3 (Right (observation digestB [tag] [manifest])))
          RuntimeManifestFetched
      result
        `shouldBe` Left (RuntimeRegistrationNotProven RuntimeManifestFetched RuntimeCRIConfigMismatch)

    it "keeps provider bodies out of its closed refusal rendering" $ do
      let decoded = decodeRuntimeImageObservation "private-provider-body"
      decoded `shouldSatisfy` isLeft
      renderRuntimePublicationError
        (RuntimeObservationRefused BeforeManifestRegistration RuntimeCRIMalformed)
        `shouldNotContain` "private-provider-body"

data Event = ImageRead RuntimeReadPhase | ManifestFetch | ReadRetry
  deriving (Eq, Show)

runFixture
  :: [Either RuntimeReadFailure RuntimeImageObservation]
  -> [Either RuntimeReadFailure RuntimeImageObservation]
  -> RuntimeManifestFetchResult
  -> IO (Either RuntimePublicationError RuntimePublicationReady, [Event])
runFixture initial closing reply = do
  before <- newIORef initial
  after <- newIORef closing
  events <- newIORef []
  let record event = modifyIORef' events (++ [event])
      observe phase = do
        record (ImageRead phase)
        let selected = case phase of
              BeforeManifestRegistration -> before
              AfterManifestRegistration -> after
        remaining <- readIORef selected
        case remaining of
          [] -> pure (Left RuntimeCRIUnavailable)
          first : rest -> modifyIORef' selected (const rest) >> pure first
      effects =
        RuntimePublicationEffects
          { observeRuntimeImage = observe
          , fetchRuntimeManifest = \_ -> record ManifestFetch >> pure reply
          , waitBeforeRuntimeReadRetry = record ReadRetry
          }
  result <- reconcileRuntimeImageReference effects expected
  recorded <- readIORef events
  pure (result, recorded)

isReady :: RuntimeReferenceDecision -> Bool
isReady decision = case decision of
  RuntimeReferenceReady _ -> True
  RuntimeReferenceNeedsFetch -> False
  RuntimeReferenceRefused _ -> False

expected :: RuntimeImageExpectation
expected = mustRight (decodeRuntimeImageExpectation tag (show [manifest]) manifestBody)

configOnly, ready :: RuntimeImageObservation
configOnly = observation digestA [tag] []
ready = observation digestA [tag] [manifest]

observation :: String -> [String] -> [String] -> RuntimeImageObservation
observation config tags references =
  mustRight . decodeRuntimeImageObservation . LazyByteString.toStrict . encode $
    object ["status" .= object ["id" .= config, "repoTags" .= tags, "repoDigests" .= references]]

repository, tag, manifest, digestA, digestB, digestC :: String
repository = ContainerImage.harborRuntimeImageRepository
tag = repository ++ ":prodbox-fixture"
manifest = repository ++ "@sha256:" ++ ByteStringChar8.unpack (hexSha256 manifestBody)
digestA = "sha256:" ++ replicate 64 'a'
digestB = "sha256:" ++ replicate 64 'b'
digestC = "sha256:" ++ replicate 64 'c'

manifestBody :: ByteString
manifestBody = manifestFor digestA

manifestFor :: String -> ByteString
manifestFor config =
  LazyByteString.toStrict . encode $
    object
      [ "schemaVersion" .= (2 :: Int)
      , "mediaType" .= ("application/vnd.oci.image.manifest.v1+json" :: String)
      , "config"
          .= object
            [ "mediaType" .= ("application/vnd.oci.image.config.v1+json" :: String)
            , "digest" .= config
            ]
      ]

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
