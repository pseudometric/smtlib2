{-# LANGUAGE OverloadedStrings,GADTs,FlexibleInstances,MultiParamTypeClasses,FunctionalDependencies,RankNTypes,DeriveDataTypeable,TypeSynonymInstances,TypeFamilies,FlexibleContexts #-}
module Language.SMTLib2.Internals where

import Data.Attoparsec
import qualified Data.AttoLisp as L
import Data.AttoLisp.Pretty
import qualified Data.Attoparsec.Number as L
import Data.ByteString as BS
import Blaze.ByteString.Builder
import System.Process
import System.IO as IO
import Data.Monoid
import Control.Monad.Reader
import Control.Monad.State
import Data.Text as T
import Data.Array
import Data.Bits
import Data.Typeable
import Data.Foldable (foldlM)
import Data.Map as Map hiding (assocs)
import Data.Set as Set
import Data.List as List (genericReplicate,mapAccumL)
import Data.Unit

-- | The SMT monad used for communating with the SMT solver
type SMT = ReaderT (Handle,Handle) (StateT (Integer,[TypeRep],Map T.Text TypeRep) IO)

-- | Haskell types which can be represented in SMT
class (Eq t,Typeable t) => SMTType t where
  type SMTAnnotation t
  getSort :: t -> SMTAnnotation t -> L.Lisp
  declareType :: t -> [(TypeRep,SMT ())]
  additionalConstraints :: t -> SMTExpr t -> [SMTExpr Bool]
  additionalConstraints _ _ = []

-- | Haskell values which can be represented as SMT constants
class SMTType t => SMTValue t where
  unmangle :: L.Lisp -> SMTAnnotation t -> SMT (Maybe t)
  mangle :: t -> SMTAnnotation t -> L.Lisp

-- | A type class for all types which support arithmetic operations in SMT
class (SMTValue t,Num t) => SMTArith t

-- | A type class for all types which support bitvector operations in SMT
class (SMTValue t,Bits t) => SMTBV t

-- | Lifts the 'Ord' class into SMT
class (SMTType t) => SMTOrd t where
  (.<.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.>=.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.>.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.<=.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool

-- | Represents a function in the SMT solver. /a/ is the argument of the function in SMT terms, /b/ is the argument in haskell types and /r/ is the result type of the function.
data SMTFun a b r = SMTFun

class Concatable a b where
    type ConcatResult a b
    concat' :: a -> b -> ConcatResult a b

-- | An abstract SMT expression
data SMTExpr t where
  Var :: SMTType t => Text -> SMTAnnotation t -> SMTExpr t
  Const :: SMTValue t => t -> SMTAnnotation t -> SMTExpr t
  Eq :: SMTType a => SMTExpr a -> SMTExpr a -> SMTExpr Bool
  Ge :: (Num a,SMTType a) => SMTExpr a -> SMTExpr a -> SMTExpr Bool
  Gt :: (Num a,SMTType a) => SMTExpr a -> SMTExpr a -> SMTExpr Bool
  Le :: (Num a,SMTType a) => SMTExpr a -> SMTExpr a -> SMTExpr Bool
  Lt :: (Num a,SMTType a) => SMTExpr a -> SMTExpr a -> SMTExpr Bool
  Distinct :: SMTType a => [SMTExpr a] -> SMTExpr Bool
  Plus :: SMTArith t => [SMTExpr t] -> SMTExpr t
  Minus :: SMTArith t => SMTExpr t -> SMTExpr t -> SMTExpr t
  Mult :: SMTArith t => [SMTExpr t] -> SMTExpr t
  Div :: SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer
  Mod :: SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer
  Divide :: SMTExpr Rational -> SMTExpr Rational -> SMTExpr Rational
  Neg :: SMTArith t => SMTExpr t -> SMTExpr t
  Abs :: SMTArith t => SMTExpr t -> SMTExpr t
  ITE :: SMTType t => SMTExpr Bool -> SMTExpr t -> SMTExpr t -> SMTExpr t
  And :: [SMTExpr Bool] -> SMTExpr Bool
  Or :: [SMTExpr Bool] -> SMTExpr Bool
  XOr :: SMTExpr Bool -> SMTExpr Bool -> SMTExpr Bool
  Implies :: SMTExpr Bool -> SMTExpr Bool -> SMTExpr Bool
  Not :: SMTExpr Bool -> SMTExpr Bool
  Select :: (Ix i,SMTType i,SMTType v) => SMTExpr (Array i v) -> SMTExpr i -> SMTExpr v
  Store :: (Ix i,SMTType i,SMTType v) => SMTExpr (Array i v) -> SMTExpr i -> SMTExpr v -> SMTExpr (Array i v)
  BVAdd :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVSub :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVMul :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVURem :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVSRem :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVUDiv :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVSDiv :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVULE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVULT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVUGE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVUGT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSLE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSLT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSGE :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVSGT :: SMTType t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
  BVExtract :: SMTType t1 => Integer -> Integer -> SMTExpr t1 -> SMTExpr t2
  BVConcat :: (SMTType t1,SMTType t2,Concatable t1 t2,t3 ~ ConcatResult t1 t2,Concatable (SMTAnnotation t1) (SMTAnnotation t2),SMTAnnotation t3 ~ ConcatResult (SMTAnnotation t1) (SMTAnnotation t2)) => SMTExpr t1 -> SMTExpr t2 -> SMTExpr t3
  BVConcats :: SMTType t1 => [SMTExpr t1] -> SMTExpr t2
  BVXor :: SMTExpr t -> SMTExpr t -> SMTExpr t
  BVAnd :: SMTExpr t -> SMTExpr t -> SMTExpr t
  Forall :: Args a b => (a -> SMTExpr Bool) -> SMTExpr Bool
  ForallList :: Args a b => Integer -> ([a] -> SMTExpr Bool) -> SMTExpr Bool
  Exists :: Args a b => (a -> SMTExpr Bool) -> SMTExpr Bool
  Let :: (SMTType a) => SMTExpr a -> (SMTExpr a -> SMTExpr b) -> SMTExpr b
  Lets :: SMTType a => [SMTExpr a] -> ([SMTExpr a] -> SMTExpr b) -> SMTExpr b
  Fun :: (Args a b,SMTType r) => Text -> SMTExpr (SMTFun a b r)
  App :: (Args a b,SMTType r) => SMTExpr (SMTFun a b r) -> a -> SMTExpr r
  ConTest :: SMTType a => Constructor a -> SMTExpr a -> SMTExpr Bool
  FieldSel :: (SMTType a,SMTType f) => Field a f -> SMTExpr a -> SMTExpr f
  Head :: SMTExpr [a] -> SMTExpr a
  Tail :: SMTExpr [a] -> SMTExpr [a]
  Insert :: SMTExpr a -> SMTExpr [a] -> SMTExpr [a]
  Named :: SMTExpr a -> Text -> SMTExpr a
  InterpolationGrp :: SMTExpr Bool -> Text -> SMTExpr Bool
  InternalFun :: [L.Lisp] -> SMTExpr (SMTFun (SMTExpr Bool) Bool Bool)
  Undefined :: SMTExpr a
  deriving Typeable

instance Show (SMTExpr a) where
    show expr = "<smt-expr>"

instance Eq a => Eq (SMTExpr a) where
    (==) (Var v1 _) (Var v2 _) = v1 == v2
    (==) (Const v1 _) (Const v2 _) = v1 == v2
    (==) (Ge l1 r1) (Ge l2 r2) = (eqExpr l1 l2) && (eqExpr r1 r2)
    (==) (Gt l1 r1) (Gt l2 r2) = (eqExpr l1 l2) && (eqExpr r1 r2)
    (==) (Le l1 r1) (Le l2 r2) = (eqExpr l1 l2) && (eqExpr r1 r2)
    (==) (Lt l1 r1) (Lt l2 r2) = (eqExpr l1 l2) && (eqExpr r1 r2)
    (==) (Distinct x1) (Distinct x2) = eqExprs x1 x2
    (==) (Plus x1) (Plus x2) = eqExprs x1 x2
    (==) (Minus l1 r1) (Minus l2 r2) = (eqExpr l1 l2) && (eqExpr r1 r2)
    (==) (Mult x1) (Mult x2) = eqExprs x1 x2
    (==) (Div l1 r1) (Div l2 r2) = l1 == l2 && r1 == r2
    (==) (Mod l1 r1) (Mod l2 r2) = l1 == l2 && r1 == r2
    (==) (Divide l1 r1) (Divide l2 r2) = l1 == l2 && r1 == r2
    (==) (Neg x) (Neg y) = x == y
    (==) (Abs x) (Abs y) = x == y
    (==) (ITE c1 l1 r1) (ITE c2 l2 r2) = c1 == c2 && eqExpr l1 l2 && eqExpr r1 r2
    (==) (And x) (And y) = x == y
    (==) (Or x) (Or y) = x == y
    (==) (XOr l1 r1) (XOr l2 r2) = l1 == l2 && r1 == r2
    (==) (Implies l1 r1) (Implies l2 r2) = l1 == l2 && r1 == r2
    (==) (Not x) (Not y) = x==y
    (==) (Select a1 i1) (Select a2 i2) = eqExpr a1 a2 && eqExpr i1 i2
    (==) (Store a1 i1 v1) (Store a2 i2 v2) = a1==a2 && i1 == i2 && v1 == v2
    (==) (BVAdd l1 r1) (BVAdd l2 r2) = l1 == l2 && r1 == r2
    (==) (BVSub l1 r1) (BVSub l2 r2) = l1 == l2 && r1 == r2
    (==) (BVMul l1 r1) (BVMul l2 r2) = l1 == l2 && r1 == r2
    (==) (BVURem l1 r1) (BVURem l2 r2) = l1 == l2 && r1 == r2
    (==) (BVSRem l1 r1) (BVSRem l2 r2) = l1 == l2 && r1 == r2
    (==) (BVUDiv l1 r1) (BVUDiv l2 r2) = l1 == l2 && r1 == r2
    (==) (BVSDiv l1 r1) (BVSDiv l2 r2) = l1 == l2 && r1 == r2
    (==) (BVULE l1 r1) (BVULE l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVULT l1 r1) (BVULT l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVUGE l1 r1) (BVUGE l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVUGT l1 r1) (BVUGT l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVSLE l1 r1) (BVSLE l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVSLT l1 r1) (BVSLT l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVSGE l1 r1) (BVSGE l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVSGT l1 r1) (BVSGT l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVExtract l1 u1 e1) (BVExtract l2 u2 e2) = l1 == l2 && u1 == u2 && eqExpr e1 e2
    (==) (BVConcat l1 r1) (BVConcat l2 r2) = eqExpr l1 l2 && eqExpr r1 r2
    (==) (BVConcats x) (BVConcats y) = eqExprs x y
    (==) (BVXor l1 r1) (BVXor l2 r2) = l1 == l2 && r1 == r2
    (==) (BVAnd l1 r1) (BVAnd l2 r2) = l1 == l2 && r1 == r2
    (==) (ConTest c1 e1) (ConTest c2 e2) = eqExpr c1 c2 && eqExpr e1 e2
    (==) (FieldSel (Field f1) e1) (FieldSel (Field f2) e2) = f1 == f2 && eqExpr e1 e2
    (==) (Head x) (Head y) = x == y
    (==) (Tail x) (Tail y) = x == y
    -- This doesn't work for unknown reasons
    --(==) (Insert x xs) (Insert y ys) = x == y && xs == ys
    (==) (Named e1 n1) (Named e2 n2) = e1==e2 && n1==n2
    (==) (InterpolationGrp e1 n1) (InterpolationGrp e2 n2) = e1 == e2 && n1 == n2
    (==) (InternalFun arg1) (InternalFun arg2) = arg1 == arg2
    (==) Undefined Undefined = True
    (==) _ _ = False
  
eqExprs :: (Eq a,Typeable a,Typeable b) => [SMTExpr a] -> [SMTExpr b] -> Bool
eqExprs (x:xs) (y:ys) = eqExpr x y && eqExprs xs ys
eqExprs [] [] = True
eqExprs _ _ = False

eqExpr :: (Eq (c a),Typeable a,Typeable b) => c a -> c b -> Bool
eqExpr lhs rhs = case gcast rhs of
                   Nothing -> False
                   Just rhs' -> lhs == rhs'

-- | Represents a constructor of a datatype /a/
--   Can be obtained by using the template haskell extension module
data Constructor a = Constructor Text deriving (Eq)

-- | Represents a field of the datatype /a/ of the type /f/
data Field a f = Field Text deriving (Eq)

newtype InterpolationGroup = InterpolationGroup Text

-- | Options controling the behaviour of the SMT solver
data SMTOption
     = PrintSuccess Bool -- ^ Whether or not to print \"success\" after each operation
     | ProduceModels Bool -- ^ Produce a satisfying assignment after each successful checkSat
     | ProduceProofs Bool -- ^ Produce a proof of unsatisfiability after each failed checkSat
     deriving (Show,Eq,Ord)

-- | A piece of information of type /r/ that can be obtained by the SMT solver
class SMTInfo i r | i -> r where
  getInfo :: i -> SMT r

-- | The name of the SMT solver
data SMTSolverName = SMTSolverName deriving (Show,Eq,Ord)

instance SMTInfo SMTSolverName String where
  getInfo _ = do
    putRequest (L.List [L.Symbol "get-info",L.Symbol ":name"])
    res <- parseResponse
    case res of
      L.List [L.Symbol ":name",L.String name] -> return $ T.unpack name

-- | The version of the SMT solver
data SMTSolverVersion = SMTSolverVersion deriving (Show,Eq,Ord)

instance SMTInfo SMTSolverVersion String where
  getInfo _ = do
    putRequest (L.List [L.Symbol "get-info",L.Symbol ":version"])
    res <- parseResponse
    case res of
      L.List [L.Symbol ":version",L.String name] -> return $ T.unpack name

-- | Instances of this class may be used as arguments for constructed functions and quantifiers.
class Args a b | a -> b where
  createArgs :: Integer -> (a,[(Text,L.Lisp)],Integer)
  unpackArgs :: (forall t. SMTExpr t -> Integer -> (c,Integer)) -> a -> b -> Integer -> ([c],Integer)
  foldExprs :: (forall t. s -> SMTExpr t -> (s,SMTExpr t)) -> s -> a -> (s,a)
  allOf :: (forall t. SMTExpr t) -> a

firstJust :: Monad m => [m (Maybe a)] -> m (Maybe a)
firstJust [] = return Nothing
firstJust (act:acts) = do
  r <- act
  case r of
    Nothing -> firstJust acts
    Just res -> return $ Just res

getUndef :: SMTExpr t -> t
getUndef _ = undefined

getFunUndef :: SMTExpr (SMTFun a b r) -> (a,b,r)
getFunUndef _ = (undefined,undefined,undefined)

declareFun :: Text -> [L.Lisp] -> L.Lisp -> SMT ()
declareFun name tps rtp
  = putRequest $ L.List [L.Symbol "declare-fun"
                        ,L.Symbol name
                        ,args tps
                        ,rtp
                        ]

defineFun :: Text -> [(Text,L.Lisp)] -> L.Lisp -> L.Lisp -> SMT ()
defineFun name arg rtp body = putRequest $ L.List [L.Symbol "define-fun"
                                                  ,L.Symbol name
                                                  ,args [ L.List [ L.Symbol n, tp ]
                                                        | (n,tp) <- arg ]
                                                  ,rtp
                                                  ,body ]

declareDatatypes :: [Text] -> [(Text,[(Text,[(Text,L.Lisp)])])] -> SMT ()
declareDatatypes params dts
  = putRequest $ L.List [L.Symbol "declare-datatypes"
                        ,args (fmap L.Symbol params)
                        ,L.List
                         [ L.List $ [L.Symbol name] 
                           ++ [ L.List $ [L.Symbol conName] 
                                ++ [ L.List [L.Symbol fieldName,tp]
                                   | (fieldName,tp) <- fields ]
                              | (conName,fields) <- cons ]
                         | (name,cons) <- dts ]
                        ]

args :: [L.Lisp] -> L.Lisp
args [] = L.Symbol "()"
args xs = L.List xs

-- | Check if the model is satisfiable (e.g. if there is a value for each variable so that every assertion holds)
checkSat :: SMT Bool
checkSat = do
  (_,hout) <- ask
  clearInput
  putRequest (L.List [L.Symbol "check-sat"])
  res <- liftIO $ BS.hGetLine hout
  case res of
    "sat" -> return True
    "sat\r" -> return True
    "unsat" -> return False
    "unsat\r" -> return False
    _ -> error $ "unknown check-sat response: "++show res

-- | Perform a stacked operation, meaning that every assertion and declaration made in it will be undone after the operation.
stack :: SMT a -> SMT a
stack act = do
  putRequest (L.List [L.Symbol "push",L.toLisp (1::Integer)])
  res <- act
  putRequest (L.List [L.Symbol "pop",L.toLisp (1::Integer)])
  return res

-- | Insert a comment into the SMTLib2 command stream.
--   If you aren't looking at the command stream for debugging, this will do nothing.
comment :: String -> SMT ()
comment msg = do
  (hin,_) <- ask
  liftIO $ IO.hPutStrLn hin $ ';':msg

-- | Spawn a shell command that is used as a SMT solver via stdin/-out to process the given SMT operation.
withSMTSolver :: String -- ^ The shell command to execute
                 -> SMT a -- ^ The SMT operation to perform
                 -> IO a
withSMTSolver solver f = do
  let cmd = CreateProcess { cmdspec = ShellCommand solver
                          , cwd = Nothing
                          , env = Nothing
                          , std_in = CreatePipe
                          , std_out = CreatePipe
                          , std_err = Inherit
                          , close_fds = False
                          }
  (Just hin,Just hout,_,handle) <- createProcess cmd
  res <- evalStateT (runReaderT (do
                                 res <- f
                                 putRequest (L.List [L.Symbol "exit"])
                                 return res
                                ) (hin,hout)) (0,[],Map.empty)
  hClose hin
  hClose hout
  terminateProcess handle
  waitForProcess handle
  return res

clearInput :: SMT ()
clearInput = do
  (_,hout) <- ask
  r <- liftIO $ hReady hout
  if r
    then (do
             liftIO $ BS.hGetSome hout 1024
             clearInput)
    else return ()

putRequest :: L.Lisp -> SMT ()
putRequest e = do
  --liftIO $ print $ prettyLisp e
  (hin,_) <- ask
  liftIO $ toByteStringIO (BS.hPutStr hin) (mappend (L.fromLispExpr e) flush)
  liftIO $ BS.hPutStrLn hin ""
  liftIO $ hFlush hin

parseResponse :: SMT L.Lisp
parseResponse = do
  (_,hout) <- ask
  str <- liftIO $ BS.hGetLine hout
  let continue (Done _ r) = return r
      continue res@(Partial _) = do
        str <- BS.hGetLine hout
        continue (feed res str)
      continue (Fail str ctx msg) = error $ "Error parsing "++show str++" response in "++show ctx++": "++msg
  liftIO $ continue $ parse L.lisp str

-- | Declare a new sort with a specified arity
declareSort :: T.Text -> Integer -> SMT ()
declareSort name arity = putRequest (L.List [L.Symbol "declare-sort",L.Symbol name,L.toLisp arity])

foldExpr :: (forall a. b -> SMTExpr a -> (b,SMTExpr a)) -> b -> SMTExpr c -> (b,SMTExpr c)
foldExpr f x (Eq l r) = let (x1,e1) = foldExpr f x l
                            (x2,e2) = foldExpr f x1 r
                        in f x2 (Eq e1 e2)
foldExpr f x (Ge l r) = let (x1,e1) = foldExpr f x l
                            (x2,e2) = foldExpr f x1 r
                        in f x2 (Ge e1 e2)
foldExpr f x (Gt l r) = let (x1,e1) = foldExpr f x l
                            (x2,e2) = foldExpr f x1 r
                        in f x2 (Gt e1 e2)
foldExpr f x (Le l r) = let (x1,e1) = foldExpr f x l
                            (x2,e2) = foldExpr f x1 r
                        in f x2 (Le e1 e2)
foldExpr f x (Lt l r) = let (x1,e1) = foldExpr f x l
                            (x2,e2) = foldExpr f x1 r
                        in f x2 (Lt e1 e2)
foldExpr f x (Distinct ds) = let (x',ds') = List.mapAccumL (foldExpr f) x ds
                             in f x' (Distinct ds')
foldExpr f x (Plus ds) = let (x',ds') = List.mapAccumL (foldExpr f) x ds
                         in f x' (Plus ds')
foldExpr f x (Minus l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (Minus e1 e2)
foldExpr f x (Mult ds) = let (x',ds') = List.mapAccumL (foldExpr f) x ds
                         in f x' (Mult ds')
foldExpr f x (Div l r) = let (x1,e1) = foldExpr f x l
                             (x2,e2) = foldExpr f x1 r
                         in f x2 (Div e1 e2)
foldExpr f x (Mod l r) = let (x1,e1) = foldExpr f x l
                             (x2,e2) = foldExpr f x1 r
                         in f x2 (Mod e1 e2)
foldExpr f x (Divide l r) = let (x1,e1) = foldExpr f x l
                                (x2,e2) = foldExpr f x1 r
                            in f x2 (Divide e1 e2)
foldExpr f x (Neg l) = let (x1,e1) = foldExpr f x l
                       in f x1 (Neg e1)
foldExpr f x (Abs l) = let (x1,e1) = foldExpr f x l
                       in f x1 (Abs e1)
foldExpr f x (ITE l r c) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                               (x3,e3) = foldExpr f x2 c
                           in f x3 (ITE e1 e2 e3)
foldExpr f x (And ds) = let (x',ds') = List.mapAccumL (foldExpr f) x ds
                        in f x' (And ds')
foldExpr f x (Or ds) = let (x',ds') = List.mapAccumL (foldExpr f) x ds
                       in f x' (Or ds')
foldExpr f x (XOr l r) = let (x1,e1) = foldExpr f x l
                             (x2,e2) = foldExpr f x1 r
                         in f x2 (XOr e1 e2)
foldExpr f x (Implies l r) = let (x1,e1) = foldExpr f x l
                                 (x2,e2) = foldExpr f x1 r
                             in f x2 (Implies e1 e2)
foldExpr f x (Not l) = let (x1,e1) = foldExpr f x l
                       in f x1 (Not e1)
foldExpr f x (Select l r) = let (x1,e1) = foldExpr f x l
                                (x2,e2) = foldExpr f x1 r
                            in f x2 (Select e1 e2)
foldExpr f x (Store l r c) = let (x1,e1) = foldExpr f x l
                                 (x2,e2) = foldExpr f x1 r
                                 (x3,e3) = foldExpr f x2 c
                             in f x3 (Store e1 e2 e3)
foldExpr f x (BVAdd l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVAdd e1 e2)
foldExpr f x (BVSub l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVSub e1 e2)
foldExpr f x (BVMul l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVMul e1 e2)
foldExpr f x (BVURem l r) = let (x1,e1) = foldExpr f x l
                                (x2,e2) = foldExpr f x1 r
                            in f x2 (BVURem e1 e2)
foldExpr f x (BVSRem l r) = let (x1,e1) = foldExpr f x l
                                (x2,e2) = foldExpr f x1 r
                            in f x2 (BVSRem e1 e2)
foldExpr f x (BVULE l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVULE e1 e2)
foldExpr f x (BVULT l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVULT e1 e2)
foldExpr f x (BVUGE l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVUGE e1 e2)
foldExpr f x (BVUGT l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVUGT e1 e2)
foldExpr f x (BVSLE l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVSLE e1 e2)
foldExpr f x (BVSLT l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVSLT e1 e2)
foldExpr f x (BVSGE l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVSGE e1 e2)
foldExpr f x (BVSGT l r) = let (x1,e1) = foldExpr f x l
                               (x2,e2) = foldExpr f x1 r
                           in f x2 (BVSGT e1 e2)
foldExpr f x (Forall g) = let g' = foldExpr f x . g
                          in f (fst $ g' $ allOf Undefined) (Forall (snd . g'))
foldExpr f x (ForallList n g) = let g' = foldExpr f x . g
                                in f (fst $ g' $ genericReplicate n (allOf Undefined)) (ForallList n (snd . g'))
foldExpr f x (Exists g) = let g' = foldExpr f x . g
                          in f (fst $ g' $ allOf Undefined) (Exists (snd . g'))
foldExpr f x (Let arg g) = let g' = foldExpr f x1 . g
                               (x1,e1) = foldExpr f x arg
                           in f (fst $ g' Undefined) (Let e1 (snd . g'))
foldExpr f x (App g arg) = let (x1,e1) = foldExpr f x g
                               (x2,e2) = foldExprs f x1 arg
                           in f x2 (App e1 e2)
foldExpr f x (ConTest c e) = let (x1,e1) = foldExpr f x e
                             in f x1 (ConTest c e1)
foldExpr f x (FieldSel g e) = let (x1,e1) = foldExpr f x e
                              in f x1 (FieldSel g e1)
foldExpr f x (Head l) = let (x1,e1) = foldExpr f x l
                        in f x1 (Head e1)
foldExpr f x (Tail l) = let (x1,e1) = foldExpr f x l
                        in f x1 (Tail e1)
foldExpr f x (Insert l r) = let (x1,e1) = foldExpr f x l
                                (x2,e2) = foldExpr f x1 r
                            in f x2 (Insert e1 e2)
foldExpr f x (Named e n) = let (x1,e1) = foldExpr f x e
                           in f x1 (Named e1 n)
foldExpr f x e = f x e


getVars :: SMTExpr a -> Set T.Text
getVars = fst . foldExpr (\s expr -> (case expr of
                                         Var n _ -> Set.insert n s
                                         _ -> s,expr)) Set.empty

replaceName :: (T.Text -> T.Text) -> SMTExpr a -> SMTExpr a
replaceName f = snd . foldExpr (\_ expr -> ((),case expr of
                                               Var n ann -> Var (f n) ann
                                               _ -> expr)) ()

