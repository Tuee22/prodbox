module TestSupport
  ( Expectation
  , describe
  , expectationFailure
  , it
  , mainWithSuite
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  , shouldReturn
  , shouldSatisfy
  )
where

import Data.List (isInfixOf)
import GHC.Stack (HasCallStack)
import Test.Tasty (TestName, TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertEqual
  , assertFailure
  , testCase
  )

type Expectation = Assertion

newtype SuiteBuilder a = SuiteBuilder (a, [TestTree])

instance Functor SuiteBuilder where
  fmap f (SuiteBuilder (value, trees)) = SuiteBuilder (f value, trees)

instance Applicative SuiteBuilder where
  pure value = SuiteBuilder (value, [])
  SuiteBuilder (function, leftTrees) <*> SuiteBuilder (value, rightTrees) =
    SuiteBuilder (function value, leftTrees ++ rightTrees)

instance Monad SuiteBuilder where
  SuiteBuilder (value, leftTrees) >>= continue =
    let SuiteBuilder (nextValue, rightTrees) = continue value
     in SuiteBuilder (nextValue, leftTrees ++ rightTrees)

mainWithSuite :: TestName -> SuiteBuilder () -> IO ()
mainWithSuite suiteName builder =
  defaultMain (testGroup suiteName (suiteTrees builder))

describe :: TestName -> SuiteBuilder () -> SuiteBuilder ()
describe groupName builder =
  appendTree (testGroup groupName (suiteTrees builder))

it :: TestName -> Expectation -> SuiteBuilder ()
it testName expectation =
  appendTree (testCase testName expectation)

expectationFailure :: String -> Expectation
expectationFailure = assertFailure

shouldBe :: (HasCallStack, Eq a, Show a) => a -> a -> Expectation
shouldBe actual expected = assertEqual "" expected actual

shouldNotBe :: (HasCallStack, Eq a, Show a) => a -> a -> Expectation
shouldNotBe actual unexpected =
  assertBool
    ("Did not expect: " ++ show unexpected)
    (actual /= unexpected)

shouldContain :: (HasCallStack, Eq a, Show a) => [a] -> [a] -> Expectation
shouldContain actual expected =
  assertBool
    ("Expected " ++ show actual ++ " to contain " ++ show expected)
    (expected `isInfixOf` actual)

shouldNotContain :: (HasCallStack, Eq a, Show a) => [a] -> [a] -> Expectation
shouldNotContain actual expected =
  assertBool
    ("Expected " ++ show actual ++ " not to contain " ++ show expected)
    (not (expected `isInfixOf` actual))

shouldReturn :: (HasCallStack, Eq a, Show a) => IO a -> a -> Expectation
shouldReturn action expected = do
  actual <- action
  shouldBe actual expected

shouldSatisfy :: (HasCallStack) => a -> (a -> Bool) -> Expectation
shouldSatisfy actual predicate =
  assertBool "Expected predicate to return True." (predicate actual)

appendTree :: TestTree -> SuiteBuilder ()
appendTree tree = SuiteBuilder ((), [tree])

suiteTrees :: SuiteBuilder () -> [TestTree]
suiteTrees (SuiteBuilder (_, trees)) = trees
