{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- Fixed inspection metadata from the actual canonical typed producer.
module Prodbox.ControlPlane.RpcBirthSettingsShape (rpcBirthSettingsShapeTemplate) where

import Data.Proxy (Proxy (..))
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CanonicalDhallValueShape.Stage (staticShapeTemplateExpression)
import Prodbox.ControlPlane.RpcBirthSettingsEnvelope (SettingsEnvelope)

rpcBirthSettingsShapeTemplate :: StaticShapeTemplate SettingsEnvelope
rpcBirthSettingsShapeTemplate =
  $( staticShapeTemplateExpression
       (Proxy :: Proxy SettingsEnvelope)
       [ StaticPathText ["parameters", "storage", "manual_pv_host_root"]
       , StaticAwsProfile ["parameters", "aws_substrate", "profile"]
       ]
   )
