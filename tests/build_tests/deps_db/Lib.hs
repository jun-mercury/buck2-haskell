module Lib (greeting) where

import Dep (answer)
import Lib.Inner (suffix)

greeting :: String
greeting = "answer " ++ show answer ++ suffix
