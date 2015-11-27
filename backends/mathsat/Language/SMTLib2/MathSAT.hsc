module Language.SMTLib2.MathSAT where

#include <mathsat.h>

import Language.SMTLib2.Internals.Backend hiding (setOption,getUnsatCore)
import qualified Language.SMTLib2.Internals.Backend as B
import Language.SMTLib2.Internals.Expression
import Language.SMTLib2.Internals.Type hiding (Type)
import Language.SMTLib2.Internals.Type.Nat

import Foreign.Ptr
import Foreign.C
import Foreign.Storable
import qualified Foreign.Marshal.Alloc as C
import Foreign.Marshal.Array
import Data.Ratio
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Foldable
import Data.Typeable
import Data.Maybe (mapMaybe)
import System.IO.Unsafe

newtype Config = Config (Ptr Config) deriving Storable
newtype Env = Env (Ptr Env) deriving Storable
newtype Term = Term (Ptr Term) deriving (Eq,Ord,Storable)
newtype Decl = Decl (Ptr Decl) deriving (Eq,Ord,Storable)
newtype Type = Type (Ptr Type) deriving Storable
newtype ProofManager = ProofManager (Ptr ProofManager) deriving Storable
newtype Proof = Proof (Ptr Proof) deriving Storable

data MathSATBackend = MathSATBackend { mathsatState :: MathSATState
                                     , mathsatCoreMapping :: Map Term Int
                                     , mathsatNames :: Map String Int
                                     --, mathsatRev :: Map CSize (SMTExpr Untyped)
                                     }

mathsatBackend :: MathSATBackend
mathsatBackend = MathSATBackend { mathsatState = NoConfig
                                , mathsatCoreMapping = Map.empty
                                , mathsatNames = Map.empty
                                --, mathsatRev = Map.empty
                                }

data MathSATState = NoConfig
                  | Configured Config
                  | Running { mathsatPartA :: CInt
                            , mathsatPartB :: CInt
                            , mathsatEnv :: Env }

data MathSATVar = ConstVar Term
                | Uninterpreted Decl
                | DefinedFun (Env -> [Term] -> IO Term) 

instance Backend MathSATBackend where
  type SMTMonad MathSATBackend = IO
  type Expr MathSATBackend = UntypedVar Term
  type Var MathSATBackend = UntypedVar Term
  type QVar MathSATBackend = NoVar
  type Fun MathSATBackend = UntypedFun Decl
  type Constr MathSATBackend = NoCon
  type Field MathSATBackend = NoField
  type FunArg MathSATBackend = NoVar
  type LVar MathSATBackend = NoVar
  type ClauseId MathSATBackend = Int
  type Model MathSATBackend = AssignmentModel MathSATBackend
  setOption (SMTLogic logic) b = do
    case mathsatState b of
      NoConfig -> return ()
      Configured prev -> destroyConfig prev
      Running _ _ _ -> error "smtlib2-mathsat: Cannot change logic at this point."
    cfg <- createDefaultConfig logic
    case cfg of
      Just rcfg -> return ((),b { mathsatState = Configured rcfg })
      Nothing -> error $ "smtlib2-mathsat: Unknown logic "++logic
  setOption (ProduceInterpolants True) b = case mathsatState b of
    NoConfig -> do
      cfg <- createConfig
      setOption cfg "interpolation" "true"
      return ((),b { mathsatState = Configured cfg })
    Configured cfg -> do
      setOption cfg "interpolation" "true"
      return ((),b)
    Running _ _ _ -> error "smtlib2-mathsat: Cannot enable interpolation after creating environment."
  setOption _ b = return ((),b)
  getInfo SMTSolverName b = return ("MathSAT",b)
  getInfo SMTSolverVersion b = do
    vers <- getVersion
    return (vers,b)
  assert (UntypedVar e) b = do
    (env,nb) <- getEnv b
    assertFormula env e
    return ((),nb)
  assertId (UntypedVar e) b = do
    (env,nb) <- getEnv b
    assertFormula env e
    let cid = Map.size (mathsatCoreMapping nb)
    return (cid,nb { mathsatCoreMapping = Map.insert e cid
                                          (mathsatCoreMapping nb) })
  assertPartition (UntypedVar e) part b = do
    (grpA,grpB,env,nb) <- getRunning b
    setITPGroup env (case part of
                      PartitionA -> grpA
                      PartitionB -> grpB)
    assertFormula env e
    return ((),nb)
  checkSat _ _ b = do
    (env,nb) <- getEnv b
    res <- solve env
    return (case res of
             Nothing -> Unknown
             Just True -> Sat
             Just False -> Unsat,nb)
  declareDatatypes _ _ = error "smtlib2-mathsat: No support for datatypes."
  push b = do
    (env,nb) <- getEnv b
    succ <- pushBacktrackPoint env
    if succ
      then return ((),nb)
      else error "smtlib2-mathsat: Failed to push."
  pop b = do
    (env,nb) <- getEnv b
    succ <- popBacktrackPoint env
    if succ
      then return ((),nb)
      else error "smtlib2-mathsat: Failed to pop."
  defineVar _ e b = return (e,b)
  declareVar name b = withSig $ \(_::Proxy t) -> do
    (env,nb) <- getEnv b
    rtp <- sortToMSat (getType :: Repr t) env
    let (cname,nnb) = case Map.lookup rname (mathsatNames nb) of
          Nothing -> (rname,nb { mathsatNames = Map.insert rname 1 (mathsatNames nb) })
          Just i -> (rname++"_"++show i,nb { mathsatNames = Map.insert rname (i+1) (mathsatNames nb) })
    decl <- declareFunction env cname rtp
    trm <- makeConstant env decl
    return (UntypedVar trm,nnb)
    where
      rname = case name of
        Nothing -> "var"
        Just n -> n
      withSig :: (Proxy t -> IO (UntypedVar Term t,MathSATBackend))
              -> IO (UntypedVar Term t,MathSATBackend)
      withSig f = f Proxy
  defineFun _ _ _ _ = error "smtlib2-mathsat: No support for user-defined functions."
  declareFun name b = withSig $ \(_::Proxy arg) (_::Proxy t) -> do
    (env,nb) <- getEnv b
    rtp <- sortToMSat (getType :: Repr t) env
    argTps <- argsToListM (\repr -> sortToMSat repr env
                          ) (getTypes :: Args Repr arg)
    ftp <- getFunctionType env argTps rtp
    let (cname,nnb) = case Map.lookup rname (mathsatNames nb) of
          Nothing -> (rname,nb { mathsatNames = Map.insert rname 1 (mathsatNames nb) })
          Just i -> (rname++"_"++show i,nb { mathsatNames = Map.insert rname (i+1) (mathsatNames nb) })
    decl <- declareFunction env cname ftp
    return (UntypedFun decl,nnb)
    where
      rname = case name of
        Nothing -> "fun"
        Just n -> n
      withSig :: (Proxy arg -> Proxy t -> IO (UntypedFun Decl '(arg,t),MathSATBackend))
              -> IO (UntypedFun Decl '(arg,t),MathSATBackend)
      withSig f = f Proxy Proxy
  getValue (UntypedVar trm) b = do
    (env,nb) <- getEnv b
    resTerm <- getModelValue env trm
    res <- exprFromMSat env (UntypedVar resTerm)
    case res of
      Const val -> return (val,nb)
  getUnsatCore b = do
    (env,nb) <- getEnv b
    core <- getUnsatCore env
    case core of
      Nothing -> error "smtlib2-mathsat: Couldn't get unsat core."
      Just rcore -> return (mapMaybe (\trm -> Map.lookup trm (mathsatCoreMapping nb)
                                     ) rcore,nb)
  interpolate b = do
    (grpA,grpB,env,nb) <- getRunning b
    res <- getInterpolant env [grpA]
    case res of
      Nothing -> error "smtlib2-mathsat: Couldn't get interpolant."
      Just interp -> return (UntypedVar interp,nb)
  comment _ b = return ((),b)
  exit b = case mathsatState b of
    NoConfig -> return ((),b)
    Configured cfg -> do
      destroyConfig cfg
      return ((),mathsatBackend)
    Running _ _ env -> do
      destroyEnv env
      return ((),mathsatBackend)
  toBackend expr b = do
    (env,nb) <- getEnv b
    res <- exprToMSat env expr
    return (UntypedVar res,nb)
  fromBackend b trm = unsafePerformIO $ do
    (env,nb) <- getEnv b
    exprFromMSat env trm

instance Show Decl where
  show decl = unsafePerformIO $ do
    cstr <- declRepr decl
    str <- peekCString cstr
    free cstr
    return str

instance Show Term where
  show term = unsafePerformIO (termRepr term)

getEnv :: MathSATBackend -> IO (Env,MathSATBackend)
getEnv b = do
  (_,_,env,nb) <- getRunning b
  return (env,nb)
  
getRunning :: MathSATBackend -> IO (CInt,CInt,Env,MathSATBackend)
getRunning b = case mathsatState b of
  NoConfig -> do
    cfg <- createConfig
    setOption cfg "gc_period" "0"
    env <- createEnv cfg
    case env of
     Just renv -> do
       grpA <- createITPGroup renv
       grpB <- createITPGroup renv
       return (grpA,grpB,renv,b { mathsatState = Running grpA grpB renv })
     Nothing -> error $ "smtlib2-mathsat: Failed to create environment."
  Configured cfg -> do
    setOption cfg "gc_period" "0"
    env <- createEnv cfg
    case env of
     Just renv -> do
       grpA <- createITPGroup renv
       grpB <- createITPGroup renv
       return (grpA,grpB,renv,b { mathsatState = Running grpA grpB renv })
     Nothing -> error $ "smtlib2-mathsat: Failed to create environment."
  Running grpA grpB env -> return (grpA,grpB,env,b)

checkErrors :: Env -> IO ()
checkErrors env = do
  msg <- lastErrorMessage env
  case msg of
   Just "" -> return ()
   Just rmsg -> error $ "smtlib2-mathsat: "++rmsg
   Nothing -> return ()

sortToMSat :: GetType t => Repr t -> Env -> IO Type
sortToMSat BoolRepr env = getBoolType env
sortToMSat IntRepr env = getIntegerType env
sortToMSat RealRepr env = getRationalType env
sortToMSat (BitVecRepr w) env
  = getBVType env (fromIntegral w)
sortToMSat (ArrayRepr (Arg idx NoArg) el) env = do
  idxTp <- sortToMSat idx env
  elTp <- sortToMSat el env
  getArrayType env idxTp elTp

sortFromMSat :: Env -> Type -> (forall tp. GetType tp => Repr tp -> IO a) -> IO a
sortFromMSat env tp f = do
  isB <- isBoolType env tp
  if isB then f BoolRepr
    else do
    isRat <- isRationalType env tp
    if isRat
      then f RealRepr
      else do
      isInt <- isIntegerType env tp
      if isInt then f IntRepr
        else do
        isBV <- isBVType env tp
        case isBV of
         Just sz -> reifyNat sz $
                    \(_::Proxy n) -> f (BitVecRepr (fromIntegral sz) :: Repr (BitVecType n))
         Nothing -> do
           isArr <- isArrayType env tp
           case isArr of
            Just (idx,el) -> sortFromMSat env idx $
                             \ridx -> sortFromMSat env el $
                                      \rel -> f (ArrayRepr (Arg ridx NoArg) rel)
            Nothing -> do
              repr <- typeRepr tp
              error $ "smtlib2-mathsat: No support for type "++repr

exprToMSat :: Env
           -> Expression (UntypedVar Term) NoVar (UntypedFun Decl) NoCon NoField NoVar NoVar (UntypedVar Term) tp
           -> IO Term
exprToMSat env (Var (UntypedVar trm)) = return trm
exprToMSat env (QVar _) = error "smtlib2-mathsat: No support for quantification."
exprToMSat env (FVar _) = error "smtlib2-mathsat: No support for user-defined functions."
exprToMSat env (LVar _) = error "smtlib2-mathsat: No support for let-expressions."
exprToMSat env (Const val) = valueToMSat val
  where
    valueToMSat :: Value NoCon tp' -> IO Term
    valueToMSat (BoolValue True) = makeTrue env
    valueToMSat (BoolValue False) = makeFalse env
    valueToMSat (IntValue n) = makeNumber env (show n)
    valueToMSat (RealValue n) = makeNumber env ((show $ numerator n)++"/"++(show $ denominator n))
    valueToMSat v@(BitVecValue val) = case v of
      (_ :: Value NoCon (BitVecType n)) -> makeBVNumber env (show val) (fromInteger $ natVal (Proxy::Proxy n)) 10
    valueToMSat (ConstrValue _ _) = error "smtlib2-mathsat: No support for datatypes."
exprToMSat env (Quantification _ _ _) = error "smtlib2-mathsat: No support for quantification."
exprToMSat env (Let _ _) = error "smtlib2-mathsat: No support for let-expressions."
exprToMSat env (App (Logic op) args) = do
  let args' = fmap (\(UntypedVar v) -> v) $ allEqToList args
  case args' of
    [] -> case op of
      Or -> makeFalse env
      And -> makeTrue env
      XOr -> makeFalse env
      Implies -> makeTrue env
    x:xs -> foldlM (case op of
                     Or -> makeOr env
                     And -> makeAnd env
                     XOr -> \x y -> do
                       nx <- makeNot env x
                       ny <- makeNot env y
                       or <- makeOr env x y
                       nor <- makeOr env nx ny
                       makeAnd env or nor
                     Implies -> \x y -> do
                       nx <- makeNot env x
                       makeOr env nx y
                   ) x xs
exprToMSat env (App Not (Arg (UntypedVar x) NoArg)) = makeNot env x
exprToMSat env (App Eq (xs::Args (UntypedVar Term) tps)) = case allEqToList xs of
  [] -> makeTrue env
  [_] -> makeTrue env
  (UntypedVar x):xs -> case getType :: Repr (SameType tps) of
    BoolRepr -> case xs of
      [UntypedVar y] -> makeIFF env x y
      (UntypedVar y):rest -> do
        fst <- makeIFF env x y
        foldlM (\cur (UntypedVar v) -> do
                   eq <- makeIFF env x v
                   makeAnd env cur eq
               ) fst rest
    _ -> case xs of
      [UntypedVar y] -> makeEqual env x y
      (UntypedVar y):rest -> do
        fst <- makeEqual env x y
        foldlM (\cur (UntypedVar v) -> do
                   eq <- makeEqual env x v
                   makeAnd env cur eq
               ) fst rest
exprToMSat env (App (OrdInt op) (Arg (UntypedVar x) (Arg (UntypedVar y) NoArg)))
  = ordToMSat env op x y
exprToMSat env (App (OrdReal op) (Arg (UntypedVar x) (Arg (UntypedVar y) NoArg)))
  = ordToMSat env op x y
exprToMSat env (App (ArithInt op) args)
  = arithToMSat env op (fmap (\(UntypedVar x) -> x) $ allEqToList args)
exprToMSat env (App (ArithReal op) args)
  = arithToMSat env op (fmap (\(UntypedVar x) -> x) $ allEqToList args)
exprToMSat env (App AbsInt (Arg (UntypedVar x) NoArg))
  = absToMSat env x
exprToMSat env (App AbsReal (Arg (UntypedVar x) NoArg))
  = absToMSat env x
exprToMSat env (App ITE (Arg (UntypedVar cond) (Arg (UntypedVar ifT :: UntypedVar Term tp) (Arg (UntypedVar ifF) NoArg))))
  = case getType :: Repr tp of
  BoolRepr -> do
    ncond <- makeNot env cond
    t1 <- makeAnd env cond ifT
    t2 <- makeAnd env ncond ifF
    makeOr env t1 t2
  _ -> makeTermITE env cond ifT ifF
exprToMSat env (App (Fun _) _) = error "smtlib2-mathsat: No support for user-defined functions."
exprToMSat env (App Select (Arg (UntypedVar arr) (Arg (UntypedVar idx) NoArg)))
  = makeArrayRead env arr idx
exprToMSat env (App Store (Arg (UntypedVar arr) (Arg (UntypedVar el) (Arg (UntypedVar idx) NoArg))))
  = makeArrayWrite env arr idx el
exprToMSat env (App f@ConstArray (Arg (UntypedVar el) NoArg)) = case f of
  (_ :: Function (UntypedFun Decl) NoCon NoField '( '[el], ArrayType idx el)) -> do
    srt <- sortToMSat (getType :: Repr (ArrayType idx el)) env
    makeArrayConst env srt el
exprToMSat env (App ToReal (Arg (UntypedVar x) NoArg)) = return x
exprToMSat env (App ToInt (Arg (UntypedVar x) NoArg)) = makeFloor env x
exprToMSat env (App (BVComp op) (Arg (UntypedVar x) (Arg (UntypedVar y) NoArg))) = case op of
  BVULE -> makeBVULEQ env x y
  BVULT -> makeBVULT env x y
  BVUGE -> makeBVULEQ env y x
  BVUGT -> makeBVULT env y x
  BVSLE -> makeBVSLEQ env x y
  BVSLT -> makeBVSLT env x y
  BVSGE -> makeBVSLEQ env y x
  BVSGT -> makeBVSLT env y x
exprToMSat env (App (BVBin op) (Arg (UntypedVar x) (Arg (UntypedVar y) NoArg)))
  = (case op of
      BVAdd -> makeBVPlus
      BVSub -> makeBVMinus
      BVMul -> makeBVTimes
      BVURem -> makeBVURem
      BVSRem -> makeBVSRem
      BVUDiv -> makeBVUDiv
      BVSDiv -> makeBVSDiv
      BVSHL -> makeBVLSHL
      BVLSHR -> makeBVLSHR
      BVASHR -> makeBVASHR
      BVXor -> makeBVXor
      BVAnd -> makeBVAnd
      BVOr -> makeBVOr) env x y
exprToMSat env (App (BVUn op) (Arg (UntypedVar x) NoArg)) = case op of
  BVNot -> makeBVNot env x
  BVNeg -> makeBVNeg env x
exprToMSat env (App Concat (Arg (UntypedVar x) (Arg (UntypedVar y) NoArg)))
  = makeBVConcat env x y
exprToMSat env (App f@(Extract start) (Arg (UntypedVar x) NoArg))
  = makeBVExtract env (fromIntegral (start'+len-1)) (fromIntegral start') x
  where
    start' = natVal start
    len = case f of
      (_::Function (UntypedFun Decl) NoCon NoField '( '[BitVecType a], BitVecType len))
        -> natVal (Proxy::Proxy len)
exprToMSat env (App (Divisible n) (Arg (UntypedVar x) NoArg)) = do
  y <- makeNumber env "0"
  makeCongruence env (show n) x y
exprToMSat env expr = error $ "smtlib2-mathsat: No support for expression "++show expr

ordToMSat :: Env -> OrdOp -> Term -> Term -> IO Term
ordToMSat env Le x y = makeLEQ env x y
ordToMSat env Ge x y = makeLEQ env y x
ordToMSat env Lt x y = do
  leq <- makeLEQ env x y
  neq <- makeEqual env x y >>= makeNot env
  makeAnd env leq neq
ordToMSat env Gt x y = do
  leq <- makeLEQ env y x
  neq <- makeEqual env x y >>= makeNot env
  makeAnd env leq neq

arithToMSat :: Env -> ArithOp -> [Term] -> IO Term
arithToMSat env Plus [] = makeNumber env "0"
arithToMSat env Plus (x:xs) = foldlM (makePlus env) x xs
arithToMSat env Mult [] = makeNumber env "1"
arithToMSat env Mult (x:xs) = foldlM (makeTimes env) x xs
arithToMSat env Minus [] = makeNumber env "0"
arithToMSat env Minus [x] = do
  n1 <- makeNumber env "-1"
  makeTimes env n1 x
arithToMSat env Minus (x:xs) = do
  n1 <- makeNumber env "-1"
  xs' <- mapM (makeTimes env n1) xs
  foldlM (makePlus env) x xs'

absToMSat :: Env -> Term -> IO Term
absToMSat env x = do
  zero <- makeNumber env "0"
  n1 <- makeNumber env "-1"
  nx <- makeTimes env n1 x
  cond <- makeLEQ env x zero
  makeTermITE env cond nx x

exprFromMSat :: GetType tp => Env -> UntypedVar Term tp
             -> IO (Expression (UntypedVar Term) NoVar (UntypedFun Decl) NoCon NoField NoVar NoVar (UntypedVar Term) tp)
exprFromMSat env (UntypedVar term) = do
  isC <- termIsConstant env term
  if isC
    then do
    decl <- termGetDecl term
    trm <- makeConstant env decl
    return (Var (UntypedVar trm))
    else do
    isN <- termIsNumber env term
    if isN
      then do
      num <- termGetNumber env term
      withRepr $ \repr -> case repr of
        IntRepr -> return $ Const (IntValue (read num))
        RealRepr -> return $ Const (RealValue (read num))
        BitVecRepr _ -> return $ Const (BitVecValue (read num))
      else do
      decl <- termGetDecl term
      tag <- declGetTag env decl
      case tag of
        #{const MSAT_TAG_ITE} -> do
          cond <- termGetArg term 0
          ifT <- termGetArg term 1
          ifF <- termGetArg term 2
          return $ App ITE (Arg (UntypedVar cond)
                            (Arg (UntypedVar ifT)
                             (Arg (UntypedVar ifF)
                              NoArg)))
        #{const MSAT_TAG_ARRAY_READ} -> do
          arr <- termGetArg term 0
          idx <- termGetArg term 1
          tp <- termGetType idx
          sortFromMSat env tp $
            \(_::Repr idx) -> return (App Select (Arg (UntypedVar arr)
                                                  (Arg (UntypedVar idx :: UntypedVar Term idx)
                                                   NoArg)))
        _ -> withRepr $ \repr -> case repr of
          BoolRepr -> case tag of
            #{const MSAT_TAG_TRUE} -> return (Const $ BoolValue True)
            #{const MSAT_TAG_FALSE} -> return (Const $ BoolValue False)
            #{const MSAT_TAG_AND} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (Logic And) (Arg (UntypedVar lhs :: UntypedVar Term BoolType)
                                        (Arg (UntypedVar rhs :: UntypedVar Term BoolType)
                                         NoArg))
            #{const MSAT_TAG_OR} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (Logic Or) (Arg (UntypedVar lhs :: UntypedVar Term BoolType)
                                       (Arg (UntypedVar rhs :: UntypedVar Term BoolType)
                                        NoArg))
            #{const MSAT_TAG_NOT} -> do
              x <- termGetArg term 0
              return $ App Not (Arg (UntypedVar x) NoArg)
            #{const MSAT_TAG_IFF} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App Eq (Arg (UntypedVar lhs :: UntypedVar Term BoolType)
                               (Arg (UntypedVar rhs :: UntypedVar Term BoolType)
                                NoArg))
            #{const MSAT_TAG_LEQ} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tp <- termGetType lhs
              isRat <- isRationalType env tp
              if isRat
                then return $ App (OrdReal Le) (Arg (UntypedVar lhs)
                                                (Arg (UntypedVar rhs)
                                                 NoArg))
                else return $ App (OrdInt Le) (Arg (UntypedVar lhs)
                                               (Arg (UntypedVar rhs)
                                                NoArg))
            #{const MSAT_TAG_EQ} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tp <- termGetType lhs
              sortFromMSat env tp $
                \(_::Repr tp) -> return $ App Eq (Arg (UntypedVar lhs :: UntypedVar Term tp)
                                                  (Arg (UntypedVar rhs :: UntypedVar Term tp)
                                                   NoArg))
            #{const MSAT_TAG_INT_MOD_CONGR} -> do
              modulus <- termIsCongruence env term
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              n1 <- makeNumber env "-1"
              nrhs <- makeTimes env n1 rhs
              diff <- makePlus env lhs nrhs
              return $ App (Divisible (read modulus)) (Arg (UntypedVar diff) NoArg)
            #{const MSAT_TAG_BV_ULT} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tp <- termGetType lhs
              Just sz <- isBVType env tp
              reifyNat sz $
                \(_::Proxy n) -> return $ App (BVComp BVULT)
                                 (Arg (UntypedVar lhs :: UntypedVar Term (BitVecType n))
                                  (Arg (UntypedVar rhs)
                                   NoArg))
            #{const MSAT_TAG_BV_SLT} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tp <- termGetType lhs
              Just sz <- isBVType env tp
              reifyNat sz $
                \(_::Proxy n) -> return $ App (BVComp BVSLT)
                                 (Arg (UntypedVar lhs :: UntypedVar Term (BitVecType n))
                                  (Arg (UntypedVar rhs)
                                   NoArg))
            #{const MSAT_TAG_BV_ULE} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tp <- termGetType lhs
              Just sz <- isBVType env tp
              reifyNat sz $
                \(_::Proxy n) -> return $ App (BVComp BVULE)
                                 (Arg (UntypedVar lhs :: UntypedVar Term (BitVecType n))
                                  (Arg (UntypedVar rhs)
                                   NoArg))
            #{const MSAT_TAG_BV_SLE} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tp <- termGetType lhs
              Just sz <- isBVType env tp
              reifyNat sz $
                \(_::Proxy n) -> return $ App (BVComp BVSLE)
                                 (Arg (UntypedVar lhs :: UntypedVar Term (BitVecType n))
                                  (Arg (UntypedVar rhs)
                                   NoArg))
          IntRepr -> case tag of
            #{const MSAT_TAG_PLUS} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (ArithInt Plus) (Arg (UntypedVar lhs :: UntypedVar Term IntType)
                                            (Arg (UntypedVar rhs :: UntypedVar Term IntType)
                                             NoArg))
            #{const MSAT_TAG_TIMES} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (ArithInt Mult) (Arg (UntypedVar lhs :: UntypedVar Term IntType)
                                            (Arg (UntypedVar rhs :: UntypedVar Term IntType)
                                             NoArg))
            #{const MSAT_TAG_FLOOR} -> do
              arg <- termGetArg term 0
              return $ App ToInt (Arg (UntypedVar arg) NoArg)
          RealRepr -> case tag of
            #{const MSAT_TAG_PLUS} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (ArithReal Plus) (Arg (UntypedVar lhs :: UntypedVar Term RealType)
                                             (Arg (UntypedVar rhs :: UntypedVar Term RealType)
                                              NoArg))
            #{const MSAT_TAG_TIMES} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (ArithReal Mult) (Arg (UntypedVar lhs :: UntypedVar Term RealType)
                                             (Arg (UntypedVar rhs :: UntypedVar Term RealType)
                                              NoArg))
          BitVecRepr _ -> case tag of
            #{const MSAT_TAG_BV_CONCAT} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              tpL <- termGetType lhs
              tpR <- termGetType rhs
              Just szL <- isBVType env tpL
              Just szR <- isBVType env tpR
              reifyAdd szL szR $
                \(_::Proxy n1) (_::Proxy n2)
                 -> let res :: KnownNat n => Proxy n -> Expression (UntypedVar Term) NoVar (UntypedFun Decl) NoCon NoField NoVar NoVar (UntypedVar Term) (BitVecType n)
                        res pr = case sameNat (Proxy::Proxy (n1+n2)) pr of
                          Just Refl -> App Concat
                                       (Arg (UntypedVar lhs :: UntypedVar Term (BitVecType n1))
                                        (Arg (UntypedVar rhs :: UntypedVar Term (BitVecType n2))
                                         NoArg))
                    in return (res Proxy)
            #{const MSAT_TAG_BV_EXTRACT} -> do
              Just (msb,lsb) <- termIsBVExtract env term
              arg <- termGetArg term 0
              Just sz <- termGetType arg >>= isBVType env
              case reifyExtract lsb (msb-lsb+1) sz
                   (\start len (_::Proxy sz)
                    -> let res :: KnownNat n => Proxy n -> Expression (UntypedVar Term) NoVar (UntypedFun Decl) NoCon NoField NoVar NoVar (UntypedVar Term) (BitVecType n)
                           res pr = case sameNat len pr of
                             Just Refl -> App (Extract start)
                                          (Arg (UntypedVar arg :: UntypedVar Term (BitVecType sz))
                                           NoArg)
                       in res Proxy) of
                Just res -> return res
            #{const MSAT_TAG_BV_NOT} -> do
              arg <- termGetArg term 0
              return $ App (BVUn BVNot) (Arg (UntypedVar arg) NoArg)
            #{const MSAT_TAG_BV_AND} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVAnd) (Arg (UntypedVar lhs)
                                          (Arg (UntypedVar rhs)
                                           NoArg))
            #{const MSAT_TAG_BV_OR} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVOr) (Arg (UntypedVar lhs)
                                         (Arg (UntypedVar rhs)
                                          NoArg))
            #{const MSAT_TAG_BV_XOR} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVXor) (Arg (UntypedVar lhs)
                                          (Arg (UntypedVar rhs)
                                           NoArg))
            #{const MSAT_TAG_BV_COMP} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              narg <- makeBVXor env lhs rhs
              return $ App (BVUn BVNot) (Arg (UntypedVar narg) NoArg)
            #{const MSAT_TAG_BV_NEG} -> do
              arg <- termGetArg term 0
              return $ App (BVUn BVNeg) (Arg (UntypedVar arg) NoArg)
            #{const MSAT_TAG_BV_ADD} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVAdd) (Arg (UntypedVar lhs)
                                          (Arg (UntypedVar rhs)
                                           NoArg))
            #{const MSAT_TAG_BV_SUB} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVSub) (Arg (UntypedVar lhs)
                                          (Arg (UntypedVar rhs)
                                           NoArg))
            #{const MSAT_TAG_BV_MUL} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVMul) (Arg (UntypedVar lhs)
                                          (Arg (UntypedVar rhs)
                                           NoArg))
            #{const MSAT_TAG_BV_UDIV} -> do
              lhs <- termGetArg term 0
              rhs <- termGetArg term 1
              return $ App (BVBin BVUDiv) (Arg (UntypedVar lhs)
                                          (Arg (UntypedVar rhs)
                                           NoArg))
            #{const MSAT_TAG_BV_ROL} -> error "smtlib2-mathsat: No support for rotate-left."
            #{const MSAT_TAG_BV_ROR} -> error "smtlib2-mathsat: No support for rotate-right."
            #{const MSAT_TAG_BV_ZEXT} -> error "smtlib2-mathsat: No support for zext."
            #{const MSAT_TAG_BV_SEXT} -> error "smtlib2-mathsat: No support for sext."
          ArrayRepr (Arg _ NoArg) _ -> case tag of
            #{const MSAT_TAG_ARRAY_WRITE} -> do
              arr <- termGetArg term 0
              idx <- termGetArg term 1
              el <- termGetArg term 2
              return $ App Store (Arg (UntypedVar arr)
                                  (Arg (UntypedVar el)
                                   (Arg (UntypedVar idx)
                                    NoArg)))
            #{const MSAT_TAG_ARRAY_CONST} -> do
              el <- termGetArg term 0
              return $ App ConstArray (Arg (UntypedVar el) NoArg)
  where
    withRepr :: GetType tp => (Repr tp -> IO (a tp)) -> IO (a tp)
    withRepr f = f getType

foreign import ccall "mathsat.h msat_free"
  free :: Ptr a -> IO ()

getVersion :: IO String
getVersion = do
  v <- getVersion'
  v' <- peekCString v
  C.free v
  return v'

foreign import ccall "mathsat.h msat_get_version"
  getVersion' :: IO CString

lastErrorMessage :: Env -> IO (Maybe String)
lastErrorMessage env = do
  msg <- lastErrorMessage' env
  if msg==nullPtr
    then return Nothing
    else do
    rmsg <- peekCString msg
    return (Just rmsg)

foreign import ccall "mathsat.h msat_last_error_message"
  lastErrorMessage' :: Env -> IO CString

foreign import ccall "mathsat.h msat_create_config"
  createConfig :: IO Config

createDefaultConfig :: String -> IO (Maybe Config)
createDefaultConfig str = withCString str $ \cstr -> do
  ptr <- createDefaultConfig' cstr
  if ptr==nullPtr
    then return Nothing
    else return $ Just (Config ptr)

foreign import ccall "mathsat.h msat_create_default_config"
  createDefaultConfig' :: CString -> IO (Ptr Config)

parseConfig :: String -> IO (Maybe Config)
parseConfig str = withCString str $ \cstr -> do
  ptr <- parseConfig' cstr
  if ptr==nullPtr
    then return Nothing
    else return $ Just (Config ptr)

foreign import ccall "mathsat.h msat_parse_config"
  parseConfig' :: CString -> IO (Ptr Config)

foreign import ccall "mathsat.h msat_destroy_config"
  destroyConfig :: Config -> IO ()

createEnv :: Config -> IO (Maybe Env)
createEnv cfg = do
  env <- createEnv' cfg
  if env==nullPtr
    then return Nothing
    else return $ Just $ Env env

foreign import ccall "mathsat.h msat_create_env"
  createEnv' :: Config -> IO (Ptr Env)

createSharedEnv :: Config -> Env -> IO (Maybe Env)
createSharedEnv cfg env = do
  env2 <- createSharedEnv' cfg env
  if env2==nullPtr
    then return Nothing
    else return $ Just $ Env env2

foreign import ccall "mathsat.h msat_create_shared_env"
  createSharedEnv' :: Config -> Env -> IO (Ptr Env)

foreign import ccall "mathsat.h msat_destroy_env"
  destroyEnv :: Env -> IO ()

gcEnv :: Env -> [Term] -> IO Bool
gcEnv env terms
  = withArrayLen terms $
    \len cterms -> do
      res <- gcEnv' env cterms (fromIntegral len)
      return $ res==0

foreign import ccall "mathsat.h msat_gc_env"
  gcEnv' :: Env -> Ptr Term -> CSize -> IO Int

setOption :: Config -> String -> String -> IO Bool
setOption cfg opt val
  = withCString opt $
    \copt -> withCString val $ \cval -> do
      res <- setOption' cfg copt cval
      return $ res==0

foreign import ccall "mathsat.h msat_set_option"
  setOption' :: Config -> CString -> CString -> IO Int

foreign import ccall "mathsat.h msat_get_bool_type"
  getBoolType :: Env -> IO Type

foreign import ccall "mathsat.h msat_get_rational_type"
  getRationalType :: Env -> IO Type

foreign import ccall "mathsat.h msat_get_integer_type"
  getIntegerType :: Env -> IO Type

foreign import ccall "mathsat.h msat_get_bv_type"
  getBVType :: Env -> CSize -> IO Type

foreign import ccall "mathsat.h msat_get_array_type"
  getArrayType :: Env -> Type -> Type -> IO Type

foreign import ccall "mathsat.h msat_get_fp_type"
  getFPType :: Env -> CSize -> CSize -> IO Type

foreign import ccall "mathsat.h msat_get_fp_roundingmode_type"
  getFPRoundingModeType :: Env -> IO Type

foreign import ccall "mathsat.h msat_get_simple_type"
  getSimpleType :: Env -> CString -> IO Type

getFunctionType :: Env -> [Type] -> Type -> IO Type
getFunctionType env params ret
  = withArrayLen params $
    \len cparams -> getFunctionType' env cparams (fromIntegral len) ret

foreign import ccall "mathsat.h msat_get_function_type"
  getFunctionType' :: Env -> Ptr Type -> CSize -> Type -> IO Type

isBoolType :: Env -> Type -> IO Bool
isBoolType env tp = fmap (==1) $ isBoolType' env tp

foreign import ccall "mathsat.h msat_is_bool_type"
  isBoolType' :: Env -> Type -> IO CInt

isRationalType :: Env -> Type -> IO Bool
isRationalType env tp = fmap (==1) $ isRationalType' env tp

foreign import ccall "mathsat.h msat_is_rational_type"
  isRationalType' :: Env -> Type -> IO CInt

isIntegerType :: Env -> Type -> IO Bool
isIntegerType env tp = fmap (==1) $ isIntegerType' env tp

foreign import ccall "mathsat.h msat_is_integer_type"
  isIntegerType' :: Env -> Type -> IO CInt

isBVType :: Env -> Type -> IO (Maybe CSize)
isBVType env tp = C.alloca $ \sz -> do
  res <- isBVType' env tp sz
  if res==1
    then (do
             rsz <- peek sz
             return $ Just rsz)
    else return Nothing

foreign import ccall "mathsat.h msat_is_bv_type"
  isBVType' :: Env -> Type -> Ptr CSize -> IO CInt

isArrayType :: Env -> Type -> IO (Maybe (Type,Type))
isArrayType env tp
  = C.alloca $
    \iTp -> C.alloca $
            \eTp -> do
              res <- isArrayType' env tp iTp eTp
              if res==1
                then (do
                         i <- peek iTp
                         e <- peek eTp
                         return $ Just (i,e))
                else return Nothing

foreign import ccall "mathsat.h msat_is_array_type"
  isArrayType' :: Env -> Type -> Ptr Type -> Ptr Type -> IO CInt

isFPType :: Env -> Type -> IO (Maybe (CSize,CSize))
isFPType env tp
  = C.alloca $
    \w1 -> C.alloca $
           \w2 -> do
             res <- isFPType' env tp w1 w2
             if res==1
               then (do
                        r1 <- peek w1
                        r2 <- peek w2
                        return $ Just (r1,r2))
               else return Nothing

foreign import ccall "mathsat.h msat_is_fp_type"
  isFPType' :: Env -> Type -> Ptr CSize -> Ptr CSize -> IO CInt

typeRepr :: Type -> IO String
typeRepr tp = do
  cstr <- typeRepr' tp
  str <- peekCString cstr
  free cstr
  return str

foreign import ccall "mathsat.h msat_type_repr"
  typeRepr' :: Type -> IO CString

declareFunction :: Env -> String -> Type -> IO Decl
declareFunction env name tp
  = withCString name $
    \cname -> declareFunction' env cname tp

foreign import ccall "mathsat.h msat_declare_function"
  declareFunction' :: Env -> CString -> Type -> IO Decl

foreign import ccall "mathsat.h msat_make_true"
  makeTrue :: Env -> IO Term

foreign import ccall "mathsat.h msat_make_false"
  makeFalse :: Env -> IO Term

foreign import ccall "mathsat.h msat_make_iff"
  makeIFF :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_or"
  makeOr :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_and"
  makeAnd :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_not"
  makeNot :: Env -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_equal"
  makeEqual :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_leq"
  makeLEQ :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_plus"
  makePlus :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_times"
  makeTimes :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_floor"
  makeFloor :: Env -> Term -> IO Term

makeNumber :: Env -> String -> IO Term
makeNumber env num
  = withCString num $
    \cnum -> makeNumber' env cnum

foreign import ccall "mathsat.h msat_make_number"
  makeNumber' :: Env -> CString -> IO Term

foreign import ccall "mathsat.h msat_make_term_ite"
  makeTermITE :: Env -> Term -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_constant"
  makeConstant :: Env -> Decl -> IO Term

makeUF :: Env -> Decl -> [Term] -> IO Term
makeUF env decl args
  = withArray args $
    \cargs -> makeUF' env decl cargs

foreign import ccall "mathsat.h msat_make_uf"
  makeUF' :: Env -> Decl -> Ptr Term -> IO Term

foreign import ccall "mathsat.h msat_make_array_read"
  makeArrayRead :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_array_write"
  makeArrayWrite :: Env -> Term -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_array_const"
  makeArrayConst :: Env -> Type -> Term -> IO Term

makeBVNumber :: Env -> String -> Int -> Int -> IO Term
makeBVNumber env rep width base
  = withCString rep $
    \crep -> makeBVNumber' env crep (fromIntegral width) (fromIntegral base)

foreign import ccall "mathsat.h msat_make_bv_number"
  makeBVNumber' :: Env -> CString -> CSize -> CSize -> IO Term

foreign import ccall "mathsat.h msat_make_bv_concat"
  makeBVConcat :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_extract"
  makeBVExtract :: Env -> CSize -> CSize -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_or"
  makeBVOr :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_xor"
  makeBVXor :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_and"
  makeBVAnd :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_not"
  makeBVNot :: Env -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_lshl"
  makeBVLSHL :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_lshr"
  makeBVLSHR :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_ashr"
  makeBVASHR :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_zext"
  makeBVZExt :: Env -> CSize -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_sext"
  makeBVSExt :: Env -> CSize -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_plus"
  makeBVPlus :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_minus"
  makeBVMinus :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_neg"
  makeBVNeg :: Env -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_times"
  makeBVTimes :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_udiv"
  makeBVUDiv :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_urem"
  makeBVURem :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_sdiv"
  makeBVSDiv :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_srem"
  makeBVSRem :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_ult"
  makeBVULT :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_uleq"
  makeBVULEQ :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_slt"
  makeBVSLT :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_sleq"
  makeBVSLEQ :: Env -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_rol"
  makeBVROL :: Env -> CSize -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_ror"
  makeBVROR :: Env -> CSize -> Term -> IO Term

foreign import ccall "mathsat.h msat_make_bv_comp"
  makeBVComp :: Env -> Term -> Term -> IO Term

makeTerm :: Env -> Decl -> [Term] -> IO Term
makeTerm env decl args
  = withArray args $ makeTerm' env decl

foreign import ccall "mathsat.h msat_make_term"
  makeTerm' :: Env -> Decl -> Ptr Term -> IO Term

makeCongruence :: Env -> String -> Term -> Term -> IO Term
makeCongruence env str t1 t2
  = withCString str $
    \cstr -> makeCongruence' env cstr t1 t2

foreign import ccall "helper.h msat_helper_make_congruence"
  makeCongruence' :: Env -> CString -> Term -> Term -> IO Term

foreign import ccall "mathsat.h msat_term_id"
  termId :: Term -> IO CSize

foreign import ccall "mathsat.h msat_term_arity"
  termArity :: Term -> IO CSize

foreign import ccall "mathsat.h msat_term_get_arg"
  termGetArg :: Term -> CSize -> IO Term

foreign import ccall "mathsat.h msat_term_get_type"
  termGetType :: Term -> IO Type

foreign import ccall "helper.h msat_helper_term_is_error"
  termIsError :: Term -> IO Bool

termIsTrue :: Term -> IO Bool
termIsTrue = fmap (==0) . termIsTrue'

foreign import ccall "mathsat.h msat_term_is_true"
  termIsTrue' :: Term -> IO CInt

termIsFalse :: Term -> IO Bool
termIsFalse = fmap (==0) . termIsFalse'

foreign import ccall "mathsat.h msat_term_is_false"
  termIsFalse' :: Term -> IO CInt

termIsNumber :: Env -> Term -> IO Bool
termIsNumber env t = fmap (/=0) (termIsNumber' env t)

foreign import ccall "mathsat.h msat_term_is_number"
  termIsNumber' :: Env -> Term -> IO CInt

termGetNumber :: Env -> Term -> IO String
termGetNumber env term = do
  cstr <- termGetNumber' env term
  res <- peekCString cstr
  --C.free cstr
  return res

foreign import ccall "helper.h msat_helper_get_number"
  termGetNumber' :: Env -> Term -> IO CString

termRepr :: Term -> IO String
termRepr t = do
  str <- termRepr' t
  res <- peekCString str
  free str
  return res

termIsUF :: Env -> Term -> IO Bool
termIsUF env t = fmap (/=0) (termIsUF' env t)

foreign import ccall "mathsat.h msat_term_is_uf"
  termIsUF' :: Env -> Term -> IO CInt

termIsConstant :: Env -> Term -> IO Bool
termIsConstant env t = fmap (/=0) (termIsConstant' env t)

foreign import ccall "mathsat.h msat_term_is_constant"
  termIsConstant' :: Env -> Term -> IO CInt

termIsCongruence :: Env -> Term -> IO String
termIsCongruence env term = do
  cstr <- termIsCongruence' env term
  res <- peekCString cstr
  free cstr
  return res

foreign import ccall "helper.h msat_helper_is_congruence"
  termIsCongruence' :: Env -> Term -> IO CString

termIsBVExtract :: Env -> Term -> IO (Maybe (CSize,CSize))
termIsBVExtract env term
  = C.alloca $ \msb -> C.alloca $ \lsb -> do
    res <- termIsBVExtract' env term msb lsb
    if res/=0
      then do
      rmsb <- peek msb
      rlsb <- peek lsb
      return $ Just (rmsb,rlsb)
      else return Nothing

foreign import ccall "mathsat.h msat_term_is_bv_extract"
  termIsBVExtract' :: Env -> Term -> Ptr CSize -> Ptr CSize -> IO CInt

termIsBVROL :: Env -> Term -> IO (Maybe CSize)
termIsBVROL env term
  = C.alloca $ \v -> do
    res <- termIsBVROL' env term v
    if res/=0
      then do
      rv <- peek v
      return (Just rv)
      else return Nothing

foreign import ccall "mathsat.h msat_term_is_bv_rol"
  termIsBVROL' :: Env -> Term -> Ptr CSize -> IO CInt

termIsBVROR :: Env -> Term -> IO (Maybe CSize)
termIsBVROR env term
  = C.alloca $ \v -> do
    res <- termIsBVROR' env term v
    if res/=0
      then do
      rv <- peek v
      return (Just rv)
      else return Nothing

foreign import ccall "mathsat.h msat_term_is_bv_ror"
  termIsBVROR' :: Env -> Term -> Ptr CSize -> IO CInt

foreign import ccall "mathsat.h msat_term_get_decl"
  termGetDecl :: Term -> IO Decl

foreign import ccall "mathsat.h msat_decl_id"
  declId :: Decl -> IO CSize

foreign import ccall "mathsat.h msat_decl_get_tag"
  declGetTag :: Env -> Decl -> IO CInt

foreign import ccall "mathsat.h msat_decl_get_return_type"
  declGetReturnType :: Decl -> IO Type

foreign import ccall "mathsat.h msat_decl_get_arity"
  declGetArity :: Decl -> IO CSize

foreign import ccall "mathsat.h msat_decl_get_arg_type"
  declGetArgType :: Decl -> CSize -> IO Type

foreign import ccall "mathsat.h msat_decl_repr"
  declRepr :: Decl -> IO CString

foreign import ccall "mathsat.h msat_term_repr"
  termRepr' :: Term -> IO CString

pushBacktrackPoint :: Env -> IO Bool
pushBacktrackPoint = fmap (==0) . pushBacktrackPoint'

foreign import ccall "mathsat.h msat_push_backtrack_point"
  pushBacktrackPoint' :: Env -> IO CInt

popBacktrackPoint :: Env -> IO Bool
popBacktrackPoint = fmap (==0) . popBacktrackPoint'

foreign import ccall "mathsat.h msat_pop_backtrack_point"
  popBacktrackPoint' :: Env -> IO CInt

assertFormula :: Env -> Term -> IO Bool
assertFormula env term = do
  res <- assertFormula' env term
  return $ res==0

foreign import ccall "mathsat.h msat_assert_formula"
  assertFormula' :: Env -> Term -> IO CInt

solve :: Env -> IO (Maybe Bool)
solve env = do
  res <- solve' env
  case res of
    #{const MSAT_SAT} -> return (Just True)
    #{const MSAT_UNSAT} -> return (Just False)
    #{const MSAT_UNKNOWN} -> return Nothing

foreign import ccall "mathsat.h msat_solve"
  solve' :: Env -> IO CInt

foreign import ccall "mathsat.h msat_create_itp_group"
  createITPGroup :: Env -> IO CInt

foreign import ccall "mathsat.h msat_set_itp_group"
  setITPGroup :: Env -> CInt -> IO ()

getInterpolant :: Env -> [CInt] -> IO (Maybe Term)
getInterpolant env grps
  = withArrayLen grps $
    \len cgrps -> do
      trm <- getInterpolant' env cgrps (fromIntegral len)
      if trm==nullPtr
        then return Nothing
        else return (Just $ Term trm)

foreign import ccall "mathsat.h msat_get_interpolant"
  getInterpolant' :: Env -> Ptr CInt -> CSize -> IO (Ptr Term)

foreign import ccall "mathsat.h msat_get_model_value"
  getModelValue :: Env -> Term -> IO Term

getUnsatCore :: Env -> IO (Maybe [Term])
getUnsatCore env
  = C.alloca $
    \sz -> do
      trms <- getUnsatCore' env sz
      if trms==nullPtr
        then return Nothing
        else (do
                 rsz <- peek sz
                 arr <- peekArray (fromIntegral rsz) trms
                 free trms
                 return $ Just arr)

foreign import ccall "mathsat.h msat_get_unsat_core"
  getUnsatCore' :: Env -> Ptr CSize -> IO (Ptr Term)

foreign import ccall "mathsat.h msat_get_proof_manager"
  getProofManager :: Env -> IO ProofManager

foreign import ccall "mathsat.h msat_destroy_proof_manager"
  destroyProofManager :: ProofManager -> IO ()

foreign import ccall "mathsat.h msat_get_proof"
  getProof :: ProofManager -> IO Proof

proofIsTerm :: Proof -> IO Bool
proofIsTerm = fmap (/=0) . proofIsTerm'

foreign import ccall "mathsat.h msat_proof_is_term"
  proofIsTerm' :: Proof -> IO CInt

foreign import ccall "mathsat.h msat_proof_get_term"
  proofGetTerm :: Proof -> IO Term

proofGetName :: Proof -> IO String
proofGetName proof = do
  name <- proofGetName' proof
  peekCString name

foreign import ccall "mathsat.h msat_proof_get_name"
  proofGetName' :: Proof -> IO CString

foreign import ccall "mathsat.h msat_proof_get_arity"
  proofGetArity :: Proof -> IO CSize

foreign import ccall "mathsat.h msat_proof_get_child"
  proofGetChild :: Proof -> CSize -> IO Proof

findDecl :: Env -> String -> IO Decl
findDecl env name = withCString name $ findDecl' env

foreign import ccall "mathsat.h msat_find_decl"
  findDecl' :: Env -> CString -> IO Decl