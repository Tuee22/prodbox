-- | The sole closed internal controller program. Pinned input and observed
-- process owners enclose preparation and total caller coordination. No repo
-- discovery, ambient settings reload or independent process owner enters here.
module Prodbox.ControlPlane.RpcAdmissionBirthController
  ( RpcBirthControllerError (..)
  , runRpcBirthController
  ) where

import Data.Bifunctor (first)
import Prodbox.ControlPlane.RpcAdmissionBirthControllerInputs
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator (RpcBirthCoordinationResult)
import Prodbox.ControlPlane.RpcAdmissionBirthRequest
import Prodbox.ControlPlane.RpcAdmissionBirthRollout

data RpcBirthControllerError
  = RpcBirthControllerInputRefused !RpcBirthControllerLoadError
  | RpcBirthControllerHostRefused !RpcBirthHostError
  deriving (Eq, Show)

runRpcBirthController
  :: RpcBirthControllerArguments
  -> IO (Either RpcBirthControllerError RpcBirthCoordinationResult)
runRpcBirthController arguments = do
  loaded <- withRpcBirthControllerInputs arguments $ \inputs -> do
    operated <- withRpcBirthControllerProcesses inputs $ \processes -> do
      let preparation = rpcBirthControllerInputPreparation inputs
          request = rpcBirthControllerPreparedRequest preparation
      prepared <-
        prepareRpcBirthOnOperation
          processes
          (rpcBirthControllerRequestCoordination request)
          (rpcBirthControllerRequestRoot request)
          (rpcBirthControllerPreparedSettings preparation)
      case prepared of
        Left cause -> pure (Left (RpcBirthControllerHostRefused cause))
        Right held ->
          first RpcBirthControllerHostRefused
            <$> coordinatePreparedRpcBirthCallerOnOperation
              (rpcBirthControllerRequestCaller request)
              (rpcBirthControllerSourcePath inputs)
              held
    pure (first RpcBirthControllerInputRefused operated >>= id)
  pure (first RpcBirthControllerInputRefused loaded >>= id)
