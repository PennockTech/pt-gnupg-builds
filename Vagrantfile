# Vagrantfile for building GnuPG packages; currently Xenial-specific.

# https://docs.vagrantup.com

class PTBuild
  attr_reader :name, :box, :base_script
  def initialize(name, box, base_script)
    @name = name
    @box = box  # https://app.vagrantup.com/boxes/search
    @base_script = base_script
  end
end

PTBOXES = [
  PTBuild.new("xenial", "ubuntu/xenial64", "debian-family"),
  PTBuild.new("jessie", "debian/jessie64", "debian-family"),
]

Vagrant.configure("2") do |config|
  # In each box, this directory is exposed as /vagrant, read-write
  # We can't reboot during provision
  #
  # If we define provision steps at this outer layer, they're run before
  # any at the inner layer, thus we can't have per-OS init before common
  # build stages.  So instead, we make it a one-liner to do each step.

  PTBOXES.each do |ptb|
    config.vm.define ptb.name, autostart: false do |node|
      node.vm.box = ptb.box

      # intended for stuff like configuring apt caches, very local
      # open to better ways of doing this
      if ENV["NAME"] == "Phil Pennock"
        if File.exists?("os/ptlocal.#{ptb.base_script}.sh")
          node.vm.provision "shell", path: "os/ptlocal.#{ptb.base_script}.sh"
        end
      end

      # core OS update and prep for Doing Things
      node.vm.provision "shell", path: "os/update.#{ptb.base_script}.sh"

      # actual package building to go here
    end
  end

end

# vim: set ft=ruby :
