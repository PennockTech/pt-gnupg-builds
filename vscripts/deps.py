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
import json
import os
import subprocess
import sys

import requests

# All defaults which should be overrideable with flags.
BASE_DIR = '~/src'
DEPENDENCIES_FN = '/vagrant/dependencies.tsort-in'
SWDB_FN = './swdb.lst'
TARBALLS_DIR = '/in'
VERSIONS_FN = '/vagrant/versions.json'
MIRROR_URL = 'https://www.gnupg.org/ftp/gcrypt/'

class Error(Exception):
  """Base class for exceptions from build."""
  pass


class Product(object):
  __slots__ = [
      'name', 'ver', 'date', 'size', 'sha1', 'sha2', 'branch', 'sha1_gz',
      'product', 'filename_base',
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
    for l in open(fn):
      before, after = l.strip().split()
      if before == after:
        continue
      self.needs[after].add(before)
    for k in self.ordered:
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

  def fetch_file(self, url, outpath):
    r = requests.get(url, stream=True)
    r.raise_for_status()
    with open(outpath, 'wb') as fd:
      for chunk in r.iter_content(chunk_size=4096):
        fd.write(chunk)

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
  parser.add_argument('--versions-file',
                      type=str, default=VERSIONS_FN,
                      help='Filename of version config for 3rd-party sw [%(default)s]')
  parser.add_argument('--mirror',
                      type=str, default=os.environ.get('MIRROR', MIRROR_URL),
                      help='GnuPG download mirror [%(default)s]')
  parser.add_argument('-v', '--verbose',
                      action='count', default=0,
                      help='Be more verbose')
  options = parser.parse_args(args=args)

  # will double-expand `~` if the shell already did that; acceptable.
  os.chdir(os.path.expanduser(options.base_dir))

  plan = BuildPlan(options)
  plan.process_swdb()
  plan.process_versions_conf()

  plan.ensure_have_each()

  #json.dump(plan.products, fp=sys.stdout, indent=2, cls=OurJSONEncoder)
  #print()

  return 0

if __name__ == '__main__':
  argv0 = sys.argv[0].rsplit('/')[-1]
  rv = _main(sys.argv[1:], argv0=argv0)
  sys.exit(rv)

# vim: set ft=python sw=2 expandtab :
