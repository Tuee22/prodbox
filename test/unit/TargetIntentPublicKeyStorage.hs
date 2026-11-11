{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

module TargetIntentPublicKeyStorage (targetIntentPublicKeyStorageSuite) where

import Control.Exception (evaluate)
import Data.ByteString qualified as Bytes
import Data.ByteString.Internal qualified as BytesInternal
import Data.List (isPrefixOf)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (plusPtr)
import GHC.Exts
  ( Int (I#)
  , MutableByteArray#
  , RealWorld
  , State#
  , getSizeofMutableByteArray#
  , isTrue#
  , sameMutableByteArray#
  )
import GHC.Exts.Heap qualified as Heap
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.IO (IO (IO))
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetIntentPublicKey
  , mkTargetIntentPublicKey
  , mkTargetIntentSigningKey
  , targetIntentPublicKeyBytes
  , targetIntentSigningPublicKey
  )
import TestSupport

targetIntentPublicKeyStorageSuite :: SuiteBuilder ()
targetIntentPublicKeyStorageSuite = describe "Target intent public-key storage" $ do
  it "detaches a validated key from a larger nonzero-offset input allocation" $ do
    (public, backing, view) <- inputView
    decoded <- either (fail . show) pure (mkTargetIntentPublicKey view)
    checkOwned public backing decoded

  it "finishes the copy before returning successful validation" $ do
    (public, backing, view) <- inputView
    accepted <- evaluate (mkTargetIntentPublicKey view)
    -- Inspect the result's field without evaluating it: a delayed copy would
    -- still retain the caller's backing even though validation has returned.
    outer <- Heap.getBoxedClosureData (Heap.asBox accepted)
    case outer of
      Heap.ConstrClosure _ [key] _ _ _ "Right" -> do
        stored <- Heap.getBoxedClosureData key
        case stored of
          Heap.ConstrClosure _ pointers words_ packageName moduleName constructor -> do
            packageName `shouldSatisfy` ("bytestring-" `isPrefixOf`)
            (moduleName, constructor, length pointers, length words_)
              `shouldBe` ("Data.ByteString.Internal.Type", "BS", 1, 2)
          other -> fail ("successful key validation retained unevaluated storage: " <> show other)
      other -> fail ("expected successful key validation: " <> show other)
    decoded <- either (fail . show) pure accepted
    checkOwned public backing decoded

  it "gives the signing-key factory the same payload-sized storage contract" $ do
    public <- syntheticPublicKey
    let stored = targetIntentPublicKeyBytes public
    Bytes.length stored `shouldBe` 32
    backingCapacity stored `shouldReturn` 32

syntheticPublicKey :: IO TargetIntentPublicKey
syntheticPublicKey =
  targetIntentSigningPublicKey
    <$> either (fail . show) pure (mkTargetIntentSigningKey (Bytes.replicate 32 7))

inputView :: IO (Bytes.ByteString, Bytes.ByteString, Bytes.ByteString)
inputView = do
  public <- targetIntentPublicKeyBytes <$> syntheticPublicKey
  let offset = 17
      total = 1048576
      backing =
        Bytes.concat
          [Bytes.replicate offset 0, public, Bytes.replicate (total - offset - Bytes.length public) 0]
      view = Bytes.take (Bytes.length public) (Bytes.drop offset backing)
      (parentPointer, parentOffset, _) = BytesInternal.toForeignPtr backing
      (viewPointer, viewOffset, _) = BytesInternal.toForeignPtr view
  sharesBacking backing view `shouldReturn` True
  backingCapacity view `shouldReturn` total
  advanced <- withForeignPtr parentPointer $ \parent ->
    withForeignPtr viewPointer $ \slice ->
      pure (parent `plusPtr` (parentOffset + offset) == slice `plusPtr` viewOffset)
  advanced `shouldBe` True
  pure (public, backing, view)

checkOwned :: Bytes.ByteString -> Bytes.ByteString -> TargetIntentPublicKey -> IO ()
checkOwned public backing decoded = do
  let stored = targetIntentPublicKeyBytes decoded
  stored `shouldBe` public
  backingCapacity stored `shouldReturn` Bytes.length public
  sharesBacking backing stored `shouldReturn` False

backingOrigin :: Bytes.ByteString -> ForeignPtrContents
backingOrigin bytes = case BytesInternal.toForeignPtr bytes of
  (ForeignPtr _ contents, _, _) -> contents

backingCapacity :: Bytes.ByteString -> IO Int
backingCapacity bytes = case backingOrigin bytes of
  PlainPtr array -> IO (arrayCapacity array)
  _ -> fail "public-key storage control requires the pinned PlainPtr representation"

arrayCapacity :: MutableByteArray# RealWorld -> State# RealWorld -> (# State# RealWorld, Int #)
arrayCapacity array state = case getSizeofMutableByteArray# array state of
  (# nextState, size #) -> (# nextState, I# size #)

sharesBacking :: Bytes.ByteString -> Bytes.ByteString -> IO Bool
sharesBacking first second = case (backingOrigin first, backingOrigin second) of
  (PlainPtr firstArray, PlainPtr secondArray) ->
    pure (isTrue# (sameMutableByteArray# firstArray secondArray))
  _ -> fail "public-key storage control requires two pinned PlainPtr backings"
