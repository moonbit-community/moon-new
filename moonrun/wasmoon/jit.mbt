///|
fn prepare_jit(
  code : @wasm.Module,
  bytes : Bytes,
  store : @vm.Store,
  instance : @vm.ModuleInstance,
  stack_size : Int64,
) -> @jit_context.JITModuleContext raise {
  // Match Wasmoon's compiler: flat function tables use signature IDs; GC and
  // declared subtypes require canonical type IDs for indirect calls.
  let subtype_check = code.types.any(type_ => {
      !type_.supertypes.is_empty() || !(type_.composite is Func(_))
    }) ||
    code.tables.any(table => {
      !(table.type_.elem_type
      is (FuncRef
      | NullFuncRef
      | RefFunc
      | RefFuncTyped(_)
      | RefNullFuncTyped(_)))
    })
  let failure = Ref("JIT compilation failed")
  // Compile the original binary to preserve source-map instruction offsets.
  guard @compiler.compile_module(
      bytes,
      opt_level=2,
      enable_cancellation=true,
      nan_canonicalization=store.nan_canonicalization,
      on_progress=progress => {
        if progress.message is Some(message) {
          failure.val = message
        }
        None
      },
    )
    is Some(artifact) else {
    raise @vm.LinkErrorDetail(failure.val)
  }
  let loaded = @compiler.verify_compiled_jit_artifact(artifact)
  let module_ = @jit.JITModule::load_artifact_with_imports(
    loaded,
    @jit_context.build_func_signatures(code),
    @jit_context.build_external_imports_for_jit(code, instance, store),
    function_names=@compiler.build_jit_function_names(code),
  )
  errdefer module_.close()
  guard module_.set_cooperative_scheduling(true) &&
    module_.configure_native_fiber_stack_size(stack_size) else {
    raise @vm.LinkErrorDetail("failed to configure JIT native fibers")
  }
  @jit_context.register_instance_funcrefs_for_jit(module_, instance, store)
  @jit_context.init_jit_memories_from_store(instance, store, module_) |> ignore
  let globals = @jit_context.init_jit_globals_from_store(
    instance, store, module_,
  )
  @jit_context.init_elem_segments(
    code,
    module_,
    instance,
    store,
    use_subtype_indirect_check=subtype_check,
  )
  @jit_context.init_bulk_segments(
    code,
    module_,
    instance,
    store,
    use_subtype_indirect_check=subtype_check,
  )
  @jit_context.JITModuleContext(
    module_,
    globals,
    instance.global_addrs[:],
    instance.table_addrs[:],
    instance.func_addrs[:],
    instance.func_type_indices[:],
    instance.canonical_type_indices[:],
    code.types,
    code.type_rec_groups,
    subtype_check,
  )
}

///|
fn Context::format_trap(
  self : Context,
  error : Error,
  jit : @jit_context.JITModuleContext,
  no_stack_trace : Bool,
) -> String {
  guard error is @jit_context.Trap(_) &&
    jit.jit_module.get_last_trap_report() is Some(report) else {
    return "\{error}"
  }
  let message = StringBuilder()
  message.write_string(report.message)
  if !no_stack_trace {
    for frame in report.wasm_frames {
      let location = @source_map.format_frame(
        frame.func_name,
        frame.wasm_offset,
        self.source_map,
      )
      let offset = match frame.native_offset {
        Some(offset) => ", JIT +0x\{offset.to_string(radix=16)}"
        None => ""
      }
      message.write_string(
        "\n    \{location} (func \{frame.func_idx}\{offset})",
      )
    }
  }
  message.to_string()
}
