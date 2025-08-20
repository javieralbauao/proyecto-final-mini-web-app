# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|

  config.vm.define :servidorWeb do |servidorWeb|
    servidorWeb.vm.box = "bento/ubuntu-22.04"
	
    servidorWeb.vm.network :private_network, ip: "192.168.60.3"
    
	servidorWeb.vm.network "forwarded_port", guest: 80,   host: 80,   auto_correct: true
    servidorWeb.vm.network "forwarded_port", guest: 443,  host: 443,  auto_correct: true
    servidorWeb.vm.network "forwarded_port", guest: 9090, host: 9090, auto_correct: true  # Prometheus
    servidorWeb.vm.network "forwarded_port", guest: 9100, host: 9100, auto_correct: true  # Node Exporter
    servidorWeb.vm.network "forwarded_port", guest: 3000, host: 3000, auto_correct: true  # Grafana
	
	servidorWeb.vm.provision "file", source: "webapp", destination: "/home/vagrant/webapp"
    servidorWeb.vm.provision "file", source: "init.sql", destination: "/home/vagrant/init.sql"
    servidorWeb.vm.provision "shell", path: "script.sh"
    servidorWeb.vm.hostname = "servidorWeb"
  end
end