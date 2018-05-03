pt-gnupg-builds
===============

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

We're using Vagrant to build packages.

First create `site-local.env`; things will work without it, but you might not
like some details embedded in packages and their names.  It should look
something like:

```
export PKG_EMAIL='maintainer@example.org'
export PKG_VERSIONEXT='suf'
```

I use a Pennock Tech email address and `pt` for `PKG_VERSIONEXT`.

You will almost certainly want to change values in `confs/deploy.sh`; if you
instead export `PT_SKIP_DEPLOY=true` in environ before building, then you can
build packages without trying to put them live on the repo server.

```console
% vagrant status
## see list of machines, typically named for OS
% ./build.sh xenial
## if problems: edit, fix, then:
% PT_RESUME_BUILD=t ./build.sh xenial
## and repeat until build.sh might work.
```

The contents of the `./in` directory are unidirectionally rsync'd towards
the VM into `/in/` on `up` and each `reload`.  The build scripts download
large assets into that directory, if they don't already exist.  `./in` is git
ignored, so this is an appropriate place to store cached assets between
attempts.  The environment variable `PT_GNUPG_IN` can be used to point to a
different local location.

You can sync more assets in with `vagrant rsync $machine_name`.

Unless disabled via env flag, the build script will invoke a deploy script for
each machine.  The included deploy scripts assume use of `aptly` for repo
management and are tuned via `confs/deploy.sh`.


Updating
--------

* Adding a new box (OS) for building on goes into `confs/machines.json`; the
  values are parsed in the `Vagrantfile` and also used elsewhere (`jq` in
  scripts).  Do not add the repo field until the initial run is complete.
* A new version of GnuPG software should come automatically from `swdb.lst`
* A new version of non-GnuPG dependent software goes in `confs/versions.json`
* Changing how a package is built goes in `confs/configures.json`
* Adding an "A needed for B" dependency ordering goes in the
  `confs/dependencies.tsort-in` file (use `column -t` for formatting, `tsort`
  to see the resulting order).
* The only items built are those in the dependencies file.
* Changes in PGP signing keys will need to be reflected _both_ in the
  key-dumps in `confs/` and in `pgp_ownertrusts` defined in `confs/params.env`


Adding new repo with aptly
--------------------------

With an S3 bucket set up, S3-website endpoint enabled (for top-level index),
CloudFront providing HTTPS from an ACM-managed cert and DNS all handled
elsewhere, the aptly steps are:

```
aptly repo create -comment "Pennock Tech Ubuntu Xenial repo" pt-xenial

jq '.skipContentsPublishing=true' .aptly.conf > x && mv x .aptly.conf
```

and then here:

```
PT_INITIAL_DEPLOY=t ./build.sh xenial
```

Yields: `deb https://public-packages.pennock.tech/pt/ubuntu/xenial/ xenial main`

We could move repo creation in-tool too, but currently leaving that out.


Todo
----

* Have `patches/gnupg21-2.1.23-*` and `patches/gnupg21-all-*`
* Audit for `XXX`, `FIXME`, `TODO`, `UNIMPLEMENTED`
