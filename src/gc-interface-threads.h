// This file is a part of Julia. License is MIT: https://julialang.org/license

#ifndef JL_GC_INTERFACE_THREADS_H
#define JL_GC_INTERFACE_THREADS_H

#ifdef __cplusplus
extern "C" {
#endif

// parallel gc thread function
void jl_parallel_gc_threadfun(void *arg);
// concurrent gc thread function
void jl_concurrent_gc_threadfun(void *arg);

#ifdef __cplusplus
}
#endif

#endif // JL_GC_INTERFACE_THREADS_H
