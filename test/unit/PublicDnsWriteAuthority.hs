-- | Sprint 5.57: the DNS validation waits out the one transient Gateway-DNS
-- convergence refusal that the public-edge wait already treats as retryable.
--
-- The `public-dns` validation read the Gateway-DNS observation once. The
-- observation is served by whichever gateway node the loopback endpoint reaches,
-- and only the node holding the ownership claim reports that it can write, so the
-- validation that ran right after a credential-lifecycle suite failed on
-- 2026-10-14 with "write authority is not ready" and passed on the next run
-- minutes later.
module PublicDnsWriteAuthority (publicDnsWriteAuthoritySuite) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Prodbox.PublicEdge (gatewayDnsWriteAuthorityNotReadyDiagnostic)
import Prodbox.TestValidation (retryWhileGatewayDnsPending)
import TestSupport

publicDnsWriteAuthoritySuite :: SuiteBuilder ()
publicDnsWriteAuthoritySuite =
  describe "Sprint 5.57 the DNS validation waits for the Gateway-DNS write authority" $ do
    it "repeats the observation while it answers the convergence refusal, then returns the answer" $ do
      calls <- newIORef (0 :: Int)
      let observe = do
            modifyIORef' calls (+ 1)
            attempt <- readIORef calls
            pure $
              if attempt < 3
                then Left gatewayDnsWriteAuthorityNotReadyDiagnostic
                else Right (Just "203.0.113.7")
      retryWhileGatewayDnsPending 10 0 observe `shouldReturn` Right (Just "203.0.113.7")
      readIORef calls `shouldReturn` 3

    it "does not repeat any other failure, or a success" $ do
      failures <- newIORef (0 :: Int)
      retryWhileGatewayDnsPending
        10
        0
        ( modifyIORef' failures (+ 1)
            >> pure (Left "Gateway-DNS observation failed: connection refused" :: Either String ())
        )
        `shouldReturn` Left "Gateway-DNS observation failed: connection refused"
      readIORef failures `shouldReturn` 1
      successes <- newIORef (0 :: Int)
      retryWhileGatewayDnsPending 10 0 (modifyIORef' successes (+ 1) >> pure (Right ()))
        `shouldReturn` Right ()
      readIORef successes `shouldReturn` 1

    it "returns the last refusal unchanged when the attempts run out" $ do
      calls <- newIORef (0 :: Int)
      retryWhileGatewayDnsPending
        4
        0
        ( modifyIORef' calls (+ 1)
            >> pure (Left gatewayDnsWriteAuthorityNotReadyDiagnostic :: Either String ())
        )
        `shouldReturn` Left gatewayDnsWriteAuthorityNotReadyDiagnostic
      readIORef calls `shouldReturn` 4
