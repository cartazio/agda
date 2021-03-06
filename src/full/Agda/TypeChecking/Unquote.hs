{-# LANGUAGE CPP               #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternGuards     #-}

module Agda.TypeChecking.Unquote where

import Control.Applicative
import Control.Monad.State (runState, get, put)
import Control.Monad.Reader (ReaderT(..), ask, asks)
import Control.Monad.Writer (WriterT(..), execWriterT, runWriterT, tell)
import Control.Monad.Trans (lift)
import Control.Monad

import Data.Char
import Data.Maybe (fromMaybe)
import Data.Traversable (traverse)
import Data.Map (Map)
import qualified Data.Map as Map

import Agda.Syntax.Common
import Agda.Syntax.Internal as I
import qualified Agda.Syntax.Reflected as R
import Agda.Syntax.Literal
import Agda.Syntax.Position
import Agda.Syntax.Fixity
import Agda.Syntax.Info
import Agda.Syntax.Translation.InternalToAbstract
import Agda.Syntax.Translation.ReflectedToAbstract

import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Datatypes ( getConHead )
import Agda.TypeChecking.DropArgs
import Agda.TypeChecking.Free
import Agda.TypeChecking.Level
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Monad.Exception
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Reduce.Monad hiding (reportSDoc)
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Quote
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.MetaVars
import Agda.TypeChecking.EtaContract
import Agda.TypeChecking.Primitive

import {-# SOURCE #-} Agda.TypeChecking.Rules.Term
import {-# SOURCE #-} Agda.TypeChecking.Rules.Def

import Agda.Utils.Except
import Agda.Utils.Impossible
import Agda.Utils.Monad ( ifM )
import Agda.Utils.Permutation ( Permutation(Perm), compactP )
import Agda.Utils.String ( Str(Str), unStr )
import Agda.Utils.VarSet (VarSet)
import qualified Agda.Utils.VarSet as Set
import Agda.Utils.Maybe.Strict (toLazy)
import Agda.Utils.FileName

#include "undefined.h"

agdaTermType :: TCM Type
agdaTermType = El (mkType 0) <$> primAgdaTerm

agdaTypeType :: TCM Type
agdaTypeType = agdaTermType

qNameType :: TCM Type
qNameType = El (mkType 0) <$> primQName

-- Keep track of the original context. We need to use that when adding new
-- definitions.
type UnquoteM = ReaderT Context (WriterT [QName] (ExceptionT UnquoteError TCM))

type UnquoteRes a = Either UnquoteError (a, [QName])

unpackUnquoteM :: UnquoteM a -> Context -> TCM (UnquoteRes a)
unpackUnquoteM m cxt = runExceptionT $ runWriterT $ runReaderT m cxt

packUnquoteM :: (Context -> TCM (UnquoteRes a)) -> UnquoteM a
packUnquoteM f = ReaderT $ \ cxt -> WriterT $ ExceptionT $ f cxt

runUnquoteM :: UnquoteM a -> TCM (UnquoteRes a)
runUnquoteM m = do
  cxt <- asks envContext
  z   <- unpackUnquoteM m cxt
  case z of
    Left err         -> return $ Left err
    Right (_, decls) -> z <$ mapM_ isDefined decls
  where
    isDefined x = do
      def <- theDef <$> getConstInfo x
      case def of
        Function{funClauses = []} -> genericError $ "Missing definition for " ++ show x
        _       -> return ()

liftU :: TCM a -> UnquoteM a
liftU = lift . lift . lift

liftU1 :: (TCM (UnquoteRes a) -> TCM (UnquoteRes b)) -> UnquoteM a -> UnquoteM b
liftU1 f m = packUnquoteM $ \ cxt -> f (unpackUnquoteM m cxt)

liftU2 :: (TCM (UnquoteRes a) -> TCM (UnquoteRes b) -> TCM (UnquoteRes c)) -> UnquoteM a -> UnquoteM b -> UnquoteM c
liftU2 f m1 m2 = packUnquoteM $ \ cxt -> f (unpackUnquoteM m1 cxt) (unpackUnquoteM m2 cxt)

inOriginalContext :: UnquoteM a -> UnquoteM a
inOriginalContext m =
  packUnquoteM $ \ cxt ->
    modifyContext (const cxt) $ unpackUnquoteM m cxt

isCon :: ConHead -> TCM Term -> UnquoteM Bool
isCon con tm = do t <- liftU tm
                  case ignoreSharing t of
                    Con con' _ -> return (con == con')
                    _ -> return False

isDef :: QName -> TCM Term -> UnquoteM Bool
isDef f tm = do
  t <- liftU tm
  case ignoreSharing t of
    Def g _ -> return (f == g)
    _       -> return False

reduceQuotedTerm :: Term -> UnquoteM Term
reduceQuotedTerm t = do
  b <- liftU $ ifBlocked t (\ m _ -> pure $ Left  m)
                           (\ t   -> pure $ Right t)
  case b of
    Left m  -> throwException $ BlockedOnMeta m
    Right t -> return t

class Unquote a where
  unquote :: I.Term -> UnquoteM a

unquoteH :: Unquote a => Arg Term -> UnquoteM a
unquoteH a | isHidden a && isRelevant a =
    unquote $ unArg a
unquoteH a = throwException $ BadVisibility "hidden"  a

unquoteN :: Unquote a => Arg Term -> UnquoteM a
unquoteN a | notHidden a && isRelevant a =
    unquote $ unArg a
unquoteN a = throwException $ BadVisibility "visible" a

choice :: Monad m => [(m Bool, m a)] -> m a -> m a
choice [] dflt = dflt
choice ((mb, mx) : mxs) dflt = ifM mb mx $ choice mxs dflt

ensureDef :: QName -> UnquoteM QName
ensureDef x = do
  i <- liftU $ (theDef <$> getConstInfo x) `catchError` \_ -> return Axiom  -- for recursive unquoteDecl
  case i of
    Constructor{} -> do
      def <- liftU $ prettyTCM =<< primAgdaTermDef
      con <- liftU $ prettyTCM =<< primAgdaTermCon
      throwException $ ConInsteadOfDef x (show def) (show con)
    _ -> return x

ensureCon :: QName -> UnquoteM QName
ensureCon x = do
  i <- liftU $ (theDef <$> getConstInfo x) `catchError` \_ -> return Axiom  -- for recursive unquoteDecl
  case i of
    Constructor{} -> return x
    _ -> do
      def <- liftU $ prettyTCM =<< primAgdaTermDef
      con <- liftU $ prettyTCM =<< primAgdaTermCon
      throwException $ DefInsteadOfCon x (show def) (show con)

pickName :: R.Type -> String
pickName a =
  case a of
    R.Pi{}   -> "f"
    R.Sort{} -> "A"
    R.Def d _ | c:_ <- show (qnameName d),
              isAlpha c -> [toLower c]
    _        -> "_"

instance Unquote ArgInfo where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [h,r] -> do
        choice
          [(c `isCon` primArgArgInfo, ArgInfo <$> unquoteN h <*> unquoteN r)]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "arg info" t

instance Unquote a => Unquote (Arg a) where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [info,x] -> do
        choice
          [(c `isCon` primArgArg, Arg <$> unquoteN info <*> unquoteN x)]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "arg" t

-- Andreas, 2013-10-20: currently, post-fix projections are not part of the
-- quoted syntax.
instance Unquote R.Elim where
  unquote t = R.Apply <$> unquote t

instance Unquote Integer where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Lit (LitNat _ n) -> return n
      _ -> throwException $ NonCanonical "integer" t

instance Unquote Double where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Lit (LitFloat _ x) -> return x
      _ -> throwException $ NonCanonical "float" t

instance Unquote Char where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Lit (LitChar _ x) -> return x
      _ -> throwException $ NonCanonical "char" t

instance Unquote Str where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Lit (LitString _ x) -> return (Str x)
      _ -> throwException $ NonCanonical "string" t

unquoteString :: Term -> UnquoteM String
unquoteString x = unStr <$> unquote x

unquoteNString :: Arg Term -> UnquoteM String
unquoteNString x = unStr <$> unquoteN x

data ErrorPart = StrPart String | TermPart R.Term | NamePart QName

instance PrettyTCM ErrorPart where
  prettyTCM (StrPart s) = text s
  prettyTCM (TermPart t) = prettyTCM t
  prettyTCM (NamePart x) = prettyTCM x

instance Unquote ErrorPart where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [x] ->
        choice [ (c `isCon` primAgdaErrorPartString, StrPart  <$> unquoteNString x)
               , (c `isCon` primAgdaErrorPartTerm,   TermPart <$> unquoteN x)
               , (c `isCon` primAgdaErrorPartName,   NamePart <$> unquoteN x) ]
               __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "error part" t

instance Unquote a => Unquote [a] where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [x,xs] -> do
        choice
          [(c `isCon` primCons, (:) <$> unquoteN x <*> unquoteN xs)]
          __IMPOSSIBLE__
      Con c [] -> do
        choice
          [(c `isCon` primNil, return [])]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "list" t

instance Unquote Hiding where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [] -> do
        choice
          [(c `isCon` primHidden,  return Hidden)
          ,(c `isCon` primInstance, return Instance)
          ,(c `isCon` primVisible, return NotHidden)]
          __IMPOSSIBLE__
      Con c vs -> __IMPOSSIBLE__
      _        -> throwException $ NonCanonical "visibility" t

instance Unquote Relevance where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [] -> do
        choice
          [(c `isCon` primRelevant,   return Relevant)
          ,(c `isCon` primIrrelevant, return Irrelevant)]
          __IMPOSSIBLE__
      Con c vs -> __IMPOSSIBLE__
      _        -> throwException $ NonCanonical "relevance" t

instance Unquote QName where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Lit (LitQName _ x) -> return x
      _                  -> throwException $ NonCanonical "name" t

instance Unquote a => Unquote (R.Abs a) where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [x,y] -> do
        choice
          [(c `isCon` primAbsAbs, R.Abs <$> (hint <$> unquoteNString x) <*> unquoteN y)]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "abstraction" t

    where hint x | not (null x) = x
                 | otherwise    = "_"

getCurrentPath :: TCM AbsolutePath
getCurrentPath = fromMaybe __IMPOSSIBLE__ <$> asks envCurrentPath

instance Unquote MetaId where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Lit (LitMeta r f x) -> do
        live <- (== f) <$> liftU getCurrentPath
        unless live $ liftU $ do
            m <- fromMaybe __IMPOSSIBLE__ . Map.lookup f <$> sourceToModule
            typeError . GenericDocError =<<
              sep [ text "Can't unquote stale metavariable"
                  , pretty m <> text "." <> pretty x ]
        return x
      _ -> throwException $ NonCanonical "meta variable" t

instance Unquote a => Unquote (Dom a) where
  unquote t = domFromArg <$> unquote t

instance Unquote R.Sort where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [] -> do
        choice
          [(c `isCon` primAgdaSortUnsupported, return R.UnknownS)]
          __IMPOSSIBLE__
      Con c [u] -> do
        choice
          [(c `isCon` primAgdaSortSet, R.SetS <$> unquoteN u)
          ,(c `isCon` primAgdaSortLit, R.LitS <$> unquoteN u)]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "sort" t

instance Unquote Literal where
  unquote t = do
    t <- reduceQuotedTerm t
    let litMeta r x = do
          file <- liftU getCurrentPath
          return $ LitMeta r file x
    case ignoreSharing t of
      Con c [x] ->
        choice
          [ (c `isCon` primAgdaLitNat,    LitNat    noRange <$> unquoteN x)
          , (c `isCon` primAgdaLitFloat,  LitFloat  noRange <$> unquoteN x)
          , (c `isCon` primAgdaLitChar,   LitChar   noRange <$> unquoteN x)
          , (c `isCon` primAgdaLitString, LitString noRange <$> unquoteNString x)
          , (c `isCon` primAgdaLitQName,  LitQName  noRange <$> unquoteN x)
          , (c `isCon` primAgdaLitMeta,   litMeta   noRange =<< unquoteN x) ]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "literal" t

instance Unquote R.Term where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [] ->
        choice
          [ (c `isCon` primAgdaTermUnsupported, return R.Unknown) ]
          __IMPOSSIBLE__

      Con c [x] -> do
        choice
          [ (c `isCon` primAgdaTermSort,      R.Sort      <$> unquoteN x)
          , (c `isCon` primAgdaTermLit,       R.Lit       <$> unquoteN x) ]
          __IMPOSSIBLE__

      Con c [x, y] ->
        choice
          [ (c `isCon` primAgdaTermVar,     R.Var     <$> (fromInteger <$> unquoteN x) <*> unquoteN y)
          , (c `isCon` primAgdaTermCon,     R.Con     <$> (ensureCon =<< unquoteN x) <*> unquoteN y)
          , (c `isCon` primAgdaTermDef,     R.Def     <$> (ensureDef =<< unquoteN x) <*> unquoteN y)
          , (c `isCon` primAgdaTermMeta,    R.Meta    <$> unquoteN x <*> unquoteN y)
          , (c `isCon` primAgdaTermLam,     R.Lam     <$> unquoteN x <*> unquoteN y)
          , (c `isCon` primAgdaTermPi,      mkPi      <$> unquoteN x <*> unquoteN y)
          , (c `isCon` primAgdaTermExtLam,  R.ExtLam  <$> unquoteN x <*> unquoteN y) ]
          __IMPOSSIBLE__
        where
          mkPi :: Dom R.Type -> R.Abs R.Type -> R.Term
          -- TODO: implement Free for reflected syntax so this works again
          --mkPi a (R.Abs "_" b) = R.Pi a (R.Abs x b)
          --  where x | 0 `freeIn` b = pickName (unDom a)
          --          | otherwise    = "_"
          mkPi a (R.Abs "_" b) = R.Pi a (R.Abs (pickName (unDom a)) b)
          mkPi a b = R.Pi a b

      Con{} -> __IMPOSSIBLE__
      Lit{} -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "term" t

instance Unquote R.Pattern where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [] -> do
        choice
          [ (c `isCon` primAgdaPatAbsurd, return R.AbsurdP)
          , (c `isCon` primAgdaPatDot,    return R.DotP)
          ] __IMPOSSIBLE__
      Con c [x] -> do
        choice
          [ (c `isCon` primAgdaPatVar,  R.VarP  <$> unquoteNString x)
          , (c `isCon` primAgdaPatProj, R.ProjP <$> unquoteN x)
          , (c `isCon` primAgdaPatLit,  R.LitP  <$> unquoteN x) ]
          __IMPOSSIBLE__
      Con c [x, y] -> do
        choice
          [ (c `isCon` primAgdaPatCon, R.ConP <$> unquoteN x <*> unquoteN y) ]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "pattern" t

instance Unquote R.Clause where
  unquote t = do
    t <- reduceQuotedTerm t
    case ignoreSharing t of
      Con c [x] -> do
        choice
          [ (c `isCon` primAgdaClauseAbsurd, R.AbsurdClause <$> unquoteN x) ]
          __IMPOSSIBLE__
      Con c [x, y] -> do
        choice
          [ (c `isCon` primAgdaClauseClause, R.Clause <$> unquoteN x <*> unquoteN y) ]
          __IMPOSSIBLE__
      Con c _ -> __IMPOSSIBLE__
      _ -> throwException $ NonCanonical "clause" t

-- Unquoting TCM computations ---------------------------------------------

-- | Argument should be a term of type @Term → TCM A@ for some A. Returns the
--   resulting term of type @A@. The second argument is the term for the hole,
--   which will typically be a metavariable. This is passed to the computation
--   (quoted).
unquoteTCM :: I.Term -> I.Term -> UnquoteM I.Term
unquoteTCM m hole = do
  qhole <- liftU $ quoteTerm hole
  evalTCM (m `apply` [defaultArg qhole])

evalTCM :: I.Term -> UnquoteM I.Term
evalTCM v = do
  v <- reduceQuotedTerm v
  liftU $ reportSDoc "tc.unquote.eval" 90 $ text "evalTCM" <+> prettyTCM v
  let failEval = throwException $ NonCanonical "type checking computation" v

  case ignoreSharing v of
    I.Def f [] ->
      choice [ (f `isDef` primAgdaTCMGetContext, tcGetContext) ]
             failEval
    I.Def f [u] ->
      choice [ (f `isDef` primAgdaTCMInferType,          tcFun1 tcInferType          u)
             , (f `isDef` primAgdaTCMNormalise,          tcFun1 tcNormalise          u)
             , (f `isDef` primAgdaTCMGetType,            tcFun1 tcGetType            u)
             , (f `isDef` primAgdaTCMGetDefinition,      tcFun1 tcGetDefinition      u)
             , (f `isDef` primAgdaTCMFreshName,          tcFun1 tcFreshName          u) ]
             failEval
    I.Def f [u, v] ->
      choice [ (f `isDef` primAgdaTCMUnify,      tcFun2 tcUnify      u v)
             , (f `isDef` primAgdaTCMCheckType,  tcFun2 tcCheckType  u v)
             , (f `isDef` primAgdaTCMDeclareDef, uqFun2 tcDeclareDef u v)
             , (f `isDef` primAgdaTCMDefineFun,  uqFun2 tcDefineFun  u v) ]
             failEval
    I.Def f [l, a, u] ->
      choice [ (f `isDef` primAgdaTCMReturn,      return (unElim u))
             , (f `isDef` primAgdaTCMTypeError,   tcFun1 tcTypeError   u)
             , (f `isDef` primAgdaTCMQuoteTerm,   tcQuoteTerm (unElim u))
             , (f `isDef` primAgdaTCMUnquoteTerm, tcFun1 (tcUnquoteTerm (mkT (unElim l) (unElim a))) u)
             , (f `isDef` primAgdaTCMBlockOnMeta, uqFun1 tcBlockOnMeta u) ]
             failEval
    I.Def f [_, _, u, v] ->
      choice [ (f `isDef` primAgdaTCMCatchError,    tcCatchError    (unElim u) (unElim v))
             , (f `isDef` primAgdaTCMExtendContext, tcExtendContext (unElim u) (unElim v))
             , (f `isDef` primAgdaTCMInContext,     tcInContext     (unElim u) (unElim v)) ]
             failEval
    I.Def f [_, _, _, _, m, k] ->
      choice [ (f `isDef` primAgdaTCMBind, tcBind (unElim m) (unElim k)) ]
             failEval
    _ -> failEval
  where
    unElim = unArg . argFromElim
    tcBind m k = do v <- evalTCM m
                    evalTCM (k `apply` [defaultArg v])

    mkT l a = El s a
      where s = Type $ Max [Plus 0 $ UnreducedLevel l]

    -- Don't catch Unquote errors!
    tcCatchError :: Term -> Term -> UnquoteM Term
    tcCatchError m h =
      liftU2 (\ m1 m2 -> m1 `catchError` \ _ -> m2) (evalTCM m) (evalTCM h)

    uqFun1 :: Unquote a => (a -> UnquoteM b) -> Elim -> UnquoteM b
    uqFun1 fun a = do
      a <- unquote (unElim a)
      fun a

    tcFun1 :: Unquote a => (a -> TCM b) -> Elim -> UnquoteM b
    tcFun1 fun = uqFun1 (liftU . fun)

    uqFun2 :: (Unquote a, Unquote b) => (a -> b -> UnquoteM c) -> Elim -> Elim -> UnquoteM c
    uqFun2 fun a b = do
      a <- unquote (unElim a)
      b <- unquote (unElim b)
      fun a b

    tcFun2 :: (Unquote a, Unquote b) => (a -> b -> TCM c) -> Elim -> Elim -> UnquoteM c
    tcFun2 fun = uqFun2 (\ x y -> liftU (fun x y))

    tcFreshName :: Str -> TCM Term
    tcFreshName s = do
      m <- currentModule
      quoteName . qualify m <$> freshName_ (unStr s)

    tcUnify :: R.Term -> R.Term -> TCM Term
    tcUnify u v = do
      (u, a) <- inferExpr        =<< toAbstract_ u
      v      <- flip checkExpr a =<< toAbstract_ v
      equalTerm a u v
      primUnitUnit

    tcBlockOnMeta :: MetaId -> UnquoteM Term
    tcBlockOnMeta x = throwException (BlockedOnMeta x)

    tcTypeError :: [ErrorPart] -> TCM a
    tcTypeError err = typeError . GenericDocError =<< fsep (map prettyTCM err)

    tcInferType :: R.Term -> TCM Term
    tcInferType v = do
      (_, a) <- inferExpr =<< toAbstract_ v
      quoteType =<< normalise a

    tcCheckType :: R.Term -> R.Type -> TCM Term
    tcCheckType v a = do
      a <- isType_ =<< toAbstract_ a
      e <- toAbstract_ v
      v <- checkExpr e a
      quoteTerm =<< normalise v

    tcQuoteTerm :: Term -> UnquoteM Term
    tcQuoteTerm v = liftU $ quoteTerm =<< normalise v

    tcUnquoteTerm :: Type -> R.Term -> TCM Term
    tcUnquoteTerm a v = do
      e <- toAbstract_ v
      v <- checkExpr e a
      return v

    tcNormalise :: R.Term -> TCM Term
    tcNormalise v = do
      (v, _) <- inferExpr =<< toAbstract_ v
      quoteTerm =<< normalise v

    tcGetContext :: UnquoteM Term
    tcGetContext = liftU $ do
      as <- map (fmap snd) <$> getContext
      as <- etaContract =<< normalise as
      buildList <*> mapM quoteDom as

    extendCxt :: Arg R.Type -> UnquoteM a -> UnquoteM a
    extendCxt a m = do
      a <- liftU $ traverse (isType_ <=< toAbstract_) a
      liftU1 (addContext (domFromArg a :: Dom Type)) m

    tcExtendContext :: Term -> Term -> UnquoteM Term
    tcExtendContext a m = do
      a <- unquote a
      extendCxt a (evalTCM m)

    tcInContext :: Term -> Term -> UnquoteM Term
    tcInContext c m = do
      c <- unquote c
      liftU1 inTopContext $ go c m
      where
        go :: [Arg R.Type] -> Term -> UnquoteM Term
        go []       m = evalTCM m
        go (a : as) m = extendCxt a $ go as m

    constInfo :: QName -> TCM Definition
    constInfo x = getConstInfo x `catchError` \ _ ->
                  genericError $ "Unbound name: " ++ show x

    tcGetType :: QName -> TCM Term
    tcGetType x = quoteType . defType =<< constInfo x

    tcGetDefinition :: QName -> TCM Term
    tcGetDefinition x = quoteDefn =<< constInfo x

    tcDeclareDef :: Arg QName -> R.Type -> UnquoteM Term
    tcDeclareDef (Arg i x) a = inOriginalContext $ do
      let h = getHiding i
          r = getRelevance i
      when (h == Hidden) $ liftU $ typeError . GenericDocError =<< text "Cannot declare hidden function" <+> prettyTCM x
      tell [x]
      liftU $ do
        reportSDoc "tc.unquote.decl" 10 $ sep [ text "declare" <+> prettyTCM x <+> text ":"
                                              , nest 2 $ prettyTCM a ]
        a <- isType_ =<< toAbstract_ a
        alreadyDefined <- (True <$ getConstInfo x) `catchError` \ _ -> return False
        when alreadyDefined $ genericError $ "Multiple declarations of " ++ show x
        addConstant x $ defaultDefn i x a emptyFunction
        when (h == Instance) $ addTypedInstance x a
        primUnitUnit

    tcDefineFun :: QName -> [R.Clause] -> UnquoteM Term
    tcDefineFun x cs = inOriginalContext $ liftU $ do
      _ <- getConstInfo x `catchError` \ _ ->
        genericError $ "Missing declaration for " ++ show x
      cs <- mapM (toAbstract_ . QNamed x) cs
      reportSDoc "tc.unquote.def" 10 $ vcat $ map prettyA cs
      let i = mkDefInfo (nameConcrete $ qnameName x) noFixity' PublicAccess ConcreteDef noRange
      checkFunDef NotDelayed i x cs
      primUnitUnit
