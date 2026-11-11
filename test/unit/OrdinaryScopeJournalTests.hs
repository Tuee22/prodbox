{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module OrdinaryScopeJournalTests (ordinaryScopeJournalSuite) where

import Codec.CBOR.Encoding (encodeListLen, encodeWord)
import Codec.CBOR.Term (Term (..))
import Codec.CBOR.Write (toStrictByteString)
import Codec.Serialise (deserialiseOrFail, encode, serialise)
import Control.Concurrent.Async (concurrently)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  , callerPrincipalCode
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.Teardown.OrdinaryScopeJournal
import System.Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Mem (performGC)
import System.Posix.Files (createSymbolicLink, setFileMode)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

ordinaryScopeJournalSuite :: SuiteBuilder ()
ordinaryScopeJournalSuite = describe "ordinary scope journal" $ do
  it "legacy product encoding stays exact across arbitrary-width logical values" $
    forM_ [1, 2 ^ (512 :: Int), 2 ^ (8192 :: Int)] $ \logical -> do
      let bytes = fixtureBytes logical logical (Bytes.replicate 32 7) (Bytes.replicate 32 9)
      binding <- right (decodeOrdinaryScopeBinding bytes)
      encodeOrdinaryScopeBinding binding @?= bytes
  it "all four String fields refuse malformed generalized UTF8" $
    forM_ [3, 9, 10, 11] $ \index ->
      forM_
        [ [0x80]
        , [0xc2]
        , [0xe0]
        , [0xf0]
        , [0xc0, 0xaf]
        , [0xe0, 0x80, 0x80]
        , [0xf0, 0x80, 0x80, 0x80]
        , [0xf4, 0x90, 0x80, 0x80]
        , [0xf5, 0x80, 0x80, 0x80]
        , [0xed, 0xa0]
        , [0xe1, 0x80, 0x41]
        ]
        $ \payload -> do
          bytes <- rewriteFixture index (const (TBytes (Bytes.pack payload)))
          assertBool "malformed scope String accepted" (isLeft (decodeOrdinaryScopeBinding bytes))
  it "valid UTF8 byte String fields retain canonicality refusal" $
    forM_ [3, 9, 10, 11] $ \index -> do
      bytes <- rewriteFixture index byteEncodedString
      assertBool "noncanonical scope String accepted" (isLeft (decodeOrdinaryScopeBinding bytes))
  it "scope product framing refuses unknown constructors and field counts" $ do
    let original = fixtureBytes 1 9000000000 (Bytes.replicate 32 7) (Bytes.replicate 32 9)
    decoded <- right (deserialiseOrFail (Lazy.fromStrict original))
    fields <- case decoded of
      TList values -> pure values
      _ -> fail "independent scope fixture is not a product"
    forM_ [TList (TInt 1 : drop 1 fields), TList (drop 1 fields), TList (fields <> [TNull])] $ \value ->
      assertBool
        "invalid scope product accepted"
        (isLeft (decodeOrdinaryScopeBinding (Lazy.toStrict (serialise value))))
  it "journal cannot be used after its owner exits" $ withFixture $ \(binding, root) -> do
    escaped <- right =<< withOrdinaryScopeJournal root pure
    prepareBoundOrdinaryScopeSubmission escaped binding (Bytes.replicate 64 97)
      >>= (@?= Left ScopeJournalClosed)
  it "journal replay survives a complete owner reopen" $ withFixture $ \(binding, root) -> do
    let operation journal = prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97)
    forM_ [1 :: Int .. 2] $ \_ -> do
      result <- right =<< withOrdinaryScopeJournal root operation
      result @?= Right Nothing
  it "competing program digests select one immutable winner" $ withFixture $ \(binding, root) -> do
    let operation value = withOrdinaryScopeJournal root $ \journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 value)
    (left, rightResult) <- concurrently (operation 97) (operation 98)
    a <- right left
    b <- right rightResult
    assertBool
      "two winners or an unexpected refusal"
      ( (a == Right Nothing && b == Left ScopeJournalProgramConflict)
          || (b == Right Nothing && a == Left ScopeJournalProgramConflict)
      )
  it "an unsafe root refuses without entering the journal callback" $ withFixture $ \(_, root) -> do
    setFileMode root 0o777
    result <-
      withOrdinaryScopeJournal root (const (assertFailure "unsafe root reached callback" :: IO ()))
    result @?= Left ScopeJournalDirectoryUnsafe
  it "a symlinked child cannot redirect the journal" $ withFixture $ \(_, root) -> do
    let outside = root </> "other"
    createDirectory outside
    setFileMode outside 0o700
    createSymbolicLink outside (root </> "ordinary-cascade")
    result <- withOrdinaryScopeJournal root (const (assertFailure "symlink reached callback"))
    assertBool "journal followed a symlink" (isLeft result)
    listDirectory outside >>= (@?= [])
  it "an unsafe request record refuses without rewriting its bytes" $ withFixture $ \(binding, root) -> do
    initialized <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    initialized @?= Right Nothing
    path <- journalRecord root "request-"
    before <- Bytes.readFile path
    setFileMode path 0o644
    result <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    result @?= Left ScopeJournalFileUnsafe
    Bytes.readFile path >>= (@?= before)
  it "a symlinked request record refuses without touching its target" $ withFixture $ \(binding, root) -> do
    initialized <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    initialized @?= Right Nothing
    path <- journalRecord root "request-"
    before <- Bytes.readFile path
    let target = root </> "external-request"
    Bytes.writeFile target before
    setFileMode target 0o600
    removeFile path
    createSymbolicLink target path
    result <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    assertBool "journal followed request symlink" (isLeft result)
    Bytes.readFile target >>= (@?= before)
  it "an oversized request record refuses before decoding" $ withFixture $ \(binding, root) -> do
    initialized <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    initialized @?= Right Nothing
    path <- journalRecord root "request-"
    Bytes.writeFile path (Bytes.replicate (maximumOrdinaryScopeJournalBytes + 1) 0)
    result <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    result @?= Left ScopeJournalEncodingTooLarge
  it "an orphan temporary is recovered only while its active slot is absent" $ withFixture $ \(binding, root) -> do
    let operation journal = prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97)
    initialized <- right =<< withOrdinaryScopeJournal root operation
    initialized @?= Right Nothing
    program <- journalRecord root "program-"
    request <- journalRecord root "request-"
    original <- Bytes.readFile program
    removeFile program
    removeFile request
    Bytes.writeFile (program <> ".pending") "partial crash residue"
    setFileMode (program <> ".pending") 0o600
    result <- right =<< withOrdinaryScopeJournal root operation
    result @?= Right Nothing
    Bytes.readFile program >>= (@?= original)
    doesPathExist (program <> ".pending") >>= (@?= False)
  it "held journal descriptor does not follow a replacement pathname" $ withFixture $ \(binding, root) -> do
    let selected = root </> "held"
        moved = root </> "moved"
    createDirectory selected
    setFileMode selected 0o700
    result <-
      right
        =<< withOrdinaryScopeJournal
          selected
          ( \journal -> do
              renameDirectory selected moved
              createDirectory selected
              setFileMode selected 0o700
              prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97)
          )
    result @?= Right Nothing
    listDirectory selected >>= (@?= [])
    _ <- journalRecord moved "program-"
    pure ()
  it "refuses retroactive program binding for a scope-only predecessor" $ withFixture $ \(binding, root) -> do
    result <-
      right
        =<< withOrdinaryScopeJournal
          root
          ( \journal -> do
              prepareOrdinaryScopeSubmission journal binding >>= (@?= Right Nothing)
              prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97)
          )
    result @?= Left ScopeJournalProgramBindingMissing
  it "operation publication requires a committed request and survives reopen" $ withFixture $ \(binding, root) -> do
    refused <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> bindOrdinaryScopeOperation journal binding (syntheticOperation 1))
    refused @?= Left ScopeJournalRequestMissing
    written <-
      right
        =<< withOrdinaryScopeJournal
          root
          ( \journal -> do
              prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97) >>= (@?= Right Nothing)
              bindOrdinaryScopeOperation journal binding (syntheticOperation 1)
          )
    written @?= Right ()
    reopened <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> prepareBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 97))
    reopened @?= Right (Just (syntheticOperation 1))
    conflict <-
      right
        =<< withOrdinaryScopeJournal
          root
          (\journal -> bindOrdinaryScopeOperation journal binding (syntheticOperation 2))
    conflict @?= Left ScopeJournalOperationConflict
  it "observes only the existing exact program and operation without preparing records" $ withFixture $ \(binding, root) -> do
    let digest = Bytes.replicate 64 97
        observe journal = observeBoundOrdinaryScopeSubmission journal binding digest
    absent <- right =<< withOrdinaryScopeJournal root observe
    absent @?= Right Nothing
    entries <- listDirectory (root </> "ordinary-cascade")
    assertBool "observation prepared a journal record" (all (== "journal.lock") entries)
    written <-
      right
        =<< withOrdinaryScopeJournal
          root
          ( \journal -> do
              prepareBoundOrdinaryScopeSubmission journal binding digest >>= (@?= Right Nothing)
              observe journal >>= (@?= Right Nothing)
              bindOrdinaryScopeOperation journal binding (syntheticOperation 1)
          )
    written @?= Right ()
    found <- right =<< withOrdinaryScopeJournal root observe
    found @?= Right (Just (syntheticOperation 1))
    conflict <-
      right
        =<< withOrdinaryScopeJournal
          root
          ( \journal ->
              observeBoundOrdinaryScopeSubmission journal binding (Bytes.replicate 64 98)
          )
    conflict @?= Left ScopeJournalProgramConflict
    request <- journalRecord root "request-"
    removeFile request
    missing <- right =<< withOrdinaryScopeJournal root observe
    missing @?= Left ScopeJournalRequestMissing
    doesPathExist request >>= (@?= False)
  it "canonical binding rejects trailing bytes without changing accepted logical width" $ do
    binding <-
      fixture (2 ^ (512 :: Int)) (2 ^ (512 :: Int)) (Bytes.replicate 32 7) (Bytes.replicate 32 9)
    let bytes = encodeOrdinaryScopeBinding binding
    decoded <- right (decodeOrdinaryScopeBinding bytes)
    encodeOrdinaryScopeBinding decoded @?= bytes
    assertBool
      "trailing byte accepted"
      (isLeft (decodeOrdinaryScopeBinding (bytes <> Bytes.singleton 0)))
  it "decoded compact nonce and key fields detach from a large encoded input view" $ do
    let bytes = fixtureBytes 1 9000000000 (Bytes.replicate 32 7) (Bytes.replicate 32 9)
        backing = Bytes.concat [Bytes.replicate 17 0, bytes, Bytes.replicate 1048576 0]
    input <- evaluate (Bytes.take (Bytes.length bytes) (Bytes.drop 17 backing))
    performGC
    (inputBytes, _) <- observeGraphBytes input
    assertBool "large input-backing precondition was optimized away" (inputBytes > 1048576)
    binding <- right (decodeOrdinaryScopeBinding input)
    declared <- evaluate (ordinaryScopeBindingNormalFormBytes binding)
    performGC
    (observed, nodes) <- observeGraphBytes binding
    assertBool
      ("binding graph=" <> show observed <> " in " <> show nodes <> " closures; declared=" <> show declared)
      (observed <= toInteger declared)

syntheticOperation :: Natural -> OperationId
syntheticOperation sequenceNumber =
  OperationId
    authorityEpochGenesis
    (ClientId "synthetic-journal-client")
    (ClientSequence sequenceNumber)
    (RequestDigest (Text.replicate 64 "c"))

withFixture :: ((OrdinaryScopeBinding, FilePath) -> IO value) -> IO value
withFixture action = withSystemTempDirectory "prodbox-scope-journal-" $ \root -> do
  setFileMode root 0o700
  binding <- fixture 1 9000000000 (Bytes.replicate 32 7) (Bytes.replicate 32 9)
  action (binding, root)

fixture :: Natural -> Natural -> Bytes.ByteString -> Bytes.ByteString -> IO OrdinaryScopeBinding
fixture logical deadline nonce publicKey =
  right (decodeOrdinaryScopeBinding (fixtureBytes logical deadline nonce publicKey))

-- Independent version-one public wire fixture. Keeping this at the codec
-- boundary avoids exposing the private native manager-identity constructor.
fixtureBytes :: Natural -> Natural -> Bytes.ByteString -> Bytes.ByteString -> Bytes.ByteString
fixtureBytes logical deadline nonce publicKey =
  toStrictByteString $
    encodeListLen 21
      <> encodeWord 0
      <> encode (1 :: Word32)
      <> encode ("synthetic-journal-component" :: Text.Text)
      <> encode (replicate 64 'a')
      <> foldMap encode ([20000000000, 15000000000, 16000000000, 17000000000, 18000000000] :: [Word64])
      <> foldMap
        encode
        ["12345678-1234-1234-1234-123456789abc", "123456789abcdef0123456789abcdef0", ":1.2" :: String]
      <> foldMap encode ([1000, 42] :: [Word32])
      <> encode (11 :: Word64)
      <> encode deadline
      <> encode (Text.replicate 64 "a")
      <> encode nonce
      <> encode (callerPrincipalCode CallerOperatorCli)
      <> encode logical
      <> encode publicKey

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

journalRecord :: FilePath -> String -> IO FilePath
journalRecord root prefix = do
  let directory = root </> "ordinary-cascade"
  entries <- listDirectory directory
  case filter (isPrefixOf prefix) entries of
    [name] -> pure (directory </> name)
    names -> fail ("expected one " <> prefix <> " record, found " <> show names)

-- Mutate only independently encoded public fixtures, never production syntax.
rewriteFixture :: Int -> (Term -> Term) -> IO Bytes.ByteString
rewriteFixture index replace = do
  let bytes = fixtureBytes 1 9000000000 (Bytes.replicate 32 7) (Bytes.replicate 32 9)
  decoded <- right (deserialiseOrFail (Lazy.fromStrict bytes))
  case decoded of
    TList fields -> case splitAt index fields of
      (prefix, selected : suffix) -> pure (Lazy.toStrict (serialise (TList (prefix <> [replace selected] <> suffix))))
      _ -> fail "independent scope fixture coordinate missing"
    _ -> fail "independent scope fixture is not a product"

byteEncodedString :: Term -> Term
byteEncodedString value = case value of
  TString text -> TBytes (TextEncoding.encodeUtf8 text)
  other -> other
