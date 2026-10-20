module Platform.Node.SnapshotProcess where

import Data.Nullable as Data.Nullable
import Effect.Aff as Effect.Aff
import Effect.Uncurried as Effect.Uncurried
import Node.ChildProcess as Node.ChildProcess

type SpawnOptions =
  { detached :: Boolean
  , stdio :: String
  }

foreign import spawnImpl :: Effect.Uncurried.EffectFn3 String (Array String) SpawnOptions Node.ChildProcess.ChildProcess

foreign import errorCodeImpl :: Effect.Aff.Error -> Data.Nullable.Nullable String
