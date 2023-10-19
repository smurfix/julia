// This file is a part of Julia. License is MIT: https://julialang.org/license

#include "julia.h"
#include "julia_internal.h"
#include "gc-stock.h"
#include "threading.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef THIRD_PARTY_GC // third-party GCs must provide their own thread functions

STATIC_INLINE int may_mark(void) JL_NOTSAFEPOINT
{
    return (jl_atomic_load(&gc_n_threads_marking) > 0);
}

STATIC_INLINE int may_sweep(jl_ptls_t ptls) JL_NOTSAFEPOINT
{
    return (jl_atomic_load(&ptls->gc_sweeps_requested) > 0);
}

// parallel gc thread function
void jl_parallel_gc_threadfun(void *arg)
{
    jl_threadarg_t *targ = (jl_threadarg_t*)arg;

    // initialize this thread (set tid and create heap)
    jl_ptls_t ptls = jl_init_threadtls(targ->tid);

    // wait for all threads
    jl_gc_state_set(ptls, JL_GC_STATE_WAITING, 0);
    uv_barrier_wait(targ->barrier);

    // free the thread argument here
    free(targ);

    while (1) {
        uv_mutex_lock(&gc_threads_lock);
        while (!may_mark() && !may_sweep(ptls)) {
            uv_cond_wait(&gc_threads_cond, &gc_threads_lock);
        }
        uv_mutex_unlock(&gc_threads_lock);
        if (may_mark()) {
            gc_mark_loop_parallel(ptls, 0);
        }
        if (may_sweep(ptls)) { // not an else!
            gc_sweep_pool_parallel();
            jl_atomic_fetch_add(&ptls->gc_sweeps_requested, -1);
        }
    }
}

// concurrent gc thread function
void jl_concurrent_gc_threadfun(void *arg)
{
    jl_threadarg_t *targ = (jl_threadarg_t*)arg;

    // initialize this thread (set tid and create heap)
    jl_ptls_t ptls = jl_init_threadtls(targ->tid);

    // wait for all threads
    jl_gc_state_set(ptls, JL_GC_STATE_WAITING, 0);
    uv_barrier_wait(targ->barrier);

    // free the thread argument here
    free(targ);

    while (1) {
        uv_sem_wait(&gc_sweep_assists_needed);
        gc_free_pages();
    }
}

#endif // THIRD_PARTY_GC

#ifdef __cplusplus
}
#endif
