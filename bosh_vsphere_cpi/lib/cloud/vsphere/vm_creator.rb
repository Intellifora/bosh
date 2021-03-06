require 'ruby_vim_sdk'
require 'cloud/vsphere/drs_rules/drs_rule'
require 'cloud/vsphere/resources/disk/ephemeral_disk'

module VSphereCloud
  class VmCreator
    def initialize(memory, disk_size, cpu, placer, client, cloud_searcher, logger, cpi, agent_env, file_provider)
      @placer = placer
      @client = client
      @cloud_searcher = cloud_searcher
      @logger = logger
      @cpi = cpi
      @memory = memory
      @disk_size = disk_size
      @cpu = cpu
      @agent_env = agent_env
      @file_provider = file_provider

      @logger.debug("VM creator initialized with memory: #{@memory}, disk: #{@disk}, cpu: #{@cpu}, placer: #{@placer}")
    end

    def create(agent_id, stemcell_cid, networks, disk_cids, environment)
      stemcell_vm = @cpi.stemcell_vm(stemcell_cid)
      raise "Could not find stemcell: #{stemcell_cid}" if stemcell_vm.nil?

      stemcell_size =
        @cloud_searcher.get_property(stemcell_vm, VimSdk::Vim::VirtualMachine, 'summary.storage.committed', ensure_all: true)
      stemcell_size /= 1024 * 1024

      disks = @cpi.disk_spec(disk_cids)
      # need to include swap and linked clone log
      ephemeral = @disk_size + @memory + stemcell_size
      cluster, datastore = @placer.place(@memory, ephemeral, disks)

      name = "vm-#{@cpi.generate_unique_name}"
      @logger.info("Creating vm: #{name} on #{cluster.mob} stored in #{datastore.mob}")

      replicated_stemcell_vm = @cpi.replicate_stemcell(cluster, datastore, stemcell_cid)
      replicated_stemcell_properties = @cloud_searcher.get_properties(replicated_stemcell_vm, VimSdk::Vim::VirtualMachine,
                                                             ['config.hardware.device', 'snapshot'],
                                                             ensure_all: true)

      devices = replicated_stemcell_properties['config.hardware.device']
      snapshot = replicated_stemcell_properties['snapshot']

      config = VimSdk::Vim::Vm::ConfigSpec.new(memory_mb: @memory, num_cpus: @cpu)
      config.device_change = []

      system_disk = devices.find { |device| device.kind_of?(VimSdk::Vim::Vm::Device::VirtualDisk) }
      pci_controller = devices.find { |device| device.kind_of?(VimSdk::Vim::Vm::Device::VirtualPCIController) }

      ephemeral_disk = VSphereCloud::EphemeralDisk.new(@disk_size, name, datastore)
      ephemeral_disk_config = ephemeral_disk.create_spec(system_disk.controller_key)
      config.device_change << ephemeral_disk_config

      dvs_index = {}
      networks.each_value do |network|
        v_network_name = network['cloud_properties']['name']
        network_mob = @client.find_by_inventory_path([cluster.datacenter.name, 'network', v_network_name])
        nic_config = @cpi.create_nic_config_spec(v_network_name, network_mob, pci_controller.key, dvs_index)
        config.device_change << nic_config
      end

      nics = devices.select { |device| device.kind_of?(VimSdk::Vim::Vm::Device::VirtualEthernetCard) }
      nics.each do |nic|
        nic_config = @cpi.create_delete_device_spec(nic)
        config.device_change << nic_config
      end

      @cpi.fix_device_unit_numbers(devices, config.device_change)

      @logger.info("Cloning vm: #{replicated_stemcell_vm} to #{name}")

      task = @cpi.clone_vm(replicated_stemcell_vm,
                      name,
                      cluster.datacenter.vm_folder.mob,
                      cluster.resource_pool.mob,
                      datastore: datastore.mob, linked: true, snapshot: snapshot.current_snapshot, config: config)
      vm = @client.wait_for_task(task)

      begin
        vm_properties = @cloud_searcher.get_properties(vm, VimSdk::Vim::VirtualMachine, ['config.hardware.device'], ensure_all: true)
        devices = vm_properties['config.hardware.device']

        network_env = @cpi.generate_network_env(devices, networks, dvs_index)
        disk_env = @cpi.generate_disk_env(system_disk, ephemeral_disk_config.device)
        env = @cpi.generate_agent_env(name, vm, agent_id, network_env, disk_env)
        env['env'] = environment
        @logger.info("Setting VM env: #{env.pretty_inspect}")

        location = @cpi.get_vm_location(
          vm,
          datacenter: cluster.datacenter.name,
          datastore: datastore.name,
          vm: name
        )

        @agent_env.set_env(vm, location, env)

        @logger.info("Powering on VM: #{vm} (#{name})")
        @client.power_on_vm(cluster.datacenter.mob, vm)

        create_drs_rules(vm, cluster)
      rescue => e
        @logger.info("#{e} - #{e.backtrace.join("\n")}")
        @cpi.delete_vm(name)
        raise e
      end
      name
    end

    def create_drs_rules(vm, cluster)
      return unless @placer.drs_rules
      return if @placer.drs_rules.size == 0

      if @placer.drs_rules.size > 1
        raise 'vSphere CPI supports only one DRS rule per resource pool'
      end

      rule_config = @placer.drs_rules.first

      if rule_config['type'] != 'separate_vms'
        raise "vSphere CPI only supports DRS rule of 'separate_vms' type"
      end

      drs_rule = VSphereCloud::DrsRule.new(
        rule_config['name'],
        @client,
        @cloud_searcher,
        cluster.mob,
        @logger
      )
      drs_rule.add_vm(vm)
    end
  end
end
