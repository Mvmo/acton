module Acton.Normalizer where

import Acton.Syntax
import Acton.Env
import Acton.Prim
import Acton.Builtin
import Utils
import Control.Monad.State.Lazy

normalize                           :: Env -> Module -> IO Module
normalize env0 m                    = return $ evalState (norm env m) 0
  where env                         = normEnv env0

--  Normalization:
--  - All imported or built-in names are qualified by module, including those imported by 'from _ import'
--  - All module aliases are replaced by their original module name
--  X All parameters are positional
--  X Parameter defaults are moved inside function definitions
--  - Comprehensions are translated into loops
--  X String literals are concatenated and delimited by double quotes
--  - Tuple (and list) patterns are replaced by a var pattern followed by explicit element assignments
--  X Indexed and sliced expressions (Index/Slice) are replaced by __getitem__/__getslice__ calls
--  - Assignments to indexed and sliced patterns (PIndex/PSlice) are replaced by __setitem__/__setslice__ calls
--  - With statemenmts are replaced by enter/exit prim calls + exception handling
--  X The assert statement is replaced by a prim call ASSERT
--  X The raise statement is replaced by one of prim calls RAISE, RAISEFROM or RERAISE
--  - The delete statement is replaced by (a sequence of) __delitem__ calls (for PIndex) or None assignments
--  X Return without argument is replaced by return None
--  - Incremental assignments are replaced by the corresponding __iop__ calls
--  - The else branch of a while loop is replaced by an explicit if statement enclosing the loop
--  - Binary and unary operators are replaced by their corresponding __op__ calls


-- Normalizing monad
type NormM a                        = State Int a

newName                             :: String -> NormM Name
newName s                           = do n <- get
                                         put (n+1)
                                         return $ Internal s n NormPass

data NormEnv                        = NormEnv

normEnv env                         = NormEnv

class Norm a where
    norm                            :: NormEnv -> a -> NormM a
    norm'                           :: NormEnv -> a -> NormM [a]
    norm' env x                     = (:[]) <$> norm env x

instance Norm a => Norm [a] where
    norm env xs                     = concat <$> mapM (norm' env) xs

instance Norm a => Norm (Maybe a) where
    norm env Nothing                = return Nothing
    norm env (Just a)               = Just <$> norm env a

instance Norm Module where
    norm env (Module qn imps ss)    = Module <$> norm env qn <*> norm env imps <*> norm env ss

instance Norm Import where
    norm env (Import l ms)          = Import l <$> norm env ms
    norm env (FromImport l m ns)    = FromImport l <$> norm env m <*> norm env ns
    norm env (FromImportAll l m)    = FromImportAll l <$> norm env m

instance Norm Stmt where
    norm env (Expr l e)             = Expr l <$> norm env e
    norm env (Assign l ts e)        = Assign l <$> norm env ts <*> norm env e
    norm env (AugAssign l p op e)   = AugAssign l <$> norm env p <*> norm env op <*> norm env e
    norm env (Assert l e mbe)       = do e' <- norm env e
                                         mbe' <- norm env mbe
                                         return $ Expr l $ eCall (eQVar primASSERT) [e', maybe eNone id mbe']
    norm env (Pass l)               = return $ Pass l
    norm env (Delete l p)           = Delete l <$> norm env p
    norm env (Return l Nothing)     = return $ Return l $ Just $ None l0
    norm env (Return l (Just e))    = do e' <- norm env e
                                         return $ Return l $ Just e'
    norm env (Raise l mbex)         = do mbex' <- norm env mbex
                                         case mbex' of
                                           Nothing ->
                                               return $ Expr l $ eCall (eQVar primRERAISE) []
                                           Just (Exception e Nothing) ->
                                               return $ Expr l $ eCall (eQVar primRAISE) [e]
                                           Just (Exception e (Just e')) -> 
                                               return $ Expr l $ eCall (eQVar primRAISEFROM) [e,e']
    norm env (Break l)              = return $ Break l
    norm env (Continue l)           = return $ Continue l
    norm env (If l bs els)          = If l <$> norm env bs <*> norm env els
    norm env (While l e b els)      = While l <$> norm env e <*> norm env b <*> norm env els
    norm env (For l p e b els)      = For l <$> norm env p <*> norm env e <*> norm env b <*> norm env els
    norm env (Try l b hs els fin)   = Try l <$> norm env b <*> norm env hs <*> norm env els <*> norm env fin
    norm env (With l is b)          = With l <$> norm env is <*> norm env b
    norm env (Data l mbt ss)        = Data l <$> norm env mbt <*> norm env ss
    norm env (VarAssign l ps e)     = VarAssign l <$> norm env ps <*> norm env e
    norm env (Decl l ds)            = Decl l <$> norm env ds

--    norm' env (Delete l p)          = 

instance Norm Decl where
    norm env (Def l n q p k t b m)  = do p' <- joinPar <$> norm env p <*> norm env k
                                         b' <- norm env b
                                         return $ Def l n q (noDefaults p') KwdNIL t (defaults p' ++ b') m
    norm env (Actor l n q p k t b)  = do p' <- joinPar <$> norm env p <*> norm env k
                                         b' <- norm env b
                                         return $ Actor l n q (noDefaults p') KwdNIL t (defaults p' ++ b')
    norm env (Class l n q as b)     = Class l n q as <$> norm env b
    norm env (Protocol l n q as b)  = Protocol l n q as <$> norm env b
    norm env (Extension l n q as b) = Extension l n q as <$> norm env b
    norm env (Signature l ns t)     = return $ Signature l ns t

instance Norm Expr where
    norm env (Var l nm)             = Var l <$> norm env nm
    norm env (Int l i s)            = Int l <$> return i <*> return s
    norm env (Float l f s)          = Float l <$> return f <*> return s
    norm env (Imaginary l i s)      = Imaginary l <$> return i <*> return s
    norm env (Bool l b)             = Bool l <$> return b
    norm env (None l)               = return $ None l
    norm env (NotImplemented l)     = return $ NotImplemented l
    norm env (Ellipsis l)           = return $ Ellipsis l
    norm env (Strings l [s])
      | head s == '"'               = return $ Strings l [s]
    norm env (Strings l ss)         = return $ Strings l ['"' : (escape '"' (concatMap stripQuotes ss)) ++ ['"']]
      where escape c []             = []
            escape c ('\\':x:xs)    = '\\' : x : escape c xs
            escape c (x:xs)
              | x == c              = '\\' : x : escape c xs
              | otherwise           = x : escape c xs
            stripQuotes s           = init $ tail s
    norm env (BStrings l ss)        = return $ BStrings l [concat ss]
    norm env (Call l e ps ks)       = Call l <$> norm env e <*> norm env ps <*> norm env ks
    norm env (Index l e [ix])       = do e' <- norm env e
                                         ix' <- norm env ix
                                         return $ Call l (eDot e' getitemKW) (PosArg ix' PosNil) KwdNil
    norm env (Slice l e [sl])       = do e' <- norm env e
                                         sl' <- norm env sl
                                         return $ Call l (eDot e' getsliceKW) (toArg sl') KwdNil
      where toArg (Sliz _ e1 e2 e3) = foldr PosArg PosNil (map (maybe (None NoLoc) id) [e1,e2,e3])
    norm env (Cond l e1 e2 e3)      = Cond l <$> norm env e1 <*> norm env e2 <*> norm env e3
    norm env (BinOp l e1 op e2)     = BinOp l <$> norm env e1 <*> norm env op <*> norm env e2
    norm env (CompOp l e ops)       = CompOp l <$> norm env e <*> norm env ops
    norm env (UnOp l op e)          = UnOp l <$> norm env op <*> norm env e 
    norm env (Dot l e nm)           = Dot l <$> norm env e <*> norm env nm
    norm env (DotI l e i)           = DotI l <$> norm env e <*> return i
    norm env (Lambda l ps ks e)     = Lambda l <$> norm env ps <*> norm env ks <*> norm env e
    norm env (Yield l e)            = Yield l <$> norm env e
    norm env (YieldFrom l e)        = YieldFrom l <$> norm env e
    norm env (Tuple l es)           = Tuple l <$> norm env es
    norm env (TupleComp l e c)      = TupleComp l <$> norm env e <*> norm env c
    norm env (Record l fs)          = Record l <$> norm env fs
    norm env (RecordComp l n e c)   = RecordComp l n <$> norm env e <*> norm env c
    norm env (List l es)            = List l <$> norm env es
    norm env (ListComp l e c)       = ListComp l <$> norm env e <*> norm env c
    norm env (Dict l as)            = Dict l <$> norm env as
    norm env (DictComp l a c)       = DictComp l <$> norm env a <*> norm env c
    norm env (Set l es)             = Set l <$> norm env es
    norm env (SetComp l e c)        = SetComp l <$> norm env e <*> norm env c
    norm env (Paren l e)            = Paren l <$> norm env e

instance Norm Pattern where
    norm env (PVar l n a)           = return $ PVar l n a
    norm env (PIndex l e ix)        = PIndex l <$> norm env e <*> norm env ix
    norm env (PSlice l e sl)        = PSlice l <$> norm env e <*> norm env sl
    norm env (PDot l e n)           = PDot l <$> norm env e <*> norm env n
    norm env (PTuple l ps)          = PTuple l <$> norm env ps
    norm env (PList l ps p)         = PList l <$> norm env ps <*> norm env p
--    norm env (PRecord l ps)         = PRecord l <$> norm env ps
    norm env (PParen l p)           = PParen l <$> norm env p

instance Norm Exception where
    norm env (Exception e mbe)      = Exception <$> norm env e <*> norm env mbe

instance Norm Name where
    norm env (Name l s)             = Name l <$> return s

instance Norm ModName where
    norm env (ModName ns)           = ModName <$> norm env ns

instance Norm QName where
    norm env (QName m n)            = QName <$> norm env m <*> norm env n
    norm env (NoQual n)             = NoQual <$> norm env n

instance Norm ModRef where
    norm env (ModRef (n,mbqn))      = (\m -> ModRef (n,m)) <$> norm env mbqn

instance Norm ModuleItem where
    norm env (ModuleItem qn mbn)    = ModuleItem <$> norm env qn <*> norm env mbn

instance Norm ImportItem where
    norm env (ImportItem nm mbn)    = ImportItem <$> norm env nm <*> norm env mbn

instance Norm (Op a) where
    norm env (Op l a)               = Op l <$> return a

instance Norm Branch where
    norm env (Branch e ss)          = Branch <$> norm env e <*> norm env ss

instance Norm Handler where
    norm env (Handler ex b)         = Handler <$> norm env ex <*> norm env b

instance Norm Except where
    norm env (ExceptAll l)          = return $ ExceptAll l
    norm env (Except l x)           = Except l <$> norm env x
    norm env (ExceptAs l x n)       = ExceptAs l <$> norm env x <*> norm env n

instance Norm PosPar where
    norm env (PosPar n t e p)       = PosPar n t <$> norm env e <*> norm env p
    norm env (PosSTAR n t)          = return $ PosSTAR n t
    norm env PosNIL                 = return PosNIL
    
instance Norm KwdPar where
    norm env (KwdPar n t e k)       = KwdPar n t <$> norm env e <*> norm env k
    norm env (KwdSTAR n t)          = return $ KwdSTAR n t
    norm env KwdNIL                 = return KwdNIL

joinPar (PosPar n t e p) k          = PosPar n t e (joinPar p k)
joinPar (PosSTAR n t) k             = PosPar n (fmap monotype t) Nothing (kwdToPos k)
joinPar PosNIL k                    = kwdToPos k

kwdToPos (KwdPar n t e k)           = PosPar n t e (kwdToPos k)
kwdToPos (KwdSTAR n t)              = PosPar n (fmap monotype t) Nothing PosNIL
kwdToPos KwdNIL                     = PosNIL

defaults (PosPar n t (Just e) p)    = s : defaults p
  where s                           = sIf1 test [set] []
        test                        = eCall (eQVar primIsNone) [eVar n]
        set                         = sAssign [pVar n Nothing] e
defaults (PosPar n t Nothing p)     = defaults p
defaults _                          = []

noDefaults (PosPar n t _ p)         = PosPar n t Nothing (noDefaults p)
noDefaults p                        = p

instance Norm PosArg where
    norm env (PosArg e p)           = PosArg <$> norm env e <*> norm env p
    norm env (PosStar e)            = PosStar <$> norm env e
    norm env PosNil                 = return PosNil
    
instance Norm KwdArg where
    norm env (KwdArg n e k)         = KwdArg n <$> norm env e <*> norm env k
    norm env (KwdStar e)            = KwdStar <$> norm env e
    norm env KwdNil                 = return KwdNil
    
instance Norm PosPat where
    norm env (PosPat p ps)          = PosPat <$> norm env p <*> norm env ps
    norm env (PosPatStar p)         = PosPatStar <$> norm env p
    norm env PosPatNil              = return PosPatNil
    
instance Norm KwdPat where
    norm env (KwdPat n p ps)        = KwdPat n <$> norm env p <*> norm env ps
    norm env (KwdPatStar p)         = KwdPatStar <$> norm env p
    norm env KwdPatNil              = return KwdPatNil
    
instance Norm OpArg where
    norm env (OpArg op e)           = OpArg <$> norm env op <*> norm env e

instance Norm Comp where
    norm env (CompFor l p e c)      = CompFor l <$> norm env p <*> norm env e <*> norm env c
    norm env (CompIf l e c)         = CompIf l <$> norm env e <*> norm env c
    norm env NoComp                 = return NoComp

instance Norm WithItem where
    norm env (WithItem e p)         = WithItem <$> norm env e <*> norm env p

instance Norm Elem where
    norm env (Elem e)               = Elem <$> norm env e
    norm env (Star e)               = Star <$> norm env e

instance Norm Assoc where
    norm env (Assoc e1 e2)          = Assoc <$> norm env e1 <*> norm env e2
    norm env (StarStar e)           = StarStar <$> norm env e
  
instance Norm Slice where
    norm env (Sliz l e1 e2 e3)      = Sliz l <$> norm env e1 <*> norm env e2 <*> norm env e3
{-
instance Norm TSchema where
    norm env (TSchema l q t d)      = TSchema l <$> norm env q <*> norm env t <*> return d

instance Norm TVar where
    norm env (TV n)                 = TV <$> norm env n

instance Norm TCon where
    norm env (TC n ts)              = TC n <$> norm env ts

instance Norm TBind where
    norm env (TBind v cs)           = TBind <$> norm env v <*> norm env cs

instance Norm Type where
    norm env (TVar l v)             = TVar l <$> norm env v
    norm env (TFun l es p k t)      = TFun l <$> norm env es <*> norm env p <*> norm env k <*> norm env t
    norm env (TTuple l p)           = TTuple l <$> norm env p
    norm env (TRecord l k)          = TRecord l <$> norm env k
    norm env (TOpt l t)             = TOpt l <$> norm env t
    norm env (TUnion l as)          = TUnion l <$> return as
    norm env (TCon  l c)            = TCon l <$> norm env c
    norm env (TAt  l c)             = TAt l <$> norm env c
    norm env (TNone l)              = return $ TNone l
    norm env (TWild l)              = return $ TWild l
    norm env (TNil l)               = return $ TNil l
    norm env (TRow l n t r)         = TRow l n <$> norm env t <*> norm env r
-}