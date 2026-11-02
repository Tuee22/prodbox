{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Native descriptor/publication controls. No application or manager mutation.
module Main (main) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Chars
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft, isRight)
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.HostControllerInputs
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity qualified as I
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import Prodbox.Subprocess.SystemdProviderProfile qualified as Profile
import System.Directory
  ( createDirectory
  , doesFileExist
  , listDirectory
  , makeAbsolute
  , removeFile
  , renameFile
  )
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.Posix.Files (createLink, createSymbolicLink, fileMode, getFileStatus, setFileMode)
import System.Posix.User (getEffectiveUserID)

right :: (Show failure) => Either failure value -> IO value
right = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

main :: IO ()
main = do
  [supplied] <- getArgs
  directory <- makeAbsolute supplied
  setFileMode directory 0o700
  uid <- getEffectiveUserID
  started <- getMonotonicTimeNSec
  right
    =<< withSystemdBus
      (started + 10000000000)
      ("/run/user/" <> show uid <> "/bus")
      ( \connection -> do
          domain <- observeManagerDomain connection
          sender <- observeBusSender connection
          other <-
            lift $ withSystemdBus (started + 10000000000) ("/run/user/" <> show uid <> "/bus") observeBusSender
          lift $
            right
              =<< Provider.withQualifiedProvider
                connection
                ( \provider -> do
                    second <- right other
                    assert "different opened connections reused a sender" (sender /= second)
                    forM_ (zip [1 :: Int ..] controls) $ \(index, name) -> do
                      let root = directory </> name
                          configuration = root </> "settings.cbor"
                          request = root </> "request.cbor"
                      createDirectory root
                      setFileMode root 0o700
                      BS.writeFile configuration "private-config-leak-canary"
                      BS.writeFile request "private-request-leak-canary"
                      mapM_ (`setFileMode` 0o400) [configuration, request]
                      now <- getMonotonicTimeNSec
                      let work = now + if name == "historical" then 100000000 else 3000000000
                      window <-
                        maybe
                          (fail "window")
                          pure
                          ( I.hostExecutionWindow
                              (work + 500000000)
                              work
                              (work + 100000000)
                              (work + 200000000)
                              (work + 300000000)
                          )
                      key <-
                        maybe
                          (fail "key")
                          pure
                          ( I.hostExecutionKeyFromText
                              (replicate 62 'a' <> ["0123456789abcdef" !! (index `div` 16), "0123456789abcdef" !! (index `mod` 16)])
                          )
                      let path = hostControllerSubmissionPath request key
                          kind = case name of
                            "ordinary-roundtrip" -> I.OrdinaryCascadeController
                            "ordinary-schema" -> I.OrdinaryCascadeController
                            _ -> I.RpcBirthController
                          open = withHostControllerInputs work configuration request
                          publish inputs = registerHostControllerSubmission kind inputs key window domain sender provider
                          readBack = do
                            readEnd <- (+ 1000000000) <$> getMonotonicTimeNSec
                            readHostControllerSubmission readEnd request key
                          checked inputs = do
                            record <- right =<< publish inputs
                            assert
                              "record fingerprint differs from held files"
                              (hostControllerSubmissionFingerprint record == hostControllerInputFingerprint inputs)
                            assert
                              "record changed operation/domain/sender/window"
                              ( hostControllerSubmissionKey record == key
                                  && hostControllerSubmissionKind record == kind
                                  && hostControllerSubmissionWindow record == window
                                  && hostControllerSubmissionDomain record == domain
                                  && hostControllerSubmissionSender record == sender
                              )
                            let bytes = encodeHostControllerSubmission record
                            assert
                              "record includes payload bytes"
                              (all (not . (`BS.isInfixOf` bytes)) ["private-config-leak-canary", "private-request-leak-canary"])
                            assert "codec roundtrip changed metadata" (decodeHostControllerSubmission bytes == Right record)
                            pure record
                      case name of
                        "ordinary-roundtrip" -> do
                          record <- right =<< open checked
                          readRecord <- right =<< readBack
                          assert "ordinary read-back changed kind/provenance" (record == readRecord)
                          let field = Family.hostControllerSubmissionField readRecord
                              birth = Family.hostOperationField I.RpcBirthController key
                              roles = [minBound .. maxBound]
                          assert
                            "recovered ordinary field borrowed a registration unit"
                            ( null
                                ( filter
                                    (`elem` map (Family.hostOperationFieldUnitName birth) roles)
                                    (map (Family.hostOperationFieldUnitName field) roles)
                                )
                            )
                        "ordinary-schema" -> do
                          record <- right =<< open checked
                          let encoded = encodeHostControllerSubmission record
                              prefix = "prodbox-host-controller-submission/kind/v1\NUL"
                          payload <- maybe (fail "ordinary kind prefix missing") pure (BS.stripPrefix prefix encoded)
                          (version, kindTag, original) <- right (deserialiseOrFail (Lazy.fromStrict payload))
                          assert "ordinary kind version/tag changed" (version == (1 :: Word8) && kindTag == (1 :: Word8))
                          birth <- right (decodeHostControllerSubmission original)
                          assert
                            "ordinary wrapper relabelled historical bytes"
                            ( hostControllerSubmissionKind birth == I.RpcBirthController
                                && encodeHostControllerSubmission birth == original
                            )
                          forM_
                            [ prefix <> Lazy.toStrict (serialise (2 :: Word8, kindTag, original))
                            , prefix <> Lazy.toStrict (serialise (version, 0 :: Word8, original))
                            , prefix <> Lazy.toStrict (serialise (version, 2 :: Word8, original))
                            , prefix <> Lazy.toStrict (serialise (version, kindTag, encoded))
                            , encoded <> "\NUL"
                            ]
                            $ \invalid ->
                              assert
                                "ordinary schema admitted an unknown/nested/trailing identity"
                                (isLeft (decodeHostControllerSubmission invalid))
                        "roundtrip" -> do
                          record <- right =<< open checked
                          readRecord <- right =<< readBack
                          assert "read-back changed original provenance" (record == readRecord)
                          mode <- fileMode <$> getFileStatus path
                          assert "submission mode is not 0400" (mode .&. 0o7777 == 0o400)
                          forM_
                            [ BS.empty
                            , BS.take 1 (encodeHostControllerSubmission record)
                            , BS.init (encodeHostControllerSubmission record)
                            , encodeHostControllerSubmission record <> "\NUL"
                            , BS.replicate 65537 0
                            ]
                            $ \bytes ->
                              assert
                                "accepted malformed/trailing/oversized submission bytes"
                                (isLeft (decodeHostControllerSubmission bytes))
                        "independent-race" -> do
                          ready <- newEmptyMVar
                          go <- newEmptyMVar
                          let attempt = right =<< open (\inputs -> putMVar ready () >> takeMVar go >> publish inputs)
                          Async.withAsync attempt $ \first -> Async.withAsync attempt $ \secondAttempt -> do
                            takeMVar ready >> takeMVar ready
                            putMVar go () >> putMVar go ()
                            results <- sequence [Async.wait first, Async.wait secondAttempt]
                            assert "independent input leases both won publication" (length (filter isRight results) == 1)
                            assert
                              "race loser was not exclusive-exists"
                              (length (filter (== Left ControllerSubmissionExists) results) == 1)
                          void (right =<< readBack)
                        "legacy-schema" -> do
                          record <- right =<< open checked
                          (_, original, _) <- unwrap record
                          legacy <- right (decodeHostControllerSubmission original)
                          assert
                            "legacy decoder minted provider provenance"
                            (hostControllerSubmissionProvider legacy == Nothing)
                          assert "legacy bytes changed on roundtrip" (encodeHostControllerSubmission legacy == original)
                          refused <- Family.observeHostSubmissionCausalClosure connection legacy
                          assert
                            "legacy submission acquired a processing witness"
                            (case refused of Left Family.HostSubmissionUnqualified -> True; _ -> False)
                        "foreign-provider" -> do
                          record <- right =<< open checked
                          (version, original, binding) <- unwrap record
                          let reference = Profile.providerContractReference Profile.ProviderAmd64
                              (prefix, suffix) = BS.breakSubstring reference binding
                          assert "submission omitted its provider reference" (not (BS.null suffix))
                          let unknown = prefix <> BS.replicate 32 0 <> BS.drop 32 suffix
                          foreignRecord <- right (decodeHostControllerSubmission (wrap version original unknown))
                          refused <- Family.observeHostSubmissionCausalClosure connection foreignRecord
                          assert
                            "foreign provider reference acquired a processing witness"
                            (case refused of Left Family.HostSubmissionProviderMismatch -> True; _ -> False)
                        "foreign-domain" -> do
                          record <- right =<< open checked
                          (version, original, binding) <- unwrap record
                          let boot = Chars.pack (I.hostManagerBootId domain)
                              (prefix, suffix) = BS.breakSubstring boot original
                              changed = Chars.cons (if Chars.head boot == 'a' then 'b' else 'a') (BS.tail boot)
                          assert "submission omitted its original domain" (not (BS.null suffix))
                          foreignRecord <-
                            right
                              ( decodeHostControllerSubmission
                                  (wrap version (prefix <> changed <> BS.drop (BS.length boot) suffix) binding)
                              )
                          refused <- Family.observeHostSubmissionCausalClosure connection foreignRecord
                          assert
                            "foreign domain acquired a processing witness"
                            (case refused of Left Family.HostSubmissionProviderMismatch -> True; _ -> False)
                        "nested-schema" -> do
                          record <- right =<< open checked
                          (version, _, binding) <- unwrap record
                          assert
                            "nested schema was accepted"
                            ( isLeft
                                (decodeHostControllerSubmission (wrap version (encodeHostControllerSubmission record) binding))
                            )
                        "schema-version" -> do
                          record <- right =<< open checked
                          (_, original, binding) <- unwrap record
                          assert
                            "unknown schema version was accepted"
                            (isLeft (decodeHostControllerSubmission (wrap 3 original binding)))
                        "duplicate" ->
                          void $
                            right
                              =<< open
                                ( \inputs -> do
                                    void (checked inputs)
                                    duplicate <- publish inputs
                                    assert "existing record became a second attempt" (duplicate == Left ControllerSubmissionExists)
                                )
                        "partial" -> do
                          BS.writeFile path BS.empty
                          setFileMode path 0o400
                          result <- right =<< open publish
                          assert "partial publication was overwritten" (result == Left ControllerSubmissionExists)
                          assert "partial record decoded" . isLeft =<< readBack
                          bytes <- BS.readFile path
                          assert "partial record changed" (BS.null bytes)
                        "cancelled-after-publication" -> do
                          outcome <-
                            try (right =<< open (\inputs -> checked inputs >> throwIO ThreadKilled))
                              :: IO (Either SomeException ())
                          assert "cancellation was swallowed" (isLeft outcome)
                          void (right =<< readBack)
                        "closed-inputs" -> do
                          held <- right =<< open pure
                          refused <- publish held
                          assert "closed input lease published a record" (refused == Left ControllerInputsClosed)
                          assert "closed lease created a file" . not =<< doesFileExist path
                        "changed-inputs" ->
                          void $
                            right
                              =<< open
                                ( \inputs -> do
                                    setFileMode request 0o600
                                    BS.writeFile request "changed"
                                    refused <- publish inputs
                                    assert "changed inputs published provenance" (isLeft refused)
                                    assert "changed inputs created a file" . not =<< doesFileExist path
                                )
                        "historical" -> do
                          record <- right =<< open checked
                          threadDelay 650000
                          assert "historical read renewed or changed original clocks" . (== Right record) =<< readBack
                          expired <- readHostControllerSubmission work request key
                          assert "expired observation budget succeeded" (expired == Left ControllerInputsExpired)
                        "symlink" -> do
                          createSymbolicLink request path
                          refused <- right =<< open publish
                          assert "symlink was overwritten" (refused == Left ControllerSubmissionExists)
                          assert "reader followed symlink" . isLeft =<< readBack
                        "hardlink" -> do
                          void (right =<< open checked)
                          createLink path (path <> ".alias")
                          assert "reader accepted a hard-linked record" . isLeft =<< readBack
                        "writable" -> do
                          void (right =<< open checked)
                          setFileMode path 0o600
                          assert "reader accepted writable provenance" . isLeft =<< readBack
                        "foreign-request-path" -> do
                          void (right =<< open checked)
                          readEnd <- (+ 1000000000) <$> getMonotonicTimeNSec
                          refused <- readHostControllerSubmission readEnd (root </> "other-request") key
                          assert "record relabelled a request path" (refused == Left ControllerSubmissionMismatch)
                        "corrupt" -> do
                          void (right =<< open checked)
                          removeFile path
                          BS.writeFile path "corrupt"
                          setFileMode path 0o400
                          assert "reader accepted corrupt replacement" . isLeft =<< readBack
                        "descriptors" -> do
                          void (right =<< open checked)
                          before <- length <$> listDirectory "/proc/self/fd"
                          forM_ [1 .. 128 :: Int] $ \_ -> void (right =<< readBack)
                          after <- length <$> listDirectory "/proc/self/fd"
                          assert "historical reader leaked a descriptor" (before == after)
                        "linked-record-replacement" -> do
                          void (right =<< open checked)
                          renameFile path (path <> ".old")
                          createSymbolicLink (path <> ".old") path
                          assert "reader followed a replacement link" . isLeft =<< readBack
                        _ -> fail "unknown submission fixture"
                      putStrLn ("PASS " <> name)
                    putStrLn ("PASS all " <> show (length controls) <> " native submission controls")
                )
      )

controls :: [String]
controls =
  [ "roundtrip"
  , "ordinary-roundtrip"
  , "ordinary-schema"
  , "independent-race"
  , "legacy-schema"
  , "foreign-provider"
  , "foreign-domain"
  , "nested-schema"
  , "schema-version"
  , "duplicate"
  , "partial"
  , "cancelled-after-publication"
  , "closed-inputs"
  , "changed-inputs"
  , "historical"
  , "symlink"
  , "hardlink"
  , "writable"
  , "foreign-request-path"
  , "corrupt"
  , "descriptors"
  , "linked-record-replacement"
  ]

unwrap :: HostControllerSubmissionRecord -> IO (Word8, BS.ByteString, BS.ByteString)
unwrap record = do
  payload <-
    maybe
      (fail "qualified submission missing v2 prefix")
      pure
      (BS.stripPrefix "prodbox-host-controller-submission/v2\NUL" (encodeHostControllerSubmission record))
  either (fail . show) pure (deserialiseOrFail (Lazy.fromStrict payload))

wrap :: Word8 -> BS.ByteString -> BS.ByteString -> BS.ByteString
wrap version original binding =
  "prodbox-host-controller-submission/v2\NUL"
    <> Lazy.toStrict (serialise (version, original, binding))
