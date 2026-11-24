{-# LANGUAGE ImportQualifiedPost #-}

-- Pure negative controls: no manager, Docker connection or worker is started.
import Control.Monad (unless)
import Prodbox.Control.KindControllerRequest (kindControllerOperationKey)
import Prodbox.Control.KindTool (kindFamilyBindingMatches)
import Prodbox.Subprocess.SystemdIdentity qualified as Identity

main :: IO ()
main = do
  let operation = replicate 32 'd'
      other = replicate 32 'e'
  key <- maybe (fail "key") pure (kindControllerOperationKey operation)
  otherKey <- maybe (fail "other key") pure (kindControllerOperationKey other)
  unless (kindFamilyBindingMatches Identity.KindController key operation) (fail "matching family refused")
  unless (not (kindFamilyBindingMatches Identity.KindController otherKey operation)) (fail "foreign key accepted")
  unless (not (kindFamilyBindingMatches Identity.KindController key "invalid")) (fail "invalid operation accepted")
  mapM_ (\family -> unless (not (kindFamilyBindingMatches family key operation)) (fail "foreign family accepted"))
    [Identity.RpcBirthController, Identity.OrdinaryCascadeController, Identity.MutationController]
  putStrLn "PASS kind family, operation key and invalid-operation binding controls"
