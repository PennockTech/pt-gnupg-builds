# This is not a script; it's support routines
# This is far too sloppy to be a real library;
# please forgive my lack of Ruby experience.
#
# This project originally used Ruby because it extracted stuff from the
# Vagrantfile and it just stuck around and was used to replace creaky POSIX
# shell.  My Ruby programming is slow and frustrating.  But hey, this is a
# decent project to improve that.
#
# But I'm not putting it on my resume any time soon.

require 'json'
require 'set'

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

class PTBuild
  attr_reader :name, :image_list, :base_script, :repo
  @@optional_fields = :box_version_pin, :comment, :gpg_command
  attr_reader *@@optional_fields
  def initialize(name, image_list, base_script, repo)
    @name = name
    @image_list = image_list
    @base_script = base_script
    @repo = repo
  end
end

$PTCONTAINERS = []
$pt_seen_containers = Set.new
$TopDir = %x(git rev-parse --show-toplevel).chomp
JSON.load(open($TopDir + '/confs/machines.json')).each do |m|
  m.has_key?('docker') or next
  raise "duplicate definition for #{m['name']}" if $pt_seen_containers.include?(m['name'])
  ptb = PTBuild.new(m['name'], m['docker'], m['base_script'], m['repo'])
  PTBuild.class_variable_get(:@@optional_fields).each { |optional|
    if m.has_key?(optional.to_s)
      atattr = '@' + optional.to_s
      # Can't guard this on options[:verbose], options is not available to this lib
      #puts "OPTIONAL on #{m['name']}: SET #{optional} TO: #{m[optional.to_s]}"
      ptb.instance_variable_set(atattr, m[optional.to_s])
    end
  }
  $PTCONTAINERS << ptb
  $pt_seen_containers.add(m['name'])
end
