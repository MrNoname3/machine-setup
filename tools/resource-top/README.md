# resource-top — what is using the memory and the CPU

[resource-top.sh](resource-top.sh) answers two questions when deciding what to
switch off on a machine:

- **`mem [N]`** — memory per program: the proportional set size (PSS) of every
  process, summed by process name. PSS splits shared pages between the
  processes that share them, so the column adds up to what is really in use,
  unlike RSS, which counts a shared library once for every process.
- **`cpu [SECONDS] [N]`** — CPU per program over a window (60 seconds by
  default), as a share of one core. A sampling tool like `top` shows a moment;
  this shows what an idle desktop burns over a minute.

Both print the top N names (25 by default). Run as root, or the processes of
other users, the system services among them, are left out.

## Use

On this machine:

```
sudo tools/resource-top/resource-top.sh mem
sudo tools/resource-top/resource-top.sh cpu 30
```

On another one, without copying anything there:

```
ssh HOST 'sudo sh -s -- mem' < tools/resource-top/resource-top.sh
```

It reads only `/proc`, so it needs nothing beyond a POSIX shell and awk.
