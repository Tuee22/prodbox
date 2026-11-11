{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Prodbox.Config.OrdinaryMemoryProfile.DeclaredShape
  ( ordinaryMemoryProfileBoundedShapeTemplate
  , ordinaryMemoryProfileShapeTemplate
  , ordinaryMemoryProfileShapeDataBytes
  ) where

import Data.Proxy (Proxy (..))
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config (RuntimeMemoryProfile)
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CanonicalDhallValueShape.BoundedStage
  ( BoundedStaticShapeTemplate
  , boundedStaticShapeTemplate
  , boundedStaticShapeTemplateExpression
  )
import Prodbox.Config.OrdinaryMemoryProfile.Schema
  ( ordinaryMemoryProfileIdentity
  , ordinaryMemoryProfileRoles
  )

ordinaryMemoryProfileBoundedShapeTemplate :: BoundedStaticShapeTemplate RuntimeMemoryProfile
ordinaryMemoryProfileBoundedShapeTemplate =
  $( boundedStaticShapeTemplateExpression
       (Proxy :: Proxy RuntimeMemoryProfile)
       [ StaticRequirement ["runtime_profile_id"] (RequireText ordinaryMemoryProfileIdentity)
       , StaticRequirement
           ["child_process_budget", "permit_capacity"]
           (RequirePresentNatural (fromIntegral ordinaryMemoryProfileRoles))
       , StaticRequirement
           ["child_process_budget", "simultaneous_peak_bytes"]
           (RequireListElements (fromIntegral ordinaryMemoryProfileRoles))
       ]
   )

-- The erased certificate proves finite structural counts, not bounded scalar
-- payloads or working-set admission. The underlying numeric data floor stays
-- independently queryable before metadata materialization.
ordinaryMemoryProfileShapeTemplate :: StaticShapeTemplate RuntimeMemoryProfile
ordinaryMemoryProfileShapeTemplate = boundedStaticShapeTemplate ordinaryMemoryProfileBoundedShapeTemplate

ordinaryMemoryProfileShapeDataBytes :: Natural
ordinaryMemoryProfileShapeDataBytes = staticShapeTemplateDataBytes ordinaryMemoryProfileShapeTemplate
