-- | Pure projection of an already inspected archive into a kind config.
-- Neither this projection nor its input is operation admission.
module Prodbox.Control.KindRuntimeConfig
  ( renderKindConfigForArchive
  ) where

import Data.ByteString.Lazy (ByteString)
import Prodbox.Config.KindPlan
  ( KindPlan
  , kindPlanNodeImage
  , renderKindConfigWithLocalImageId
  )
import Prodbox.Control.NodeArchive
  ( VerifiedNodeArchive (nodeConfigDigest, nodeSelectedDigest)
  )

-- | Bind the configured selection digest to the inspected selection before
-- rendering its config digest as the local image ID. The caller must hold and
-- recheck the inspected archive, observe the local image, and separately
-- establish mutation admission, settlement and cleanup.
renderKindConfigForArchive :: KindPlan -> VerifiedNodeArchive -> Maybe ByteString
renderKindConfigForArchive plan archive =
  case break (== '@') (kindPlanNodeImage plan) of
    (_, '@' : configuredDigest)
      | configuredDigest == nodeSelectedDigest archive ->
          renderKindConfigWithLocalImageId plan (nodeConfigDigest archive)
    _ -> Nothing
