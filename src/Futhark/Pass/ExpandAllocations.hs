{-# LANGUAGE TypeFamilies, FlexibleContexts #-}
-- | Expand allocations inside of maps when possible.
module Futhark.Pass.ExpandAllocations
       ( expandAllocations )
       where

import Control.Monad.Except
import Control.Monad.State
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe
import Data.List
import Data.Monoid

import Futhark.Error
import Futhark.MonadFreshNames
import Futhark.Tools
import Futhark.Util
import Futhark.Pass
import Futhark.Representation.AST
import Futhark.Representation.ExplicitMemory
       hiding (Prog, Body, Stm, Pattern, PatElem,
               BasicOp, Exp, Lambda, FunDef, FParam, LParam, RetType)
import qualified Futhark.Representation.ExplicitMemory.IndexFunction as IxFun

expandAllocations :: Pass ExplicitMemory ExplicitMemory
expandAllocations =
  Pass "expand allocations" "Expand allocations" $
  intraproceduralTransformation transformFunDef

transformFunDef :: FunDef ExplicitMemory -> PassM (FunDef ExplicitMemory)
transformFunDef fundec = do
  body' <- either throwError return <=< modifyNameSource $ runState $ runExceptT m
  return fundec { funDefBody = body' }
  where m = transformBody $ funDefBody fundec

type ExpandM = ExceptT InternalError (State VNameSource)

transformBody :: Body ExplicitMemory -> ExpandM (Body ExplicitMemory)
transformBody (Body () bnds res) = do
  bnds' <- mconcat <$> mapM transformStm (stmsToList bnds)
  return $ Body () bnds' res

transformStm :: Stm ExplicitMemory -> ExpandM (Stms ExplicitMemory)

transformStm (Let pat aux e) = do
  (bnds, e') <- transformExp =<< mapExpM transform e
  return $ bnds <> oneStm (Let pat aux e')
  where transform = identityMapper { mapOnBody = const transformBody
                                   }

transformExp :: Exp ExplicitMemory -> ExpandM (Stms ExplicitMemory, Exp ExplicitMemory)

transformExp (Op (Inner (Kernel desc space ts kbody))) =
  case extractKernelBodyAllocations bound_in_kernel kbody of
    Left err -> compilerLimitationS err
    Right (kbody', thread_allocs) -> do
      num_threads64 <- newVName "num_threads64"
      let num_threads64_pat = Pattern [] [PatElem num_threads64 $ MemPrim int64]
          num_threads64_bnd = Let num_threads64_pat (defAux ()) $ BasicOp $
                              ConvOp (SExt Int32 Int64) (spaceNumThreads space)

      (alloc_bnds, alloc_offsets) <-
        expandedAllocations
        (Var num_threads64, spaceNumGroups space, spaceGroupSize space)
        (spaceGlobalId space, spaceGroupId space, spaceLocalId space) thread_allocs
      let kbody'' = offsetMemoryInKernelBody alloc_offsets kbody'

      return (oneStm num_threads64_bnd <> alloc_bnds,
              Op $ Inner $ Kernel desc space ts kbody'')

  where bound_in_kernel =
          S.fromList $ M.keys $ scopeOfKernelSpace space <>
          scopeOf (kernelBodyStms kbody)

transformExp e =
  return (mempty, e)

-- | Extract allocations from 'Thread' statements with
-- 'extractThreadAllocations'.
extractKernelBodyAllocations :: Names -> KernelBody InKernel
                             -> Either String (KernelBody InKernel,
                                               M.Map VName (SubExp, Space))
extractKernelBodyAllocations bound_before_body kbody = do
  (allocs, stms) <- mapAccumLM extract M.empty $ stmsToList $ kernelBodyStms kbody
  return (kbody { kernelBodyStms = mconcat stms }, allocs)
  where extract allocs bnd = do
          (bnds, body_allocs) <- extractThreadAllocations bound_before_body $ oneStm bnd
          return (allocs <> body_allocs, bnds)

extractThreadAllocations :: Names -> Stms InKernel
                         -> Either String (Stms InKernel, M.Map VName (SubExp, Space))
extractThreadAllocations bound_before_body bnds = do
  (allocs, bnds') <- mapAccumLM isAlloc M.empty $ stmsToList bnds
  return (stmsFromList $ catMaybes bnds', allocs)
  where bound_here = bound_before_body `S.union` boundByStms bnds

        isAlloc _ (Let (Pattern [] [patElem]) _ (Op (Alloc (Var v) _)))
          | v `S.member` bound_here =
            throwError $ "Size " ++ pretty v ++
            " for block " ++ pretty patElem ++
            " is not lambda-invariant"

        isAlloc allocs (Let (Pattern [] [patElem]) _ (Op (Alloc size space))) =
          return (M.insert (patElemName patElem) (size, space) allocs,
                  Nothing)

        isAlloc allocs bnd =
          return (allocs, Just bnd)

expandedAllocations :: (SubExp,SubExp, SubExp)
                    -> (VName, VName, VName)
                    -> M.Map VName (SubExp, Space)
                    -> ExpandM (Stms ExplicitMemory, RebaseMap)
expandedAllocations (num_threads64, num_groups, group_size) (_thread_index, group_id, local_id) thread_allocs = do
  -- We expand the allocations by multiplying their size with the
  -- number of kernel threads.
  (alloc_bnds, rebase_map) <- unzip <$> mapM expand (M.toList thread_allocs)

  -- Fix every reference to the memory blocks to be offset by the
  -- thread number.
  let alloc_offsets =
        RebaseMap { rebaseMap = mconcat rebase_map
                  , indexVariable = (group_id, local_id)
                  , kernelWidth = (num_groups, group_size)
                  }
  return (mconcat alloc_bnds, alloc_offsets)
  where expand (mem, (per_thread_size, Space "local")) = do
          let allocpat = Pattern [] [PatElem mem $
                                     MemMem per_thread_size $ Space "local"]
          return (oneStm $ Let allocpat (defAux ()) $
                   Op $ Alloc per_thread_size $ Space "local",
                  mempty)

        expand (mem, (per_thread_size, space)) = do
          total_size <- newVName "total_size"
          let sizepat = Pattern [] [PatElem total_size $ MemPrim int64]
              allocpat = Pattern [] [PatElem mem $
                                     MemMem (Var total_size) space]
          return (stmsFromList
                  [Let sizepat (defAux ()) $
                    BasicOp $ BinOp (Mul Int64) num_threads64 per_thread_size,
                   Let allocpat (defAux ()) $
                    Op $ Alloc (Var total_size) space],
                  M.singleton mem newBase)

        newBase old_shape =
          let num_dims = length old_shape
              perm = [0, num_dims+1] ++ [1..num_dims]
              root_ixfun = IxFun.iota (primExpFromSubExp int32 num_groups : old_shape
                                       ++ [primExpFromSubExp int32 group_size])
              permuted_ixfun = IxFun.permute root_ixfun perm
              untouched d = DimSlice 0 d 1
              offset_ixfun = IxFun.slice permuted_ixfun $
                             [DimFix (LeafExp group_id int32),
                              DimFix (LeafExp local_id int32)] ++
                             map untouched old_shape
          in offset_ixfun

data RebaseMap = RebaseMap {
    rebaseMap :: M.Map VName ([PrimExp VName] -> IxFun)
    -- ^ A map from memory block names to new index function bases.
  , indexVariable :: (VName, VName)
  , kernelWidth :: (SubExp, SubExp)
  }

lookupNewBase :: VName -> [PrimExp VName] -> RebaseMap -> Maybe IxFun
lookupNewBase name dims = fmap ($dims) . M.lookup name . rebaseMap

offsetMemoryInKernelBody :: RebaseMap -> KernelBody InKernel
                         -> KernelBody InKernel
offsetMemoryInKernelBody initial_offsets kbody =
  kbody { kernelBodyStms = stmsFromList stms' }
  where stms' = snd $ mapAccumL offsetMemoryInStm initial_offsets $
                stmsToList $ kernelBodyStms kbody

offsetMemoryInBody :: RebaseMap -> Body InKernel -> Body InKernel
offsetMemoryInBody offsets (Body attr bnds res) =
  Body attr (stmsFromList $ snd $ mapAccumL offsetMemoryInStm offsets $ stmsToList bnds) res

offsetMemoryInStm :: RebaseMap -> Stm InKernel
                      -> (RebaseMap, Stm InKernel)
offsetMemoryInStm offsets (Let pat attr e) =
  (offsets', Let pat' attr $ offsetMemoryInExp offsets e)
  where (offsets', pat') = offsetMemoryInPattern offsets pat

offsetMemoryInPattern :: RebaseMap -> Pattern InKernel -> (RebaseMap, Pattern InKernel)
offsetMemoryInPattern offsets (Pattern ctx vals) =
  (offsets', Pattern ctx vals')
  where offsets' = foldl inspectCtx offsets ctx
        vals' = map inspectVal vals
        inspectVal patElem =
          patElem { patElemAttr =
                       offsetMemoryInMemBound offsets' $ patElemAttr patElem
                  }
        inspectCtx ctx_offsets patElem
          | Mem _ _ <- patElemType patElem =
              error $ unwords ["Cannot deal with existential memory block",
                               pretty (patElemName patElem),
                               "when expanding inside kernels."]
          | otherwise =
              ctx_offsets

offsetMemoryInParam :: RebaseMap -> Param (MemBound u) -> Param (MemBound u)
offsetMemoryInParam offsets fparam =
  fparam { paramAttr = offsetMemoryInMemBound offsets $ paramAttr fparam }

offsetMemoryInMemBound :: RebaseMap -> MemBound u -> MemBound u
offsetMemoryInMemBound offsets (MemArray bt shape u (ArrayIn mem ixfun))
  | Just new_base <- lookupNewBase mem (IxFun.base ixfun) offsets =
      MemArray bt shape u $ ArrayIn mem $ IxFun.rebase new_base ixfun
offsetMemoryInMemBound _ summary =
  summary

offsetMemoryInBodyReturns :: RebaseMap -> BodyReturns -> BodyReturns
offsetMemoryInBodyReturns offsets (MemArray pt shape u (ReturnsInBlock mem ixfun))
  | Just ixfun' <- isStaticIxFun ixfun,
    Just new_base <- lookupNewBase mem (IxFun.base ixfun') offsets =
      MemArray pt shape u $ ReturnsInBlock mem $
      IxFun.rebase (fmap (fmap Free) new_base) ixfun
offsetMemoryInBodyReturns _ br = br

offsetMemoryInExp :: RebaseMap -> Exp InKernel -> Exp InKernel
offsetMemoryInExp offsets (DoLoop ctx val form body) =
  DoLoop (zip ctxparams' ctxinit) (zip valparams' valinit) form body'
  where (ctxparams, ctxinit) = unzip ctx
        (valparams, valinit) = unzip val
        body' = offsetMemoryInBody offsets body
        ctxparams' = map (offsetMemoryInParam offsets) ctxparams
        valparams' = map (offsetMemoryInParam offsets) valparams
offsetMemoryInExp offsets (Op (Inner (GroupStream w max_chunk lam accs arrs))) =
  Op (Inner (GroupStream w max_chunk lam' accs arrs))
  where lam' =
          lam { groupStreamLambdaBody = offsetMemoryInBody offsets $
                                        groupStreamLambdaBody lam
              , groupStreamAccParams = map (offsetMemoryInParam offsets) $
                                       groupStreamAccParams lam
              , groupStreamArrParams = map (offsetMemoryInParam offsets) $
                                       groupStreamArrParams lam
              }
offsetMemoryInExp offsets (Op (Inner (GroupReduce w lam input))) =
  Op (Inner (GroupReduce w lam' input))
  where lam' = lam { lambdaBody = offsetMemoryInBody offsets $ lambdaBody lam }
offsetMemoryInExp offsets (Op (Inner (Combine cspace ts active body))) =
  Op $ Inner $ Combine cspace ts active $ offsetMemoryInBody offsets body
offsetMemoryInExp offsets e = mapExp recurse e
  where recurse = identityMapper
                  { mapOnBody = const $ return . offsetMemoryInBody offsets
                  , mapOnBranchType = return . offsetMemoryInBodyReturns offsets
                  }
