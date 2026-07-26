# Third-party components

The code written for this project (`install.sh`, `build.sh`, `tests/`, and the
documentation) is original work by the project author and is licensed MIT, see
[LICENSE](LICENSE). Two things in this repository are **not** covered by that MIT grant:

- `bin/btproxy-x86_64`, a third-party binary, described in full below.
- The license texts under [`LICENSES/`](LICENSES/), which are the verbatim, unmodifiable
  texts published by the FSF and the respective copyright holders.

## `bin/btproxy-x86_64`

An **unmodified build of `btproxy`** from the [BlueZ](http://www.bluez.org/) project, the
Linux Bluetooth stack. It is not authored by this project, only compiled and redistributed
here. Reproduce it with [`build.sh`](build.sh).

- **Upstream source:** BlueZ 5.66, `https://www.kernel.org/pub/linux/bluetooth/bluez-5.66.tar.xz`
- **Built from:** `tools/btproxy.c`, linked against `src/libshared-mainloop.la`

Linking pulls in more than `btproxy.c`, so the single binary combines three licenses:

| Component | Copyright | License |
|---|---|---|
| `tools/btproxy.c` | (C) 2011-2012 Intel Corporation<br>(C) 2004-2010 Marcel Holtmann `<marcel@holtmann.org>` | [GPL-2.0-or-later](LICENSES/GPL-2.0-or-later.txt) |
| `src/shared/util.c`, `mainloop.c`, `mainloop-notify.c`, and other `libshared-mainloop` sources | (C) Intel Corporation, Marcel Holtmann and BlueZ contributors | [LGPL-2.1-or-later](LICENSES/LGPL-2.1-or-later.txt) |
| `src/shared/ecc.c` | (C) 2013 Kenneth MacKay | [BSD-2-Clause](LICENSES/BSD-2-Clause.txt) |

The combined work is therefore distributed under the **GPL-2.0-or-later**, the strongest of
the three. The MIT license on the rest of this repository does not apply to it.

BSD-2-Clause clause 2 requires that binary redistributions reproduce the copyright notice
and disclaimer: that text is included verbatim at
[LICENSES/BSD-2-Clause.txt](LICENSES/BSD-2-Clause.txt) and accompanies every release.

### Written offer for source code (GPL-2.0 section 3b)

The complete corresponding source for `bin/btproxy-x86_64` is the unmodified BlueZ 5.66
tarball linked above, and [`build.sh`](build.sh) is the exact recipe used to compile it.

In addition, and to satisfy GPL-2.0 section 3(b) directly: **for three years from the date
you received this binary, the author will provide a complete machine-readable copy of the
corresponding source code, on a medium customarily used for software interchange, for no
more than the cost of physically performing that distribution.** Request it by opening an
issue at https://github.com/lucid-fabrics/proxmox-bluetooth/issues.
