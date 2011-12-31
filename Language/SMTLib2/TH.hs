{-# LANGUAGE TemplateHaskell,OverloadedStrings #-}
module Language.SMTLib2.TH 
       (deriveSMT,
        constructor,
        field,
        matches)
       where

import Language.SMTLib2.Internals
import Language.Haskell.TH
import qualified Data.AttoLisp as L
import Data.Text as T
import Data.Typeable
import Data.List as List
import Data.Maybe (catMaybes)

type ExtrType = [(Name,[(Name,Type)])]

deriveSMT :: Name -> Q [Dec]
deriveSMT name = do
  tp <- extractDataType name
  pat <- newName "u"
  let decls = [instanceD (cxt []) (appT (conT ''SMTType) (conT name))
               [funD 'getSort [clause [wildP] (normalB $ generateSortExpr name) []],
                funD 'declareType [clause [varP pat] (normalB $ generateDeclExpr name tp pat) []]
               ],
               instanceD (cxt []) (appT (conT ''SMTValue) (conT name))
               [generateMangleFun tp,
                generateUnmangleFun tp]
              ]
  sequence decls

endType :: Type -> Type
endType (AppT _ tp) = endType tp
endType tp = tp

constructor :: Name -> Q Exp
constructor name = do
  inf <- reify name
  case inf of
    DataConI _ tp _ _ -> [| Constructor $(stringE $ nameBase name) :: Constructor $(return $ endType tp) |]

field :: Name -> Q Exp
field name = do
  inf <- reify name
  case inf of
    VarI _ (AppT (AppT ArrowT orig) res) _ _ -> [| Field $(stringE $ nameBase name) :: Field $(return orig) $(return res) |]
    _ -> error $ show inf ++ " is not a valid field"

extractDataType :: Name -> Q ExtrType
extractDataType name = do
  inf <- reify name
  return $ case inf of
    TyConI (DataD _ _ _ cons _)
      -> fmap (\con -> case con of
                  RecC n vars -> (n,fmap (\(vn,_,tp) -> (vn,tp)) vars)
                  NormalC n [] -> (n,[])
                  _ -> error $ "Can't derive SMT classes for constructor "++show con
              ) cons
    _ -> error $ "Can't derive SMT classes for "++show inf

generateSortExpr :: Name -> Q Exp
generateSortExpr name = [| L.Symbol $(stringE $ nameBase name) |]

generateDeclExpr :: Name -> ExtrType -> Name -> Q Exp
generateDeclExpr dname cons pat
  = Prelude.foldl (\cur tp -> [| $(cur) ++ declareType (undefined :: $(return tp)) |])
    [| [(typeOf $(varE pat),declareDatatypes [] [(T.pack $(stringE $ nameBase dname),
                                                  $(listE [ tupE [ [| T.pack $(stringE $ nameBase cname) |],  
                                                                   listE [ tupE [ stringE $ nameBase sname,
                                                                                  [| getSort (undefined :: $(return tp)) |]
                                                                                ] 
                                                                         | (sname,tp) <- sels ]
                                                                 ]
                                                          | (cname,sels) <- cons ])
                                                 )])] |]
    [ tp
    | (_,fields) <- cons, 
      (_,tp) <- fields
    ]

generateMangleFun :: ExtrType -> Q Dec
generateMangleFun cons
  = funD 'mangle [ do
    vars <- mapM (const $ newName "f") fields
    clause [conP cname (fmap varP vars)]
            (normalB (if Prelude.null vars
                      then [| L.Symbol $(stringE $ nameBase cname) |]
                      else [| L.List $ [L.Symbol $(stringE $ nameBase cname)] ++
                                       $(listE [ [| mangle $(varE v) |]
                                               | v <- vars ])
                            |])) []
    | (cname,fields) <- cons
    ]

generateUnmangleFun :: ExtrType -> Q Dec
generateUnmangleFun cons
  = funD 'unmangle 
    [do
       vars <- mapM (const $ newName "f") fields
       clause [(if Prelude.null fields
                then conP 'L.Symbol [litP $ stringL $ nameBase cname]
                else conP 'L.List [listP $ [conP 'L.Symbol [litP $ stringL $ nameBase cname]]++
                                           (fmap varP vars)])]
                (normalB $ appsE $ (conE cname):[ [| unmangle $(varE v) |]
                                                | v <- vars
                                                ]) []
    | (cname,fields) <- cons
    ]

matches :: Q Exp -> Q Pat -> Q Exp
matches exp pat = do
  p <- pat
  case matches' exp p of
    Nothing -> [| constant True |]
    Just res -> res
  where
    matches' exp (LitP l) = Just [| $exp .==. $(litE l) |]
    matches' _ WildP = Nothing
    matches' exp (ConP name []) = Just [| is $exp $(constructor name) |]
    matches' exp (ConP name pats) = Just $ do
      DataConI _ _ d _ <- reify name
      TyConI (DataD _ _ _ cons _) <- reify d
      let Just (RecC _ fields) = List.find (\con -> case con of
                                               RecC n _ -> n==name
                                               _ -> False) cons
      [| and' $ (is $exp $(constructor name)): $(listE $ catMaybes [ matches' [| $exp .# $(field f) |] pat | ((f,_,_),pat) <- Prelude.zip fields pats ]) |]
    matches' exp (RecP name pats) = Just [| and' $ (is $exp $(constructor name)): $(listE $ catMaybes [ matches' [| $exp .# $(field f) |] pat | (f,pat) <- pats ]) |]
    