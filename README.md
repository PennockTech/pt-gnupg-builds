pdp-gnupg-builds
================

Intended for packaging GnuPG and supporting tools for a variety of OS
releases.

We deliberately do not create packages which install in the normal system
paths.  Keep GnuPG packages supported by your OS vendor there.  Remember that
breaking OS tooling around GnuPG can break your ability to keep your OS
up-to-date and secure.

Instead, we install under `/opt/gnupg`.  All packages custom-built for GnuPG
install into that prefix.  This includes other major projects such as GnuTLS.


Building
--------

We're using Vagrant to build packages.  Details TBD.

```console
% vagrant status
## see list of machines, typically named for OS
% ./build.sh xenial
## if problems: edit, fix, then:
% vagrant provision xenial
## and repeat until build.sh might work.
```

The contents of the `./in` directory are unidirectionally rsync'd towards
the VM into `/in/` on `up` and each `reload`.  The build scripts download
large assets into that directory, if they don't already exist.  `./in` is git
ignored, so this is an appropriate place to store cached assets between
attempts.  The environment variable `PT_GNUPG_IN` can be used to point to a
different local location.

You can sync more assets in with `vagrant rsync $machine_name`

---

Leave publish/signing for manual step, but emit instructions.

If no repo defined, how figure out what needed?
Have a `version-bumps.conf` file: `gnupg21 2.1.23 3` to build `-pdp3` not
`-pdp1`.
Have `patches/gnupg21-2.1.23-*` and `patches/gnupg21-all-*`
