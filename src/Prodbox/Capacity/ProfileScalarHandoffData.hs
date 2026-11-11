-- | Data at the selected scalar handoff, excluding the shared input origin
-- and separately funded Integer/Natural/limb data. No SDK/compiler continuation,
-- importer, stack, dead allocation, GC or whole-reader certificate is supplied.
module Prodbox.Capacity.ProfileScalarHandoffData
  ( profileScalarHandoffDataBytes
  ) where

import Numeric.Natural (Natural)
import Prodbox.Capacity.BoxedNormalForm (boxedRecordBytes)

-- Pinned 64-bit ABI, bytestring-0.11.5.4 and cborg-0.2.10.0:
-- Done has an input reference, unpacked offset and result reference. Charge
-- the profile input and trailing ByteString view headers; the known originating
-- buffer's ForeignPtr/array is charged independently. ProfileScalar has a boxed
-- offset and Integer reference, and Right adds one pointer. ProfileCursor has
-- its input reference and boxed Int. Boxing is charged even if GHC unpacks it.
-- Two minimal headers also cover an empty trailing view's owner/empty array.
-- This conservative joint term holds the SDK result, private strict result,
-- cursor and converted Natural together. Other transient views and all state
-- tuples/continuations retain separate obligations. No arbitrary view obtains
-- an ownership or admission witness from this arithmetic.
profileScalarHandoffDataBytes :: Natural
profileScalarHandoffDataBytes =
  boxedRecordBytes [0, 0, 0]
    + 2 * boxedRecordBytes [0, 0, 0]
    + boxedRecordBytes [16, 0]
    + boxedRecordBytes [0]
    + boxedRecordBytes [0, 16]
    + 2 * boxedRecordBytes []
