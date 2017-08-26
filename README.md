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
% vagrant up xenial
```

Build, ensure synced back, copy towards destination and aptly add, snapshot,
etc.

Leave publish/signing for manual step, but emit instructions.

If no repo defined, how figure out what needed?
Have a `version-bumps.conf` file: `gnupg21 2.1.23 3` to build `-pdp3` not
`-pdp1`.
Have `patches/gnupg21-2.1.23-*` and `patches/gnupg21-all-*`
