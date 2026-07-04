-- Capacity schema for Sprint 1.55.
--
-- The Haskell mirror lives in Prodbox.Capacity.Config. This Dhall file owns the
-- pure capacity algebra operators that authored capacity documents can import:
-- componentwise budget containment, explicit request/limit resource envelopes,
-- host/RKE2 reservation containment, and the storage-only projection used by
-- the tiered-storage capacity doctrine.

let Budget = { cpu : Natural, memory : Natural, storage : Natural }

let ResourceVector =
      { milli_cpu : Natural
      , memory_mib : Natural
      , ephemeral_storage_mib : Natural
      , durable_storage_mib : Natural
      }

let ResourceEnvelope = { request : ResourceVector, limit : ResourceVector }

let NamespaceQuota = { namespace_name : Text, quota : ResourceVector }

let WorkloadResourceProfile =
      { profile_id : Text
      , profile_namespace : Text
      , replicas : Natural
      , resources : ResourceEnvelope
      }

let ResourcePlan =
      { host_capacity : ResourceVector
      , rke2_reserved : ResourceVector
      , eviction_floor : ResourceVector
      , namespace_quotas : List NamespaceQuota
      , workload_profiles : List WorkloadResourceProfile
      }

let lessOrEq =
      \(a : Natural) ->
      \(b : Natural) ->
        Natural/isZero (Natural/subtract b a)

let positive =
      \(value : Natural) ->
        Natural/isZero value == False

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

let vectorFitsWithin =
      \(inner : ResourceVector) ->
      \(outer : ResourceVector) ->
            lessOrEq inner.milli_cpu outer.milli_cpu
        &&  lessOrEq inner.memory_mib outer.memory_mib
        &&  lessOrEq inner.ephemeral_storage_mib outer.ephemeral_storage_mib
        &&  lessOrEq inner.durable_storage_mib outer.durable_storage_mib

let vectorPositive =
      \(vector : ResourceVector) ->
            positive vector.milli_cpu
        &&  positive vector.memory_mib
        &&  positive vector.ephemeral_storage_mib
        &&  positive vector.durable_storage_mib

let envelopeValid =
      \(envelope : ResourceEnvelope) ->
            vectorPositive envelope.request
        &&  vectorPositive envelope.limit
        &&  vectorFitsWithin envelope.request envelope.limit

let plus =
      \(left : Budget) ->
      \(right : Budget) ->
        { cpu = left.cpu + right.cpu
        , memory = left.memory + right.memory
        , storage = left.storage + right.storage
        }

let vectorPlus =
      \(left : ResourceVector) ->
      \(right : ResourceVector) ->
        { milli_cpu = left.milli_cpu + right.milli_cpu
        , memory_mib = left.memory_mib + right.memory_mib
        , ephemeral_storage_mib =
            left.ephemeral_storage_mib + right.ephemeral_storage_mib
        , durable_storage_mib =
            left.durable_storage_mib + right.durable_storage_mib
        }

let hostReservationFits =
      \(plan : ResourcePlan) ->
        vectorFitsWithin
          (vectorPlus plan.rke2_reserved plan.eviction_floor)
          plan.host_capacity

let zero = { cpu = 0, memory = 0, storage = 0 }

let zeroVector =
      { milli_cpu = 0
      , memory_mib = 0
      , ephemeral_storage_mib = 0
      , durable_storage_mib = 0
      }

let selfNode = { cpu = 8, memory = 16, storage = 100 }

let selfWorkload = { cpu = 4, memory = 8, storage = 40 }

let selfEnvelope =
      { request =
          { milli_cpu = 250
          , memory_mib = 256
          , ephemeral_storage_mib = 512
          , durable_storage_mib = 1
          }
      , limit =
          { milli_cpu = 500
          , memory_mib = 512
          , ephemeral_storage_mib = 1024
          , durable_storage_mib = 1
          }
      }

let selfPlan =
      { host_capacity =
          { milli_cpu = 12000
          , memory_mib = 32768
          , ephemeral_storage_mib = 200000
          , durable_storage_mib = 500000
          }
      , rke2_reserved =
          { milli_cpu = 1000
          , memory_mib = 2048
          , ephemeral_storage_mib = 10240
          , durable_storage_mib = 1024
          }
      , eviction_floor =
          { milli_cpu = 500
          , memory_mib = 1024
          , ephemeral_storage_mib = 10240
          , durable_storage_mib = 1024
          }
      , namespace_quotas =
          [ { namespace_name = "prodbox-system"
            , quota =
                { milli_cpu = 6000
                , memory_mib = 22000
                , ephemeral_storage_mib = 100000
                , durable_storage_mib = 250000
                }
            }
          ] : List NamespaceQuota
      , workload_profiles =
          [ { profile_id = "gateway"
            , profile_namespace = "prodbox-system"
            , replicas = 1
            , resources = selfEnvelope
            }
          ] : List WorkloadResourceProfile
      }

let fitsWithinSelf =
      assert : fitsWithin selfWorkload selfNode === True

let storageFitsWithinSelf =
      assert : storageFitsWithin selfWorkload selfNode === True

let plusZeroSelf =
      assert : plus zero selfNode === selfNode

let envelopeValidSelf =
      assert : envelopeValid selfEnvelope === True

let hostReservationFitsSelf =
      assert : hostReservationFits selfPlan === True

in  { Budget = Budget
    , ResourceVector = ResourceVector
    , ResourceEnvelope = ResourceEnvelope
    , NamespaceQuota = NamespaceQuota
    , WorkloadResourceProfile = WorkloadResourceProfile
    , ResourcePlan = ResourcePlan
    , zero = zero
    , zeroVector = zeroVector
    , plus = plus
    , vectorPlus = vectorPlus
    , fitsWithin = fitsWithin
    , storageFitsWithin = storageFitsWithin
    , vectorFitsWithin = vectorFitsWithin
    , envelopeValid = envelopeValid
    , hostReservationFits = hostReservationFits
    }
