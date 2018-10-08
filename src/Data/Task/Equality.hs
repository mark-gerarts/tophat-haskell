module Data.Task.Equality
  ( (===), (~=)
  , prop_pair_left_identity, prop_pair_right_identity, prop_pair_associativity
  , prop_choose_left_identity, prop_choose_right_identity, prop_choose_associativity
  , prop_choose_left_absorbtion, prop_choose_left_catch
  , prop_step_left_identity, prop_step_right_identity, prop_step_assocaitivity
  ) where


import Preload

import Data.Task
import Data.Task.Input

import System.IO.Unsafe


infix 1 ===, ~=



-- Equivallence ----------------------------------------------------------------


(===) :: Basic a => MonadRef l m => TaskT l m a -> TaskT l m a -> m Bool
t1 === t2 = do
  ( (_, v1), (_, v2) ) <- norm t1 t2
  pure $ v1 == v2


norm :: MonadRef l m => TaskT l m a -> TaskT l m a -> m ( (TaskT l m a, Maybe a), ( TaskT l m a, Maybe a ) )
norm t1 t2 = do
  t1' <- normalise t1
  t2' <- normalise t2
  v1 <- value t1'
  v2 <- value t2'
  pure $ ( (t1', v1), (t2', v2) )



-- Similarity ------------------------------------------------------------------


(~=) :: Basic a => MonadTrace NotApplicable m => MonadRef l m => TaskT l m a -> TaskT l m a -> m Bool
t1 ~= t2 = do
  ( (t1', v1), (t2', v2) ) <- norm t1 t2
  if v1 == v2 then do
    ok12 <- simulating t1' t2'
    ok21 <- simulating t2' t1'
    pure $ ok12 && ok21
  else
    pure False

  where

    simulating t1' t2' = do
      is1 <- inputs t1'
      is2 <- inputs t2'
      forall is1 $ \i1 -> forany is2 $ \i2 -> progressing t1' i1 t2' i2

    progressing t1' i1 t2' i2
      | i1 ~? i2 = do
          t1'' <- handle t1' i1
          t2'' <- handle t2' i2
          t1'' ~= t2''
      | otherwise =
          pure True



-- Properties ------------------------------------------------------------------

-- Monoidal functor --


prop_pair_left_identity :: TaskIO Int -> Bool
prop_pair_left_identity t = unsafePerformIO $
  tmap snd (edit () |&| t) === t


prop_pair_right_identity :: TaskIO Int -> Bool
prop_pair_right_identity t = unsafePerformIO $
  tmap fst (t |&| edit ()) === t


prop_pair_associativity :: TaskIO Int -> TaskIO Int -> TaskIO Int -> Bool
prop_pair_associativity r s t = unsafePerformIO $
  tmap assoc (r |&| (s |&| t)) === (r |&| s) |&| t



-- Alternative functor --


prop_choose_left_identity :: TaskIO Int -> Bool
prop_choose_left_identity t = unsafePerformIO $
  fail |!| t === t


prop_choose_right_identity :: TaskIO Int -> Bool
prop_choose_right_identity t = unsafePerformIO $
  t |!| fail === t


prop_choose_associativity :: TaskIO Int -> TaskIO Int -> TaskIO Int -> Bool
prop_choose_associativity r s t = unsafePerformIO $
  r |!| (s |!| t) === (r |!| s) |!| t


prop_choose_left_absorbtion :: TaskIO Int -> Bool
prop_choose_left_absorbtion t = unsafePerformIO $
  fail >>! (\_ -> t) === fail


prop_choose_left_catch :: Int -> TaskIO Int -> Bool
prop_choose_left_catch x t = unsafePerformIO $
  edit x |!| t === edit x



-- Monad --


prop_step_left_identity :: Int -> TaskIO Int -> Bool
prop_step_left_identity x t = unsafePerformIO $
  edit x >>! (\_ -> t) === t


prop_step_right_identity :: TaskIO Int -> Bool
prop_step_right_identity t = unsafePerformIO $
  t >>! (\y -> edit y) === t


prop_step_assocaitivity :: TaskIO Int -> TaskIO Int -> TaskIO Int -> Bool
prop_step_assocaitivity r s t = unsafePerformIO $
  (r >>! (\_ -> s)) >>! (\_ -> t) === r >>! (\_ -> s >>! (\_ -> t))



-- Helpers --


assoc :: ( a, ( b, c ) ) -> ( ( a, b ), c )
assoc ( a, ( b, c ) ) = ( ( a, b ), c )
