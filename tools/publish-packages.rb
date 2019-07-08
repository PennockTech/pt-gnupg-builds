#!/usr/bin/env ruby
require 'json'
require 'optparse'
require 'pathname'

require_relative 'support'

Options = {
  :copy => true,
  :invalidate => true
}
OptionParser.new do |opts|
  opts.banner = "Usage: publish-packages [<specific-target> ...]"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    Options[:verbose] = v
  end

  opts.on("--initial", "Initial deploy for machine; do extra setup") do |v|
    Options[:initial] = v
  end

  opts.on("--[no-]copy", "Don't copy files into aptly") do |v|
    Options[:copy] = v
  end

  opts.on("--[no-]invalidate", "Don't CloudFront invalidate") do |v|
    Options[:invalidate] = v
  end
end.parse!

SEEN_BASE_SCRIPTS = {}
DEFERRED_DEPLOY_TARGETS = {}

def deploy_one(build_name)
  if env_want?('PT_SKIP_DEPLOY')
    puts "[#{build_name}] skipping deploy-to-reposerver because PT_SKIP_DEPLOY set"
    return
  end

  build = $PTCONTAINERS.select {|x| x.name == build_name}.first
  base_script = build.base_script || 'default'

  deploy = Pathname("#{$TopDir}/os/deploy.#{base_script}.sh")
  can_batch = Pathname("#{$TopDir}/os/deploy.#{base_script}.can-batch")

  if ! deploy.exist?
    puts "[#{build.name}] no deploy script (wanted: #{deploy.relative_path_from $TopDir})"
    return
  end

  dep_argv = [deploy.to_path, build.name]
  if Options[:initial]
    dep_argv += ['-initial']
  end

  if can_batch.exist?
    # This bit I think was intended as protection against multiple builds
    # falling back to 'default' but ... so what?
    # This needs a rethink.
    if SEEN_BASE_SCRIPTS.has_key?(base_script)
      if SEEN_BASE_SCRIPTS[base_script] != deploy.to_path
        raise "[#{build.name}] mismatch in base command for #{base_script}: #{SEEN_BASE_SCRIPTS[base_script]} vs #{deploy.to_path}"
      end
      SEEN_BASE_SCRIPTS[base_script] = deploy.to_path
    end

    if !DEFERRED_DEPLOY_TARGETS.has_key?(base_script)
      DEFERRED_DEPLOY_TARGETS[base_script] = []
    end
    DEFERRED_DEPLOY_TARGETS[base_script] << build.name
    dep_argv += ['-copy-only']
  end

  if Options[:copy]
    system(*dep_argv)
    case $?
    when 0
      puts "[#{build.name}] deploy succeeded"
    when 3
      puts "[#{build.name}] deploy FAILED _but_ indicated non-fatal"
    else
      puts "[#{build.name}] deploy FAILED exiting #{$?}"
      puts " ... beware, we might have abandoned cleanup for earlier deploys" # FIXME
      exit $?.to_i
    end
  end

  if Options[:invalidate]
    if !can_batch.exist?
      system("#{$TopDir}/tools/caching_invalidate", build.name)
    end
  end

end

def deploy_deferred
  if env_want?('PT_SKIP_DEPLOY')
    return
  end

  if SEEN_BASE_SCRIPTS.empty?
    puts "no deferred deploys"
    return
  end

  invalidate = []
  for group in SEEN_BASE_SCRIPTS.keys.sort
    system(SEEN_BASE_SCRIPTS[group], '-deferred', *DEFERRED_DEPLOY_TARGETS[group])
    invalidate << DEFERRED_DEPLOY_TARGETS[group]
  end

  system("#{$TopDir}/tools/caching_invalidate", *invalidate)
end

if !Pathname('~/.aws/config').expand_path.exist?
  #raise "missing ~/.aws/config"
end

ARGV.concat($pt_seen_containers.sort) if ARGV.length == 0

ARGV.each do |name|
  if !$pt_seen_containers.include?(name)
    # Don't raise, just mention it, so that deploy_deferred will still run.
    # Could use exception handling instead, but not much reason here.
    puts "unknown container name: #{name}"
    continue
  end

  deploy_one name
end
deploy_deferred

