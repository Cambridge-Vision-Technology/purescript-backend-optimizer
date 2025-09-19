module PureScript.Backend.Optimizer.QIMap where

import Prelude

import Control.Alt (class Alt)
import Control.Plus (class Plus)
import Data.Eq (class Eq1)
import Data.Foldable (class Foldable, foldl)
import Data.FoldableWithIndex (foldlWithIndex)
import Data.FunctorWithIndex (class FunctorWithIndex, mapWithIndex)
import Data.Map (Map)
import Data.Map as Map
import Data.Map.Internal as Internal
import Data.Maybe (Maybe(..), maybe)
import Data.Ord (class Ord1)
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (class Traversable)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Optimizer.CoreFn (Ident, ModuleName, Qualified(..))

-- This map is more efficient than `Map (Qualified Ident)`, because it avoids
-- repeated comparisons of the module name and can inline the string comparisons.
data QIMap v = QIMap (Map ModuleName (Map Ident v)) (Map Ident v)
derive instance Functor QIMap
derive instance Foldable QIMap
derive instance Traversable QIMap
derive instance Eq v => Eq (QIMap v)
derive instance Ord v => Ord (QIMap v)
derive instance Eq1 QIMap
derive instance Ord1 QIMap

instance Apply QIMap where
  apply (QIMap qf uf) (QIMap qa ua) = QIMap (apply <$> qf <*> qa) (uf <*> ua)
instance Alt QIMap where
  alt = union
instance Plus QIMap where
  empty = empty
instance FunctorWithIndex (Qualified Ident) QIMap where
  mapWithIndex f (QIMap qm um) = QIMap
    (qm # mapWithIndex \q -> mapWithIndex \i -> f (Qualified (Just q) i))
    (um # mapWithIndex \i -> f (Qualified Nothing i))

instance Semigroup v => Semigroup (QIMap v) where
  append = unionWith append
instance Semigroup v => Monoid (QIMap v) where
  mempty = empty

empty :: forall v. QIMap v
empty = QIMap Map.empty Map.empty

fromMap :: Map (Qualified Ident) ~> QIMap
fromMap = foldlWithIndex (\qi m v -> insert qi v m) empty

fromFoldable :: forall f v. Foldable f => f (Tuple (Qualified Ident) v) -> QIMap v
fromFoldable = foldl (\m (Tuple qi v) -> insert qi v m) empty

singleton :: forall v. Qualified Ident -> v -> QIMap v
singleton (Qualified (Just q) i) v = QIMap (Map.singleton q (Map.singleton i v)) Map.empty
singleton (Qualified _ i) v = QIMap Map.empty (Map.singleton i v)

union :: forall v. QIMap v -> QIMap v -> QIMap v
union (QIMap q1 u1) (QIMap q2 u2) = QIMap (Map.unionWith Map.union q1 q2) (Map.union u1 u2)

unionWith :: forall v. (v -> v -> v) -> QIMap v -> QIMap v -> QIMap v
unionWith f (QIMap q1 u1) (QIMap q2 u2) = QIMap (Map.unionWith (Map.unionWith f) q1 q2) (Map.unionWith f u1 u2)

unions :: forall v f. Foldable f => f (QIMap v) -> QIMap v
unions = foldl union empty

insert :: forall v. Qualified Ident -> v -> QIMap v -> QIMap v
insert (Qualified (Just q) i) = _insertQ q i
insert (Qualified _ i) = _insertU i
_insertQ :: forall v. ModuleName -> Ident -> v -> QIMap v -> QIMap v
_insertQ q i v (QIMap qm um) = QIMap (Map.alter inner q qm) um
  where
  inner (Just im) = Just (Map.insert i v im)
  inner _ = Just (Map.singleton i v)
_insertU :: forall v. Ident -> v -> QIMap v -> QIMap v
_insertU i v (QIMap qm um) = QIMap qm (Map.insert i v um)

lookup :: forall v. Qualified Ident -> QIMap v -> Maybe v
lookup (Qualified (Just q) i) = _lookupQ q i
lookup (Qualified _ i) = _lookupU i
_lookupQ :: forall v. ModuleName -> Ident -> QIMap v -> Maybe v
_lookupQ q i (QIMap qm _) = _lookupM q qm >>= _lookupI i
_lookupU :: forall v. Ident -> QIMap v -> Maybe v
_lookupU i (QIMap _ um) = _lookupI i um

member :: forall v. Qualified Ident -> QIMap v -> Boolean
member (Qualified (Just q) i) = _memberQ q i
member (Qualified _ i) = _memberU i
_memberQ :: forall v. ModuleName -> Ident -> QIMap v -> Boolean
_memberQ q i (QIMap qm _) = _lookupM q qm # maybe false (Map.member i)
_memberU :: forall v. Ident -> QIMap v -> Boolean
_memberU i (QIMap _ um) = Map.member i um

delete :: forall v. Qualified Ident -> QIMap v -> QIMap v
delete (Qualified (Just q) i) = _deleteQ q i
delete (Qualified _ i) = _deleteU i
_deleteQ :: forall v. ModuleName -> Ident -> QIMap v -> QIMap v
_deleteQ q i (QIMap qm um) = QIMap (Map.alter inner q qm) um
  where
  inner (Just im) | im' <- Map.delete i im, not Map.isEmpty im' = Just im'
  inner _ = Nothing
_deleteU :: forall v. Ident -> QIMap v -> QIMap v
_deleteU i (QIMap qm um) = QIMap qm (Map.delete i um)

moduleNames :: forall v. QIMap v -> Set ModuleName
moduleNames (QIMap qm _) = Map.keys qm

matchModules :: Set ModuleName -> QIMap ~> QIMap
matchModules names (QIMap qm um) = QIMap (Set.toMap names *> qm) um

filterModules :: (Maybe ModuleName -> Boolean) -> QIMap ~> QIMap
filterModules p (QIMap qm um) = QIMap (Map.filterKeys (p <<< Just) qm) (if p Nothing then um else Map.empty)

lookupModule :: forall v. ModuleName -> QIMap v -> Maybe (Map.Map Ident v)
lookupModule q (QIMap qm _) = _lookupM q qm


_lookupM :: forall v. ModuleName -> Map ModuleName v -> Maybe v
_lookupM k = go
  where
  go = case _ of
    Internal.Node _ _ mk mv ml mr ->
      if k == mk then Just mv else
      if k < mk then go ml else go mr
    _ -> Nothing

_lookupI :: forall v. Ident -> Map Ident v -> Maybe v
_lookupI k = go
  where
  go = case _ of
    Internal.Node _ _ mk mv ml mr ->
      if k == mk then Just mv else
      if k < mk then go ml else go mr
    _ -> Nothing
