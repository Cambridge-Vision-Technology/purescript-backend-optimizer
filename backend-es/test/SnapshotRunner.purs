module Test.SnapshotRunner
  ( Phase(..)
  , launch
  , runSnapshot
  , requireSuccess
  , writePhase
  , stallWorker
  , stallDescendant
  ) where

import Prelude

import Control.Monad.Error.Class as Control.Monad.Error.Class
import Data.Argonaut as Data.Argonaut
import Data.Array as Data.Array
import Data.Bifunctor as Data.Bifunctor
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.Newtype as Data.Newtype
import Data.Nullable as Data.Nullable
import Data.Posix as Data.Posix
import Data.Posix.Signal as Data.Posix.Signal
import Data.Time.Duration as Data.Time.Duration
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Class.Console as Effect.Class.Console
import Effect.Ref as Effect.Ref
import Effect.Uncurried as Effect.Uncurried
import Node.ChildProcess as Node.ChildProcess
import Node.ChildProcess.Types as Node.ChildProcess.Types
import Node.Encoding as Node.Encoding
import Node.EventEmitter as Node.EventEmitter
import Node.FS.Aff as Node.FS.Aff
import Node.Path as Node.Path
import Node.Process as Node.Process
import Platform.Node.SnapshotProcess as Platform.Node.SnapshotProcess
import Test.SnapshotPolicy as Test.SnapshotPolicy

data Phase = Startup | Setup | Codegen | Assertions | Complete | DiagnosticWaiting

derive instance Eq Phase

instance Show Phase where
  show Startup = "startup"
  show Setup = "setup"
  show Codegen = "codegen"
  show Assertions = "assertions"
  show Complete = "complete"
  show DiagnosticWaiting = "diagnostic-descendant-started"

data Outcome = Exited Int | TimedOut | SpawnFailed

type Receipt =
  { exitCode :: Int
  , cleaned :: Boolean
  , elapsed :: Data.Time.Duration.Milliseconds
  }

type OwnedSnapshot =
  { pid :: Data.Posix.Pid
  , exited :: Effect.Ref.Ref (Data.Maybe.Maybe Node.ChildProcess.Types.Exit)
  , spawnFailed :: Effect.Ref.Ref Boolean
  , removeExitHandler :: Effect.Effect Unit
  }

clock :: Effect.Effect Data.Time.Duration.Milliseconds
clock = Data.Time.Duration.Milliseconds <<< (_ * 1000.0) <$> Node.Process.uptime

launch :: Effect.Aff.Aff Unit -> Effect.Effect Unit
launch action = do
  fiber <- Effect.Aff.runAff report action
  Node.EventEmitter.on_ (Node.Process.mkSignalH Data.Posix.Signal.SIGTERM)
    (Effect.Aff.launchAff_ (Effect.Aff.killFiber (Effect.Aff.error "Snapshot runner received SIGTERM") fiber *> Effect.Class.liftEffect (Node.Process.exit' 143)))
    Node.Process.process
  Node.EventEmitter.on_ (Node.Process.mkSignalH Data.Posix.Signal.SIGINT)
    (Effect.Aff.launchAff_ (Effect.Aff.killFiber (Effect.Aff.error "Snapshot runner received SIGINT") fiber *> Effect.Class.liftEffect (Node.Process.exit' 130)))
    Node.Process.process
  where
  report = case _ of
    Data.Either.Right _ -> pure unit
    Data.Either.Left err -> do
      Effect.Class.Console.error (Effect.Aff.message err)
      code <- Node.Process.getExitCode
      when (code == Data.Maybe.Nothing) (Node.Process.setExitCode 1)

processExists :: Data.Posix.Pid -> Effect.Effect Boolean
processExists pid = Control.Monad.Error.Class.try (Node.Process.killInt pid 0) >>= case _ of
  Data.Either.Right _ -> pure true
  Data.Either.Left err ->
    if Data.Nullable.toMaybe (Platform.Node.SnapshotProcess.errorCodeImpl err) == Data.Maybe.Just "ESRCH" then pure false
    else Control.Monad.Error.Class.throwError err

signalGroup :: Data.Posix.Pid -> String -> Effect.Effect Unit
signalGroup pid signal = do
  let
    group = Data.Posix.Pid (negate (Data.Newtype.unwrap pid))
  Control.Monad.Error.Class.try (Node.Process.killStr group signal) >>= case _ of
    Data.Either.Right _ -> pure unit
    Data.Either.Left err ->
      if Data.Nullable.toMaybe (Platform.Node.SnapshotProcess.errorCodeImpl err) == Data.Maybe.Just "ESRCH" then pure unit
      else Control.Monad.Error.Class.throwError err

spawnWorker :: String -> Array String -> Effect.Effect OwnedSnapshot
spawnWorker entry args = do
  executable <- Node.Process.execPath
  exited <- Effect.Ref.new Data.Maybe.Nothing
  spawnFailed <- Effect.Ref.new false
  child <- Effect.Uncurried.runEffectFn3 Platform.Node.SnapshotProcess.spawnImpl executable (Data.Array.cons entry args) { detached: true, stdio: "inherit" }
  Node.EventEmitter.on_ Node.ChildProcess.exitH (flip Effect.Ref.write exited <<< Data.Maybe.Just) child
  Node.EventEmitter.on_ Node.ChildProcess.errorH (\err -> Effect.Class.Console.error ("Snapshot spawn error: " <> show err) *> Effect.Ref.write true spawnFailed) child
  pid <- Node.ChildProcess.pid child >>= case _ of
    Data.Maybe.Just value -> pure value
    Data.Maybe.Nothing -> Control.Monad.Error.Class.throwError (Effect.Aff.error "Snapshot subprocess did not acquire a PID.")
  removeExitHandler <- Node.EventEmitter.on Node.Process.exitH (const (signalGroup pid "SIGKILL")) Node.Process.process
  pure { pid, exited, spawnFailed, removeExitHandler }

waitWorker :: Data.Time.Duration.Milliseconds -> OwnedSnapshot -> Effect.Aff.Aff Outcome
waitWorker cutoff owned = do
  now <- Effect.Class.liftEffect clock
  exited <- Effect.Class.liftEffect (Effect.Ref.read owned.exited)
  failed <- Effect.Class.liftEffect (Effect.Ref.read owned.spawnFailed)
  if now >= cutoff then pure TimedOut
  else if failed then pure SpawnFailed
  else case exited of
    Data.Maybe.Just (Node.ChildProcess.Types.Normally code) -> pure (Exited code)
    Data.Maybe.Just (Node.ChildProcess.Types.BySignal _) -> pure (Exited 1)
    Data.Maybe.Nothing -> Effect.Aff.delay (Data.Time.Duration.Milliseconds 5.0) *> waitWorker cutoff owned

cleanup :: Data.Time.Duration.Milliseconds -> Data.Time.Duration.Milliseconds -> OwnedSnapshot -> Effect.Aff.Aff Boolean
cleanup reserve availableDeadline owned = do
  began <- Effect.Class.liftEffect clock
  Effect.Class.liftEffect (signalGroup owned.pid "SIGTERM")
  let
    deadline = min availableDeadline (began <> reserve)
    forceAt = began <> Data.Newtype.over Data.Time.Duration.Milliseconds (_ / 2.0) (difference deadline began)
    group = Data.Posix.Pid (negate (Data.Newtype.unwrap owned.pid))
    wait forced = do
      now <- Effect.Class.liftEffect clock
      groupAlive <- Effect.Class.liftEffect (processExists group)
      rootAlive <- Effect.Class.liftEffect (processExists owned.pid)
      if not groupAlive && not rootAlive then pure true
      else if now >= deadline then do
        Effect.Class.liftEffect (signalGroup owned.pid "SIGKILL")
        pure false
      else do
        when (not forced && now >= forceAt) (Effect.Class.liftEffect (signalGroup owned.pid "SIGKILL"))
        Effect.Aff.delay (Data.Time.Duration.Milliseconds 5.0)
        wait (forced || now >= forceAt)
  result <- wait false
  exited <- Effect.Class.liftEffect (Effect.Ref.read owned.exited)
  Effect.Class.liftEffect owned.removeExitHandler
  Effect.Class.Console.error ("snapshot cleanup pid=" <> show (Data.Newtype.unwrap owned.pid) <> " group=" <> show (Data.Newtype.unwrap group) <> " subprocessExit=" <> show exited <> " rootGoneAndGroupGone=" <> show result)
  pure result

writePhase :: String -> Phase -> Effect.Aff.Aff Unit
writePhase selector phase = Node.FS.Aff.writeTextFile Node.Encoding.UTF8 (".snapshot-" <> selector <> ".phase") (show phase)

difference :: Data.Time.Duration.Milliseconds -> Data.Time.Duration.Milliseconds -> Data.Time.Duration.Milliseconds
difference = Data.Newtype.over2 Data.Time.Duration.Milliseconds (-)

runSnapshot :: Test.SnapshotPolicy.Deadline -> String -> String -> Array String -> Boolean -> Effect.Aff.Aff Receipt
runSnapshot policy entry selector args diagnostic = do
  root <- Effect.Class.liftEffect Node.Process.cwd
  phasePath <- Effect.Class.liftEffect (Node.Path.resolve [ root, "backend-es", "test-snapshots" ] (".snapshot-" <> selector <> ".phase"))
  descendantPath <- Effect.Class.liftEffect (Node.Path.resolve [ root, "backend-es", "test-snapshots" ] (".snapshot-" <> selector <> ".descendant"))
  started <- Effect.Class.liftEffect clock
  let
    deadline = started <> Test.SnapshotPolicy.budget policy
    cutoff = difference deadline (Test.SnapshotPolicy.cleanupReserve policy)
  Node.FS.Aff.writeTextFile Node.Encoding.UTF8 phasePath (show Startup)
  cleaned <- Effect.Class.liftEffect (Effect.Ref.new false)
  outcome <- Effect.Aff.bracket
    ( Effect.Class.liftEffect do
        owned <- spawnWorker entry args
        Effect.Class.Console.error ("snapshot started selector=" <> selector <> " pid=" <> show (Data.Newtype.unwrap owned.pid) <> " budgetMs=" <> show (Data.Newtype.unwrap (Test.SnapshotPolicy.budget policy)))
        pure owned
    )
    (\owned -> cleanup (Test.SnapshotPolicy.cleanupReserve policy) deadline owned >>= Effect.Class.liftEffect <<< flip Effect.Ref.write cleaned)
    (waitWorker cutoff)
  clean <- Effect.Class.liftEffect (Effect.Ref.read cleaned)
  phase <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 phasePath
  when diagnostic do
    encoded <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 descendantPath
    descendant <- case Data.Argonaut.jsonParser encoded >>= Data.Bifunctor.lmap Data.Argonaut.printJsonDecodeError <<< Data.Argonaut.decodeJson of
      Data.Either.Left err -> Effect.Aff.throwError (Effect.Aff.error (show err))
      Data.Either.Right value -> pure (Data.Posix.Pid value)
    alive <- Effect.Class.liftEffect (processExists descendant)
    Effect.Class.Console.error ("snapshot control descendantPid=" <> show (Data.Newtype.unwrap descendant) <> " descendantGone=" <> show (not alive))
    when alive (Effect.Aff.throwError (Effect.Aff.error "Snapshot control descendant survived cleanup."))
  ended <- Effect.Class.liftEffect clock
  let
    elapsed = difference ended started
    exitCode = case outcome of
      TimedOut -> 124
      SpawnFailed -> 1
      Exited code | clean && elapsed <= Test.SnapshotPolicy.budget policy -> code
      _ -> 1
    status = case outcome of
      TimedOut -> "timeout"
      SpawnFailed -> "spawn-failed"
      Exited _ -> "exited"
  Effect.Class.Console.error ("snapshot result selector=" <> selector <> " status=" <> status <> " exit=" <> show exitCode <> " elapsedMs=" <> show (Data.Newtype.unwrap elapsed) <> " budgetMs=" <> show (Data.Newtype.unwrap (Test.SnapshotPolicy.budget policy)) <> " phase=" <> phase <> " cleanup=" <> show clean)
  pure { exitCode, cleaned: clean, elapsed }

requireSuccess :: Receipt -> Effect.Aff.Aff Unit
requireSuccess receipt = when (receipt.exitCode /= 0) do
  Effect.Class.liftEffect (Node.Process.setExitCode receipt.exitCode)
  Effect.Aff.throwError (Effect.Aff.error "Snapshot execution failed; see the deadline and cleanup receipt.")

stallDescendant :: Unit -> Effect.Aff.Aff Unit
stallDescendant _ = do
  Effect.Aff.delay (Test.SnapshotPolicy.budget Test.SnapshotPolicy.normalDeadline)
  stallDescendant unit

stallWorker :: String -> Effect.Aff.Aff Unit
stallWorker selector = do
  argv <- Effect.Class.liftEffect Node.Process.argv
  entry <- case Data.Array.index argv 1 of
    Data.Maybe.Nothing -> Effect.Aff.throwError (Effect.Aff.error "Missing snapshot runner entry point.")
    Data.Maybe.Just value -> Effect.Class.liftEffect (Node.Path.resolve [] value)
  Effect.Class.liftEffect (Node.EventEmitter.on_ (Node.Process.mkSignalH Data.Posix.Signal.SIGTERM) (pure unit) Node.Process.process)
  executable <- Effect.Class.liftEffect Node.Process.execPath
  child <- Effect.Class.liftEffect (Effect.Uncurried.runEffectFn3 Platform.Node.SnapshotProcess.spawnImpl executable [ entry, "--diagnostic-descendant" ] { detached: false, stdio: "inherit" })
  Effect.Class.liftEffect (Node.EventEmitter.on_ Node.ChildProcess.errorH (const (Node.Process.setExitCode 1)) child)
  Effect.Class.liftEffect (Node.EventEmitter.on_ Node.ChildProcess.exitH (\exit -> Effect.Class.Console.error ("snapshot control descendant reaped exit=" <> show exit)) child)
  pid <- Effect.Class.liftEffect (Node.ChildProcess.pid child) >>= case _ of
    Data.Maybe.Nothing -> Effect.Aff.throwError (Effect.Aff.error "Diagnostic descendant did not acquire a PID.")
    Data.Maybe.Just value -> pure value
  Effect.Class.liftEffect (Node.Process.chdir (Node.Path.concat [ "backend-es", "test-snapshots" ]))
  Node.FS.Aff.writeTextFile Node.Encoding.UTF8 (".snapshot-" <> selector <> ".descendant") (show (Data.Newtype.unwrap pid))
  writePhase selector DiagnosticWaiting
  Effect.Class.Console.error ("snapshot control descendant started pid=" <> show (Data.Newtype.unwrap pid))
  stallDescendant unit
