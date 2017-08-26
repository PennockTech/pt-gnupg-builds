# Vagrantfile for building GnuPG packages; currently Xenial-specific.

# https://docs.vagrantup.com

Vagrant.configure("2") do |config|
  # https://app.vagrantup.com/boxes/search
  config.vm.box = "ubuntu/xenial64"

  # Note that "./" is automatically synced to "/vagrant", read-write
  # So this is unneeded, instead `/vagrant/vscripts`
  #config.vm.synced_folder "./vscripts", "/vagrant_scripts"

  config.vm.provision "shell", inline: <<-SHELL
    umask 022
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
    pt_apt_get() { apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" "$@"; }
    rm -f /etc/timezone
    echo UTC > /etc/timezone
    dpkg-reconfigure tzdata
    unset TZ
    pt_apt_get update
    pt_apt_get dist-upgrade
    pt_apt_get autoremove
    dpkg -l | grep '^rc' | awk '{ print $2 }' | xargs apt-get --assume-yes purge
  SHELL
  # we can't reboot during vagrant provision
end

# vim: set ft=ruby :
