module Compiler

import LangDefs.ToyAST
import LangDefs.WasmAST
import Backend.Optimizer

import Data.Vect
import Data.Fin

%default covering

map_enum : Int -> (Int -> a -> b) -> List a -> List b
map_enum acc f [] = []
map_enum acc f (x :: xs) = f acc x :: map_enum (acc + 1) f xs

valueToWasmValue : Value -> WasmValue
valueToWasmValue (ValueInt x) = WasmValueI64 x
valueToWasmValue (ValueFloat x) = WasmValueF64 x
valueToWasmValue (ValueBool True) = WasmValueI32 1
valueToWasmValue (ValueBool False) = WasmValueI32 0

compile_type : Type' -> WasmType
compile_type TypeInt = WasmTypeI64
compile_type TypeDouble = WasmTypeF64
compile_type TypeBool = WasmTypeI32


cast_instrs : (t : Type') -> (to_t : Type') -> List WasmInstr
cast_instrs TypeInt TypeDouble = [WasmInstrF64ConvertI64_s]
cast_instrs TypeInt TypeBool = [WasmInstrI64Eqz, WasmInstrI32Eqz]
cast_instrs TypeDouble TypeInt = [WasmInstrI64TruncF64_s]
cast_instrs TypeDouble TypeBool = [WasmInstrConst (WasmValueF64 0), WasmInstrF64Neq]
cast_instrs TypeBool TypeInt = [WasmInstrI64ExtendI32_s]
cast_instrs TypeBool TypeDouble = [WasmInstrF64ConvertI32_s]
cast_instrs TypeInt TypeInt = []
cast_instrs TypeDouble TypeDouble = []
cast_instrs TypeBool TypeBool = []


lift_local_decls : Expr d fns -> List Type'
lift_local_decls (ExprValue x) = []
lift_local_decls (ExprVar var) = []
lift_local_decls (ExprDeclareVar t initExpr after) = t :: (lift_local_decls initExpr ++ lift_local_decls after)
lift_local_decls (ExprUpdateVar var newExpr after) = lift_local_decls newExpr ++ lift_local_decls after
lift_local_decls (ExprCall f args) = foldl (\decls,arg => lift_local_decls arg ++ decls) [] args
lift_local_decls (ExprIf cond t true false) = lift_local_decls cond ++ lift_local_decls true ++ lift_local_decls false
lift_local_decls (ExprWhile cond body after) = lift_local_decls cond ++ lift_local_decls body ++ lift_local_decls after
lift_local_decls (ExprIAdd x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFAdd x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprISub x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFSub x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprIMul x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFMul x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprIDiv x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFDiv x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprIMod x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprIGT x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFGT x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprIGTE x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFGTE x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprIEQ x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFEQ x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprILTE x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFLTE x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprILT x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprFLT x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprAnd x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprOr x y) = lift_local_decls x ++ lift_local_decls y
lift_local_decls (ExprNot x) = lift_local_decls x
lift_local_decls (ExprINeg x) = lift_local_decls x
lift_local_decls (ExprFNeg x) = lift_local_decls x
lift_local_decls (ExprCast x t to_t) = lift_local_decls x

is_small_int_expr : Expr d fns -> Bool
is_small_int_expr (ExprValue (ValueInt x)) = is_small_int x
is_small_int_expr e = False

compile_expr : Int -> Expr d fns -> (List WasmInstr, Int)
compile_expr numBound (ExprValue x) = ([WasmInstrConst (valueToWasmValue x)], numBound)
compile_expr numBound (ExprVar var) = ([WasmInstrLocalGet (numBound - (toIntNat $ finToNat var) - 1)], numBound)
compile_expr numBound (ExprDeclareVar t initExpr after) =
    let (i_instrs, numBound') = compile_expr numBound initExpr in
    let (a_instrs, numBound'') = compile_expr (1 + numBound') after in
    (i_instrs ++ (WasmInstrLocalSet numBound' :: a_instrs), numBound'')
compile_expr numBound (ExprUpdateVar var newExpr after) =
    let (n_instrs, numBound') = compile_expr numBound newExpr in
    let (a_instrs, numBound'') = compile_expr numBound' after in
    (n_instrs ++ (WasmInstrLocalSet (numBound' - (toIntNat $ finToNat var) - 1) :: a_instrs), numBound'')
compile_expr numBound (ExprCall f args) =
    let (args_ins, numBound') = foldl (\(instrs,b),arg =>
                                        let (ins, b') = compile_expr b arg in
                                        (ins ++ instrs, b')
                                ) (the (List WasmInstr) [], numBound) args in
    (args_ins ++ [WasmInstrCall (toIntNat $ finToNat f)], numBound')
compile_expr numBound (ExprIf cond t true false) =
    let (cond_ins, numBound') = compile_expr numBound cond in
    let (true_ins, numBound'') = compile_expr numBound' true in
    let (false_ins, numBound''') = compile_expr numBound'' false in
    (cond_ins ++ [WasmInstrIf (Just $ compile_type t) true_ins false_ins], numBound''')
compile_expr numBound (ExprWhile cond body after) =
    let (cond_ins, numBound') = compile_expr numBound cond in
    let (body_ins, numBound'') = compile_expr numBound' body in
    let (after_ins, numBound''') = compile_expr numBound'' after in
    (WasmInstrBlock Nothing (
        cond_ins ++ [WasmInstrI32Eqz, WasmInstrBrIf 0] ++
        [WasmInstrLoop Nothing (
            body_ins ++ [WasmInstrDrop] ++ cond_ins ++ [WasmInstrBrIf 0]
        )]
    ) :: after_ins, numBound''')
compile_expr numBound (ExprIAdd x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Add], numBound'')
compile_expr numBound (ExprFAdd x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Add], numBound'')
compile_expr numBound (ExprISub x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Sub], numBound'')
compile_expr numBound (ExprFSub x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Sub], numBound'')
compile_expr numBound (ExprINeg x) =
    let (xins, numBound') = compile_expr numBound x in
    ([WasmInstrConst (WasmValueI64 0)] ++ xins ++ [WasmInstrI64Sub], numBound')
compile_expr numBound (ExprFNeg x) =
    let (xins, numBound') = compile_expr numBound x in
    (xins ++ [WasmInstrF64Neg], numBound')
compile_expr numBound (ExprIMul x_tmp y_tmp) =
    if is_small_int_expr x_tmp
        then let (xins, numBound') = compile_expr numBound x_tmp in
             let (yins, numBound'') = compile_expr numBound' y_tmp in
             (xins ++ yins ++ [WasmInstrI64Mul], numBound'')
        else let (xins, numBound') = compile_expr numBound x_tmp in
             let (yins, numBound'') = compile_expr numBound' y_tmp in
             (yins ++ xins ++ [WasmInstrI64Mul], numBound'')

    -- let (xins, numBound') = compile_expr numBound x in
    -- let (yins, numBound'') = compile_expr numBound' y in
    -- (xins ++ yins ++ [WasmInstrI64Mul], numBound'')
compile_expr numBound (ExprFMul x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Mul], numBound'')
compile_expr numBound (ExprIDiv x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Div_s], numBound'')
    -- if yins == [WasmInstrConst (WasmValueI64 2)]
    --     then (xins ++ [WasmInstrConst (WasmValueI64 1), WasmInstrI64Shr_u], numBound'')
    --     else (xins ++ yins ++ [WasmInstrI64Div_s], numBound'')
compile_expr numBound (ExprFDiv x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Div], numBound'')
compile_expr numBound (ExprIMod x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Rem_s], numBound'')
    -- if yins == [WasmInstrConst (WasmValueI64 2)]
    --     then (xins ++ [WasmInstrConst (WasmValueI64 1), WasmInstrI64And], numBound'')
    --     else (xins ++ yins ++ [WasmInstrI64Rem_s], numBound'')
compile_expr numBound (ExprIGT x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Gt_s], numBound'')
compile_expr numBound (ExprFGT x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Gt], numBound'')
compile_expr numBound (ExprIGTE x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Ge_s], numBound'')
compile_expr numBound (ExprFGTE x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Ge], numBound'')
compile_expr numBound (ExprIEQ x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Eq], numBound'')
compile_expr numBound (ExprFEQ x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Eq], numBound'')
compile_expr numBound (ExprILTE x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Le_s], numBound'')
compile_expr numBound (ExprFLTE x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Le], numBound'')
compile_expr numBound (ExprILT x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI64Lt_s], numBound'')
compile_expr numBound (ExprFLT x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrF64Lt], numBound'')
compile_expr numBound (ExprAnd x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI32And], numBound'')
compile_expr numBound (ExprOr x y) =
    let (xins, numBound') = compile_expr numBound x in
    let (yins, numBound'') = compile_expr numBound' y in
    (xins ++ yins ++ [WasmInstrI32Or], numBound'')
compile_expr numBound (ExprNot x) =
    let (xins, numBound') = compile_expr numBound x in
    (xins ++ [WasmInstrI32Eqz], numBound')
compile_expr numBound (ExprCast x t to_t) =
    let (xins, numBound') = compile_expr numBound x in
    (xins ++ cast_instrs t to_t, numBound')

compile_function : Int -> FuncDef fns -> WasmFunction
compile_function id (MkFuncDef returnType argumentTypes body) =
    MkWasmFunction
        (map compile_type argumentTypes)
        (compile_type returnType)
        (map compile_type (lift_local_decls body))
        (fst (compile_expr (toIntNat (length argumentTypes)) body))
        id

export
compile_module : Module nmfns -> WasmModule
compile_module (MkModule functions) =
    let main_f = head functions in
    let wasmFunctions = map_enum 0 compile_function (toList functions) in
    MkWasmModule wasmFunctions 0 (compile_type $ returnType main_f)


-- export
-- compile_module : Bool -> Module nmfns -> WasmModule
-- compile_module optim m = optimize_module optim (compile_module' m)
