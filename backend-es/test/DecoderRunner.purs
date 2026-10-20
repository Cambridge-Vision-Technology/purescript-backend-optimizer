module Test.DecoderRunner where

import Prelude

import Data.Array as Data.Array
import Data.Maybe as Data.Maybe
import Effect as Effect
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Node.Path as Node.Path
import Node.Process as Node.Process
import Test.CoreFnJson as Test.CoreFnJson
import Test.SnapshotPolicy as Test.SnapshotPolicy
import Test.SnapshotRunner as Test.SnapshotRunner
import Test.Utils as Test.Utils

main :: Effect.Effect Unit
main = Test.SnapshotRunner.launch do
  args <- Data.Array.drop 2 <$> Effect.Class.liftEffect Node.Process.argv
  case args of
    [ "corefn-int-literals", "--worker" ] -> do
      Effect.Class.liftEffect (Node.Process.chdir (Node.Path.concat [ "backend-es", "test-snapshots" ]))
      Test.SnapshotRunner.writePhase "corefn-int-literals" Test.SnapshotRunner.Assertions
      Effect.Class.liftEffect Test.CoreFnJson.main
      Test.SnapshotRunner.writePhase "corefn-int-literals" Test.SnapshotRunner.Complete
    [ "corefn-int-literals" ] -> do
      Test.Utils.mkdirp (Node.Path.concat [ "backend-es", "test-snapshots" ])
      argv <- Effect.Class.liftEffect Node.Process.argv
      entry <- Effect.Class.liftEffect case Data.Array.index argv 1 of
        Data.Maybe.Nothing -> Effect.Exception.throw "Missing decoder implementation test entry point"
        Data.Maybe.Just value -> Node.Path.resolve [] value
      receipt <- Test.SnapshotRunner.runSnapshot Test.SnapshotPolicy.normalDeadline entry "corefn-int-literals" [ "corefn-int-literals", "--worker" ] false
      Test.SnapshotRunner.requireSuccess receipt
    _ -> Effect.Class.liftEffect (Effect.Exception.throw "Expected exact decoder implementation test selector corefn-int-literals")
