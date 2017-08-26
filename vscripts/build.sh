#!/bin/sh -eu

env > /out/debug.env.$(hostname).log
/vagrant/vscripts/deps.py > /out/debug.$(hostname).log
