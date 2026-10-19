///|
fn Context::worker_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "thread_pool/init_thread_pool" =>
      [I64(host.initialize_thread_pool(i64(args[0])))]
    "thread_pool/destroy_thread_pool" => {
      host.destroy_thread_pool()
      []
    }
    "thread_pool/make_sleep_job" => {
      let duration = i32(args[0])
      guard duration >= 0 else { raise @vm.TypeMismatch }
      [
        I64(
          host.new_job(() => {
            @async.sleep(duration)
            { ret: 0, errno: 0, data: b"", opened: None, }
          }),
        ),
      ]
    }
    "thread_pool/spawn_worker" | "thread_pool/spawn_worker_with_pipe" => {
      guard host.jobs.get(i64(args[1])) is Some(job) else {
        raise @vm.TypeMismatch
      }
      let completion = if name == "thread_pool/spawn_worker_with_pipe" {
        guard host.fds.get(i64(args[2])) is Some(fd) else {
          raise @vm.TypeMismatch
        }
        Some(fd)
      } else {
        None
      }
      [I64(host.spawn_worker(i32(args[0]), job, completion))]
    }
    "thread_pool/wake_worker" => {
      guard host.workers.get(i64(args[0])) is Some(worker) &&
        worker.done &&
        host.jobs.get(i64(args[2])) is Some(job) else {
        raise @vm.TypeMismatch
      }
      host.start_worker(worker, i32(args[1]), job)
      []
    }
    "thread_pool/free_worker" | "thread_pool/worker_enter_idle" => {
      guard host.workers.get(i64(args[0])) is Some(worker) && worker.done else {
        raise @vm.TypeMismatch
      }
      if name == "thread_pool/free_worker" {
        host.workers.remove(i64(args[0]))
        if worker.completion is Some(fd) {
          fd.release()
        }
      }
      []
    }
    "thread_pool/cancel_worker" | "thread_pool/cancel_worker_with_retry" => {
      guard host.workers.get(i64(args[0])) is Some(worker) else {
        raise @vm.TypeMismatch
      }
      if worker.done {
        [I32(2)]
      } else {
        if worker.task is Some(task) {
          task.cancel()
        }
        [I32(1)]
      }
    }
    "thread_pool/job_get_ret"
    | "thread_pool/job_get_err"
    | "thread_pool/free_job" => {
      let handle = i64(args[0])
      guard host.jobs.get(handle) is Some(job) && !job.running else {
        raise @vm.TypeMismatch
      }
      if name == "thread_pool/free_job" {
        host.jobs.remove(handle)
        job.dispose()
        []
      } else {
        guard job.result is Some(result) else { raise @vm.TypeMismatch }
        [
          I32(
            if name == "thread_pool/job_get_ret" {
              result.ret
            } else {
              result.errno
            },
          ),
        ]
      }
    }
    "thread_pool/fetch_completion/unix" => {
      guard host.pool is Some(pool) &&
        !pool.closed &&
        pool.source == i64(args[0]) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      let memory = guest_memory(caller)
      let address = i32(args[1]).reinterpret_as_uint().to_int64()
      let capacity = i32(args[2])
      guard capacity >= 0 &&
        address + capacity.to_int64() * 4L <= memory.byte_len() else {
        host.async_errno = @sys.fault_errno
        return [I32(-1)]
      }
      let completed = pool.fetch_completion(capacity)
      for index, id in completed {
        memory.store_i32_at(address + index.to_int64() * 4L, id)
      }
      [I32(completed.length() * 4)]
    }
    "thread_pool/errno_is_cancelled" =>
      [
        I32(
          if i32(args[0]) == (if @async.platform is Windows { 995 } else { 4 }) {
            1
          } else {
            0
          },
        ),
      ]
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}
