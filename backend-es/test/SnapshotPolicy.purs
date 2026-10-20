module Test.SnapshotPolicy
  ( Deadline
  , normalDeadline
  , parseDeadline
  , budget
  , cleanupReserve
  ) where

import Prelude

import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.Newtype as Data.Newtype
import Data.Number as Data.Number
import Data.Time.Duration as Data.Time.Duration

data Deadline = Deadline Data.Time.Duration.Milliseconds

normalDeadline :: Deadline
normalDeadline = Deadline (Data.Time.Duration.Milliseconds 60000.0)

budget :: Deadline -> Data.Time.Duration.Milliseconds
budget (Deadline value) = value

parseDeadline :: String -> Data.Either.Either String Deadline
parseDeadline input = case Data.Number.fromString input of
  Data.Maybe.Just value | value >= 1000.0 && value <= Data.Newtype.unwrap (budget normalDeadline) ->
    Data.Either.Right (Deadline (Data.Time.Duration.Milliseconds value))
  _ ->
    Data.Either.Left "Snapshot deadline must be between 1000 and 60000 milliseconds; it cannot increase or disable the normal limit."

cleanupReserve :: Deadline -> Data.Time.Duration.Milliseconds
cleanupReserve deadline = Data.Time.Duration.Milliseconds (min 2000.0 (Data.Newtype.unwrap (budget deadline) / 3.0))
