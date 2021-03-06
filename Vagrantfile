# Vagrantfile for building GnuPG packages; currently Xenial-specific.

# https://docs.vagrantup.com

class PTBuild
  attr_reader :name, :box, :base_script, :repo
  @@optional_fields = :box_version_pin, :comment
  attr_reader *@@optional_fields
  def initialize(name, box, base_script, repo)
    @name = name
    @box = box  # https://app.vagrantup.com/boxes/search
    @base_script = base_script
    @repo = repo
  end
end

PTMACHINES = []
pt_seen_machines = Set.new
TopDir = %x(git rev-parse --show-toplevel).chomp
JSON.load(open(TopDir + '/confs/machines.json')).each do |m|
  m.has_key?('box') or next   # box for Vagrant, other keys for other implementations
  raise "duplicate definition for #{m['name']}" if pt_seen_machines.include?(m['name'])
  ptb = PTBuild.new(m['name'], m['box'], m['base_script'], m['repo'])
  PTBuild.class_variable_get(:@@optional_fields).each { |optional|
    if m.has_key?(optional.to_s)
      atattr = '@' + optional.to_s
      #puts "OPTIONAL on #{m['name']}: SET #{optional} TO: #{m[optional.to_s]}"
      ptb.instance_variable_set(atattr, m[optional.to_s])
    end
  }
  PTMACHINES << ptb
  pt_seen_machines.add(m['name'])
end

asset_indir = ENV["PT_GNUPG_IN"] || "./in"

# Triggers local environmental actions such as configuring home cache; this
# should become somewhat less kludgy.
enable_ptlocal = ENV["NAME"] == "Phil Pennock"

# Passed onto the actual build invocation.
vbuild_env = {
  # Canonical would be: https://www.gnupg.org/ftp/gcrypt/
  'MIRROR': ENV['PT_GNUPG_DOWNLOAD_MIRROR'] || 'https://www.mirrorservice.org/sites/ftp.gnupg.org/gcrypt/'
}
ENV.select {|k,v| k.start_with?('PKG_')}.each do |k,v|
  case k
  when 'PKG_CONFIG_PATH'
    nil
  else
    vbuild_env[k] = v
  end
end
if ENV.has_key?('PT_INITIAL_DEPLOY')
  vbuild_env['PT_INITIAL_DEPLOY'] = ENV['PT_INITIAL_DEPLOY']
end

Vagrant.configure("2") do |config|
  # In each machine, this directory is exposed as /vagrant, read-write
  # On _some_ OSes, writes propagate back to us.
  #
  # We can't reboot during provision
  #
  # If we define provision steps at this outer layer, they're run before
  # any at the inner layer, thus we can't have per-OS init before common
  # build stages.  So instead, we make it a one-liner to do each step.

  config.vm.provider "virtualbox" do |v|
    v.memory = 4096
    v.cpus = 2
  end

  PTMACHINES.each do |ptb|
    # contents synced _back_ via build script, but should also sync outwards to enable cached re-use
    generated_assets_dir = "./out/#{ptb.name}"

    config.vm.define ptb.name, autostart: false do |node|
      node.vm.box = ptb.box

      unless ptb.box_version_pin.nil?
        node.vm.box_version = ptb.box_version_pin
      end

      # only ever _add_ files to /in, never delete; assume large binaries which never have
      # small deltas.  Copy only on demand, don't stomp on things mid-script.
      config.vm.synced_folder "#{asset_indir}/", "/in", create: true, type: "rsync",
        rsync__args: ["--verbose", "--rsync-path='sudo rsync'", "--archive", "--checksum", "--whole-file"],
        rsync__auto: false

      # TODO: support AWS/GCE/whatever as well as local images
      #
      # There are provenance chain issues for GnuPG built remotely, but as long
      # as we're using public base images there's really not a big difference.
      # If you're very cautious then you'll want to adjust the .box field of
      # each VM in the list above.

      # intended for stuff like configuring apt caches, very local
      if enable_ptlocal and File.exists?("os/ptlocal.#{ptb.base_script}.sh")
        node.vm.provision "shell", path: "os/ptlocal.#{ptb.base_script}.sh", name: "pennocktech-local"
      end

      # core OS update and prep for Doing Things
      node.vm.provision "shell", path: "os/update.#{ptb.base_script}.sh", name: "os-update"
      #
      # apt/whatever site-local setup for fetching existing packages
      if !ptb.repo.nil?
        node.vm.provision "shell" do |s|
          s.name = "gnupg-repo-setup"
          s.path = "os/gnupg-repos.#{ptb.base_script}.sh"
          s.args = [ptb.repo]
          s.env = vbuild_env
        end
      end

      # directory made in OS update and chowned to normal user, do not need/want sudo
      # but don't want to copy any logfiles in
      if File.exists?(generated_assets_dir)
        config.vm.synced_folder "#{generated_assets_dir}/", "/out", create: false, type: "rsync",
          rsync__args: ["--verbose", "--archive", "--checksum", "--whole-file", "--exclude=*.log"],
          rsync__auto: false
      end
      # XXX: synced folders are all done before shell steps, depsite order
      # here, and /out is created in a shell step and chowned to the correct user, and the above
      # is done with no sudo ... so probably should not have worked.
      #
      # I'm guessing that there's some synced_folder rsync framework which
      # pre-creates the directory so that things worked anyway?

      node.vm.provision "shell", path: "vscripts/user.presetup.sh", privileged: false, name: "user-presetup", env: vbuild_env

      node.vm.provision "shell" do |s|
        s.name = "build"
        s.path = "vscripts/deps.py"
        s.privileged = false
        s.args = ['--ostype', ptb.base_script, '--boxname', ptb.name, '--run-inside']
        s.env = vbuild_env
      end
    end
  end

end

# vim: set ft=ruby :
