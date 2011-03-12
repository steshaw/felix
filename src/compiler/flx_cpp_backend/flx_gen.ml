open List

open Flx_bbdcl
open Flx_beta
open Flx_bexe
open Flx_bexpr
open Flx_bparameter
open Flx_btype
open Flx_cexpr
open Flx_ctorgen
open Flx_ctypes
open Flx_display
open Flx_egen
open Flx_exceptions
open Flx_label
open Flx_list
open Flx_maps
open Flx_mtypes2
open Flx_name
open Flx_ogen
open Flx_pgen
open Flx_print
open Flx_types
open Flx_typing
open Flx_unify
open Flx_util

module CS = Flx_code_spec

let find_variable_indices syms bsym_table index =
  let children = Flx_bsym_table.find_children bsym_table index in
  Flx_types.BidSet.fold begin fun bid bids ->
    try match Flx_bsym_table.find_bbdcl bsym_table bid with
      | BBDCL_val (_,_,(`Val | `Var | `Ref)) -> bid :: bids
      | _ -> bids
    with Not_found -> bids
  end children []

let get_variable_typename syms bsym_table i ts =
  let bsym =
    try Flx_bsym_table.find bsym_table i with Not_found ->
      failwith ("[get_variable_typename] can't find index " ^ string_of_bid i)
  in
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table (Flx_bsym.sr bsym) (tsubst vs ts t) in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_val (vs,t,_) ->
      if length ts <> length vs then begin
        failwith
        (
          "[get_variable_typename} wrong number of args, expected vs = " ^
          si (length vs) ^
          ", got ts=" ^
          si (length ts)
        )
      end;
      let t = rt vs t in
      cpp_typename syms bsym_table t

  | _ ->
      failwith "[get_variable_typename] Expected variable"

let format_vars syms bsym_table vars ts =
  catmap  ""
  (fun idx ->
    let instname =
      try Some (cpp_instance_name syms bsym_table idx ts)
      with _ -> None
    in
      match instname with
      | Some instname ->
        let typename = get_variable_typename syms bsym_table idx ts in
        "  " ^ typename ^ " " ^ instname ^ ";\n"
      | None -> "" (* ignore unused variables *)
  )
  vars

let find_members syms bsym_table index ts =
  let variables = find_variable_indices syms bsym_table index in
  match format_vars syms bsym_table variables ts with
  | "" -> ""
  | x ->
  (*
  "  //variables\n" ^
  *)
  x

let typeof_bparams bps =
  btyp_tuple (Flx_bparameter.get_btypes bps)

let get_type bsym_table index =
  let bsym =
    try Flx_bsym_table.find bsym_table index
    with _ -> failwith ("[get_type] Can't find index " ^ si index)
  in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(ps,_),ret,_) ->
      btyp_function (typeof_bparams ps,ret)
  | _ -> failwith "Only function and procedure types handles by get_type"


let is_gc_pointer syms bsym_table sr t =
  (*
  print_endline ("[is_gc_ptr] Checking type " ^ sbt bsym_table t);
  *)
  match t with
  | BTYP_function _ -> true
  | BTYP_pointer _ -> true
  | BTYP_inst (i,_) ->
    let bsym =
      try Flx_bsym_table.find bsym_table i with Not_found ->
        clierr sr ("[is_gc_pointer] Can't find nominal type " ^
          string_of_bid i);
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_external_type (_,tqs,_,_) -> mem `GC_pointer tqs
    | _ -> false
    end
  | _ -> false

let gen_C_function syms bsym_table props index id sr vs bps ret' ts instance_no =
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let requires_ptf = mem `Requires_ptf props in
  (*
  print_endline ("C Function " ^ id ^ " " ^ if requires_ptf then "requires ptf" else "does NOT require ptf");
  *)
  let ps = List.map (fun {pid=id; pindex=ix; ptyp=t} -> id,t) bps in
  let params = Flx_bparameter.get_bids bps in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating C function inst " ^
    string_of_bid instance_no ^ "=" ^
    id ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  let argtype = typeof_bparams bps in
  if length ts <> length vs then
  failwith
  (
    "[gen_function} wrong number of args, expected vs = " ^
    si (length vs) ^
    ", got ts=" ^
    si (length ts)
  );
  let argtype = rt vs argtype in
  let rt' vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let ret = rt' vs ret' in
  if ret = btyp_tuple [] then "// elided (returns unit)\n" else

  let funtype = fold syms.counter (btyp_function (argtype, ret)) in

  (* let argtypename = cpp_typename syms bsym_table argtype in *)
  let display = get_display_list bsym_table index in
  assert (length display = 0);
  let name = cpp_instance_name syms bsym_table index ts in
  let rettypename = cpp_typename syms bsym_table ret in
  rettypename ^ " " ^
  (if mem `Cfun props then "" else "FLX_REGPARM ")^
  name ^ "(" ^
  (
    let s =
      match length params with
      | 0 -> ""
      | 1 ->
        let ix = hd params in
        if Hashtbl.mem syms.instances (ix, ts)
        && not (argtype = btyp_tuple [] or argtype = btyp_void ())
        then cpp_typename syms bsym_table argtype else ""
      | _ ->
        let counter = ref 0 in
        fold_left
        (fun s {pindex=i; ptyp=t} ->
          let t = rt vs t in
          if Hashtbl.mem syms.instances (i,ts) && not (t = btyp_tuple [])
          then s ^
            (if String.length s > 0 then ", " else " ") ^
            cpp_typename syms bsym_table t
          else s (* elide initialisation of elided variable *)
        )
        ""
        bps
    in
      (
        if (not (mem `Cfun props)) then
        (
          if String.length s > 0
          then (if requires_ptf then "FLX_FPAR_DECL " else "") ^s
          else (if requires_ptf then "FLX_FPAR_DECL_ONLY" else "")
        ) else s
      )
  ) ^
  ");\n"

let gen_class syms bsym_table props index id sr vs ts instance_no =
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let requires_ptf = mem `Requires_ptf props in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating class inst " ^
    si instance_no ^ "=" ^
    id ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  if length ts <> length vs then
  failwith
  (
    "[gen_function} wrong number of args, expected vs = " ^
    si (length vs) ^
    ", got ts=" ^
    si (length ts)
  );
  let display = get_display_list bsym_table index in
  let frame_dcls =
    if requires_ptf then
    "  FLX_FMEM_DECL\n"
    else ""
  in
  let display_string = match display with
    | [] -> ""
    | display ->
      cat ""
      (
        List.map
        (fun (i, vslen) ->
         try
         let instname = cpp_instance_name syms bsym_table i (list_prefix ts vslen) in
         "  " ^ instname ^ " *ptr" ^ instname ^ ";\n"
         with _ -> failwith "Can't cal display name"
         )
        display
      )
  and ctor_dcl name =
    "  " ^name^
    (if length display = 0
    then (if requires_ptf then "(FLX_FPAR_DECL_ONLY);\n" else "();\n")
    else (
    "  (" ^
    (if requires_ptf then
    "FLX_FPAR_DECL "
    else ""
    )
    ^
    cat ","
      (
        List.map
        (
          fun (i,vslen) ->
          let instname = cpp_instance_name syms bsym_table i (list_prefix ts vslen) in
          instname ^ "*"
        )
        display
      )^
      ");\n"
    ))
  (*
  and dtor_dcl name =
    "  ~" ^ name ^"();\n"
  *)
  in
  let members = find_members syms bsym_table index ts in
  let name = cpp_instance_name syms bsym_table index ts in
    let ctor = ctor_dcl name in
  "struct " ^ name ^
  " {\n" ^
  (*
  "  //os frames\n" ^
  *)
  frame_dcls ^
  (*
  "  //display\n" ^
  *)
  (
    if String.length display_string = 0 then "" else
    display_string ^ "\n"
  )
  ^
  members ^
  (*
  "  //constructor\n" ^
  *)
  ctor ^
  (
    if mem `Heap_closure props then
    (*
    "  //clone\n" ^
    *)
    "  " ^name^"* clone();\n"
    else ""
  )
  ^
  (*
  "  //call\n" ^
  *)
  "};\n"


(* vs here is the (name,index) list of type variables *)
let gen_function syms bsym_table props index id sr vs bps ret' ts instance_no =
  let stackable = mem `Stack_closure props in
  let heapable = mem `Heap_closure props in
  (*
  let strb x y = (if x then " is " else " is not " ) ^ y in
  print_endline ("The function " ^ id ^ strb stackable "stackable");
  print_endline ("The function " ^ id ^ strb heapable "heapable");
  *)
  (*
  let heapable = not stackable or heapable in
  *)
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let requires_ptf = mem `Requires_ptf props in
  let yields = mem `Yields props in
  (*
  print_endline ("The function " ^ id ^ (if requires_ptf then " REQUIRES PTF" else "DOES NOT REQUIRE PTF"));
  *)
  let ps = List.map (fun {pid=id; pindex=ix; ptyp=t} -> id,t) bps in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating function inst " ^
    string_of_bid instance_no ^ "=" ^
    id ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  let argtype = typeof_bparams bps in
  if length ts <> length vs then
  failwith
  (
    "[gen_function} wrong number of args, expected vs = " ^
    si (length vs) ^
    ", got ts=" ^
    si (length ts)
  );
  let argtype = rt vs argtype in
  let rt' vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let ret = rt' vs ret' in
  if ret = btyp_tuple [] then "// elided (returns unit)\n" else

  let funtype = fold syms.counter (btyp_function (argtype, ret)) in

  let argtypename = cpp_typename syms bsym_table argtype in
  let funtypename =
    if mem `Heap_closure props then
      try Some (cpp_type_classname syms bsym_table funtype)
      with _ -> None
    else None
  in
  let display = get_display_list bsym_table index in
  let frame_dcls =
    if requires_ptf then
    "  FLX_FMEM_DECL\n"
    else ""
  in
  let pc_dcls =
    if yields then
    "  FLX_PC_DECL\n"
    else ""
  in
  let display_string = match display with
    | [] -> ""
    | display ->
      cat ""
      (
        List.map
        (fun (i, vslen) ->
         try
         let instname = cpp_instance_name syms bsym_table i (list_prefix ts vslen) in
         "  " ^ instname ^ " *ptr" ^ instname ^ ";\n"
         with _ -> failwith "Can't cal display name"
         )
        display
      )
  and ctor_dcl name =
    "  " ^name^
    (if length display = 0
    then (if requires_ptf then "(FLX_FPAR_DECL_ONLY);\n" else "();\n")
    else (
    "  (" ^
    (if requires_ptf then
    "FLX_FPAR_DECL "
    else ""
    )
    ^
    cat ", "
      (
        List.map
        (
          fun (i,vslen) ->
          let instname = cpp_instance_name syms bsym_table i (list_prefix ts vslen) in
          instname ^ "*"
        )
        display
      )^
      ");\n"
    ))
  (*
  and dtor_dcl name =
    "  ~" ^ name ^"();\n"
  *)
  in
  let members = find_members syms bsym_table index ts in
  match ret with
  | BTYP_void ->
    let name = cpp_instance_name syms bsym_table index ts in
    let ctor = ctor_dcl name in
    "struct " ^ name ^
    (match funtypename with
    | Some x -> ": "^x
    | None -> if not heapable then "" else ": ::flx::rtl::con_t"
    )
    ^
    " {\n" ^
    (*
    "  //os frames\n" ^
    *)
    frame_dcls ^
    (*
    "  //display\n" ^
    *)
    display_string ^ "\n" ^
    members ^
    (*
    "  //constructor\n" ^
    *)
    ctor ^
    (
      if mem `Heap_closure props then
      (*
      "  //clone\n" ^
      *)
      "  " ^name^"* clone();\n"
      else ""
    )
    ^
    (*
    "  //call\n" ^
    *)
    (if argtype = btyp_tuple [] or argtype = btyp_void ()
    then
      (if stackable then "  void stack_call();\n" else "") ^
      (if heapable then "  ::flx::rtl::con_t *call(::flx::rtl::con_t*);\n" else "")
    else
      (if stackable then "  void stack_call("^argtypename^" const &);\n" else "") ^
      (if heapable then "  ::flx::rtl::con_t *call(::flx::rtl::con_t*,"^argtypename^" const &);\n" else "")
    ) ^
    (*
    "  //resume\n" ^
    *)
    (if heapable then "  ::flx::rtl::con_t *resume();\n" else "")
    ^
    "};\n"

  | _ ->
    let name = cpp_instance_name syms bsym_table index ts in
    let rettypename = cpp_typename syms bsym_table ret in
    let ctor = ctor_dcl name in
    "struct " ^ name ^
    (match funtypename with
    | Some x -> ": "^x
    | None -> ""
    )
    ^
    " {\n" ^
    (*
    "  //os frames\n" ^
    *)
    frame_dcls ^
    pc_dcls ^
    (*
    "  //display\n" ^
    *)
    display_string ^ "\n" ^
    members ^
    (*
    "  //constructor\n" ^
    *)
    ctor ^
    (
      if mem `Heap_closure props then
      (*
      "  //clone\n" ^
      *)
      "  " ^name^"* clone();\n"
      else ""
    )
    ^
    (*
    "  //apply\n" ^
    *)
    "  "^rettypename^
    " apply(" ^
    (if argtype = btyp_tuple [] or argtype = btyp_void () then ""
    else argtypename^" const &")^
    ");\n"  ^
    "};\n"


let gen_function_names syms bsym_table =
  let xxsym_table = ref [] in
  Hashtbl.iter
  (fun x i ->
    (* if proper_descendant parent then  *)
    xxsym_table := (i,x) :: !xxsym_table
  )
  syms.instances
  ;

  let s = Buffer.create 2000 in
  List.iter
  (fun (i,(index,ts)) ->
    let tss =
      if length ts = 0 then "" else
      "[" ^ catmap "," (sbt bsym_table) ts^ "]"
    in
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[gen_functions] can't find index " ^ string_of_bid index)
    in
    match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint), _, _) ->
      if mem `Cfun props || mem `Pure props && not (mem `Heap_closure props) then begin
      end else begin
        let name = cpp_instance_name syms bsym_table index ts in
        bcat s ("struct " ^ name ^ ";\n");
      end

    | _ -> () (* bcat s ("//SKIPPING " ^ id ^ "\n") *)
  )
  (sort compare !xxsym_table)
  ;
  Buffer.contents s

(* This code generates the class declarations *)
let gen_functions syms bsym_table =
  let xxsym_table = ref [] in
  Hashtbl.iter
  (fun x i ->
    (* if proper_descendant parent then  *)
    xxsym_table := (i,x) :: !xxsym_table
  )
  syms.instances
  ;

  let s = Buffer.create 2000 in
  List.iter
  (fun ((i:bid_t),(index,ts)) ->
    let tss =
      if length ts = 0 then "" else
      "[" ^ catmap "," (sbt bsym_table) ts^ "]"
    in
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[gen_functions] can't find index " ^ string_of_bid index)
    in
    match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
      let is_proc = Flx_btype.is_void ret in
      let name = if is_proc then "FUNCTION" else "PROCEDURE" in
      bcat s ("\n//------------------------------\n");
      if mem `Cfun props || mem `Pure props && not (mem `Heap_closure props) then begin
        bcat s ("//PURE C " ^ name ^ " <" ^ string_of_bid index ^ ">: " ^
          qualified_name_of_bindex bsym_table index ^ tss ^
          "\n");
        bcat s
        (gen_C_function
          syms
          bsym_table
          props
          index
          (Flx_bsym.id bsym)
          (Flx_bsym.sr bsym)
          vs
          ps
          ret
          ts
          i)
      end else begin
        bcat s ("//" ^ name ^ " <" ^ string_of_bid index ^ ">: " ^
          qualified_name_of_bindex bsym_table index ^ tss ^
          "\n");
        bcat s
        (gen_function
          syms
          bsym_table
          props
          index
          (Flx_bsym.id bsym)
          (Flx_bsym.sr bsym)
          vs
          ps
          ret
          ts
          i)
      end

    | BBDCL_external_fun (_,vs,ps_cf,ret',_,_,`Callback (ps_c,_)) ->
      let instance_no = i in
      bcat s ("\n//------------------------------\n");
      if ret' = btyp_void () then begin
        bcat s ("//CALLBACK C PROC <" ^ string_of_bid index ^ ">: " ^
          qualified_name_of_bindex bsym_table index ^ tss ^
          "\n");
      end else begin
        bcat s ("//CALLBACK C FUNCTION <" ^ string_of_bid index ^ ">: " ^
          qualified_name_of_bindex bsym_table index ^ tss ^
          "\n");
      end
      ;
      let rt vs t =
        beta_reduce syms.Flx_mtypes2.counter bsym_table (Flx_bsym.sr bsym) (tsubst vs ts t)
      in
      if syms.compiler_options.print_flag then
      print_endline
      (
        "//Generating C callback function inst " ^
        string_of_bid instance_no ^ "=" ^
        Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
        (
          if length ts = 0 then ""
          else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
        )
      );
      if length ts <> length vs then
      failwith
      (
        "[gen_function} wrong number of args, expected vs = " ^
        si (length vs) ^
        ", got ts=" ^
        si (length ts)
      );
      let ret = rt vs ret' in
      (*
      let name = cpp_instance_name syms bsym_table index ts in
      *)
      let name = Flx_bsym.id bsym in (* callbacks can't be polymorphic .. for now anyhow *)
      let rettypename = cpp_typename syms bsym_table ret in
      let sss =
        "extern \"C\" " ^
        rettypename ^ " " ^
        name ^ "(" ^
        (
          match length ps_c with
          | 0 -> ""
          | 1 -> cpp_typename syms bsym_table (hd ps_c)
          | _ ->
            fold_left
            (fun s t ->
              let t = rt vs t in
              s ^
              (if String.length s > 0 then ", " else "") ^
              cpp_typename syms bsym_table t
            )
            ""
            ps_c
        ) ^
        ");\n"
      in bcat s sss

    | _ -> () (* bcat s ("//SKIPPING " ^ id ^ "\n") *)
  )
  (sort compare !xxsym_table)
  ;
  Buffer.contents s

(*
let gen_dtor syms bsym_table name display ts =
  name^"::~"^name^"(){}\n"
*)
let is_closure_var bsym_table index =
  let var_type bsym_table index =
    let id,_,entry =
      try Hashtbl.find bsym_table index
      with Not_found -> failwith ("[var_type] ]Can't get index " ^ si index)
    in match entry with
    | BBDCL_val (_,t,(`Val | `Var | `Ref)) -> t
    | _ -> failwith ("[var_type] expected "^id^" to be variable")
  in
  match var_type bsym_table index with
  | BTYP_function _ -> true
  | _ -> false

(* NOTE: it isn't possible to pass an explicit tuple as a single
argument to a primitive, nor a single value of tuple/array type.
In the latter case a cast/abstraction can defeat this, for the
former you'll need to make a dummy variable.
*)



type kind_t = Function | Procedure

let gen_exe filename
  syms
  bsym_table
  (label_map, label_usage_map)
  counter
  this
  vs
  ts
  instance_no
  needs_switch
  stackable
  exe
=
  let sr = Flx_bexe.get_srcref exe in
  if length ts <> length vs then
  failwith
  (
    "[gen_exe} wrong number of args, expected vs = " ^
    si (length vs) ^
    ", got ts=" ^
    si (length ts)
  );
  let src_str = string_of_bexe bsym_table 0 exe in
  let with_comments = syms.compiler_options.with_comments in
  (*
  print_endline ("generating exe " ^ string_of_bexe bsym_table 0 exe);
  print_endline ("vs = " ^ catmap "," (fun (s,i) -> s ^ "->" ^ si i) vs);
  print_endline ("ts = " ^ catmap ","  (sbt bsym_table) ts);
  *)
  let tsub t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let ge = gen_expr syms bsym_table this vs ts in
  let ge' = gen_expr' syms bsym_table this vs ts in
  let tn t = cpp_typename syms bsym_table (tsub t) in
  let bsym =
    try Flx_bsym_table.find bsym_table this with _ ->
      failwith ("[gen_exe] Can't find this " ^ string_of_bid this)
  in
  let our_display = get_display_list bsym_table this in
  let kind = match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (_,_,_,BTYP_void,_) -> Procedure
    | BBDCL_fun (_,_,_,_,_) -> Function
    | _ -> failwith "Expected executable code to be in function or procedure"
  in let our_level = length our_display in

  let rec handle_closure sr is_jump index ts subs' a stack_call =
    let index',ts' = index,ts in
    let index, ts = Flx_typeclass.fixup_typeclass_instance syms bsym_table index ts in
    if index <> index' then
      clierr sr ("Virtual call of " ^ string_of_bid index' ^ " dispatches to " ^
        string_of_bid index')
    ;
    let subs =
      catmap ""
      (fun ((_,t) as e,s) ->
        let t = cpp_ltypename syms bsym_table t in
        let e = ge sr e in
        "      " ^ t ^ " " ^ s ^ " = " ^ e ^ ";\n"
      )
      subs'
    in
    let sub_start =
      if String.length subs = 0 then ""
      else "      {\n" ^ subs
    and sub_end =
      if String.length subs = 0 then ""
      else "      }\n"
    in
    let bsym =
      try Flx_bsym_table.find bsym_table index with _ ->
        failwith ("[gen_exe(call)] Can't find index " ^ string_of_bid index)
    in
    begin
    match Flx_bsym.bbdcl bsym with
    | BBDCL_external_fun (_,vs,_,BTYP_void,_,_,`Code code) ->
      assert (not is_jump);

      if length vs <> length ts then
      clierr sr "[gen_prim_call] Wrong number of type arguments"
      ;

      let ws s =
        let s = sc "expr" s in
        (if with_comments then "      // " ^ src_str ^ "\n" else "") ^
        sub_start ^
        "      " ^ s ^ "\n" ^
        sub_end
      in
      begin match code with
      | CS.Identity -> syserr sr "Identity proc is nonsense"
      | CS.Virtual ->
          clierr2 sr (Flx_bsym.sr bsym) ("Instantiate virtual procedure(1) " ^ Flx_bsym.id bsym) ;
      | CS.Str s -> ws (ce_expr "expr" s)
      | CS.Str_template s ->
        let ss = gen_prim_call syms bsym_table tsub ge' s ts a (Flx_btype.btyp_none()) sr (Flx_bsym.sr bsym) "atom"  in
        ws ss
      end

    | BBDCL_external_fun (_,vs,ps_cf,ret,_,_,`Callback _) ->
      assert (not is_jump);
      assert (ret = btyp_void ());

      if length vs <> length ts then
      clierr sr "[gen_prim_call] Wrong number of type arguments"
      ;
      let s = Flx_bsym.id bsym ^ "($a);" in
      let s =
        gen_prim_call syms bsym_table tsub ge' s ts a (Flx_btype.btyp_none()) sr (Flx_bsym.sr bsym) "atom"
      in
      let s = sc "expr" s in
      (if with_comments then "      // " ^ src_str ^ "\n" else "") ^
      sub_start ^
      "      " ^ s ^ "\n" ^
      sub_end


    | BBDCL_fun (props,vs,ps,BTYP_void,bexes) ->
      if bexes = []
      then
      "      //call to empty procedure " ^ Flx_bsym.id bsym ^ " elided\n"
      else begin
        let n = fresh_bid counter in
        let the_display =
          let d' =
            List.map begin fun (i,vslen) ->
              "ptr" ^ cpp_instance_name syms bsym_table i (list_prefix ts vslen)
            end (get_display_list bsym_table index)
          in
            if length d' > our_level
            then "this" :: tl d'
            else d'
        in
        (* if we're calling from inside a function,
           we pass a 0 continuation as the caller 'return address'
           otherwise pass 'this' as the caller 'return address'
           EXCEPT that stack calls don't pass a return address at all
        *)
        let this = match kind with
          | Function ->
            if is_jump
            then
              clierr sr "can't jump inside function"
            else if stack_call then ""
            else "0"

          | Procedure ->
            if stack_call then "" else
            if is_jump then "tmp"
            else "this"
        in

        let args = match a with
          | _,BTYP_tuple [] -> this
          | _ ->
            (
              let a = ge sr a in
              if this = "" then a else this ^ ", " ^ a
            )
        in
        let name = cpp_instance_name syms bsym_table index ts in
        if mem `Cfun props then begin
          (if with_comments
          then "      //call cproc " ^ src_str ^ "\n"
          else "") ^
          "      " ^ name ^"(" ^ args ^ ");\n"
        end
        else if stack_call then begin
          (*
          print_endline ("[handle_closure] GENERATING STACK CALL for " ^ id);
          *)
          (if with_comments
          then "      //run procedure " ^ src_str ^ "\n"
          else "") ^
          "      {\n" ^
          subs ^
          "      " ^ name ^ Flx_gen_display.strd the_display props^ "\n" ^
          "      .stack_call(" ^ args ^ ");\n" ^
          "      }\n"
        end
        else
        let ptrmap = name ^ "_ptr_map" in
        begin
          match kind with
          | Function ->
            (if with_comments
            then "      //run procedure " ^ src_str ^ "\n"
            else "") ^
            "      {\n" ^
            subs ^
            "      ::flx::rtl::con_t *_p =\n" ^
            "      (FLX_NEWP(" ^ name ^ ")" ^ Flx_gen_display.strd the_display props^ ")\n" ^
            "      ->call(" ^ args ^ ");\n" ^
            "      while(_p) _p=_p->resume();\n" ^
            "      }\n"

          | Procedure ->
            let call_string =
              "      return (FLX_NEWP(" ^ name ^ ")" ^ Flx_gen_display.strd the_display props ^ ")" ^
              "\n      ->call(" ^ args ^ ");\n"
            in
            if is_jump
            then
              (if with_comments then
              "      //jump to procedure " ^ src_str ^ "\n"
              else "") ^
              "      {\n" ^
              subs ^
              "      ::flx::rtl::con_t *tmp = _caller;\n" ^
              "      _caller = 0;\n" ^
              call_string ^
              "      }\n"
            else
            (
              needs_switch := true;
              (if with_comments then
              "      //call procedure " ^ src_str ^ "\n"
              else ""
              )
              ^

              sub_start ^
              "      FLX_SET_PC(" ^ cid_of_bid n ^ ")\n" ^
              call_string ^
              sub_end ^
              "    FLX_CASE_LABEL(" ^ cid_of_bid n ^ ")\n"
            )
        end
      end

    | _ ->
      failwith
      (
        "[gen_exe] Expected '" ^ Flx_bsym.id bsym ^ "' to be procedure constant, got " ^
        string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index
      )
    end
  in
  let gen_nonlocal_goto pc frame s =
    (* WHAT THIS CODE DOES: we pop the call stack until
       we find the first ancestor containing the target label,
       set the pc there, and return its continuation to the
       driver; we know the address of this frame because
       it must be in this function's display.
    *)
    let target_instance =
      try Hashtbl.find syms.instances (frame, ts)
      with Not_found -> failwith "Woops, bugged code, wrong type arguments for instance?"
    in
    let frame_ptr = "ptr" ^ cpp_instance_name syms bsym_table frame ts in
    "      // non local goto " ^ cid_of_flxid s ^ "\n" ^
    "      {\n" ^
    "        ::flx::rtl::con_t *tmp1 = this;\n" ^
    "        while(tmp1 && " ^ frame_ptr ^ "!= tmp1)\n" ^
    "        {\n" ^
    "          ::flx::rtl::con_t *tmp2 = tmp1->_caller;\n" ^
    "          tmp1 -> _caller = 0;\n" ^
    "          tmp1 = tmp2;\n" ^
    "        }\n" ^
    "      }\n" ^
    "      " ^ frame_ptr ^ "->pc = FLX_FARTARGET(" ^ cid_of_bid pc ^ "," ^ cid_of_bid target_instance ^ "," ^ s ^ ");\n" ^
    "      return " ^ frame_ptr ^ ";\n"
  in
  let forget_template sr s = match s with
  | CS.Identity -> syserr sr "Identity proc is nonsense(2)!"
  | CS.Virtual -> clierr sr "Instantiate virtual procedure(2)!"
  | CS.Str s -> s
  | CS.Str_template s -> s
  in
  let rec gexe exe =
    (*
    print_endline (string_of_bexe bsym_table 0 exe);
    *)
    match exe with
    | BEXE_axiom_check _ -> assert false
    | BEXE_code (sr,s) -> forget_template sr s
    | BEXE_nonreturn_code (sr,s) -> forget_template sr s
    | BEXE_comment (_,s) -> "/*" ^ s ^ "*/\n"
    | BEXE_label (_,s) ->
      let local_labels =
        try Hashtbl.find label_map this with _ ->
          failwith ("[gen_exe] Can't find label map of " ^ string_of_bid this)
      in
      let label_index =
        try Hashtbl.find local_labels s
        with _ -> failwith ("[gen_exe] In " ^ Flx_bsym.id bsym ^ ": Can't find label " ^ cid_of_flxid s)
      in
      let label_kind = get_label_kind_from_index label_usage_map label_index in
      (match kind with
        | Procedure ->
          begin match label_kind with
          | `Far ->
            needs_switch := true;
            "    FLX_LABEL(" ^ cid_of_bid label_index ^ "," ^
              cid_of_bid instance_no ^ "," ^ cid_of_flxid s ^ ")\n"
          | `Near ->
            "    " ^ cid_of_flxid s ^ ":;\n"
          | `Unused -> ""
          end

        | Function ->
          begin match label_kind with
          | `Far -> failwith ("[gen_exe] In function " ^ Flx_bsym.id bsym ^ 
              ": Non-local going to label " ^s)
          | `Near ->
            "    " ^ cid_of_flxid s ^ ":;\n"
          | `Unused -> ""
          end
      )

    (* FIX THIS TO PUT SOURCE REFERENCE IN *)
    | BEXE_halt (sr,msg) ->
      let msg = Flx_print.string_of_string ("HALT: " ^ msg) in
      let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
      let s = Flx_print.string_of_string f ^"," ^
        si sl ^ "," ^ si sc ^ "," ^
        si el ^ "," ^ si ec
      in
       "      FLX_HALT(" ^ s ^ "," ^ msg ^ ");\n"

    | BEXE_trace (sr,v,msg) ->
      let msg = Flx_print.string_of_string ("TRACE: " ^ msg) in
      let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
      let s = Flx_print.string_of_string f ^"," ^
        si sl ^ "," ^ si sc ^ "," ^
        si el ^ "," ^ si ec
      in
       "      FLX_TRACE(" ^ v ^"," ^ s ^ "," ^ msg ^ ");\n"


    | BEXE_goto (sr,s) ->
      begin match find_label bsym_table label_map this s with
      | `Local _ -> "      goto " ^ cid_of_flxid s ^ ";\n"
      | `Nonlocal (pc,frame) -> gen_nonlocal_goto pc frame s
      | `Unreachable ->
        print_endline "LABELS ..";
        let labels = Hashtbl.find label_map this in
        Hashtbl.iter (fun lab lno ->
          print_endline ("Label " ^ lab ^ " -> " ^ string_of_bid lno);
        )
        labels
        ;
        clierr sr ("Unconditional Jump to unreachable label " ^ cid_of_flxid s)
      end

    | BEXE_ifgoto (sr,e,s) ->
      begin match find_label bsym_table label_map this s with
      | `Local _ ->
        "      if(" ^ ge sr e ^ ") goto " ^ cid_of_flxid s ^ ";\n"
      | `Nonlocal (pc,frame) ->
        let skip = "_" ^ cid_of_bid (fresh_bid syms.counter) in
        let not_e = ce_prefix "!" (ge' sr e) in
        let not_e = string_of_cexpr not_e in
        "      if("^not_e^") goto " ^ cid_of_flxid skip ^ ";\n"  ^
        gen_nonlocal_goto pc frame s ^
        "    " ^ cid_of_flxid skip ^ ":;\n"

      | `Unreachable ->
        clierr sr ("Conditional Jump to unreachable label " ^ s)
      end

    (* Hmmm .. stack calls ?? *)
    | BEXE_call_stack (sr,index,ts,a)  ->
      let bsym =
        try Flx_bsym_table.find bsym_table index with _ ->
          failwith ("[gen_expr(apply instance)] Can't find index " ^
            string_of_bid index)
      in
      let ge_arg ((x,t) as a) =
        let t = tsub t in
        match t with
        | BTYP_tuple [] -> ""
        | _ -> ge sr a
      in
      let nth_type ts i = match ts with
        | BTYP_tuple ts -> nth ts i
        | BTYP_array (t,BTYP_unitsum n) -> assert (i<n); t
        | _ -> assert false
      in
      begin match Flx_bsym.bbdcl bsym with
      | BBDCL_fun (props,vs,(ps,traint),BTYP_void,_) ->
        assert (mem `Stack_closure props);
        let a = match a with (a,t) -> a, tsub t in
        let ts = List.map tsub ts in
        (* C FUNCTION CALL *)
        if mem `Cfun props || mem `Pure props && not (mem `Heap_closure props) then
          let display = get_display_list bsym_table index in
          let name = cpp_instance_name syms bsym_table index ts in
          let s =
            assert (length display = 0);
            match ps with
            | [] -> ""
            | [{pindex=i; ptyp=t}] ->
              if Hashtbl.mem syms.instances (i,ts)
              && not (t = btyp_tuple [])
              then
                ge_arg a
              else ""

            | _ ->
              begin match a with
              | BEXPR_tuple xs,_ ->
                (*
                print_endline ("Arg to C function is tuple " ^ sbe a);
                *)
                fold_left
                (fun s (((x,t) as xt),{pindex=i}) ->
                  let x =
                    if Hashtbl.mem syms.instances (i,ts)
                    && not (t = btyp_tuple [])
                    then ge_arg xt
                    else ""
                  in
                  if String.length x = 0 then s else
                  s ^
                  (if String.length s > 0 then ", " else "") ^ (* append a comma if needed *)
                  x
                )
                ""
                (combine xs ps)

              | _,tt ->
                let tt = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts tt) in
                (* NASTY, EVALUATES EXPR MANY TIMES .. *)
                let n = ref 0 in
                fold_left
                (fun s (i,{pindex=j;ptyp=t}) ->
                  (*
                  print_endline ( "ps = " ^ catmap "," (fun (id,(p,t)) -> id) ps);
                  print_endline ("tt=" ^ sbt bsym_table tt);
                  *)
                  let t = nth_type tt i in
                  let a' = bexpr_get_n t (i,a) in
                  let x =
                    if Hashtbl.mem syms.instances (j,ts)
                    && not (t = btyp_tuple [])
                    then ge_arg a'
                    else ""
                  in
                  incr n;
                  if String.length x = 0 then s else
                  s ^ (if String.length s > 0 then ", " else "") ^ x
                )
                ""
                (combine (nlist (length ps)) ps)
              end
          in
          let s =
            if mem `Requires_ptf props then
              if String.length s > 0 then "FLX_FPAR_PASS " ^ s
              else "FLX_FPAR_PASS_ONLY"
            else s
          in
            "  " ^ name ^ "(" ^ s ^ ");\n"
        else
          let subs,x = Flx_unravel.unravel syms bsym_table a in
          let subs = List.map
            (fun ((e,t),s) -> (e,tsub t), cid_of_flxid s)
            subs
          in
          handle_closure sr false index ts subs x true
      | _ -> failwith "procedure expected"
      end


    | BEXE_call_prim (sr,index,ts,a)
    | BEXE_call_direct (sr,index,ts,a)
    | BEXE_call (sr,(BEXPR_closure (index,ts),_),a) ->
      let a = match a with (a,t) -> a, tsub t in
      let subs,x = Flx_unravel.unravel syms bsym_table a in
      let subs = List.map (fun ((e,t),s) -> (e,tsub t), cid_of_flxid s) subs in
      let ts = List.map tsub ts in
      handle_closure sr false index ts subs x false

    (* i1: variable
       i2, class_ts: class closure
       i3: constructor
       a: ctor argument
    *)
    | BEXE_jump (sr,((BEXPR_closure (index,ts),_)),a)
    | BEXE_jump_direct (sr,index,ts,a) ->
      let a = match a with (a,t) -> a, tsub t in
      let subs,x = Flx_unravel.unravel syms bsym_table a in
      let subs = List.map (fun ((e,t),s) -> (e,tsub t), cid_of_flxid s) subs in
      let ts = List.map tsub ts in
      handle_closure sr true index ts subs x false

    (* If p is a variable containing a closure,
       and p recursively invokes the same closure,
       then the program counter and other state
       of the closure would be lost, so we clone it
       instead .. the closure variables is never
       used (a waste if it isn't re-entered .. oh well)
     *)

    | BEXE_call (sr,p,a) ->
      let args =
        let this = match kind with
          | Procedure -> "this"
          | Function -> "0"
        in
        match a with
        | _,BTYP_tuple [] -> this
        | _ -> this ^ ", " ^ ge sr a
      in
      begin let _,t = p in match t with
      | BTYP_cfunction _ ->
        "    "^ge sr p ^ "("^ge sr a^");\n"
      | _ ->
      match kind with
      | Function ->
        (if with_comments then
        "      //run procedure " ^ src_str ^ "\n"
        else "") ^
        "      {\n" ^
        "        ::flx::rtl::con_t *_p = ("^ge sr p ^ ")->clone()\n      ->call("^args^");\n" ^
        "        while(_p) _p=_p->resume();\n" ^
        "      }\n"



      | Procedure ->
        needs_switch := true;
        let n = fresh_bid counter in
        (if with_comments then
        "      //"^ src_str ^ "\n"
        else "") ^
        "      FLX_SET_PC(" ^ cid_of_bid n ^ ")\n" ^
        "      return (" ^ ge sr p ^ ")->clone()\n      ->call(" ^ args ^");\n" ^
        "    FLX_CASE_LABEL(" ^ cid_of_bid n ^ ")\n"
      end

    | BEXE_jump (sr,p,a) ->
      let args = match a with
        | _,BTYP_tuple [] -> "tmp"
        | _ -> "tmp, " ^ ge sr a
      in
      begin let _,t = p in match t with
      | BTYP_cfunction _ ->
        "    "^ge sr p ^ "("^ge sr a^");\n"
      | _ ->
      (if with_comments then
      "      //"^ src_str ^ "\n"
      else "") ^
      "      {\n" ^
      "        ::flx::rtl::con_t *tmp = _caller;\n" ^
      "        _caller=0;\n" ^
      "        return (" ^ ge sr p ^ ")\n      ->call(" ^ args ^");\n" ^
      "      }\n"
      end

    | BEXE_proc_return _ ->
      if stackable then
      "      return;\n"
      else
      "      FLX_RETURN\n"

    | BEXE_svc (sr,index) ->
      let bsym =
        try Flx_bsym_table.find bsym_table index with _ ->
          failwith ("[gen_expr(name)] Can't find index " ^ string_of_bid index)
      in
      let t =
        match Flx_bsym.bbdcl bsym with
        | BBDCL_val (_,t,(`Val | `Var)) -> t
        | _ -> syserr (Flx_bsym.sr bsym) "Expected read argument to be variable"
      in
      let n = fresh_bid counter in
      needs_switch := true;
      "      //read variable\n" ^
      "      p_svc = &" ^ get_var_ref syms bsym_table this index ts^";\n" ^
      "      FLX_SET_PC(" ^ cid_of_bid n ^ ")\n" ^
      "      return this;\n" ^
      "    FLX_CASE_LABEL(" ^ cid_of_bid n ^ ")\n"


    | BEXE_yield (sr,e) ->
      let labno = fresh_bid counter in
      let code =
        "      FLX_SET_PC(" ^ cid_of_bid labno ^ ")\n" ^
        (
          let _,t = e in
          (if with_comments then
          "      //" ^ src_str ^ ": type "^tn t^"\n"
          else "") ^
          "      return "^ge sr e^";\n"
        )
        ^
        "    FLX_CASE_LABEL(" ^ cid_of_bid labno ^ ")\n"
      in
      needs_switch := true;
      code

    | BEXE_fun_return (sr,e) ->
      let _,t = e in
      (if with_comments then
      "      //" ^ src_str ^ ": type "^tn t^"\n"
      else "") ^
      "      return "^ge sr e^";\n"

    | BEXE_nop (_,s) -> "      //Nop: " ^ s ^ "\n"

    | BEXE_assign (sr,e1,(( _,t) as e2)) ->
      let t = tsub t in
      begin match t with
      | BTYP_tuple [] -> ""
      | _ ->
      (if with_comments then "      //"^src_str^"\n" else "") ^
      "      "^ ge sr e1 ^ " = " ^ ge sr e2 ^
      ";\n"
      end

    | BEXE_init (sr,v,((_,t) as e)) ->
      let t = tsub t in
      begin match t with
      | BTYP_tuple [] -> ""
      | _ ->
        let bsym =
          try Flx_bsym_table.find bsym_table v with Not_found ->
            failwith ("[gen_expr(init) can't find index " ^ string_of_bid v)
        in
        begin match Flx_bsym.bbdcl bsym with
        | BBDCL_val (_,_,kind) ->
            (if with_comments then "      //"^src_str^"\n" else "") ^
            "      " ^
            begin match kind with
            | `Tmp -> get_variable_typename syms bsym_table v [] ^ " "
            | _ -> ""
            end ^
            get_ref_ref syms bsym_table this v ts ^
            " " ^
            " = " ^
            ge sr e ^
            ";\n"
          | _ -> assert false
        end
      end

    | BEXE_begin -> "      {\n"
    | BEXE_end -> "      }\n"

    | BEXE_assert (sr,e) ->
       let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
       let s = string_of_string f ^ "," ^
         si sl ^ "," ^ si sc ^ "," ^
         si el ^ "," ^ si ec
       in
       "      {if(FLX_UNLIKELY(!(" ^ ge sr e ^ ")))\n" ^
       "        FLX_ASSERT_FAILURE("^s^");}\n"

    | BEXE_assert2 (sr,sr2,e1,e2) ->
       let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
       let s = string_of_string f ^ "," ^
         si sl ^ "," ^ si sc ^ "," ^
         si el ^ "," ^ si ec
       in
       let f2, sl2, sc2, el2, ec2 = Flx_srcref.to_tuple sr2 in
       let s2 = string_of_string f2 ^ "," ^
         si sl2 ^ "," ^ si sc2 ^ "," ^
         si el2 ^ "," ^ si ec2
       in
       (match e1 with
       | None ->
       "      {if(FLX_UNLIKELY(!(" ^ ge sr e2 ^ ")))\n"
       | Some e ->
       "      {if(FLX_UNLIKELY("^ge sr e^" && !(" ^ ge sr e2 ^ ")))\n"
       )
       ^
       "        FLX_ASSERT2_FAILURE("^s^"," ^ s2 ^");}\n"
  in gexe exe

let gen_exes
  filename
  syms
  bsym_table
  display
  label_info
  counter
  index
  exes
  vs
  ts
  instance_no
  stackable
=
  let needs_switch = ref false in
  let s = cat ""
    (List.map (gen_exe
      filename
      syms
      bsym_table
      label_info
      counter
      index
      vs
      ts
      instance_no
      needs_switch
      stackable)
    exes)
  in
  s,!needs_switch

(* PROCEDURES are implemented by continuations.
   The constructor accepts the display vector to
   form the closure object. The call method accepts
   the callers continuation object as a return address,
   and the procedure argument, and returns a continuation.
   The resume method runs the continuation until
   it returns a continuation to some object, possibly
   the same object. A flag in the continuation object
   determines whether the yield of control is a request
   for data or not (if so, the dispatcher must place the data
   in the nominated place before calling the resume method again.
*)

(* FUNCTIONS are implemented as functoids:
  the constructor accepts the display vector so as
  to form a closure object, the apply method
  accepts the argument and runs the function.
  The machine stack is used for functions.
*)
let gen_C_function_body filename syms bsym_table
  label_info counter index ts sr instance_no
=
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("gen_C_function_body] can't find " ^ string_of_bid index)
  in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating C function body inst " ^
    string_of_bid instance_no ^ "=" ^
    Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(bps,traint),ret',exes) ->
    (*
    print_endline ("Properties=" ^ catmap "," (fun x->st (x:>felix_term_t)) props);
    *)
    let requires_ptf = mem `Requires_ptf props in
    if length ts <> length vs then
    failwith
    (
      "[get_function_methods] wrong number of type args, expected vs = " ^
      si (length vs) ^
      ", got ts=" ^
      si (length ts)
    );
    let name = cpp_instance_name syms bsym_table index ts in

    "//C FUNC <" ^ string_of_bid index ^ ">: " ^ name ^ "\n" ^

    let argtype = typeof_bparams bps in
    let argtype = rt vs argtype in
    let rt' vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
    let ret = rt' vs ret' in
    if ret = btyp_tuple [] then "// elided (returns unit)\n\n" else


    let funtype = fold syms.counter (btyp_function (argtype, ret)) in
    (* let argtypename = cpp_typename syms bsym_table argtype in *)
    let rettypename = cpp_typename syms bsym_table ret in

    let params = Flx_bparameter.get_bids bps in
    let exe_string,_ =
      try
        gen_exes filename syms bsym_table [] label_info counter index exes vs ts instance_no true
      with x ->
        (*
        print_endline (Printexc.to_string x);
        print_endline (catmap "\n" (string_of_bexe bsym_table 1) exes);
        print_endline "Can't gen exes ..";
        *)
        raise x
    in
    let dcl_vars =
      let kids = Flx_bsym_table.find_children bsym_table index in
      let kids =
        BidSet.fold begin fun bid lst ->
          let bsym =
            try Flx_bsym_table.find bsym_table bid with Not_found ->
              failwith ("[C func body, vars] Can't find index " ^
                string_of_bid bid);
          in
          match Flx_bsym.bbdcl bsym with
          | BBDCL_val (vs,t,(`Val | `Var)) when not (List.mem bid params) ->
              (bid, rt vs t) :: lst
          | BBDCL_val (vs,t,`Ref) when not (List.mem bid params) ->
              (bid, btyp_pointer (rt vs t)) :: lst
          | _ -> lst
        end kids []
      in
      fold_left
      (fun s (i,t) -> s ^ "  " ^
        cpp_typename syms bsym_table t ^ " " ^
        cpp_instance_name syms bsym_table i ts ^ ";\n"
      )
      "" kids
    in
      rettypename ^ " " ^
      (if mem `Cfun props then "" else "FLX_REGPARM ")^
      name ^ "(" ^
      (
        let s =
          match bps with
          | [] -> ""
          | [{pkind=k; pindex=i; ptyp=t}] ->
            if Hashtbl.mem syms.instances (i, ts)
            && not (argtype = btyp_tuple [] or argtype = btyp_void ())
            then
              let t = rt vs t in
              let t = match k with
(*                | `PRef -> btyp_pointer t *)
                | `PFun -> btyp_function (btyp_void (),t)
                | _ -> t
              in
              cpp_typename syms bsym_table t ^ " " ^
              cpp_instance_name syms bsym_table i ts
            else ""
          | _ ->
              let counter = ref dummy_bid in
              fold_left
              (fun s {pkind=k; pindex=i; ptyp=t} ->
                let t = rt vs t in
                let t = match k with
(*                  | `PRef -> btyp_pointer t *)
                  | `PFun -> btyp_function (btyp_void (),t)
                  | _ -> t
                in
                let n = fresh_bid counter in
                if Hashtbl.mem syms.instances (i,ts) && not (t = btyp_tuple [])
                then s ^
                  (if String.length s > 0 then ", " else " ") ^
                  cpp_typename syms bsym_table t ^ " " ^
                  cpp_instance_name syms bsym_table i ts
                else s (* elide initialisation of elided variable *)
              )
              ""
              bps
        in
          (
            if not (mem `Cfun props) &&
            requires_ptf then
              if String.length s > 0
              then "FLX_APAR_DECL " ^ s
              else "FLX_APAR_DECL_ONLY"
            else s
          )
      )^
      "){\n" ^
      dcl_vars ^
      exe_string ^
      "}\n"

  | _ -> failwith "function expected"

let gen_C_procedure_body filename syms bsym_table
  label_info counter index ts sr instance_no
=
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("gen_C_function_body] can't find " ^ string_of_bid index)
  in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating C procedure body inst " ^
    string_of_bid instance_no ^ "=" ^
    Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(bps,traint),BTYP_void,exes) ->
    let requires_ptf = mem `Requires_ptf props in
    if length ts <> length vs then
    failwith
    (
      "[get_function_methods] wrong number of type args, expected vs = " ^
      si (length vs) ^
      ", got ts=" ^
      si (length ts)
    );
    let name = cpp_instance_name syms bsym_table index ts in
    let argtype = typeof_bparams bps in
    let argtype = rt vs argtype in

    let funtype = fold syms.counter (btyp_function (argtype, btyp_void ())) in
    (* let argtypename = cpp_typename syms bsym_table argtype in *)

    let params = Flx_bparameter.get_bids bps in
    let exe_string,_ =
      try
        gen_exes filename syms bsym_table [] label_info counter index exes vs ts instance_no true
      with x ->
        (*
        print_endline (Printexc.to_string x);
        print_endline (catmap "\n" (string_of_bexe bsym_table 1) exes);
        print_endline "Can't gen exes ..";
        *)
        raise x
    in
    let dcl_vars =
      let kids = Flx_bsym_table.find_children bsym_table index in
      let kids =
        BidSet.fold begin fun bid lst ->
          let bsym =
            try Flx_bsym_table.find bsym_table bid with Not_found ->
              failwith ("[C func body, vars] Can't find index " ^
                string_of_bid bid);
          in
          match Flx_bsym.bbdcl bsym with
          | BBDCL_val (vs,t,(`Val | `Var)) when not (mem bid params) ->
              (bid, rt vs t) :: lst
          | BBDCL_val (vs,t,`Ref) when not (mem bid params) ->
              (bid, btyp_pointer (rt vs t)) :: lst
          | _ -> lst
        end kids []
      in
      fold_left
      (fun s (i,t) -> s ^ "  " ^
        cpp_typename syms bsym_table t ^ " " ^
        cpp_instance_name syms bsym_table i ts ^ ";\n"
      )
      "" kids
    in
    let output =
      "//C PROC <" ^ string_of_bid index ^ ">: " ^ name ^ "\n" ^
      "void " ^
      (if mem `Cfun props then "" else "FLX_REGPARM ")^
      name ^ "(" ^
      (
        let s =
          match bps with
          | [] -> ""
          | [{pkind=k; pindex=i; ptyp=t}] ->
            if Hashtbl.mem syms.instances (i, ts)
            && not (argtype = btyp_tuple [] or argtype = btyp_void ())
            then
              let t = rt vs t in
              let t = match k with
                (*
                | `PRef -> btyp_pointer t
                *)
                | `PFun -> btyp_function (btyp_void (),t)
                | _ -> t
              in
              cpp_typename syms bsym_table t ^ " " ^
              cpp_instance_name syms bsym_table i ts
            else ""
          | _ ->
              let counter = ref 0 in
              fold_left
              (fun s {pkind=k; pindex=i; ptyp=t} ->
                let t = rt vs t in
                let t = match k with
                  | `PFun -> btyp_function (btyp_void (),t)
                  | _ -> t
                in
                let n = !counter in incr counter;
                if Hashtbl.mem syms.instances (i,ts) && not (t = btyp_tuple [])
                then s ^
                  (if String.length s > 0 then ", " else " ") ^
                  cpp_typename syms bsym_table t ^ " " ^
                  cpp_instance_name syms bsym_table i ts
                else s (* elide initialisation of elided variable *)
              )
              ""
              bps
        in
          (
            if (not (mem `Cfun props)) && requires_ptf then
              if String.length s > 0
              then "FLX_APAR_DECL " ^ s
              else "FLX_APAR_DECL_ONLY"
            else s
          )
      )^
      "){\n" ^
      dcl_vars ^
      exe_string ^
      "}\n"
      in 
      output

  | _ -> failwith "procedure expected"

let gen_function_methods filename syms bsym_table
  label_info counter index ts instance_no : string * string
=
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("[gen_function_methods] can't find " ^ string_of_bid index)
  in
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table (Flx_bsym.sr bsym) (tsubst vs ts t) in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating function body inst " ^
    string_of_bid instance_no ^ "=" ^
    Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(bps,traint),ret',exes) ->
    if length ts <> length vs then
    failwith
    (
      "[get_function_methods} wrong number of args, expected vs = " ^
      si (length vs) ^
      ", got ts=" ^
      si (length ts)
    );
    let argtype = typeof_bparams bps in
    let argtype = rt vs argtype in
    let rt' vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table (Flx_bsym.sr bsym) (tsubst vs ts t) in
    let ret = rt' vs ret' in
    if ret = btyp_tuple [] then "// elided (returns unit)\n","" else

    let funtype = fold syms.counter (btyp_function (argtype, ret)) in

    let argtypename = cpp_typename syms bsym_table argtype in
    let name = cpp_instance_name syms bsym_table index ts in

    let display = get_display_list bsym_table index in

    let rettypename = cpp_typename syms bsym_table ret in

    let ctor =
      let vars = find_references syms bsym_table index ts in
      let funs = filter (fun (_,t) -> is_gc_pointer syms bsym_table (Flx_bsym.sr bsym) t) vars in
      gen_ctor syms bsym_table name display funs [] [] ts props
    in
    let params = Flx_bparameter.get_bids bps in
    let exe_string,needs_switch =
      try
        gen_exes filename syms bsym_table display label_info counter index exes vs ts instance_no false
      with x ->
        (*
        print_endline (Printexc.to_string x);
        print_endline (catmap "\n" (string_of_bexe bsym_table 1) exes);
        print_endline "Can't gen exes ..";
        *)
        raise x
    in
    let cont = "::flx::rtl::con_t *" in
    let apply =
      rettypename^ " " ^name^
      "::apply("^
      (if argtype = btyp_tuple [] or argtype = btyp_void ()
      then ""
      else argtypename ^" const &_arg ")^
      "){\n" ^
      (*
      (if mem `Uses_gc props then
      "  gc_profile_t &gc = *PTF gcp;\n"
      else ""
      )
      ^
      *)
      (
        match bps with
        | [] -> ""
        | [{pindex=i}] ->
          if Hashtbl.mem syms.instances (i, ts)
          && not (argtype = btyp_tuple [] or argtype = btyp_void ())
          then
            "  " ^ cpp_instance_name syms bsym_table i ts ^ " = _arg;\n"
          else ""
        | _ ->
          let counter = ref 0 in
          List.fold_left begin fun s i ->
            let n = !counter in incr counter;
            if Hashtbl.mem syms.instances (i,ts)
            then
              let memexpr =
                match argtype with
                | BTYP_array _ -> ".data["^si n^"]"
                | BTYP_tuple _ -> ".mem_"^ si n
                | _ -> assert false
              in
              s ^ "  " ^ cpp_instance_name syms bsym_table i ts ^ " = _arg"^ memexpr ^";\n"
            else s (* elide initialisation of elided variable *)
          end "" params
      )^
        (if needs_switch then
        "  FLX_START_SWITCH\n" else ""
        ) ^
        exe_string ^
        "    throw -1; // HACK! \n" ^ (* HACK .. should be in exe_string .. *)
        (if needs_switch then
        "  FLX_END_SWITCH\n" else ""
        )
      ^
      "}\n"
    and clone =
      "  " ^ name ^ "* "^name^"::clone(){\n"^
      (if mem `Generator props then
      "  return this;\n"
      else
      "  return new(*PTF gcp,"^name^"_ptr_map,true) "^name^"(*this);\n"
      )^
      "}\n"
    in
      let q = qualified_name_of_bindex bsym_table index in
      let ctor =
      "//FUNCTION <" ^ string_of_bid index ^ ">: " ^ q ^ ": Constructor\n" ^
      ctor^ "\n" ^
      (
        if mem `Heap_closure props then
        "\n//FUNCTION <" ^ string_of_bid index ^ ">: " ^ q ^ ": Clone method\n" ^
        clone^ "\n"
        else ""
      )
      and apply =
      "//FUNCTION <" ^ string_of_bid index ^">: "  ^ q ^ ": Apply method\n" ^
      apply^ "\n"
      in apply,ctor


  | _ -> failwith "function expected"

let gen_procedure_methods filename syms bsym_table
  label_info counter index ts instance_no : string * string
=
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("[gen_procedure_methods] Can't find index " ^
        string_of_bid index)
  in (* can't fail *)
  let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table (Flx_bsym.sr bsym) (tsubst vs ts t) in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "//Generating procedure body inst " ^
    string_of_bid instance_no ^ "=" ^
    Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
    (
      if length ts = 0 then ""
      else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
    )
  );
  match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(bps,traint),BTYP_void,exes) ->
    if length ts <> length vs then
    failwith
    (
      "[get_procedure_methods} wrong number of args, expected vs = " ^
      si (length vs) ^
      ", got ts=" ^
      si (length ts)
    );
    let stackable = mem `Stack_closure props in
    let heapable = mem `Heap_closure props in
    (*
    let heapable = not stackable or heapable in
    *)
    let argtype = typeof_bparams bps in
    let argtype = rt vs argtype in
    let funtype = fold syms.counter (btyp_function (argtype, btyp_void ())) in

    let argtypename = cpp_typename syms bsym_table argtype in
    let name = cpp_instance_name syms bsym_table index ts in

    let display = get_display_list bsym_table index in

    let ctor =
      let vars = find_references syms bsym_table index ts in
      let funs = filter (fun (i,t) -> is_gc_pointer syms bsym_table (Flx_bsym.sr bsym) t) vars in
      gen_ctor syms bsym_table name display funs [] [] ts props
    in

    (*
    let dtor = gen_dtor syms bsym_table name display ts in
    *)
    let ps = List.map (fun {pid=id; pindex=ix; ptyp=t} -> id,t) bps in
    let params = Flx_bparameter.get_bids bps in
    let exe_string,needs_switch =
      (*
      gen_exes filename syms bsym_table display label_info counter index exes vs ts instance_no (stackable && not heapable)
      *)
      gen_exes filename syms bsym_table display label_info counter index exes vs ts instance_no stackable
    in

    let cont = "::flx::rtl::con_t *" in
    let heap_call_arg_sig, heap_call_arg =
      match argtype with
      | BTYP_tuple [] -> cont ^ "_ptr_caller","0"
      | _ -> cont ^ "_ptr_caller, " ^ argtypename ^" const &_arg","0,_arg"
    and stack_call_arg_sig =
      match argtype with
      | BTYP_tuple [] -> ""
      | _ -> argtypename ^" const &_arg"
    in
    let unpack_args =
      match bps with
      | [] -> ""
      | [{pindex=i}] ->
          if Hashtbl.mem syms.instances (i,ts)
          && not (argtype = btyp_tuple [] or argtype = btyp_void ())
          then
            "  " ^ cpp_instance_name syms bsym_table i ts ^ " = _arg;\n"
          else ""

      | _ ->
          let counter = ref 0 in
          List.fold_left begin fun s i ->
            let n = !counter in incr counter;
            if Hashtbl.mem syms.instances (i,ts)
            then
              let memexpr =
                match argtype with
                | BTYP_array _ -> ".data["^si n^"]"
                | BTYP_tuple _ -> ".mem_"^ si n
                | _ -> assert false
              in
              s ^ "  " ^ cpp_instance_name syms bsym_table i ts ^ " = _arg" ^ memexpr ^";\n"
            else s (* elide initialisation of elided variables *)
          end "" params
    in
    let stack_call =
        "void " ^name^ "::stack_call(" ^ stack_call_arg_sig ^ "){\n" ^
        (
          if not heapable
          then unpack_args ^ exe_string
          else
            "  ::flx::rtl::con_t *cc = call("^heap_call_arg^");\n" ^
            "  while(cc) cc = cc->resume();\n"
        ) ^ "\n}\n"
    and heap_call =
        cont ^ " " ^ name ^ "::call(" ^ heap_call_arg_sig ^ "){\n" ^
        "  _caller = _ptr_caller;\n" ^
        unpack_args ^
        "  INIT_PC\n" ^
        "  return this;\n}\n"
    and resume =
      if exes = []
      then
        cont^name^"::resume(){//empty\n"^
        "     FLX_RETURN\n" ^
        "}\n"
      else
        cont^name^"::resume(){\n"^
        (if needs_switch then
        "  FLX_START_SWITCH\n" else ""
        ) ^
        exe_string ^
        "    FLX_RETURN\n" ^ (* HACK .. should be in exe_string .. *)
        (if needs_switch then
        "  FLX_END_SWITCH\n" else ""
        )^
        "}\n"
    and clone =
      "  " ^name^"* "^name^"::clone(){\n" ^
        "  return new(*PTF gcp,"^name^"_ptr_map,true) "^name^"(*this);\n" ^
        "}\n"
    in
      let q =
        try qualified_name_of_bindex bsym_table index
        with Not_found ->
          string_of_bid instance_no ^ "=" ^
          Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
          (
            if length ts = 0 then ""
            else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
          )
      in
      let ctor =
      "//PROCEDURE <" ^ string_of_bid index ^ ":> " ^ q ^ ": Constructor\n" ^
      ctor^
      (
        if mem `Heap_closure props then
        "\n//PROCEDURE <" ^ string_of_bid index ^ ":> " ^ q ^ ": Clone method\n" ^
        clone
        else ""
      )
      and call =
      "\n//PROCEDURE <" ^ string_of_bid index ^ ":> " ^ q ^ ": Call method\n" ^
      (if stackable then stack_call else "") ^
      (if heapable then heap_call else "") ^
      (if heapable then
        "\n//PROCEDURE <" ^ string_of_bid index ^ ":> " ^ q ^ ": Resume method\n" ^
        resume
        else ""
      )
      in call,ctor

  | _ -> failwith "procedure expected"


let gen_execute_methods filename syms bsym_table label_info counter bf bf2 =
  let s = Buffer.create 2000 in
  let s2 = Buffer.create 2000 in
  Hashtbl.iter
  (fun (index,ts) instance_no ->
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("[gen_execute_methods] Can't find index " ^ string_of_bid index)
  in

  begin match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(ps,traint),BTYP_void,_) ->
    bcat s ("//------------------------------\n");
    if mem `Cfun props || mem `Pure props && not (mem `Heap_closure props) then
      bcat s (
        gen_C_procedure_body filename syms bsym_table
        label_info counter index ts (Flx_bsym.sr bsym) instance_no
      )
    else
      let call,ctor =
        gen_procedure_methods filename syms bsym_table
        label_info counter index ts instance_no
      in
      bcat s call;
      bcat s2 ctor

  | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
    bcat s ("//------------------------------\n");
    if mem `Cfun props || mem `Pure props && not (mem `Heap_closure props) then
      bcat s (
        gen_C_function_body filename syms bsym_table
        label_info counter index ts (Flx_bsym.sr bsym) instance_no
      )
    else
      let apply,ctor =
        gen_function_methods filename syms bsym_table
        label_info counter index ts instance_no
      in
      bcat s2 ctor;
      bcat s apply

  | BBDCL_external_fun (_,vs,ps_cf,ret',_,_,`Callback (ps_c,client_data_pos)) ->
      let tss =
        if length ts = 0 then "" else
        "[" ^ catmap "," (sbt bsym_table) ts^ "]"
      in
      bcat s ("\n//------------------------------\n");
      if ret' = btyp_void () then begin
        bcat s ("//CALLBACK C PROCEDURE <" ^ string_of_bid index ^ ">: " ^
          qualified_name_of_bindex bsym_table index ^ tss ^ "\n");
      end else begin
        bcat s ("//CALLBACK C FUNCTION <" ^ string_of_bid index ^ ">: " ^
          qualified_name_of_bindex bsym_table index ^ tss ^ "\n");
      end
      ;
      let rt vs t = beta_reduce syms.Flx_mtypes2.counter bsym_table (Flx_bsym.sr bsym) (tsubst vs ts t) in
      let ps_c = List.map (rt vs) ps_c in
      let ps_cf = List.map (rt vs) ps_cf in
      let ret = rt vs ret' in
      if syms.compiler_options.print_flag then
      print_endline
      (
        "//Generating C callback function inst " ^
        string_of_bid instance_no ^ "=" ^
        Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
        (
          if length ts = 0 then ""
          else "[" ^ catmap "," (sbt bsym_table) ts ^ "]"
        )
      );
      if length ts <> length vs then
      failwith
      (
        "[gen_function} wrong number of args, expected vs = " ^
        si (length vs) ^
        ", got ts=" ^
        si (length ts)
      );
      (*
      let name = cpp_instance_name syms bsym_table index ts in
      *)
      let name = Flx_bsym.id bsym in (* callbacks can't be polymorphic .. for now anyhow *)
      let rettypename = cpp_typename syms bsym_table ret in
      let n = length ps_c in
      let flx_fun_atypes =
        rev
        (
          fold_left
          (fun lst (t,i) ->
            if i = client_data_pos
            then lst
            else (t,i)::lst
          )
          []
          (combine ps_c (nlist n))
        )
      in
      let flx_fun_atype =
        if length flx_fun_atypes = 1 then fst (hd flx_fun_atypes)
        else btyp_tuple (List.map fst flx_fun_atypes)
      in
      let flx_fun_reduced_atype = rt vs flx_fun_atype in
      let flx_fun_atype_name = cpp_typename syms bsym_table flx_fun_atype in
      let flx_fun_reduced_atype_name = cpp_typename syms bsym_table flx_fun_reduced_atype in
      let flx_fun_args = List.map (fun (_,i) -> "_a" ^ si i) flx_fun_atypes in
      let flx_fun_arg = match length flx_fun_args with
        | 0 -> ""
        | 1 -> hd flx_fun_args
        | _ ->
          (* argument tuple *)
          let a = flx_fun_atype_name ^ "(" ^ String.concat "," flx_fun_args ^")" in
          if flx_fun_reduced_atype_name <> flx_fun_atype_name
          then "reinterpret<" ^ flx_fun_reduced_atype_name ^ ">("^a^")"
          else a

      in
      let sss =
        (* return type *)
        rettypename ^ " " ^

        (* function name *)
        name ^ "(" ^
        (
          (* parameter list *)
          match length ps_c with
          | 0 -> ""
          | 1 -> cpp_typename syms bsym_table (hd ps_c) ^ " _a0"
          | _ ->
            fold_left
            (fun s (t,j) ->
              s ^
              (if String.length s > 0 then ", " else "") ^
              cpp_typename syms bsym_table t ^ " _a" ^ si j
            )
            ""
            (combine ps_c (nlist n))
        ) ^
        "){\n"^
        (
          (* body *)
          let flx_fun_type = nth ps_cf client_data_pos in
          let flx_fun_type_name = cpp_typename syms bsym_table flx_fun_type in
          (* cast *)
          "  " ^ flx_fun_type_name ^ " callback = ("^flx_fun_type_name^")_a" ^ si client_data_pos ^ ";\n" ^
          (
            if ret = btyp_void () then begin
              "  ::flx::rtl::con_t *p = callback->call(0" ^
              (if String.length flx_fun_arg > 0 then "," ^ flx_fun_arg else "") ^
              ");\n" ^
              "  while(p)p = p->resume();\n"
            end else begin
              "  return callback->apply(" ^ flx_fun_arg ^ ");\n";
            end
          )
        )^
        "  }\n"
      in bcat s sss

  | _ -> ()
  end
  ;
  output_string bf (Buffer.contents s);
  output_string bf2 (Buffer.contents s2);
  Buffer.clear s;
  Buffer.clear s2;
  )
  syms.instances

let gen_biface_header syms bsym_table biface = match biface with
  | BIFACE_export_python_fun (sr,index, export_name) ->
     "// PYTHON FUNCTION " ^ export_name ^ " header to go here??\n"

  | BIFACE_export_fun (sr,index, export_name) ->
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[gen_biface_header] Can't find index " ^ string_of_bid index)
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
      let display = get_display_list bsym_table index in
      if length display <> 0
      then clierr sr "Can't export nested function";

      let arglist =
        List.map
        (fun {ptyp=t} -> cpp_typename syms bsym_table t)
        ps
      in
      let arglist = "  " ^
        (if length ps = 0 then "FLX_FPAR_DECL_ONLY"
        else "FLX_FPAR_DECL\n" ^ cat ",\n  " arglist
        )
      in
      let name, rettypename =
        match ret with
        | BTYP_void -> "PROCEDURE", "::flx::rtl::con_t * "
        | _ -> "FUNCTION", cpp_typename syms bsym_table ret
      in

      "//EXPORT " ^ name ^ " " ^ cpp_instance_name syms bsym_table index [] ^
      " as " ^ export_name ^ "\n" ^
      "extern \"C\" FLX_EXPORT " ^ rettypename ^ " " ^
      export_name ^ "(\n" ^ arglist ^ "\n);\n"

    | _ -> failwith "Not implemented: export non-function/procedure"
    end

  | BIFACE_export_type (sr, typ, export_name) ->
    "//EXPORT type " ^ sbt bsym_table typ ^ " as " ^ export_name  ^ "\n" ^
    "typedef " ^ cpp_type_classname syms bsym_table typ ^ " " ^ export_name ^ "_class;\n" ^
    "typedef " ^ cpp_typename syms bsym_table typ ^ " " ^ export_name ^ ";\n"

let gen_biface_body syms bsym_table biface = match biface with
  | BIFACE_export_python_fun (sr,index, export_name) ->
     "// PYTHON FUNCTION " ^ export_name ^ " body to go here??\n"

  | BIFACE_export_fun (sr,index, export_name) ->
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[gen_biface_body] Can't find index " ^ string_of_bid index)
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint),BTYP_void,_) ->
      if length vs <> 0
      then clierr (Flx_bsym.sr bsym) ("Can't export generic procedure " ^ Flx_bsym.id bsym)
      ;
      let display = get_display_list bsym_table index in
      if length display <> 0
      then clierr (Flx_bsym.sr bsym) "Can't export nested function";

      let args = rev (fold_left (fun args
        ({ptyp=t; pid=name; pindex=pidx} as arg) ->
        try ignore(cpp_instance_name syms bsym_table pidx []); arg :: args
        with _ -> args
        )
        []
        ps)
      in
      let params =
        List.map
        (fun {ptyp=t; pindex=pidx; pid=name} ->
          cpp_typename syms bsym_table t ^ " " ^ name
        )
        ps
      in
      let strparams = "  " ^
        (if length params = 0 then "FLX_FPAR_DECL_ONLY"
        else "FLX_FPAR_DECL\n  " ^ cat ",\n  " params
        )
      in
      let class_name = cpp_instance_name syms bsym_table index [] in
      let strargs =
        let ge = gen_expr syms bsym_table index [] [] in
        match ps with
        | [] -> "0"
        | [{ptyp=t; pid=name; pindex=idx}] -> "0" ^ ", " ^ name
        | _ ->
          let a =
            let counter = ref 0 in
            bexpr_tuple
              (btyp_tuple (Flx_bparameter.get_btypes ps))
              (
                List.map
                (fun {ptyp=t; pid=name; pindex=idx} ->
                  bexpr_expr (name,t)
                )
                ps
              )
          in
          "0" ^ ", " ^ ge sr a
      in

      "//EXPORT PROC " ^ cpp_instance_name syms bsym_table index [] ^
      " as " ^ export_name ^ "\n" ^
      "::flx::rtl::con_t *" ^ export_name ^ "(\n" ^ strparams ^ "\n){\n" ^
      (
        if mem `Stack_closure props then
        (
          if mem `Pure props && not (mem `Heap_closure props) then
          (
            "  " ^ class_name ^"(" ^
            (
              if mem `Requires_ptf props then
                if length args = 0
                then "FLX_APAR_PASS_ONLY "
                else "FLX_APAR_PASS "
              else ""
            )
            ^
            cat ", " (Flx_bparameter.get_names args) ^ ");\n"
          )
          else
          (
            "  " ^ class_name ^ "(_PTFV)\n" ^
            "    .stack_call(" ^ (catmap ", " (fun {pid=id}->id) args) ^ ");\n"
          )
        )
        ^
        "  return 0;\n"
        else
        "  return (new(*_PTF gcp,"^class_name^"_ptr_map,true)\n" ^
        "    " ^ class_name ^ "(_PTFV))" ^
        "\n      ->call(" ^ strargs ^ ");\n"
      )
      ^
      "}\n"

    | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
      if length vs <> 0
      then clierr (Flx_bsym.sr bsym) ("Can't export generic function " ^ Flx_bsym.id bsym)
      ;
      let display = get_display_list bsym_table index in
      if length display <> 0
      then clierr sr "Can't export nested function";
      let arglist =
        List.map
        (fun {ptyp=t; pid=name} -> cpp_typename syms bsym_table t ^ " " ^ name)
        ps
      in
      let arglist = "  " ^
        (if length ps = 0 then "FLX_FPAR_DECL_ONLY"
        else "FLX_FPAR_DECL\n  " ^ cat ",\n  " arglist
        )
      in
      (*
      if mem `Stackable props then print_endline ("Stackable " ^ export_name);
      if mem `Stack_closure props then print_endline ("Stack_closure" ^ export_name);
      *)
      let is_C_fun = mem `Pure props && not (mem `Heap_closure props) in
      let requires_ptf = mem `Requires_ptf props in

      let rettypename = cpp_typename syms bsym_table ret in
      let class_name = cpp_instance_name syms bsym_table index [] in

      "//EXPORT FUNCTION " ^ class_name ^
      " as " ^ export_name ^ "\n" ^
      rettypename ^" " ^ export_name ^ "(\n" ^ arglist ^ "\n){\n" ^
      (if is_C_fun then
      "  return " ^ class_name ^ "(" ^
      (
        if requires_ptf
        then "_PTFV" ^ (if length ps > 0 then "," else "")
        else ""
      )
      ^cat ", " (Flx_bparameter.get_names ps) ^ ");\n"
      else
      "  return (new(*_PTF gcp,"^class_name^"_ptr_map,true)\n" ^
      "    " ^ class_name ^ "(_PTFV)\n" ^
      "    ->apply(" ^ cat ", " (Flx_bparameter.get_names ps) ^ ");\n"
      )^
      "}\n"

    | _ -> failwith "Not implemented: export non-function/procedure"
    end

  | BIFACE_export_type _ -> ""

let gen_biface_headers syms bsym_table bifaces =
  cat "" (List.map (gen_biface_header syms bsym_table) bifaces)

let gen_biface_bodies syms bsym_table bifaces =
  cat "" (List.map (gen_biface_body syms bsym_table) bifaces)

(*  Generate Python module initialisation entry point
if a Python module function is detected as an export
*)

let gen_python_module modname syms bsym_table bifaces =
  let pychk acc elt = match elt with
  | BIFACE_export_python_fun (sr,index,name) ->
    let class_name = cpp_instance_name syms bsym_table index [] in
    let loc = Flx_srcref.short_string_of_src sr in
    let entry = name, class_name, loc in
    entry :: acc
  | _ -> acc
  in
  let funs = fold_left pychk [] bifaces in
  match funs with
  | [] -> ""
  | funs -> 
      "// Python 3 module definition for " ^ modname ^ "\n" ^
      "static PyMethodDef " ^ modname ^ "_methods [] = {\n" ^
      cat "" (rev_map (fun (export_name, symbol_name, loc) ->
      "  {" ^ "\"" ^ export_name ^ "\", " ^ symbol_name ^ 
      ", METH_VARARGS, \""^loc^"\"},\n"
      ) funs) ^ 
      "  {NULL, NULL, 0, NULL}\n" ^
      "};\n" ^
      "static PyModuleDef " ^ modname ^"_module = {\n" ^
        "PyModuleDef_HEAD_INIT,       // m_base\n"^
        modname ^ ",                  // m_name\n" ^
        "\"" ^ modname ^ " generated by Felix \", // m_doc\n" ^
        "-1,                          // m_size\n" ^          
        modname ^ "_methods,          // m_methods\n" ^
        "0,                           // m_reload\n" ^                                      
        "0,                           // m_traverse\n" ^                                      
        "0,                           // m_clear\n" ^                                      
        "0                           // m_free\n" ^                                      
      "}\n" ^
      "PyObject *init" ^ modname ^ "()" ^ 
      " { return PyModuleCreate(&" ^ modname ^ "_module);}\n"

