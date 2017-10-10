require 'linux_admin'

class ApplianceEmbeddedAnsible < EmbeddedAnsible
  TOWER_VERSION_FILE     = "/var/lib/awx/.tower_version".freeze
  SETUP_SCRIPT           = "ansible-tower-setup".freeze
  SECRET_KEY_FILE        = "/etc/tower/SECRET_KEY".freeze
  SETTINGS_FILE          = "/etc/tower/settings.py".freeze
  EXCLUDE_TAGS           = "packages,migrations,firewall".freeze
  HTTP_PORT              = 54_321
  HTTPS_PORT             = 54_322

  def self.available?
    return false unless MiqEnvironment::Command.is_appliance?
    required_rpms = Set["ansible-tower-server", "ansible-tower-setup"]
    required_rpms.subset?(LinuxAdmin::Rpm.list_installed.keys.to_set)
  end

  def start
    if configured? && !upgrade?
      update_proxy_settings
      services.each { |service| LinuxAdmin::Service.new(service).start.enable }
    else
      configure_secret_key
      run_setup_script(EXCLUDE_TAGS)
    end

    5.times do
      return if alive?

      _log.info("Waiting for EmbeddedAnsible to respond")
      sleep WAIT_FOR_ANSIBLE_SLEEP
    end

    raise "EmbeddedAnsible service is not responding after setup"
  end

  def stop
    services.each { |service| LinuxAdmin::Service.new(service).stop }
  end

  def disable
    services.each { |service| LinuxAdmin::Service.new(service).stop.disable }
  end

  def running?
    services.all? { |service| LinuxAdmin::Service.new(service).running? }
  end

  def configured?
    return false unless File.exist?(SECRET_KEY_FILE)
    return false unless setup_completed?

    key = miq_database.ansible_secret_key
    key.present? && key == File.read(SECRET_KEY_FILE)
  end

  def api_connection
    api_connection_raw("localhost", HTTP_PORT)
  end

  private

  def upgrade?
    local_tower_version != tower_rpm_version
  end

  def services
    AwesomeSpawn.run!("source /etc/sysconfig/ansible-tower; echo $TOWER_SERVICES").output.split
  end

  def run_setup_script(exclude_tags)
    json_extra_vars = {
      :minimum_var_space  => 0,
      :http_port          => HTTP_PORT,
      :https_port         => HTTPS_PORT,
      :tower_package_name => "ansible-tower-server"
    }.to_json

    with_inventory_file do |inventory_file_path|
      params = {
        "--"         => nil,
        :extra_vars= => json_extra_vars,
        :inventory=  => inventory_file_path,
        :skip_tags=  => exclude_tags
      }
      AwesomeSpawn.run!(SETUP_SCRIPT, :params => params)
    end
    write_setup_complete_file
  rescue AwesomeSpawn::CommandResultError => e
    _log.error("EmbeddedAnsible setup script failed with: #{e.message}")
    miq_database.ansible_secret_key = nil
    FileUtils.rm_f(setup_complete_file)
    raise
  end

  def with_inventory_file
    file = Tempfile.new("miq_inventory")
    begin
      file.write(inventory_file_contents)
      file.close
      yield(file.path)
    ensure
      file.unlink
    end
  end

  def configure_secret_key
    key = miq_database.ansible_secret_key
    if key.present?
      File.write(SECRET_KEY_FILE, key)
    else
      AwesomeSpawn.run!("/usr/bin/python -c \"import uuid; file('#{SECRET_KEY_FILE}', 'wb').write(uuid.uuid4().hex)\"")
      miq_database.ansible_secret_key = File.read(SECRET_KEY_FILE)
    end
  end

  def update_proxy_settings
    current_contents = File.read(SETTINGS_FILE)
    new_contents = current_contents.gsub(/^.*AWX_TASK_ENV\['(HTTPS?_PROXY|NO_PROXY)'\].*$/, "")

    proxy_uri = VMDB::Util.http_proxy_uri(:embedded_ansible) || VMDB::Util.http_proxy_uri
    if proxy_uri
      new_contents << "\n" unless new_contents.end_with?("\n")
      new_contents << "AWX_TASK_ENV['HTTP_PROXY'] = '#{proxy_uri}'\n"
      new_contents << "AWX_TASK_ENV['HTTPS_PROXY'] = '#{proxy_uri}'\n"
      new_contents << "AWX_TASK_ENV['NO_PROXY'] = '127.0.0.1'\n"
    end
    File.write(SETTINGS_FILE, new_contents)
  end

  def generate_admin_authentication
    miq_database.set_ansible_admin_authentication(:password => generate_password)
  end

  def generate_rabbitmq_authentication
    miq_database.set_ansible_rabbitmq_authentication(:password => generate_password)
  end

  def generate_database_authentication
    auth = miq_database.set_ansible_database_authentication(:password => generate_password)
    database_connection.select_value("CREATE ROLE #{database_connection.quote_column_name(auth.userid)} WITH LOGIN PASSWORD #{database_connection.quote(auth.password)}")
    database_connection.select_value("CREATE DATABASE awx OWNER #{database_connection.quote_column_name(auth.userid)} ENCODING 'utf8'")
    auth
  end

  def inventory_file_contents
    admin_auth    = miq_database.ansible_admin_authentication || generate_admin_authentication
    rabbitmq_auth = miq_database.ansible_rabbitmq_authentication || generate_rabbitmq_authentication
    database_auth = miq_database.ansible_database_authentication || generate_database_authentication
    db_config     = Rails.configuration.database_configuration[Rails.env]

    <<-EOF.strip_heredoc
      [tower]
      localhost ansible_connection=local

      [database]

      [all:vars]
      admin_password='#{admin_auth.password}'

      pg_host='#{db_config["host"] || "localhost"}'
      pg_port='#{db_config["port"] || "5432"}'

      pg_database='awx'
      pg_username='#{database_auth.userid}'
      pg_password='#{database_auth.password}'

      rabbitmq_port=5672
      rabbitmq_vhost=tower
      rabbitmq_username='#{rabbitmq_auth.userid}'
      rabbitmq_password='#{rabbitmq_auth.password}'
      rabbitmq_cookie=cookiemonster
      rabbitmq_use_long_name=false
      rabbitmq_enable_manager=false
    EOF
  end

  def generate_password
    SecureRandom.base64(18).tr("+/", "-_")
  end

  def database_connection
    ActiveRecord::Base.connection
  end

  def local_tower_version
    File.read(TOWER_VERSION_FILE).strip
  end

  def tower_rpm_version
    LinuxAdmin::Rpm.info("ansible-tower-server")["version"]
  end

  def write_setup_complete_file
    FileUtils.touch(setup_complete_file)
  end

  def setup_completed?
    File.exist?(setup_complete_file)
  end

  def setup_complete_file
    Rails.root.join("tmp", "embedded_ansible_setup_complete")
  end

  def miq_database
    MiqDatabase.first
  end
end
