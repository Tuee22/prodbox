{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module RoughtimeSignerFixture (fixtureRoot, signedReply) where

import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (Digest, SHA512, hash)
import Crypto.PubKey.Ed25519 qualified as Ed
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Word (Word32, Word64)

key :: [Word] -> Ed.SecretKey
key bytes = case Ed.secretKey (BS.pack (map fromIntegral bytes)) of
  CryptoPassed secret -> secret
  CryptoFailed failure -> error (show failure)

root, delegate :: Ed.SecretKey
root = key [0 .. 31]
delegate = key [32 .. 63]
fixtureRoot :: ByteString
fixtureRoot = BA.convert (Ed.toPublic root)

hash32 :: ByteString -> ByteString
hash32 bytes = BS.take 32 (BA.convert (hash bytes :: Digest SHA512))
u32 :: Word32 -> ByteString
u32 n = BS.pack [fromIntegral (n `shiftR` (8 * i)) | i <- [0 .. 3]]
u64 :: Word64 -> ByteString
u64 n = BS.pack [fromIntegral (n `shiftR` (8 * i)) | i <- [0 .. 7]]
read32 :: ByteString -> Word32
read32 bytes =
  foldl' (\acc (i, b) -> acc .|. (fromIntegral b `shiftL` (8 * i))) 0 (zip [0 ..] (BS.unpack bytes))
encode :: [(ByteString, ByteString)] -> ByteString
encode input =
  u32 (fromIntegral (length pairs))
    <> BS.concat (map (u32 . fromIntegral) offsets)
    <> BS.concat (map fst pairs)
    <> BS.concat (map snd pairs)
 where
  pairs = sortOn (read32 . fst) input
  offsets = take (length pairs - 1) (drop 1 (scanl (+) 0 (map (BS.length . snd) pairs)))
frame :: ByteString -> ByteString
frame body = "ROUGHTIM" <> u32 (fromIntegral (BS.length body)) <> body
signature :: Ed.SecretKey -> ByteString -> ByteString
signature secret = BA.convert . Ed.sign secret (Ed.toPublic secret)

-- The fixture parses only its own controlled client packet.
nonceFromRequest :: ByteString -> ByteString
nonceFromRequest wire = lookupNonce 0
 where
  msg = BS.drop 12 wire
  count = fromIntegral (read32 (BS.take 4 msg)) :: Int
  offset i
    | i == 0 = 0
    | otherwise = fromIntegral (read32 (BS.take 4 (BS.drop (4 * i) msg)))
  tag i = BS.take 4 (BS.drop (4 * count + 4 * i) msg)
  lookupNonce i
    | i >= count = error "fixture request has no nonce"
    | tag i == "NONC" = BS.take 32 (BS.drop (8 * count + offset i) msg)
    | otherwise = lookupNonce (i + 1)

signedReply :: ByteString -> ByteString
signedReply request =
  frame $
    encode
      [ ("SIG\0", signature delegate ("Roughtime v1 response signature\0" <> signed))
      , ("NONC", nonceFromRequest request)
      , ("TYPE", u32 1)
      , ("PATH", sibling)
      , ("SREP", signed)
      , ("CERT", certificate)
      , ("INDX", u32 1)
      ]
 where
  sibling = hash32 "independent fixture leaf"
  merkleRoot = hash32 (BS.singleton 1 <> sibling <> hash32 (BS.singleton 0 <> request))
  signed =
    encode
      [("VER\0", u32 1), ("RADI", u32 3), ("MIDP", u64 1800000000), ("VERS", u32 1), ("ROOT", merkleRoot)]
  delegation =
    encode
      [("PUBK", BA.convert (Ed.toPublic delegate)), ("MINT", u64 1799999990), ("MAXT", u64 1800000010)]
  certificate =
    encode
      [ ("SIG\0", signature root ("Roughtime v1 delegation signature\0" <> delegation))
      , ("DELE", delegation)
      ]
