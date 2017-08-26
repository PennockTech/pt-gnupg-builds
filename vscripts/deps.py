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

BASE_DIR = '~/src'
# could just move to invoking tsort ourselves
DEPENDENCIES_FN = '/vagrant/dependencies.tsort-in'
SWDB_FN = './swdb.lst'

class Error(Exception):
  """Base class for exceptions from build."""
  pass


class Product(object):
  __slots__ = ['name', 'ver', 'date', 'size', 'sha1', 'sha2', 'branch', 'sha1_gz']
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
  def __init__(self, depends_fn):
    self._get_depends(depends_fn)

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

  def process_swdb(self, fn):
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
      if p is not None and p.name != prod:
        self.product_list.append(p)
        p = None
      if p is None:
        p = Product()
        p.name = prod
      setattr(p, attr, value)
    if p is not None:
      self.product_list.append(p)
    self.products = {}
    for p in self.product_list:
      if p in self.products:
        raise Error('revisited {} after moving on'.format(p.name))
      self.products[p.name] = p


def _main(args, argv0):
  parser = argparse.ArgumentParser(
      description=__doc__,
      formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('-v', '--verbose',
                      action='count', default=0,
                      help='Be more verbose')
  options = parser.parse_args(args=args)

  os.chdir(os.path.expanduser(BASE_DIR))

  plan = BuildPlan(DEPENDENCIES_FN)
  plan.process_swdb(SWDB_FN)

  json.dump(plan.products, fp=sys.stdout, indent=2, cls=OurJSONEncoder)
  print()

  return 0

if __name__ == '__main__':
  argv0 = sys.argv[0].rsplit('/')[-1]
  rv = _main(sys.argv[1:], argv0=argv0)
  sys.exit(rv)

# vim: set ft=python sw=2 expandtab :
