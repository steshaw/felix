Package: src/packages/control.fdoc


==============
Control Basics
==============

============ ==================================
key          file                               
============ ==================================
__init__.flx share/lib/std/control/__init__.flx 
control.flx  share/lib/std/control/control.flx  
swapop.fsyn  share/lib/grammar/swapop.fsyn      
============ ==================================

Control Synopsis
================



.. code-block:: felix

  //[__init__.flx]
  // stream is part of datatype, included in std/datatype/__init__
  include "std/control/control";
  include "std/control/unique";
  include "std/control/iterator";
  include "std/control/schannels";
  include "std/control/fibres";
  include "std/control/spipes";
  include "std/control/chips";
  
  //include "std/control/mux";
  
Misc Control Flow
=================


.. index:: Control(class)
.. index:: fix(fun)
.. index:: flat_fact(fun)
.. index:: _swap(proc)
.. index:: forever(proc)
.. index:: pass(proc)
.. index:: for_each(proc)
.. index:: branch(proc)
.. index:: throw(gen)
.. index:: raise(proc)
.. index:: proc_fail(proc)
.. index:: fun_fail(fun)
.. index:: entry_label(fun)
.. index:: current_position(fun)
.. index:: entry_label(fun)
.. index:: current_continuation(fun)
.. index:: throw_continuation(proc)
.. index:: svc_req_t(union)
.. code-block:: felix

  //[control.flx]
  open class Control
  {
    open C_hack;
  
    // FIXPOINT OPERATOR
    fun fix[D,C] (f:(D->C)->D->C) (x:D) : C => f (fix f) x;
  
    /* Example use: factorial function
    fun flat_fact (g:int->int) (x:int):int =>
      if x == 0 then 1 
      else x * g (x - 1)
    ;
    var fact = fix flat_fact;
    println$ fact 5;
    */
  
    proc _swap[t] (a:&t,b:&t) =
    {
      var tmp = *a;
      a <- *b;
      b <- tmp;
    }
  
    //$ infinite loop
    proc forever (bdy:unit->void)
    {
      rpeat:>
        bdy();
        goto rpeat;
      dummy:> // fool reachability checker
    }
  
    publish "do nothing [the name pass comes from Python]"
    proc pass(){}
  
    //$ C style for loop
    proc for_each
      (init:unit->void)
      (cond:unit->bool)
      (incr:unit->void)
      (bdy:unit->void)
    {
      init();
      rpeat:>
        if not (cond()) goto finish;
        bdy();
        incr();
        goto rpeat;
      finish:>
    }
  
    proc branch-and-link (target:&LABEL, save:&LABEL)
    {
       save <- next;
       goto *target;
       next:>
    }
  
    //$ throw[ret, exn] throw exception of type exn
    //$ in a context expecting type ret. 
    gen throw[ret,exn] : exn -> ret = "(throw $1,*(?1*)0)";
    proc raise[exn] : exn = "(throw $1);";
    proc proc_fail:string = 'throw ::std::runtime_error($1);' 
      requires Cxx_headers::stdexcept;
  
    // Note: must be a fun not a gen to avoid lifting.
    fun fun_fail[ret]:string -> ret = '(throw ::std::runtime_error($1),*(?1*)0)' 
      requires Cxx_headers::stdexcept;
  
    //$ This is the type of a Felix procedural
    //$ continuations in C++ lifted into Felix.
    //$ Do not confuse this with the Felix type of the procedure.
    _gc_pointer type cont = "::flx::rtl::con_t*";
  
    fun entry_label : cont -> LABEL = "::flx::rtl::jump_address_t($1)";
    fun current_position : cont -> LABEL = "::flx::rtl::jump_address_t($1,$1->pc)";
    fun entry_label[T] (p:T->0):LABEL => entry_label (C_hack::cast[cont] p);
  
    //$ This is a hack to get the procedural continuation
    //$ currently executing, it is just the procedures
    //$ C++ this pointer.
    fun current_continuation: unit -> cont = "this";
  
    //$ The type of a Felix fthread or fibre, which is
    //$ a container which holds a procedural continuation.
    _gc_pointer type fthread = "::flx::rtl::fthread_t*";
  
  
    //$  Throw a continuation. This is unsafe. It should
    //$  work from a top level procedure, or any function
    //$  called by such a procedure, but may fail
    //$  if thrown from a procedure called by a function.
    //$  The library run and driver will catch the
    //$  continuation and execute it instead of the
    //$  current continuation. If the library run is used
    //$  and the continuation being executed is down the
    //$  C stack, the C stack will not have been correctly
    //$  popped. Crudely, nested drivers should rethrow
    //$  the exception until the C stack is in the correct
    //$  state to execute the continuation, but there is no
    //$  way to determine that at the moment.
    //$
    //$  Compiler generated runs ignore the exception,
    //$  the library run catches it. Exceptions typically
    //$  use a non-local goto, and they cannot pass across
    //$  a function boundary.
  
    proc throw_continuation(x: unit->void) { _throw (C_hack::cast[cont] x); }
    private proc _throw: cont = "throw $1;";
  
    //$ Type of the implementation of a  synchronous channel.
    //$ should be private but needed in this class for the data type,
    //$ and also needed in schannels to do the svc call.
  
    _gc_pointer type _schannel = "::flx::rtl::schannel_t*";
  
    //$ Felix-OS service call codes.
    // THESE VALUES MUST SYNC WITH THE RTL
    // LAYOUT CHANGE: pointers are now stored in the _uctor_
    // instead of on the heap with a pointer in the uctor
    // This doesn't affect abstract types, even if they're pointers in C
    union svc_req_t =
    /*0*/ | svc_yield
    /*1*/ | svc_get_fthread         of &fthread    // CHANGED LAYOUT
    /*2*/ | svc_read                of address
    /*3*/ | svc_general             of &address    // CHANGED LAYOUT
    /*4*/ | svc_reserved1
    /*5*/ | svc_spawn_pthread       of fthread
    /*6*/ | svc_spawn_detached      of fthread
    /*7*/ | svc_sread               of _schannel * &address
    /*8*/ | svc_swrite              of _schannel * &address
    /*9*/ | svc_kill                of fthread
    /*10*/ | svc_swait
    /*11*/ | svc_multi_swrite       of _schannel * &address 
    /*12*/ | svc_schedule_detached  of fthread
    ;
  
    //$ Procedure to perform a supervisor call. 
    //$ this interface just gets rid of the horrible requirement
    //$ the request be in a variable so it is addressable.
    //$ The _svc statement is a compiler intrinsic.
    noinline proc svc(svc_x:svc_req_t) {
      var svc_y=svc_x;
      _svc svc_y;
    }
  
  }


.. code-block:: felix

  //[swapop.fsyn]
  syntax swapop
  {
    sswapop := "<->" =># "'_swap";
  }



