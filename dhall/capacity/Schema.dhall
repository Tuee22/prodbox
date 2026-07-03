-- Capacity schema for Sprint 1.51.
--
-- The Haskell mirror lives in Prodbox.Capacity.Config. This Dhall file owns the
-- pure capacity algebra operators that authored capacity documents can import:
-- componentwise budget containment plus the storage-only projection used by the
-- tiered-storage capacity doctrine.

let Budget = { cpu : Natural, memory : Natural, storage : Natural }

let lessOrEq =
      \(a : Natural) ->
      \(b : Natural) ->
        Natural/isZero (Natural/subtract b a)

let fitsWithin =
      \(inner : Budget) ->
      \(outer : Budget) ->
            lessOrEq inner.cpu outer.cpu
        &&  lessOrEq inner.memory outer.memory
        &&  lessOrEq inner.storage outer.storage

let storageFitsWithin =
      \(inner : Budget) ->
      \(outer : Budget) ->
        lessOrEq inner.storage outer.storage

let plus =
      \(left : Budget) ->
      \(right : Budget) ->
        { cpu = left.cpu + right.cpu
        , memory = left.memory + right.memory
        , storage = left.storage + right.storage
        }

let zero = { cpu = 0, memory = 0, storage = 0 }

let selfNode = { cpu = 8, memory = 16, storage = 100 }

let selfWorkload = { cpu = 4, memory = 8, storage = 40 }

let fitsWithinSelf =
      assert : fitsWithin selfWorkload selfNode === True

let storageFitsWithinSelf =
      assert : storageFitsWithin selfWorkload selfNode === True

let plusZeroSelf =
      assert : plus zero selfNode === selfNode

in  { Budget = Budget
    , zero = zero
    , plus = plus
    , fitsWithin = fitsWithin
    , storageFitsWithin = storageFitsWithin
    }
