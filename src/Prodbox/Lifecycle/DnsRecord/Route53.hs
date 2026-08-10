-- | The one conversion from a typed DNS coordinate to the Route 53 wire shape.
--
-- Sprint @4.73@: both DNS writers this repository owns — the home Gateway
-- Runtime's A-record lane and the Provider Worker's public-A and SES lanes —
-- must render the same coordinate to the same request bytes. Two copies of
-- this conversion is precisely the defect
-- @chaos_hardening_doctrine.md § 23@ names: a typed value crossing out of a
-- region reconstructed by more than one encoder, so tightening the type
-- updates one of them and silently leaves the other wrong.
--
-- 'nativeDnsRecordType' is total over 'DnsRecordType' rather than defaulting,
-- so a new record type is a compile error here instead of a wire shape nobody
-- chose.
module Prodbox.Lifecycle.DnsRecord.Route53
  ( nativeDnsRecordType
  , nativeDnsRecordSet
  )
where

import Data.Set qualified as Set
import Prodbox.Aws.Native.Route53 qualified as NativeRoute53
import Prodbox.Lifecycle.DnsRecord
  ( DnsRecordCoordinate
  , DnsRecordSet
  , DnsRecordType (..)
  , dnsCoordinateName
  , dnsCoordinateType
  , dnsRecordSetTtl
  , dnsRecordSetValues
  , dnsRecordValueText
  )

nativeDnsRecordType :: DnsRecordType -> NativeRoute53.RecordType
nativeDnsRecordType recordType = case recordType of
  DnsRecordA -> NativeRoute53.RecordA
  DnsRecordTxt -> NativeRoute53.RecordTXT
  DnsRecordCname -> NativeRoute53.RecordCNAME
  DnsRecordMx -> NativeRoute53.RecordMX

-- | The record set a coordinate and its desired values denote on the wire.
--
-- The name and the type come from the coordinate, never from a caller-supplied
-- pair beside it, so a request cannot address one coordinate and write another.
nativeDnsRecordSet
  :: DnsRecordCoordinate
  -> DnsRecordSet
  -> NativeRoute53.ResourceRecordSet
nativeDnsRecordSet coordinate recordSet =
  NativeRoute53.ResourceRecordSet
    { NativeRoute53.rrsName = dnsCoordinateName coordinate
    , NativeRoute53.rrsType = nativeDnsRecordType (dnsCoordinateType coordinate)
    , NativeRoute53.rrsTtl = fromIntegral (dnsRecordSetTtl recordSet)
    , NativeRoute53.rrsRecords =
        map dnsRecordValueText (Set.toAscList (dnsRecordSetValues recordSet))
    }
