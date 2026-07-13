# How do I add a shell command?

The CAN shell ([../com-modules.md](../com-modules.md)) runs on the bus-owning comm
thread: one raw frame in = one command line, one ISO-TP text block out. Built-ins
(`help`, `ps`, `uptime`, `stat`, ...) come with the platform; example-specific commands
are one config entry + one C function.

## 1. Name it in `[shell]`

```toml
[shell]
commands = ["m4sig", "iocx"]   # each name X -> C `shell_X(out, cap)` in the glue
bus = "can0"
in  = 0x7F0                    # command line (raw frame, <= 8 chars)
out = 0x7F1                    # response (ISO-TP block)
fc  = 0x7F2                    # host flow control
```

## 2. Implement it in the example's `comm_glue.c`

```c
/* return the number of bytes written into out (cap is the response buffer size) */
int shell_m4sig(unsigned char *out, int cap) {
    char *p = (char *)out, *end = (char *)out + cap;
    p = ps_str(p, end, "M4 FB: n ");
    p = ps_u32(p, end, value);
    p = ps_str(p, end, "\n");
    return (int)(p - (char *)out);
}
```

Rules: bounded work (it runs on the comm thread between bus ticks), no allocation, no
blocking. `make gen` emits the adapter + `g_sh.register(...)`; the command shows up in
`help` automatically.

## 3. Talk to it

From the blobly_net GUI: the Shell panel (`Shl`). From a Linux host with can-utils:

```sh
isotprecv -s 7F2 -d 7F1 -b 0 can0 &          # listen for the ISO-TP response
cansend can0 7F0#$(echo -n "m4sig" | xxd -p) # send the command line
```

Commands that take arguments receive the raw line: the generated adapter passes
`(args, args_len, now, rsp)` to V-side commands; C-side `shell_X(out, cap)` commands
are argument-less by contract (add parsing when a command earns it).
