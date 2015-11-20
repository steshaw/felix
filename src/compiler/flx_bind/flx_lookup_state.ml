
type lookup_state_t = {
  counter : Flx_types.bid_t ref;
  print_flag: bool;
  ticache : (Flx_types.bid_t, Flx_btype.t) Hashtbl.t;
  varmap: Flx_mtypes2.typevarmap_t; 
    (* used by unification to fix the return types of functions
     * MUST be a reference to the global one because that's used
     * in the front and back ends extensively..
     *)
  sym_table: Flx_sym_table.t;
  env_cache: (Flx_types.bid_t, Flx_mtypes2.env_t) Hashtbl.t;
}

let make_lookup_state print_flag counter varmap ticache sym_table =
  {
    counter = counter;
    print_flag = print_flag;
    ticache = ticache; 
    varmap = varmap;
    sym_table = sym_table;
    env_cache = Hashtbl.create 97;
  }

let hfind msg h k =
  try Flx_sym_table.find h k
  with Not_found ->
    print_endline ("flx_lookup Flx_sym_table.find failed " ^ msg);
    raise Not_found

let get_data table index =
  try Flx_sym_table.find table index
  with Not_found ->
    failwith ("[Flx_lookup.get_data] No definition of <" ^
      Flx_print.string_of_bid index ^ ">")

let get_varmap state = state.varmap


let rsground : Flx_types.recstop = {
  Flx_types.constraint_overload_trail = [];
  idx_fixlist = [];
  type_alias_fixlist = [];
  as_fixlist = [];
  expr_fixlist = [];
  depth = 0;
  open_excludes = [];
  strr_limit = 5;
}


