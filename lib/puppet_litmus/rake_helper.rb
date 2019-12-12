# frozen_string_literal: true

module PuppetLitmus; end # rubocop:disable Style/Documentation

# helper methods for the litmus rake tasks
module PuppetLitmus::RakeHelper
  DEFAULT_CONFIG_DATA ||= { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }.freeze
  VALID_PROVISIONERS ||= %w[abs docker docker_exp vagrant vmpooler].freeze

  # Gets a string representing the operating system and version.
  #
  # @param metadata [Hash] metadata to parse for operating system info
  # @return [String] the operating system string with version info for use in provisioning.
  def get_metadata_operating_systems(metadata)
    return unless metadata.is_a?(Hash)
    return unless metadata['operatingsystem_support'].is_a?(Array)

    metadata['operatingsystem_support'].each do |os_info|
      next unless os_info['operatingsystem'] && os_info['operatingsystemrelease']

      os_name = case os_info['operatingsystem']
                when 'Amazon', 'Archlinux', 'AIX', 'OSX'
                  next
                when 'OracleLinux'
                  'oracle'
                when 'Windows'
                  'win'
                else
                  os_info['operatingsystem'].downcase
                end

      os_info['operatingsystemrelease'].each do |release|
        version = case os_name
                  when 'ubuntu', 'osx'
                    release.sub('.', '')
                  when 'sles'
                    release.gsub(%r{ SP[14]}, '')
                  when 'win'
                    release = release.delete('.') if release.include? '8.1'
                    release.sub('Server', '').sub('10', '10-pro')
                  else
                    release
                  end

        yield "#{os_name}-#{version.downcase}-x86_64".delete(' ')
      end
    end
  end

  # Executes a command on the test runner.
  #
  # @param command [String] command to execute.
  # @return [Object] the standard out stream.
  def run_local_command(command)
    require 'open3'
    stdout, stderr, status = Open3.capture3(command)
    error_message = "Attempted to run\ncommand:'#{command}'\nstdout:#{stdout}\nstderr:#{stderr}"
    raise error_message unless status.to_i.zero?

    stdout
  end

  # Builds all the modules in a specified module
  #
  # @param source_folder [String] the folder to get the modules from
  # @return [Array] an array of module tar's
  def build_modules_in_folder(source_folder)
    folder_list = Dir.entries(source_folder).reject { |f| File.directory? f }
    module_tars = []
    folder_list.each do |folder|
      file = File.new(File.join(source_folder, folder))
      next if File.symlink?(file)

      opts = {}
      opts[:module_dir] = file.path
      opts[:'target-dir'] = File.join(Dir.pwd, 'pkg')
      opts[:force] = true
      # remove old build folder if exists, before we build afresh
      FileUtils.rm_rf(builder.build_dir) if File.directory?(builder.build_dir)

      # build_module
      module_tar = build_module(opts)
      module_tars.push(File.new(module_tar))
    end
    module_tars
  end

  def provision(provisioner, platform, inventory_vars)
    require 'bolt_spec/run'
    include BoltSpec::Run
    raise "the provision module was not found in #{DEFAULT_CONFIG_DATA['modulepath']}, please amend the .fixtures.yml file" unless
      File.directory?(File.join(DEFAULT_CONFIG_DATA['modulepath'], 'provision'))

    unless VALID_PROVISIONERS.include?(provisioner)
      raise "Unknown provisioner '#{provisioner}', try #{VALID_PROVISIONERS.join('/')}"
    end

    params = if inventory_vars.nil?
               { 'action' => 'provision', 'platform' => platform, 'inventory' => Dir.pwd }
             else
               { 'action' => 'provision', 'platform' => platform, 'inventory' => Dir.pwd, 'vars' => inventory_vars }
             end
    PuppetLitmus.bolt.run_task("provision::#{provisioner}", 'localhost', params, config: DEFAULT_CONFIG_DATA, inventory: nil)
  end

  def provision_list(provision_hash, key)
    provisioner = provision_hash[key]['provisioner']
    inventory_vars = provision_hash[key]['vars']
    # Splat the params into environment variables to pass to the provision task but only in this runspace
    provision_hash[key]['params']&.each { |k, value| ENV[k.upcase] = value.to_s }
    results = []
    provision_hash[key]['images'].each do |image|
      results << provision(provisioner, image, inventory_vars)
    end
    results
  end

  def tear_down_nodes(targets, inventory_hash)
    require 'bolt_spec/run'
    include BoltSpec::Run
    config_data = { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }
    raise "the provision module was not found in #{config_data['modulepath']}, please amend the .fixtures.yml file" unless File.directory?(File.join(config_data['modulepath'], 'provision'))

    results = {}
    targets.each do |node_name|
      next if node_name == 'litmus_localhost'

      result = tear_down(node_name, inventory_hash)
      results[node_name] = result unless result == []
    end
    results
  end

  def tear_down(node_name, inventory_hash)
    # how do we know what provisioner to use
    node_facts = facts_from_node(inventory_hash, node_name)
    return [] unless VALID_PROVISIONERS.include?(node_facts['provisioner'])

    params = { 'action' => 'tear_down', 'node_name' => node_name, 'inventory' => Dir.pwd }
    PuppetLitmus.bolt.run_task("provision::#{node_facts['provisioner']}", 'localhost', params, config: DEFAULT_CONFIG_DATA, inventory: nil)
  end

  def install_agent(collection, targets, inventory_hash)
    require 'bolt_spec/run'
    include BoltSpec::Run
    params = if collection.nil?
               {}
             else
               { 'collection' => collection }
             end
    raise "puppet_agent was not found in #{DEFAULT_CONFIG_DATA['modulepath']}, please amend the .fixtures.yml file" unless File.directory?(File.join(DEFAULT_CONFIG_DATA['modulepath'], 'puppet_agent'))

    PuppetLitmus.bolt.run_task('puppet_agent::install', targets, params, config: DEFAULT_CONFIG_DATA, inventory: inventory_hash)
  end

  def configure_path(inventory_hash)
    results = []
    # fix the path on ssh_nodes
    unless inventory_hash['groups'].select { |group| group['name'] == 'ssh_nodes' }.size.zero?
      results = PuppetLitmus.bolt.run_command('echo PATH="$PATH:/opt/puppetlabs/puppet/bin" > /etc/environment',
                                              'ssh_nodes', config: nil, inventory: inventory_hash)
    end
    results
  end

  def build_module(opts)
    # old cli_way
    # pdk_build_command = 'bundle exec pdk build  --force'
    # stdout, stderr, _status = Open3.capture3(pdk_build_command)
    # raise "Failed to run 'pdk_build_command',#{stdout} and #{stderr}" if (stderr =~ %r{completed successfully}).nil?
    require 'pdk/module/build'
    require 'pdk/util'

    builder = PDK::Module::Build.new(opts)
    builder.build
  end

  def install_module(inventory_hash, target_node_name, module_tar)
    require 'bolt_spec/run'
    include BoltSpec::Run
    target_nodes = find_targets(inventory_hash, target_node_name)
    target_string = if target_node_name.nil?
                      'all'
                    else
                      target_node_name
                    end
    run_local_command("bundle exec bolt file upload \"#{module_tar}\" /tmp/#{File.basename(module_tar)} --nodes #{target_string} --inventoryfile inventory.yaml")
    install_module_command = "puppet module install /tmp/#{File.basename(module_tar)}"
    PuppetLitmus.bolt.run_command(install_module_command, target_nodes, config: nil, inventory: inventory_hash)
  end

  def metadata_module_name
    require 'json'
    raise 'Could not find metadata.json' unless File.exist?(File.join(Dir.pwd, 'metadata.json'))

    metadata = JSON.parse(File.read(File.join(Dir.pwd, 'metadata.json')))
    raise 'Could not read module name from metadata.json' if metadata['name'].nil?

    metadata['name']
  end

  def uninstall_module(inventory_hash, target_node_name, module_to_remove = nil)
    require 'bolt_spec/run'
    include BoltSpec::Run
    module_name = module_to_remove || metadata_module_name
    target_nodes = find_targets(inventory_hash, target_node_name)
    install_module_command = "puppet module uninstall #{module_name}"
    PuppetLitmus.bolt.run_command(install_module_command, target_nodes, config: nil, inventory: inventory_hash)
  end
end
