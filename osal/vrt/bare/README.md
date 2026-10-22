# osal/vrt/bare — deliberately empty

Every `-freestanding` transpile passes `-bare-builtin-dir osal/vrt/bare`. V3 compiles the V files
of a bare builtin directory into `builtin`, and without the flag it takes
`vlib/builtin/linux_bare`: a Linux process's `_start`, syscalls and a dlmalloc heap over `mmap`,
whose `malloc`/`calloc`/`realloc`/`free` collide with the ones `osal/vrt` exports for these
images ("duplicate export name `calloc`"). None of it is right for a bare-metal target.

The hooks builtin calls on a freestanding image stay in `osal/vrt/vrt_d_freestanding.v`, exported
by their C names, so this directory holds no V file. `tools/loom2v/no_v_run_makefiles_test.v`
checks that every freestanding transpile names it.
