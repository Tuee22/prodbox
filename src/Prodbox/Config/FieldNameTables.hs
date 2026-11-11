{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

module Prodbox.Config.FieldNameTables
  ( awsProfileFieldNames
  , scalingSubstrateFieldNames
  , retainedDeclarationFieldNames
  , retainedSectionFieldNames
  , fieldNameTablesDataBytes
  ) where

import Numeric.Natural (Natural)
import Prodbox.Config.FieldNameTable
import Prodbox.Config.FieldNameTable.Stage (fieldNameTableCode, fieldNameTablesDataCode)

{-# NOINLINE awsProfileFieldNames #-}
awsProfileFieldNames :: FieldNameTable 'AwsProfileFields
awsProfileFieldNames = $$(fieldNameTableCode SAwsProfileFields)
{-# NOINLINE scalingSubstrateFieldNames #-}
scalingSubstrateFieldNames :: FieldNameTable 'ScalingSubstrateFields
scalingSubstrateFieldNames = $$(fieldNameTableCode SScalingSubstrateFields)
{-# NOINLINE retainedDeclarationFieldNames #-}
retainedDeclarationFieldNames :: FieldNameTable 'RetainedDeclarationFields
retainedDeclarationFieldNames = $$(fieldNameTableCode SRetainedDeclarationFields)
{-# NOINLINE retainedSectionFieldNames #-}
retainedSectionFieldNames :: FieldNameTable 'RetainedSectionFields
retainedSectionFieldNames = $$(fieldNameTableCode SRetainedSectionFields)

-- A separate generated scalar: querying it does not materialize any table.
{-# NOINLINE fieldNameTablesDataBytes #-}
fieldNameTablesDataBytes :: Natural
fieldNameTablesDataBytes = $$(fieldNameTablesDataCode)
