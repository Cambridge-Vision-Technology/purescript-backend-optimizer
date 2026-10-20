module Platform.JavaScript.CoreFnInt where

foreign import isIntegerImpl :: Number -> Boolean

foreign import fromNumberImpl :: Number -> Int
