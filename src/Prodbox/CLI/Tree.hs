module Prodbox.CLI.Tree
  ( renderCommandTree
  )
where

import Prodbox.CLI.Spec (CommandSpec (..))

renderCommandTree :: CommandSpec -> String
renderCommandTree = unlines . go ""
 where
  go prefix spec =
    (prefix ++ name spec)
      : concatMap (go (prefix ++ "  ")) (children spec)
