#!/usr/bin/env ruby
require 'io/console'
require 'json'
require 'optparse'
require 'pathname'
require 'set'
require 'shellwords'

require_relative 'support'

$options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: build-docker [<specific-target> ...]"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    $options[:verbose] = v
  end
  opts.on("-l", "--list", "List known targets and exit") do |v|
    $options[:list] = true
  end
  opts.on("--[no-]skip-os-update", "Skip OS update") do |v|
    $options[:skip_os_update] = true
  end
  opts.on("-k", "--[no-]keep-failed-builds", "Do not delete container for failed builds") do |v|
    $options[:keep_failed_builds] = true
  end
end.parse!

# support.rb
source_site_env

def banner(title, big: false)
  @columns ||= IO.console.winsize[1]
  @start ||= STDOUT.isatty ? "\e[36;1m" : ''
  @end ||= STDOUT.isatty ? "\e[m" : ''
  if big
    # We are in the middle of a Very Large amount of text, we really want to stand out a lot.
    # Obnoxiously so, if need be: should be visible when scrolling through terminal history at speed.
    # ╭─╮       ╭─╮ ╭─╮   🮮
    # ├─┤ title ├─┼─┼─┼───┤
    # 🮮 └───────┘ └─┘ └───┘
    repeat_count = (@columns - title.length - 7) / 4
    right_pad = (@columns - title.length - 7) % 4
    puts "#{@start}╭─╮" + (" " * (title.length + 2)) + ("╭─╮ " * repeat_count) + (" " * right_pad) + "🮮"
    puts "├─┤ #{title} ├─┼─" + ("┼─┼─" * (repeat_count-1)) + ("─" * right_pad) + "┤"
    puts "🮮 └" + ("─" * (title.length + 2)) + ("┘ └─" * repeat_count) + ("─" * right_pad) + "┘#{@end}"
  else
    # Same as the publish-packages.rb implementation
    puts "#{@start}───┤ #{title} ├" + ("─" * (@columns - title.length - 8)) + "#{@end}"
  end
end

class MissingDockerImagesError < StandardError; end

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

$asset_indir = ENV["PT_GNUPG_IN"] || "./in"
# Triggers local environmental actions such as configuring home cache; this
# should become somewhat less kludgy.
$enable_ptlocal = ENV["NAME"] == "Phil Pennock"

def find_usable_image(wanted_name)
  candidates = $PTCONTAINERS.select{|c| c.name == wanted_name}
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
    raise MissingDockerImagesError, "#{spec.name}: tried #{spec.image_list}"
  end

  return spec, image
end

def run_container(wanted_name)
  spec, image = find_usable_image(wanted_name)

  generated_assets_dir = Pathname("./out/#{spec.name}")
  if ! generated_assets_dir.exist?
    generated_assets_dir.mkdir
  end
  generated_assets_dir = generated_assets_dir.realpath.to_path


  container_id = nil
  build_succeeded = false
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
    if ! $options[:skip_os_update]
      bash_commands += ["os/update.#{spec.base_script}.sh"]
    end
    if ! spec.repo.nil?
      bash_commands += [
        "os/gnupg-repos.#{spec.base_script}.sh '#{spec.repo}'"
      ]
    end

    presetup_cmd = 'vscripts/user.presetup.sh'
    deps_cmd = "vscripts/deps.py --ostype #{spec.base_script} --boxname #{spec.name} --run-inside"

    if ! spec.gpg_command.nil?
      presetup_cmd = "env GPG=#{spec.gpg_command} #{presetup_cmd}"
      deps_cmd += " --gpg '#{spec.gpg_command}'"
    end

    bash_commands += [presetup_cmd]
    bash_commands += [deps_cmd]

#    bash_commands += [
#      'kill -1 1',   # most reliable shutdown method
#    ]

    # If debugging this script and you don't want to actually run the docker
    # container, and a failure is okay, then just add -n to the flags to bash
    d_run_argv += [ '/bin/bash', '-c', bash_commands.join(' && ')]
    $stderr.puts "+ #{d_run_argv.shelljoin}\n"
    IO.popen(d_run_argv) do |out|
      container_id = out.read
      container_id.rstrip!
    end
    puts "[#{spec.name}] running #{image}: #{container_id}"
    # There is a race here, we're going to lose the very first output.
    # Thus we sleep first.
    if not system("docker", "attach", container_id)
      return false
    end

    if not system("docker", "wait", container_id)
      return false
    end

    build_succeeded = true
    return true

  ensure
    if ! container_id.nil?
      if build_succeeded || ! $options[:keep_failed_builds]
        puts "[#{spec.name}] killing container (#{image}): #{container_id}"
        system("docker", "rm", container_id)
      end
    end
  end

end

if $options[:list]
  $pt_seen_containers.sort.each do |c|
    puts c
  end
  exit 0
end

ARGV.concat($pt_seen_containers.sort) if ARGV.length == 0

# First pass through, validate them all before the human wanders away and comes
# back later to discover things died unexpectedly early.
all_names_okay = true
valid_names = []
invalid_names = []
ARGV.each do |name|
  banner "validate: #{name}"
  if !$pt_seen_containers.include?(name)
    raise "no valid docker images for building: #{name}"
  end
  begin
    spec, image = find_usable_image(name)
    valid_names += [name]
  rescue MissingDockerImagesError => exception
    invalid_names += [name]
    all_names_okay = false
    $stderr.puts("[#{name}] docker pre-check failed: #{$!}")
  end
end

if ! all_names_okay
  $stderr.puts("aborting, without running any valid container builds")
  $stderr.puts("Okay at Docker level    : #{valid_names}")
  $stderr.puts("Missing at Docker level : #{invalid_names}")
  exit 1
end

succeeded = []
failed = []
ARGV.each do |name|
  banner name, big: true
  if run_container name
    succeeded.append(name)
  else
    failed.append(name)
  end
end

puts "Done with any builds.  Success: #{succeeded.length}  Failure: #{failed.length}"
puts "  Success: #{succeeded.join(' ')}"
puts "  Failure: #{failed.join(' ')}"

if !failed.empty?
  exit 1
end

puts """
Invoke publish-packages.rb to copy files to repos.
That will prompt for a PGP passphrase, if key is so protected.
That has a timeout.  So be ready.

"""
