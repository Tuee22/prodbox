{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Internal RFC 10049 wire verification. A signed claim is not trusted time.
module Prodbox.ControlPlane.Roughtime.Protocol (Request, RequestError (..), ServerClaim (..), newRequest, requestBytes, verifyResponse) where

import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (Digest, SHA512, hash)
import Crypto.PubKey.Ed25519 qualified as Ed
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32, Word64)

data RequestError
  = InvalidKey
  | InvalidNonce
  | InvalidMessage
  | InvalidSignature
  | InvalidProof
  | InvalidTime
  deriving (Eq, Show)
data Request = Request !ByteString !ByteString !ByteString
requestBytes :: Request -> ByteString
requestBytes (Request wire _ _) = wire

data ServerClaim = ServerClaim {midpointSeconds :: !Word64, radiusSeconds :: !Word32}
  deriving (Eq, Show)

hash32 :: ByteString -> ByteString
hash32 bytes = BS.take 32 (BA.convert (hash bytes :: Digest SHA512))

word32 :: Word32 -> ByteString
word32 n = BS.pack [fromIntegral (n `shiftR` (8 * i)) | i <- [0 .. 3]]
read32 :: ByteString -> Either RequestError Word32
read32 bytes
  | BS.length bytes /= 4 = Left InvalidMessage
  | otherwise =
      Right
        (foldl' (\acc (i, b) -> acc .|. (fromIntegral b `shiftL` (8 * i))) 0 (zip [0 ..] (BS.unpack bytes)))
read64 :: ByteString -> Either RequestError Word64
read64 bytes
  | BS.length bytes /= 8 = Left InvalidMessage
  | otherwise =
      Right
        (foldl' (\acc (i, b) -> acc .|. (fromIntegral b `shiftL` (8 * i))) 0 (zip [0 ..] (BS.unpack bytes)))
tag :: ByteString -> Word32
tag t = either (const 0) id (read32 t)

encode :: [(ByteString, ByteString)] -> ByteString
encode pairs =
  word32 (fromIntegral (length pairs))
    <> BS.concat (map (word32 . fromIntegral) offsets)
    <> BS.concat (map fst pairs)
    <> BS.concat (map snd pairs)
 where
  offsets = take (length pairs - 1) (drop 1 (scanl (+) 0 (map (BS.length . snd) pairs)))
frame :: ByteString -> ByteString
frame msg = "ROUGHTIM" <> word32 (fromIntegral (BS.length msg)) <> msg

-- Nonces are generated here so callers cannot accidentally choose or reuse one.
newRequest :: ByteString -> IO (Either RequestError Request)
newRequest root
  | BS.length root /= 32 = pure (Left InvalidKey)
  | otherwise = makeRequest root <$> getRandomBytes 32

makeRequest :: ByteString -> ByteString -> Either RequestError Request
makeRequest root nonce
  | BS.length root /= 32 = Left InvalidKey
  | BS.length nonce /= 32 = Left InvalidNonce
  | otherwise = Right (Request wire root nonce)
 where
  fields =
    [ ("VER\0", word32 1)
    , ("SRV\0", hash32 (BS.singleton 255 <> root))
    , ("NONC", nonce)
    , ("TYPE", word32 0)
    ]
  base = encode (fields ++ [("ZZZZ", "")])
  wire = frame (encode (fields ++ [("ZZZZ", BS.replicate (1024 - BS.length base) 0)]))

parseFrame :: Int -> ByteString -> Either RequestError (Map Word32 ByteString)
parseFrame limit wire = do
  if BS.length wire < 12 || BS.length wire > limit || BS.take 8 wire /= "ROUGHTIM"
    then Left InvalidMessage
    else pure ()
  len <- read32 (BS.take 4 (BS.drop 8 wire))
  if fromIntegral len /= BS.length wire - 12
    then Left InvalidMessage
    else parseMessage (BS.drop 12 wire)

parseMessage :: ByteString -> Either RequestError (Map Word32 ByteString)
parseMessage bytes = do
  if BS.length bytes < 8 || BS.length bytes `mod` 4 /= 0 then Left InvalidMessage else pure ()
  n0 <- read32 (BS.take 4 bytes)
  if n0 == 0 || n0 > 64 then Left InvalidMessage else pure ()
  let n = fromIntegral n0; header = n * 8
  if BS.length bytes < header then Left InvalidMessage else pure ()
  offsets <- traverse (read32 . (\i -> BS.take 4 (BS.drop (4 + 4 * i) bytes))) [0 .. n - 2]
  tags <- traverse (read32 . (\i -> BS.take 4 (BS.drop (4 * n + 4 * i) bytes))) [0 .. n - 1]
  let size = BS.length bytes - header
      positions = 0 : map fromIntegral offsets ++ [size]
      ascending xs = and (zipWith (<) xs (drop 1 xs))
      nondesc xs = and (zipWith (<=) xs (drop 1 xs))
  let validTag value =
        let octets = BS.unpack (word32 value); (letters, padding) = span (\c -> c >= 65 && c <= 90) octets
         in not (null letters) && all (== 0) padding
  if not (ascending tags)
    || not (all validTag tags)
    || not (nondesc positions)
    || any (\i -> i > size || i `mod` 4 /= 0) positions
    then Left InvalidMessage
    else pure ()
  pure $
    Map.fromList
      ( zip
          tags
          (zipWith (\a b -> BS.take (b - a) (BS.drop (header + a) bytes)) positions (drop 1 positions))
      )

field :: ByteString -> Map Word32 ByteString -> Either RequestError ByteString
field name fields = maybe (Left InvalidMessage) Right (Map.lookup (tag name) fields)
sizeField :: Int -> ByteString -> Map Word32 ByteString -> Either RequestError ByteString
sizeField size name fields = do
  value <- field name fields
  if BS.length value == size then Right value else Left InvalidMessage

verifySig :: ByteString -> ByteString -> ByteString -> Either RequestError ()
verifySig key message sig = case (Ed.publicKey key, Ed.signature sig) of
  (CryptoPassed pk, CryptoPassed signature) | Ed.verify pk message signature -> Right ()
  _ -> Left InvalidSignature

chunks :: Int -> ByteString -> [ByteString]
chunks n bytes
  | BS.null bytes = []
  | otherwise = let (a, b) = BS.splitAt n bytes in a : chunks n b

verifyResponse :: Request -> ByteString -> Either RequestError ServerClaim
verifyResponse (Request wire root nonce) reply = do
  outer <- parseFrame (BS.length wire) reply
  returnedNonce <- sizeField 32 "NONC" outer
  if returnedNonce /= nonce then Left InvalidProof else pure ()
  typ <- sizeField 4 "TYPE" outer >>= read32
  if typ /= 1 then Left InvalidMessage else pure ()
  sig <- sizeField 64 "SIG\0" outer
  certBytes <- field "CERT" outer
  cert <- parseMessage certBytes
  delegation <- field "DELE" cert
  delegationSig <- sizeField 64 "SIG\0" cert
  verifySig root ("Roughtime v1 delegation signature\0" <> delegation) delegationSig
  delegated <- parseMessage delegation
  key <- sizeField 32 "PUBK" delegated
  minTime <- sizeField 8 "MINT" delegated >>= read64
  maxTime <- sizeField 8 "MAXT" delegated >>= read64
  signed <- field "SREP" outer
  verifySig key ("Roughtime v1 response signature\0" <> signed) sig
  content <- parseMessage signed
  version <- sizeField 4 "VER\0" content >>= read32
  versions <- field "VERS" content
  if BS.null versions || BS.length versions `mod` 4 /= 0 || BS.length versions > 128
    then Left InvalidMessage
    else pure ()
  supported <- traverse read32 (chunks 4 versions)
  if version /= 1 || version `notElem` supported || not (and (zipWith (<) supported (drop 1 supported)))
    then Left InvalidMessage
    else pure ()
  midpoint <- sizeField 8 "MIDP" content >>= read64
  radius <- sizeField 4 "RADI" content >>= read32
  if radius == 0 || minTime > midpoint || midpoint > maxTime then Left InvalidTime else pure ()
  expectedRoot <- sizeField 32 "ROOT" content
  index <- sizeField 4 "INDX" outer >>= read32
  path <- field "PATH" outer
  if BS.length path `mod` 32 /= 0 || BS.length path > 1024 then Left InvalidProof else pure ()
  let combine (current, i) sibling =
        ( hash32 (BS.singleton 1 <> if i .&. 1 == 0 then current <> sibling else sibling <> current)
        , i `shiftR` 1
        )
      (observedRoot, remainingIndex) = foldl' combine (hash32 (BS.singleton 0 <> wire), index) (chunks 32 path)
  if remainingIndex /= 0 || observedRoot /= expectedRoot
    then Left InvalidProof
    else Right (ServerClaim midpoint radius)
