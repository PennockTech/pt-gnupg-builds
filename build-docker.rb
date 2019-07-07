#!/usr/bin/env ruby
require 'json'
require 'optparse'
require 'pathname'
require 'set'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: DockerTargets [<specific-target> ...]"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    options[:verbose] = v
  end
end.parse!

def env_want?(varname)
  value = ENV.fetch(varname) { "" }
  return !value.empty?
end

def source_site_env
  previous = Hash[`bash -c 'printenv --null'`.split("\x00").map{ |kv| kv.split('=', 2) }]
  `bash -c '. ./site-local.env; printenv --null'`.split("\x00").each{ |kv|
    k, v = kv.split('=', 2)
    if !previous.has_key?(k) || previous[k] != v
      case k
      when 'SHLVL'
      else
        ENV[k] = v
      end
    end
  }
end
source_site_env

# Passed onto the actual build invocation.
$vbuild_env = {
  # Canonical would be: https://www.gnupg.org/ftp/gcrypt/
  'MIRROR': ENV['PT_GNUPG_DOWNLOAD_MIRROR'] || 'https://www.mirrorservice.org/sites/ftp.gnupg.org/gcrypt/'
}
ENV.select {|k,v| k.start_with?('PKG_')}.each do |k,v|
  case k
  when 'PKG_CONFIG_PATH'
    nil
  else
    $vbuild_env[k] = v
  end
end
if ENV.has_key?('PT_INITIAL_DEPLOY')
  $vbuild_env['PT_INITIAL_DEPLOY'] = ENV['PT_INITIAL_DEPLOY']
end


class PTBuild
  attr_reader :name, :image_list, :base_script, :repo
  @@optional_fields = :box_version_pin, :comment
  attr_reader *@@optional_fields
  def initialize(name, image_list, base_script, repo)
    @name = name
    @image_list = image_list
    @base_script = base_script
    @repo = repo
  end
end

PTCONTAINERS = []
pt_seen_containers = Set.new
TopDir = %x(git rev-parse --show-toplevel).chomp
JSON.load(open(TopDir + '/confs/machines.json')).each do |m|
  m.has_key?('docker') or next
  raise "duplicate definition for #{m['name']}" if pt_seen_containers.include?(m['name'])
  ptb = PTBuild.new(m['name'], m['docker'], m['base_script'], m['repo'])
  PTBuild.class_variable_get(:@@optional_fields).each { |optional|
    if m.has_key?(optional.to_s)
      atattr = '@' + optional.to_s
      puts "OPTIONAL on #{m['name']}: SET #{optional} TO: #{m[optional.to_s]}" if options[:verbose]
      ptb.instance_variable_set(atattr, m[optional.to_s])
    end
  }
  PTCONTAINERS << ptb
  pt_seen_containers.add(m['name'])
end

$asset_indir = ENV["PT_GNUPG_IN"] || "./in"
# Triggers local environmental actions such as configuring home cache; this
# should become somewhat less kludgy.
$enable_ptlocal = ENV["NAME"] == "Phil Pennock"

def run_container(wanted_name)
  candidates = PTCONTAINERS.select{|c| c.name == wanted_name}
  if candidates.length == 0
    raise "Found 0 matches for #{wanted_name}"
  elsif candidates.length > 1
    raise "Bug: found more than one match for #{wanted_name}"
  end
  spec = candidates[0]

  if env_want?('PT_SKIP_BUILD')
    puts "[#{spec.name}] skipping build because PT_SKIP_BUILD set"
    return
  end

  puts "[#{spec.name}] image candidates #{spec.image_list}"
  image = nil

  spec.image_list.each do |candidate|
    args = %w/docker image inspect/ + [candidate]
    if system(*args, 1=>"/dev/null", 2=>1)
      image = candidate
      break
    end
  end

  if image.nil?
    raise "Docker has none of those images preloaded; load one manually please"
  end

  generated_assets_dir = Pathname("./out/#{spec.name}")
  if ! generated_assets_dir.exist?
    generated_assets_dir.mkdir
  end
  generated_assets_dir = generated_assets_dir.realpath.to_path


  container_id = nil
  begin
    d_run_argv = ["docker", "run", "-dt"]
    $vbuild_env.each do |k, v|
      d_run_argv += ['-e', k.to_s + '=' + v]
    end
    #d_run_argv += ['-v', Pathname($asset_indir).realpath.to_path + ':/in']
    #d_run_argv += ['-v', generated_assets_dir + ':/out']
    #d_run_argv += ['-v', Pathname('.').realpath.to_path + ':/vagrant',
    d_run_argv += ['--mount', "type=bind,src=#{Pathname($asset_indir).realpath.to_path},dst=/in,readonly"]
    d_run_argv += ['--mount', "type=bind,src=#{generated_assets_dir},dst=/out"]
    d_run_argv += ['--mount', "type=bind,src=#{Pathname('.').realpath.to_path},dst=/vagrant,readonly"]
    d_run_argv += ['-w', '/vagrant']
    d_run_argv += [image]
    bash_commands = []
    # We detach, print info, then attach; give that a moment to reduce how much
    # output we lose (but it doesn't really matter if we do lose output, as
    # long as things are otherwise working).
    bash_commands += ['sleep 1']

    if $enable_ptlocal and File.exists?("os/ptlocal.#{spec.base_script}.sh")
      bash_commands += ["os/ptlocal.#{spec.base_script}.sh"]
    end
    bash_commands += ["os/update.#{spec.base_script}.sh"]
    if ! spec.repo.nil?
      bash_commands += [
        "os/gnupg-repos.#{spec.base_script}.sh #{spec.repo}"
      ]
    end
    bash_commands += ['vscripts/user.presetup.sh']
    bash_commands += ["vscripts/deps.py --ostype #{spec.base_script} --boxname #{spec.name} --run-inside"]
#    bash_commands += [
#      'kill -1 1',   # most reliable shutdown method
#    ]

    d_run_argv += [ '/bin/bash', '-c', bash_commands.join(' && ')]
    puts "#{d_run_argv}\n"
    IO.popen(d_run_argv) do |out|
      container_id = out.read
      container_id.rstrip!
    end
    puts "[#{spec.name}] running #{image}: #{container_id}"
    # There is a race here, we're going to lose the very first output.
    # Thus we sleep first.
    system("docker", "attach", container_id)
    # XXX

    system("docker", "wait", container_id)

  ensure
    if ! container_id.nil?
      puts "[#{spec.name}] killing container (#{image}): #{container_id}"
      system("docker", "rm", container_id)
    end
  end

end

def deploy_one(build_name)
  if env_want?('PT_SKIP_DEPLOY')
    puts "[#{build_name}] skipping deploy-to-reposerver because PT_SKIP_DEPLOY set"
    return
  end
  raise "unimplemented"
  # FIXME FIXME: for now, can _deploy_ with the shell script.
end

def deploy_deferred
  raise "unimplemented"
end

ARGV.concat(pt_seen_containers.sort) if ARGV.length == 0

ARGV.each do |name|
  if !pt_seen_containers.include?(name)
    raise "unknown container name: #{name}"
  end
  run_container name
end

if !env_want?('PT_SKIP_DEPLOY') && !env_want?('PT_SKIP_GPGDELAY_PROMPT')
  puts """
Done with any builds, going to copy/deploy packages into repos.
This will prompt for a PGP passphrase, if key is so protected.
That has a timeout.  So be ready.

"""
  print 'Hit enter when ready ...'
  $stdout.flush
  STDIN.gets
end

if !Pathname('~/.aws/config').expand_path.exist?
  #raise "missing ~/.aws/config"
end

ARGV.each do |name|
  deploy_one name
end
deploy_deferred
