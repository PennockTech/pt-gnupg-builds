#!/usr/bin/env python3

"""
build: Build GnuPG and dependencies, in order

Ultimate goal (probably not implemented yet) is to handle existing packages on
apt repo, grab those which are usable if none of their dependencies need
rebuilding, reuse as much as possible, but build what's needed.
"""

__author__ = 'phil@pennock-tech.com (Phil Pennock)'

import argparse
import collections
import datetime
import json
import os
import platform
import subprocess
import sys
import tempfile

import requests

# This is so wrong; the defaults should be defined as relative to dirs settable
# with flags, so that don't need to override these early with environ.  I
# messed up.
CONFS_DIR = os.environ.get('PT_BUILD_CONFIGS_DIR', '/vagrant/confs')
TARBALLS_DIR = os.environ.get('PT_BUILD_TARBALLS_DIR', '/in')
RESULTS_DIR = os.environ.get('PT_BUILD_OUTPUTS_DIR', '/out')

# All defaults which should be overrideable with flags.
BASE_DIR = '~/src'
DEPENDENCIES_FN = CONFS_DIR + '/dependencies.tsort-in'
MUTEX_FN = CONFS_DIR + '/mutual-exclude'
SWDB_FN = TARBALLS_DIR + '/swdb.lst'
PATCHES_DIR = '/vagrant/patches'
VERSIONS_FN = CONFS_DIR + '/versions.json'
CONFIGURES_FN = CONFS_DIR + '/configures.json'
MIRROR_URL = 'https://www.gnupg.org/ftp/gcrypt/'
PKG_EMAIL = 'unknown@localhost'
PKG_PREFIX = 'optgnupg'
PKG_VERSIONEXT = 'unknown'
PKG_INSTALL_CMD = '/usr/local/bin/pt-build-pkg-install'  # wrapper: sudo dpkg -i (or equivalent per OS)
PKG_UNINSTALL_CMD = '/usr/local/bin/pt-build-pkg-uninstall'

PACKAGE_TYPES = {
    'debian-family': 'deb',
    }

class Error(Exception):
  """Base class for exceptions from build."""
  pass


class Product(object):
  __slots__ = [
      'name', 'ver', 'date', 'size', 'sha1', 'sha2', 'branch', 'sha1_gz',
      'product', 'filename_base', 'dirname', 'tarball', 'third_party',
      ]
  def as_dict(self):
    """as_dict returns a dict clone of the Product, for JSON serialization."""
    x = {}
    for s in self.__slots__:
      if hasattr(self, s):
        x[s] = getattr(self, s)
    return x

class OurJSONEncoder(json.JSONEncoder):
  """OurJSONEncoder handles as_dict methods for less sucky JSON encoding."""
  def default(self, o):
    if hasattr(o, 'as_dict'):
      return o.as_dict()
    return json.JSONEncoder.default(self, o)

class BuildPlan(object):
  """BuildPlan represents our state of knowledge around what needs to happen."""
  def __init__(self, options):
    self.options = options
    self._get_depends(options.dependencies_file)
    self._get_mutexes(options.mutex_file)
    # FIXME: relies upon being run in clean OS images!
    self.installed = set()
    self._fetched = []

  def _get_depends(self, fn):
    p = subprocess.Popen(['tsort', fn],
         stdout=subprocess.PIPE, stderr=sys.stderr, stdin=open(os.devnull, 'r'),
         universal_newlines=True)
    self.ordered = list(map(lambda s: s.strip(), p.stdout.readlines()))

    self.needs = collections.defaultdict(set)
    self.direct_needs = {}
    for l in open(fn):
      before, after = l.strip().split()
      if before == after:
        continue
      self.needs[after].add(before)
    for k in self.ordered:
      self.direct_needs[k] = sorted(self.needs[k])
      for dep in list(self.needs[k]):
        self.needs[k].update(self.needs[dep])

    self.invalidates = collections.defaultdict(set)
    for k in self.needs.keys():
      for rev in self.needs[k]:
        self.invalidates[rev].add(k)

  def _get_mutexes(self, fn):
    # partitions via sets where each member is a dict key pointing to the set
    self.mutually_excluded = {}
    for l in open(fn):
      l = l.strip()
      if not l or l.startswith('#'):
        continue
      not_together = set(l.split())
      for member in not_together:
        self.mutually_excluded[member] = not_together

  def process_swdb(self, fn=None):
    if fn is None:
      fn = self.options.swdb_file
    self.product_list = []
    p = None
    for l in open(fn):
      prod_attr, value = l.strip().split()
      if '_w32' in prod_attr or '_src_' in prod_attr or '_exe_' in prod_attr or '_isrc_' in prod_attr:
        continue
      prod, attr = prod_attr.split('_', 1)
      # pragmatic tears here
      if prod in set(['libgpg', 'gpgrt']) and attr.startswith('error_'):
        prod += '_error'
        attr = attr[6:]
      if p is not None and p.product != prod:
        self.product_list.append(p)
        p = None
      if p is None:
        p = Product()
        p.product = prod
        p.name = prod.replace('_', '-')
        p.filename_base = p.name
        if p.name.startswith('gnupg2'):
          p.filename_base = 'gnupg'
        p.third_party = False
      setattr(p, attr, value)
    if p is not None:
      self.product_list.append(p)
    self.products = {}
    for p in self.product_list:
      if p in self.products:
        raise Error('revisited {} after moving on'.format(p.name))
      self.products[p.name] = p

  def process_versions_conf(self, vfn=None):
    if vfn is None:
      vfn = self.options.versions_file
    self.other_versions = json.load(open(vfn))
    if 'products' not in self.other_versions:
      raise Error('Missing key "products" in {!r}'.format(vfn))
    if 'overrides' not in self.other_versions:
      self.other_versions['overrides'] = {}

  def process_configures(self, cfn=None):
    if cfn is None:
      cfn = self.options.configures_file
    self.configures = json.load(open(cfn))
    if 'prefix' not in self.configures:
      raise Error('Missing key "prefix" in {!r}'.format(cfn))

  def ensure_have_each(self, tardir=None):
    if tardir is None:
      tardir = self.options.tarballs_dir
    for product in self.ordered:
      if product in self.products:
        self.ensure_swdb_product(self.products[product], tardir)
      else:
        self.ensure_3rdparty_product(product, tardir)

  def ensure_swdb_product(self, product, tardir):
    fn = '{0.filename_base}-{0.ver}.tar.bz2'.format(product)
    want_path = os.path.join(tardir, fn)
    dl_src = '{o.mirror}{slash}{p.filename_base}/{fn}'.format(
        o=self.options, p=product, fn=fn,
        slash = '' if self.options.mirror.endswith('/') else '/')

    self.check_and_download(product.name, want_path, dl_src)
    self.products[product.name].tarball = want_path
    self.products[product.name].dirname = '{0.filename_base}-{0.ver}'.format(product)

  def check_and_download(self, name, want_path, dl_src):
    print('\033[36m{}\033[0m'.format(name), flush=True)
    for ext in ('', '.sig'):
      path_name = want_path + ext
      if not os.path.exists(path_name):
        self.fetch_file(dl_src + ext, path_name)

    subprocess.check_call([self.options.gpg, '--trust-model', self.options.gnupg_trust_model, '--verify', want_path + ext],
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))

  def ensure_3rdparty_product(self, product, tardir):
    if product not in self.other_versions['products']:
      raise Error('no version configured in {o.versions_file} for {p}'.format(
        o=self.options, p=product))
    other = self.other_versions['products'][product]
    fn = '{p}-{other[version]}.tar.{other[compress]}'.format(
        p=product, other=other)
    want_path = os.path.join(tardir, fn)
    dl_src = '{other[urlbase]}{slash}{fn}'.format(
        other=other, fn=fn,
        slash = '' if other['urlbase'].endswith('/') else '/')

    self.check_and_download(product, want_path, dl_src)
    p = Product()
    p.third_party = True
    p.name = p.filename_base = p.product = product
    p.ver = other['version']
    p.tarball = want_path
    p.dirname = other.get('dirname', '{p}-{other[version]}'.format(p=product, other=other))
    self.products[product] = p

  def fetch_file(self, url, outpath):
    print('\033[36;1mFetching <{}>\033[0m'.format(url), flush=True)
    r = requests.get(url, stream=True)
    r.raise_for_status()
    with open(outpath, 'wb') as fd:
      for chunk in r.iter_content(chunk_size=4096):
        fd.write(chunk)
    self._fetched.append(outpath)

  def build_each(self):
    for product_name in self.ordered:
      # TODO: use the repo spec to check an existing repo server's contents
      # instead of requiring the pkg be present on local FS
      # install that if not depending upon something we've had to recompile,
      # else if it exists but we have had to recompile a dep then auto-bump the
      # pkgver suffix and build anyway.
      # Also: figure out how to keep those pkgvers in sync across N OSes, if doing that way.
      pkgpath = self._pkg_generated_pathname(self.products[product_name])
      if os.path.exists(pkgpath):
        print('\033[36mAlready have: \033[1m{}\033[0m  \033[36;3m{}\033[0m'.format(product_name, pkgpath), flush=True)
        self.install_package(self.products[product_name], pkgpath)
        continue
      print('\033[36mExpecting to create: \033[3m{}\033[0m'.format(pkgpath), flush=True)
      self.build_one(product_name)

  def _normalize_list(self, items):
    return list(map(lambda s: s.replace('#{prefix}', self.configures['prefix']), items))

  def _some_file_for_stage(self, product, stage, prefix):
    return os.path.join(
        os.path.expanduser(self.options.base_dir),
        '.{prefix}.{p.name}.{stage}'.format(p=product, stage=stage, prefix=prefix))

  def _flagfile_for_stage(self, product, stage):
    # _could_ use inspect module to auto-determine stage, but prefer slightly less magic
    return self._some_file_for_stage(product, stage, 'done')

  def _stdout_for_stage(self, product, stage):
    return self._some_file_for_stage(product, stage, 'stdout')

  def _stderr_for_stage(self, product, stage):
    return self._some_file_for_stage(product, stage, 'stderr')

  def _record_done_stage(self, product, stage, content=None):
    with open(self._flagfile_for_stage(product, stage), 'w') as fh:
      if content is None:
        content = datetime.datetime.now().isoformat()
      print(content, file=fh)

  def _have_done_stage(self, product, stage, want_content=False):
    if not want_content:
      return os.path.exists(self._flagfile_for_stage(product, stage))
    try:
      return list(map(lambda s: s.rstrip(), open(self._flagfile_for_stage(product, stage)).readlines()))
    except:
      return None

  def _print_already(self, stagename):
    print('\033[34mAlready: \033[3m{}\033[0m'.format(stagename), flush=True)

  def build_one(self, product_name):
    if product_name not in self.configures['packages']:
      raise Error('missing configure information for {!r}'.format(product_name))
    params = self._normalize_list(self.configures['common_params'] + self.configures['packages'][product_name].get('params', []))
    envs = self._normalize_list(self.configures['packages'][product_name].get('env', []))
    if 'sometimes' in self.configures['packages'][product_name]:
      for chunk in self.configures['packages'][product_name]['sometimes']:
        if 'boxes' not in chunk:
          continue
        if self.options.boxname not in chunk['boxes']:
          print('\033[35mWe are {!r} and that is not found in boxes constraints for this chunk'.format(self.options.boxname), flush=True)
          continue
        params += self._normalize_list(chunk.get('params', []))
        envs += self._normalize_list(chunk.get('env', []))
    print('\033[36;1mBuild: \033[3m{}\033[0m'.format(product_name), flush=True)
    product = self.products[product_name]
    self.ensure_clear_for(product)
    self.untar(product, product.tarball, product.dirname)
    try:
      os.chdir(product.dirname)
      self.patch(product)
      self.run_configure(product, params, envs)
      tmp = self.install_temptree(product)
      self.prepackage_fixup(product, tmp)
      pkg_path = self.package(product, tmp)
      self.install_package(product, pkg_path) # need for later packages to build
    finally:
      os.chdir(os.path.expanduser(self.options.base_dir))

  def ensure_clear_for(self, product):
    if product.name not in self.mutually_excluded:
      print('\033[38;5;49mNo packages defined as conflicting with {!r}\033[0m'.format(product.name), flush=True)
      return
    saw_conflict = []
    for disallow in self.mutually_excluded[product.name]:
      if disallow == product.name:
        continue
      if disallow in self.installed:
        saw_conflict.append(disallow)
        print('\033[31mConflicting package for {p.name!r} installed: \033[1m{c!r}\033[0m'.format(
          p=product, c=disallow), flush=True)
        self.uninstall(self.products[disallow])
    if saw_conflict:
      print('\033[38;5;49mPackage {p.name!r} in set [{s}]; uninstalled: [{u}]'.format(
        p=product, s=' '.join(self.mutually_excluded[product.name]), u=' '.join(saw_conflict)), flush=True)
    else:
      print('\033[38;5;49mNo packages conflicting with {p.name!r} were installed [set: {s}]\033[0m'.format(
        p=product, s=' '.join(self.mutually_excluded[product.name])), flush=True)


  def untar(self, product, tarball, expected_dirname):
    STAGENAME = 'untar'
    if self._have_done_stage(product, STAGENAME):
      self._print_already(STAGENAME)
      return
    subprocess.check_call(['tar', '-xf', tarball],
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    if not os.path.isdir(expected_dirname):
      raise Error('Missing expected dir {!r} from {!r}'.format(expected_dirname, tarball))
    self._record_done_stage(product, STAGENAME)

  def patch(self, product):
    print('warning: patching unimplemented so far (YAGNI until you do)', file=sys.stderr, flush=True)

  def run_configure(self, product, params, envs):
    STAGENAME = 'configure'
    if self._have_done_stage(product, STAGENAME):
      self._print_already(STAGENAME)
      return
    newenv = os.environ.copy()
    for e in envs:
      try:
        k, v = e.split('=', 1)
        if v:
          newenv[k] = v
        else:
          del newenv[k]
      except ValueError:
        del newenv[e]
    with open(self._stdout_for_stage(product, STAGENAME), 'wb') as stdout:
      with open(self._stderr_for_stage(product, STAGENAME), 'wb') as stderr:
        subprocess.check_call(['./configure'] + params,
            stdout=stdout, stderr=stderr, stdin=open(os.devnull, 'r'),
            env=newenv)
    self._record_done_stage(product, STAGENAME)

  def install_temptree(self, product):
    """Returns the tree where the content is."""
    STAGENAME = 'tmpinstall'
    already = self._have_done_stage(product, STAGENAME, want_content=True)
    if already:
      self._print_already(STAGENAME)
      return already[0]
    pattern = 'pkgbuild.{}.'.format(product.filename_base)
    tree = tempfile.mkdtemp(prefix=pattern)
    # We deliberately never delete the tree;
    # leave the installs around until VM destruction.
    with open(self._stdout_for_stage(product, STAGENAME), 'wb') as stdout:
      with open(self._stderr_for_stage(product, STAGENAME), 'wb') as stderr:
        subprocess.check_call(['make', 'install', 'DESTDIR='+tree],
            stdout=stdout, stderr=stderr, stdin=open(os.devnull, 'r'))
    self._record_done_stage(product, STAGENAME, content=tree)
    return tree

  def prepackage_fixup(self, product, temp_tree):
    STAGENAME = 'prepackage-fixup'
    if self._have_done_stage(product, STAGENAME):
      self._print_already(STAGENAME)
      return
    fixup_list = list(map(lambda s: s.replace('#{temp_tree}', temp_tree),
      self._normalize_list(self.configures['packages'][product.name].get('fixups', []))))
    for fixup in fixup_list:
      subprocess.check_call(fixup, shell=True,
          stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    self._record_done_stage(product, STAGENAME)

  def _pkg_full_version(self, product):
    overrides = self.other_versions['overrides'].get(product.name, {})
    pkgver = str(overrides.get('pkg_version', '1'))  # protect against `3` where expected `"3"`
    return '{p.ver}-{opts.pkg_version_ext}{pkgver}'.format(
        p=product, opts=self.options, pkgver=pkgver)

  def _pkg_generated_pathname(self, product):
    # This depends upon the -p option to `fpm` in .package(), but fpm does interpolation.
    # FIXME: _amd_64.deb hardcoded:
    return os.path.join(self.options.results_dir,
      self.options.pkg_prefix + '-' + product.filename_base + '_' + self._pkg_full_version(product) + '_amd64.deb'
      )

  def package(self, product, temp_tree):
    STAGENAME = 'package'
    already = self._have_done_stage(product, STAGENAME, want_content=True)
    if already:
      self._print_already(STAGENAME)
      return already[0]
    with open('.rbenv-gemsets', 'w') as f:
      print('fpm', file=f)
    full_version = self._pkg_full_version(product)
    cmdline = [
      'fpm',
      '-s', 'dir',
      '-t', PACKAGE_TYPES[self.options.ostype],
      '-m', self.options.pkg_email,
      '-p', os.path.join(self.options.results_dir, 'NAME_FULLVERSION_ARCH.EXTENSION'),
      '-C', temp_tree,
      '-x', os.path.join(self.configures['prefix'].lstrip(os.path.sep), 'share', 'info', 'dir'),
      '-n', self.options.pkg_prefix + '_' + product.filename_base,
      '-v', full_version,
      ]
    for depname in self.direct_needs[product.name]:
      cmdline.append('-d')
      cmdline.append(self.options.pkg_prefix + '_' + depname)
    for dep in self.configures['packages'][product.name].get('os-deps', {}).get(self.options.ostype, []):
      cmdline.append('-d')
      cmdline.append(dep)
    cmdline.append(os.path.normpath(self.configures['prefix']).lstrip(os.path.sep).split(os.path.sep)[0]) # aka: 'opt'
    subprocess.check_call(cmdline,
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    pkgname = self._pkg_generated_pathname(product)
    self._record_done_stage(product, STAGENAME, content=pkgname)
    return pkgname

  def install_package(self, product, pkgpath):
    STAGENAME = 'install_pkg'
    if self._have_done_stage(product, STAGENAME):
      self._print_already(STAGENAME)
      return
    subprocess.check_call([PKG_INSTALL_CMD, pkgpath],
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    self._record_done_stage(product, STAGENAME)
    self.installed.add(product.name)

  def uninstall(self, product):
    # should we nuke stagenames for this product?
    subprocess.check_call([PKG_UNINSTALL_CMD, self.options.pkg_prefix + '-' + product.filename_base],
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))

  def report(self):
    print('\nFetched {} files'.format(len(self._fetched)), end='')
    if self._fetched:
      print(':')
      for f in self._fetched:
        short = f.rsplit('/', 1)[-1]
        print('  {}'.format(short))
    else:
      print('.')
    print('Installed {} files'.format(len(self.installed)), end='')
    if self.installed:
      print(':')
      for p in sorted(self.installed):
        print('  {}'.format(p))
    else:
      print('.')

def _main(args, argv0):
  parser = argparse.ArgumentParser(
      description=__doc__,
      formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('--base-dir',
                      type=str, default=BASE_DIR,
                      help='Where to work [%(default)s]')
  parser.add_argument('--dependencies-file',
                      type=str, default=DEPENDENCIES_FN,
                      help='Filename with pairs of dependencies therein [%(default)s]')
  parser.add_argument('--mutex-file',
                      type=str, default=MUTEX_FN,
                      help='File where each line is names of packages which can\'t be installed together [%(default)s]')
  parser.add_argument('--swdb-file',
                      type=str, default=SWDB_FN,
                      help='Filename of downloaded & verified swdb list [%(default)s]')
  parser.add_argument('--tarballs-dir',
                      type=str, default=TARBALLS_DIR,
                      help='Where tarballs might be and will be cached (r/w) [%(default)s]')
  parser.add_argument('--patches-dir',
                      type=str, default=PATCHES_DIR,
                      help='Where patches can be found [%(default)s]')
  parser.add_argument('--versions-file',
                      type=str, default=VERSIONS_FN,
                      help='Filename of version config for 3rd-party sw [%(default)s]')
  parser.add_argument('--configures-file',
                      type=str, default=CONFIGURES_FN,
                      help='Filename of configure instructions [%(default)s]')
  parser.add_argument('--gpg',
                      type=str, default='gpg',
                      help='gpg command to use [%(default)s]')
  parser.add_argument('--gnupg-trust-model',
                      type=str, default='direct',
                      help='GnuPG trust model to use [%(default)s]')
  parser.add_argument('--pkg-install-cmd',
                      type=str, default=PKG_INSTALL_CMD,
                      help='Command to install a package [%(default)s]')
  parser.add_argument('--mirror',
                      type=str, default=os.environ.get('MIRROR', MIRROR_URL),
                      help='GnuPG download mirror [%(default)s]')
  parser.add_argument('--results-dir',
                      type=str, default=os.environ.get('PACKAGES_OUT_DIR', RESULTS_DIR),
                      help='Where built packages are dropped')
  parser.add_argument('--pkg-email',
                      type=str, default=os.environ.get('PKG_EMAIL', PKG_EMAIL),
                      help='Email for packages [%(default)s]')
  parser.add_argument('--pkg-prefix',
                      type=str, default=os.environ.get('PKG_PREFIX', PKG_PREFIX),
                      help='Prefix for packages [%(default)s]')
  parser.add_argument('--pkg-version-ext',
                      type=str, default=os.environ.get('PKG_VERSIONEXT', PKG_VERSIONEXT),
                      help='Version suffix base for packages [%(default)s]')
  parser.add_argument('--ostype',
                      type=str, choices=PACKAGE_TYPES.keys(), default='debian-family',
                      help='OS type for various packaging defaults')
  parser.add_argument('--prepare-outside',
                      action='store_true', default=False,
                      help='Do stuff we want outside the VMs')
  parser.add_argument('--run-inside',
                      action='store_true', default=False,
                      help='Only stuff we want inside the VMs')  # added as noop, but Vagrant uses, so is available as a guard
  parser.add_argument('--boxname',
                      type=str, default=os.environ.get('PT_BOX_NAME', platform.node()),
                      help='Box name for conditional flags')

  options = parser.parse_args(args=args)

  # will double-expand `~` if the shell already did that; acceptable.
  os.chdir(os.path.expanduser(options.base_dir))

  plan = BuildPlan(options)
  plan.process_swdb()
  plan.process_versions_conf()
  plan.process_configures()

  plan.ensure_have_each()

  if options.prepare_outside:
    plan.report()
    return

  print('FIXME: load in patch-levels, load in per-product patch paths!', flush=True)
  plan.build_each()

  #json.dump(plan.products, fp=sys.stdout, indent=2, cls=OurJSONEncoder)
  #print()
  plan.report()

  return 0

if __name__ == '__main__':
  argv0 = sys.argv[0].rsplit('/')[-1]
  rv = _main(sys.argv[1:], argv0=argv0)
  sys.exit(rv)

# vim: set ft=python sw=2 expandtab :
