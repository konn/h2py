module Main (main) where

import H2Py.Inspection.QSortDC qualified as QSortDC
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "optimized Core"
      [ QSortDC.tests
      ]
