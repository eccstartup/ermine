{-# LANGUAGE CPP #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
--------------------------------------------------------------------
-- |
-- Copyright :  (c) Edward Kmett 2011-2012
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------
module Ermine.Inference.Kind
  ( inferKind
  , checkKind
  , checkDataTypeKinds
  , checkDataTypeGroup
  , checkDataTypeKind
  , checkConstructorKind
  ) where

import Bound
import Bound.Var
import Control.Applicative
import Control.Comonad
import Control.Lens
import Control.Monad
import Control.Monad.Reader.Class
import Control.Monad.State
import Control.Monad.Writer.Strict
import Data.Bifunctor
import Data.Foldable hiding (concat)
import Data.Graph (stronglyConnComp, flattenSCC)
import Data.IntSet.Lens
import Data.List (nub, elemIndex)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Traversable (for)
import Data.Void
import Ermine.Diagnostic
import Ermine.Syntax
import Ermine.Syntax.DataType as Data
import Ermine.Syntax.Global
import Ermine.Syntax.Hint
import Ermine.Syntax.Kind as Kind
import Ermine.Syntax.Scope
import qualified Ermine.Syntax.Type as Type
import Ermine.Syntax.Type hiding (Var)
import Ermine.Unification.DataType
import Ermine.Unification.Kind
import Ermine.Unification.Meta

productKind :: Int -> Kind k
productKind 0 = star
productKind n = star :-> productKind (n - 1)

matchFunKind :: KindM s -> M s (KindM s, KindM s)
matchFunKind (a :-> b)    = return (a, b)
matchFunKind (HardKind _) = fail "not a fun kind"
matchFunKind (Var kv) = do
  a <- Var <$> newMeta ()
  b <- Var <$> newMeta ()
  (a, b) <$ runWriterT (unifyKindVar kv (a :-> b))

instantiateSchema :: Schema (MetaK s) -> M s (KindM s)
instantiateSchema (Schema hs s) = do
  vs <- forM hs (\_ -> Var <$> newMeta ())
  return $ instantiate (vs!!) s
{-# INLINE instantiateSchema #-}

-- | Check that the 'Kind' of a given 'Type' can unify with the specified kind.
checkKind :: Type (MetaK s) (KindM s) -> KindM s -> M s ()
checkKind t k = do
  k' <- inferKind t
  () <$ runWriterT (unifyKind k k')

-- | Infer a kind for a given type.
inferKind :: Type (MetaK s) (KindM s) -> M s (KindM s)
inferKind (Loc l t)                = local (set rendering l) $ inferKind t
inferKind (Type.Var tk)            = return tk
inferKind (HardType Arrow)         = return $ star :-> star :-> star
inferKind (HardType (Con _ s))     = instantiateSchema (vacuous s)
inferKind (HardType (Tuple n))     = return $ productKind n
inferKind (HardType ConcreteRho{}) = return rho
inferKind (App f x) = do
  kf <- inferKind f
  (a, b) <- matchFunKind kf
  b <$ checkKind x a
inferKind (And cs) = constraint <$ traverse_ (checkKind ?? constraint) cs
inferKind (Exists n tks cs) = do
  sks <- for n $ \_ -> newSkolem ()
  let btys = instantiateVars sks . extract <$> tks
  checkKind (instantiateKindVars sks $ instantiateVars btys cs) constraint
  return constraint
inferKind (Forall n tks cs b) = do
  sks <- for n $ \_ -> newSkolem ()
  let btys = instantiateVars sks . extract <$> tks
  checkKind (instantiateKindVars sks (instantiateVars btys cs)) constraint
  checkKind (instantiateKindVars sks (instantiateVars btys b)) star
  return star

fixCons :: (Ord t) => Map t (Type k u) -> (t -> Type k u) -> DataType k t -> DataType k u
fixCons m f dt = boundBy (\t -> fromMaybe (f t) $ Map.lookup t m) dt

-- checkDataTypeKinds :: MonadMeta s m
--                    => [DataType () Text] -> m [DataType Void Void]
checkDataTypeKinds :: [DataType () Text] -> M s [DataType Void Void]
checkDataTypeKinds dts = flip evalStateT Map.empty
                       . fmap concat . traverse (ck.flattenSCC) $ stronglyConnComp graph
 where
 graph = map (\dt -> (dt, dt^.name, toListOf typeVars dt)) dts
 conMap = Map.fromList . map (\dt -> (dt^.name, con (dt^.global) (dataTypeSchema dt)))
 ck scc = StateT $ \m -> do
   let scc' = map (fixCons m pure) scc
   cscc <- checkDataTypeGroup scc'
   return (cscc, m `Map.union` conMap cscc)

-- checkDataTypeGroup :: MonadMeta s m
--                    => [DataType (Maybe Text) Text] -> m [DataType Void Void]
checkDataTypeGroup :: [DataType () Text] -> M s [DataType Void Void]
checkDataTypeGroup dts = do
  dkss <- for dts $ \dt -> (\dt' -> (dt', dataTypeSchema dt')) <$> kindVars newMeta dt
  let m = Map.fromList $ first (^.name) <$> dkss
  checked <- for dkss $ \(dt, Schema _ s) -> do
    sks <- for (dt^.kparams) $ \_ -> newSkolem ()
    let selfKind = instantiateVars sks s
    dt' <- for dt $ \t ->
             if t == dt^.name
               then pure selfKind
               else case Map.lookup t m of
                 Just sc -> refresh sc
                 Nothing -> fail "unknown reference"
    (dt,sks,) <$> checkDataTypeKind selfKind dt'
  let sm = Map.fromList $ (\(dt, _, sch) -> (dt^.name, con (dt^.global) sch)) <$> checked
      sdts = checked <&> \(dt, sks, _) ->
               (sks, fixCons sm (\_ -> error "checkDataTypeGroup: IMPOSSIBLE") dt)
  traverse closeKinds sdts
 where
 refresh (Schema ks s) = (instantiateVars ?? s) <$> traverse (\_ -> newMeta ()) ks
 closeKinds (sks, dt) = do
   dt' <- zonkDataType dt
   let fvs = nub . toListOf (kindVars . filtered (isn't skolem)) $ dt'
       offset = length sks
       f (F m) | Just i <- m `elemIndex` fvs = pure . B $ i + offset
               | Just i <- m `elemIndex` sks = pure . B $ i + offset
               | otherwise                   = fail "escaped skolem"
       f (B i)                               = pure $ B i
       reabstr = fmap toScope . traverse f . fromScope
   ts' <- (traverse . traverse) reabstr $ dt'^.tparams
   cs' <- (traverse . kindVars) f $ dt'^.constrs
   return $ DataType (dt^.global) (dt^.kparams ++ (Unhinted () <$ fvs)) ts' cs'

-- | Checks that the types in a data declaration have sensible kinds.
-- checkDataTypeKind :: MonadMeta s m
--                   => KindM s -> DataType (MetaK s) (KindM s) -> m (Schema a)
checkDataTypeKind :: KindM s -> DataType (MetaK s) (KindM s) -> M s (Schema a)
checkDataTypeKind self (DataType _ ks ts cs) = do
  sks <- for ks $ \_ -> newSkolem ()
  let btys = instantiateVars sks . extract <$> ts
  for_ cs $ \c -> checkConstructorKind
                    (bimap (unvar (sks!!) id) (unvar (btys !!) id) c)
  checkKind (apps (pure self) $ pure <$> btys) star
  generalizeOver (setOf (traverse.metaId) sks) self

-- | Checks that the types in a data constructor have sensible kinds.
-- checkConstructorKind :: MonadMeta s m
--                      => Constructor (MetaK s) (KindM s)
--                      -> m ()
checkConstructorKind :: Constructor (MetaK s) (KindM s) -> M s ()
checkConstructorKind (Constructor _ ks ts fs) = do
  sks <- for ks $ \_ -> newSkolem ()
  let btys = instantiateVars sks . extract <$> ts
  for_ fs $ \fld ->
    checkKind (instantiateKindVars sks $ instantiateVars btys fld) star
