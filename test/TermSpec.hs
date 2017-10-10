{-# LANGUAGE DataKinds #-}
module TermSpec where

import Data.Functor.Listable
import Data.Term
import Test.Hspec (Spec, describe, parallel)
import Test.Hspec.Expectations.Pretty
import Test.Hspec.LeanCheck

spec :: Spec
spec = parallel $ do
  describe "Term" $ do
    prop "equality is reflexive" $
      \ a -> a `shouldBe` (a :: Term ListableSyntax ())
