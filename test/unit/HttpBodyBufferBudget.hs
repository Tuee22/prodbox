module HttpBodyBufferBudget (httpBodyBufferBudgetCases) where

import Numeric.Natural (Natural)
import Prodbox.Http.BodyBufferBudget
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, (@?=))

httpBodyBufferBudgetCases :: [(String, Assertion)]
httpBodyBufferBudgetCases =
  ("negative limits refuse", bodyBufferPlan (-1) @?= Nothing)
    : [(show (limit, chunks), verify limit chunks) | limit <- limits, chunks <- shapes]
 where
  limits = [0, 1, 2, 32767, 32768, 32769, 2097152, maxBound - 1, maxBound]
  shapes =
    [ []
    , [0]
    , [1]
    , [1, 1]
    , [32768, 1, 32768]
    , [32767, 1, 1]
    , [fromIntegral (maxBound :: Int), 1]
    , [2 ^ (100 :: Int)]
    ]

verify :: Int -> [Natural] -> IO ()
verify limit chunks = case bodyBufferPlan limit of
  Nothing -> assertFailure "valid limit refused"
  Just initial -> walk initial 0 0 chunks
 where
  walk plan used allocated remaining = do
    bodyBufferUsedBytes plan @?= fromIntegral used
    assertBool
      "capacity contains exactly the admitted prefix"
      (used <= fromIntegral (bodyBufferCapacityBytes plan) && bodyBufferCapacityBytes plan <= limit)
    assertBool
      "all payload allocations stay within the geometric budget"
      (allocated <= bodyBufferTotalPayloadAllocationMaximumBytes plan)
    case remaining of
      [] -> pure ()
      chunk : rest -> case appendBodyBufferChunk plan chunk of
        BodyBufferExceeded observed -> do
          observed @?= used + chunk
          assertBool "only a real crossing refuses" (observed > fromIntegral limit)
        BodyBufferReuse next -> do
          assertBool "reuse does not allocate" (bodyBufferCapacityBytes next == bodyBufferCapacityBytes plan)
          walk next (used + chunk) allocated rest
        BodyBufferAllocate next -> do
          let oldCapacity = fromIntegral (bodyBufferCapacityBytes plan)
              newCapacity = fromIntegral (bodyBufferCapacityBytes next)
          assertBool "growth is demand driven" (used + chunk > oldCapacity)
          assertBool
            "both live payload buffers fit the same budget"
            (oldCapacity + newCapacity <= bodyBufferLivePayloadMaximumBytes next)
          walk next (used + chunk) (allocated + newCapacity) rest
