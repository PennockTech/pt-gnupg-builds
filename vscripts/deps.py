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
import subprocess
import sys
import tempfile

import requests

# All defaults which should be overrideable with flags.
BASE_DIR = '~/src'
DEPENDENCIES_FN = '/vagrant/confs/dependencies.tsort-in'
SWDB_FN = './swdb.lst'
TARBALLS_DIR = '/in'
RESULTS_DIR = '/out'
PATCHES_DIR = '/vagrant/patches'
VERSIONS_FN = '/vagrant/confs/versions.json'
CONFIGURES_FN = '/vagrant/confs/configures.json'
MIRROR_URL = 'https://www.gnupg.org/ftp/gcrypt/'
PKG_EMAIL = 'pdp@pennock-tech.com' # FIXME before even think about going public
PKG_PREFIX = 'optgnupg'
PKG_VERSIONEXT = 'pdp'  # FIXME
INSTALL_CMD = ['sudo', 'dpkg', '-i'] # FIXME

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

  def process_swdb(self, fn=None):
    if fn is None:
      fn = self.options.swdb_file
    self.product_list = []
    p = None
    for l in open(fn):
      prod_attr, value = l.strip().split()
      if '_w32' in prod_attr:
        continue
      prod, attr = prod_attr.split('_', 1)
      # pragmatic tears here
      if prod == 'libgpg' and attr.startswith('error_'):
        prod = 'libgpg_error'
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
    print('\033[36m{}\033[0m'.format(name))
    for ext in ('', '.sig'):
      path_name = want_path + ext
      if not os.path.exists(path_name):
        self.fetch_file(dl_src + ext, path_name)

    subprocess.check_call('gpg --trust-model direct --verify'.split() + [want_path + ext],
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
    print('Fetching <{}>'.format(url))
    r = requests.get(url, stream=True)
    r.raise_for_status()
    with open(outpath, 'wb') as fd:
      for chunk in r.iter_content(chunk_size=4096):
        fd.write(chunk)

  def build_each(self):
    for product_name in self.ordered:
      print('FIXME: check for existing package at right patch-level')
      self.build_one(product_name)

  def _normalize_list(self, items):
    return list(map(lambda s: s.replace('#{prefix}', self.configures['prefix']), items))

  def _flagfile_for_stage(self, product, stage):
    # _could_ use inspect module to auto-determine stage, but prefer slightly less magic
    return os.path.join(
      os.path.expanduser(self.options.base_dir),
      '.done.{p.name}.{stage}'.format(p=product, stage=stage))

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
    print('\033[34mAlready: \033[3m{}\033[0m'.format(stagename))

  def build_one(self, product_name):
    if product_name not in self.configures['packages']:
      raise Error('missing configure information for {!r}'.format(product_name))
    params = self._normalize_list(self.configures['common_params'] + self.configures['packages'][product_name].get('params', []))
    envs = self._normalize_list(self.configures['packages'][product_name].get('env', []))
    print('\033[36;1mBuild: \033[3m{}\033[0m'.format(product_name))
    product = self.products[product_name]
    self.untar(product, product.tarball, product.dirname)
    try:
      os.chdir(product.dirname)
      self.patch(product)
      self.run_configure(product, params, envs)
      tmp = self.install_temptree(product)
      pkg_path = self.package(product, tmp)
      self.install_package(product, pkg_path) # need for later packages to build
    finally:
      os.chdir(os.path.expanduser(self.options.base_dir))

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
    print('warning: patching unimplemented so far (YAGNI until you do)', file=sys.stderr)

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
    subprocess.check_call(['./configure'] + params,
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'),
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
    subprocess.check_call(['make', 'install', 'DESTDIR='+tree],
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    self._record_done_stage(product, STAGENAME, content=tree)
    return tree

  def package(self, product, temp_tree):
    STAGENAME = 'package'
    already = self._have_done_stage(product, STAGENAME, want_content=True)
    if already:
      self._print_already(STAGENAME)
      return already[0]
    with open('.rbenv-gemsets', 'w') as f:
      print('fpm', file=f)
    full_version = product.ver + '-' + self.options.pkg_version_ext + '1'  # FIXME handle counter bumps
    cmdline = [
      'fpm',
      '-s', 'dir',
      '-t', 'deb', # FIXME when not debs
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
    cmdline.append(os.path.normpath(self.configures['prefix']).lstrip(os.path.sep).split(os.path.sep)[0]) # aka: 'opt'
    subprocess.check_call(cmdline,
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    pkgname = os.path.join(self.options.results_dir,
      self.options.pkg_prefix + '-' + product.filename_base + '_' + full_version + '_amd64.deb'  # FIXME
      )
    self._record_done_stage(product, STAGENAME, content=pkgname)
    return pkgname

  def install_package(self, product, pkgpath):
    STAGENAME = 'install_pkg'
    if self._have_done_stage(product, STAGENAME):
      self._print_already(STAGENAME)
      return
    subprocess.check_call(INSTALL_CMD + [pkgpath],
        stdout=sys.stdout, stderr=sys.stderr, stdin=open(os.devnull, 'r'))
    self._record_done_stage(product, STAGENAME)


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
  parser.add_argument('--mirror',
                      type=str, default=os.environ.get('MIRROR', MIRROR_URL),
                      help='GnuPG download mirror [%(default)s]')
  parser.add_argument('--results-dir',
                      type=str, default=os.environ.get('PACKAGES_OUT_DIR', RESULTS_DIR),
                      help='Where built packages are dropped')
  parser.add_argument('--pkg-email',
                      type=str, default=PKG_EMAIL,
                      help='Email for packages [%(default)s]')
  parser.add_argument('--pkg-prefix',
                      type=str, default=PKG_PREFIX,
                      help='Prefix for packages [%(default)s]')
  parser.add_argument('--pkg-version-ext',
                      type=str, default=PKG_VERSIONEXT,
                      help='Version suffix base for packages [%(default)s]')
  options = parser.parse_args(args=args)

  # will double-expand `~` if the shell already did that; acceptable.
  os.chdir(os.path.expanduser(options.base_dir))

  plan = BuildPlan(options)
  plan.process_swdb()
  plan.process_versions_conf()
  plan.process_configures()

  plan.ensure_have_each()
  print('FIXME: load in patch-levels, load in per-product patch paths!')
  plan.build_each()

  #json.dump(plan.products, fp=sys.stdout, indent=2, cls=OurJSONEncoder)
  #print()

  return 0

if __name__ == '__main__':
  argv0 = sys.argv[0].rsplit('/')[-1]
  rv = _main(sys.argv[1:], argv0=argv0)
  sys.exit(rv)

# vim: set ft=python sw=2 expandtab :
