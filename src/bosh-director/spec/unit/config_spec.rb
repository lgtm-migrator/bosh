require 'spec_helper'
require 'fakefs/spec_helpers'

#
# This supplants the config_old_spec.rb behavior. We are
# moving class behavior to instance behavior.
#

describe Bosh::Director::Config do
  include FakeFS::SpecHelpers
  let(:test_config_path) { asset('test-director-config.yml') }
  let(:test_config) { YAML.safe_load(File.read(test_config_path)) }
  let(:temp_dir) { Dir.mktmpdir }
  let(:base_config) do
    blobstore_dir = File.join(temp_dir, 'blobstore')
    FileUtils.mkdir_p(blobstore_dir)

    config = YAML.safe_load(File.read(test_config_path))
    config['dir'] = temp_dir
    config['blobstore'] = {
      'provider' => 'local',
      'options' => {
        'blobstore_path' => blobstore_dir,
      },
    }
    config['snapshots']['enabled'] = true
    config
  end

  before do
    configure_fake_config_files(test_config_path)
  end

  describe 'initialization' do
    it 'loads config from a yaml file' do
      config = described_class.load_file(asset('test-director-config.yml'))
      expect(config.name).to eq('Test Director')
    end

    it 'loads config from a hash' do
      config = described_class.load_hash(test_config)
      expect(config.name).to eq('Test Director')
    end
  end

  describe 'director ips' do
    before do
      allow(Socket).to receive(:ip_address_list).and_return([
        instance_double(Addrinfo, ip_address: '127.0.0.1', ip?: true, ipv4_loopback?: true, ipv6_loopback?: false, ipv6_linklocal?: false),
        instance_double(Addrinfo, ip_address: '10.10.0.6',   ip?: true, ipv4_loopback?: false, ipv6_loopback?: false, ipv6_linklocal?: false),
        instance_double(Addrinfo, ip_address: '10.11.0.16',  ip?: true, ipv4_loopback?: false, ipv6_loopback?: false, ipv6_linklocal?: false),
        instance_double(Addrinfo, ip_address: '::1',         ip?: true, ipv4_loopback?: false, ipv6_loopback?: true,  ipv6_linklocal?: false),
        instance_double(Addrinfo, ip_address: 'fe80::%eth0', ip?: true, ipv4_loopback?: false, ipv6_loopback?: false, ipv6_linklocal?: true),
        instance_double(Addrinfo, ip_address: 'fd7a::',      ip?: true, ipv4_loopback?: false, ipv6_loopback?: false, ipv6_linklocal?: false),
      ])
    end

    it 'should select the non-loopback ips off of the the Socket class' do
      described_class.configure(test_config)
      expect(described_class.director_ips).to eq(['10.10.0.6', '10.11.0.16', 'fd7a::'])
    end
  end

  describe '#max_create_vm_retries' do
    context 'when hash has value set' do
      it 'returns the configuration value' do
        test_config['max_vm_create_tries'] = 3
        described_class.configure(test_config)
        expect(described_class.max_vm_create_tries).to eq(3)
      end
    end

    context 'when hash does not have value set' do
      it 'returns default value of five as per previous behavior' do
        # our fixture does not have this set so this is a no-op
        # i'm doing this because i want to be more explicit
        test_config.delete('max_vm_create_tries')
        described_class.configure(test_config)
        expect(described_class.max_vm_create_tries).to eq(5)
      end
    end

    context 'when hash contains a non integral value' do
      it 'raises an error' do
        test_config['max_vm_create_tries'] = 'bad number'
        expect do
          described_class.configure(test_config)
        end.to raise_error(ArgumentError)
      end
    end
  end

  describe '#flush_arp' do
    context 'when hash has value set' do
      it 'returns the configuration value' do
        test_config['flush_arp'] = true
        described_class.configure(test_config)
        expect(described_class.flush_arp).to eq(true)
      end
    end

    context 'when hash does not have value set' do
      it 'returns default value of false' do
        # our fixture does not have this set so this is a no-op
        # i'm doing this because the test we copied did it
        test_config.delete('flush_arp')
        described_class.configure(test_config)
        expect(described_class.flush_arp).to eq(false)
      end
    end
  end

  describe '#local_dns' do
    context 'when hash has value set' do
      it 'returns the configuration value' do
        test_config['local_dns']['enabled'] = true
        test_config['local_dns']['include_index'] = true
        test_config['local_dns']['use_dns_addresses'] = true
        described_class.configure(test_config)
        expect(described_class.local_dns_enabled?).to eq(true)
        expect(described_class.local_dns_include_index?).to eq(true)
        expect(described_class.local_dns_use_dns_addresses?).to eq(true)
      end
    end

    context 'when hash does not have value set' do
      it 'returns default value of false' do
        described_class.configure(test_config)
        expect(described_class.local_dns_enabled?).to eq(false)
        expect(described_class.local_dns_include_index?).to eq(false)
        expect(described_class.local_dns_use_dns_addresses?).to eq(false)
      end
    end
  end

  describe '#keep_unreachable_vms' do
    context 'when hash has value set' do
      it 'returns the configuration value' do
        test_config['keep_unreachable_vms'] = true
        described_class.configure(test_config)
        expect(described_class.keep_unreachable_vms).to eq(true)
      end
    end

    context 'when hash does not have value set' do
      it 'returns default value of false' do
        test_config.delete('keep_unreachable_vms')
        described_class.configure(test_config)
        expect(described_class.keep_unreachable_vms).to eq(false)
      end
    end
  end

  describe '#cpi_task_log' do
    before do
      described_class.configure(test_config)
      described_class.cloud_options['properties']['cpi_log'] = 'fake-cpi-log'
    end

    it 'returns cpi task log' do
      expect(described_class.cpi_task_log).to eq('fake-cpi-log')
    end
  end

  describe '#configure' do
    context 'logger' do
      let(:log_dir) { Dir.mktmpdir }
      let(:log_file) { File.join(log_dir, 'logfile') }
      after { FileUtils.rm_rf(log_dir) }

      context 'when the config specifies a file logger' do
        before { test_config['logging']['file'] = 'fake-file' }

        it 'configures the logger with a file appender' do
          appender = Logging::Appender.new('file')
          expect(Logging.appenders).to receive(:file).with(
            'Director',
            hash_including(filename: 'fake-file'),
          ).and_return(appender)
          described_class.configure(test_config)
        end
      end

      it 'filters out log message that are SELECT NULL' do
        test_config['logging']['file'] = log_file
        test_config['logging']['level'] = 'debug'

        described_class.configure(test_config)

        described_class.logger.debug('before')
        described_class.logger.debug('(10.01s) (conn: 123456789) SELECT NULL')
        described_class.logger.debug('after')

        log_contents = File.read(log_file)

        expect(log_contents).to include('before')
        expect(log_contents).to include('after')
        expect(log_contents).not_to include('SELECT NULL')
      end

      it 'redacts log messages containing INSERT queries' do
        test_config['logging']['file'] = log_file
        test_config['logging']['level'] = 'debug'

        described_class.configure(test_config)

        described_class.logger.debug('before')
        described_class.logger.debug(
          %((10.01s) (conn: 123456789) INSERT INTO "potatoface" ("diggity", "column2") VALUES ('alice', 'bob')),
        )
        described_class.logger.debug('after')

        log_contents = File.read(log_file)

        expect(log_contents).to include('before')
        expect(log_contents).to include('after')
        expect(log_contents).to include('INSERT INTO "potatoface" <redacted>')
      end

      it 'redacts log messages containing UPDATE queries' do
        test_config['logging']['file'] = log_file
        test_config['logging']['level'] = 'debug'

        described_class.configure(test_config)

        described_class.logger.debug('before')
        described_class.logger.debug(
          %((10.01s) (conn: 123456789) UPDATE "potatoface" SET "diggity" = 'bob', "column2" = 'alice', 'bob'),
        )
        described_class.logger.debug('after')

        log_contents = File.read(log_file)

        expect(log_contents).to include('before')
        expect(log_contents).to include('after')
        expect(log_contents).to include('UPDATE "potatoface" <redacted>')
      end
    end

    context 'when agent env specified' do
      let(:expected_agent_env) do
        {
          'blobstores' => [
            {
              'provider' => 'local',
              'options' => {
                'blobstore_path' => '/path/to/blobstore',
              },
            },
            {
              'provider' => 'local',
              'options' => {
                'blobstore_path' => '/path/to/blobstore',
              },
            },
          ],
        }
      end

      it 'parses agent env correctly' do
        described_class.configure(base_config)
        expect(described_class.agent_env).to eq(expected_agent_env)
      end
    end

    context 'config server' do
      context 'when enabled' do
        before do
          test_config['config_server'] = {
            'enabled' => true,
            'url' => 'https://127.0.0.1:8080',
            'ca_cert_path' => '/var/vcap/jobs/director/config/config_server_ca.cert',
          }

          test_config['config_server']['uaa'] = {
            'url' => 'fake-uaa-url',
            'client_id' => 'fake-client-id',
            'client_secret' => 'fake-client-secret',
            'ca_cert_path' => 'fake-uaa-ca-cert-path',
          }
        end

        it 'should have parsed out config server values' do
          described_class.configure(test_config)

          expect(described_class.config_server['url']).to eq('https://127.0.0.1:8080')
          expect(described_class.config_server['ca_cert_path']).to eq('/var/vcap/jobs/director/config/config_server_ca.cert')

          expect(described_class.config_server['uaa']['url']).to eq('fake-uaa-url')
          expect(described_class.config_server['uaa']['client_id']).to eq('fake-client-id')
          expect(described_class.config_server['uaa']['client_secret']).to eq('fake-client-secret')
          expect(described_class.config_server['uaa']['ca_cert_path']).to eq('fake-uaa-ca-cert-path')
        end

        context 'config server urls' do
          it 'should return an array of urls' do
            described_class.configure(test_config)
            config = Bosh::Director::Config.new(test_config)
            expect(config.config_server_urls).to eq(['https://127.0.0.1:8080'])
          end
        end

        context 'when url is not https' do
          before do
            test_config['config_server']['url'] = 'http://127.0.0.1:8080'
          end

          it 'errors' do
            expect {  described_class.configure(test_config) }.to raise_error(ArgumentError, 'Config Server URL should always be https. Currently it is http://127.0.0.1:8080')
          end
        end
      end

      context 'when disabled' do
        before do
          test_config['config_server_enabled'] = false
        end

        it 'should not have parsed out the values' do
          described_class.configure(test_config)

          expect(described_class.config_server).to eq('enabled' => false)
        end
      end
    end

    describe 'enable_nats_delivered_templates' do
      it 'defaults to false' do
        described_class.configure(test_config)
        expect(described_class.enable_nats_delivered_templates).to be_falsey
      end

      context 'when explicitly set' do
        context 'when set to true' do
          before { test_config['enable_nats_delivered_templates'] = true }

          it 'resolves to true' do
            described_class.configure(test_config)
            expect(described_class.enable_nats_delivered_templates).to be_truthy
          end
        end

        context 'when set to false' do
          before { test_config['enable_nats_delivered_templates'] = false }

          it 'resolves to false' do
            described_class.configure(test_config)
            expect(described_class.enable_nats_delivered_templates).to be_falsey
          end
        end
      end
    end

    describe 'allow_errands_on_stopped_instances' do
      it 'defaults to false' do
        described_class.configure(test_config)
        expect(described_class.allow_errands_on_stopped_instances).to be_falsey
      end

      context 'when explicitly set to true' do
        before do
          test_config['allow_errands_on_stopped_instances'] = true
        end

        it 'resolves to true' do
          described_class.configure(test_config)
          expect(described_class.allow_errands_on_stopped_instances).to be_truthy
        end
      end
    end

    describe 'director version' do
      it 'sets the expected version/revision' do
        described_class.configure(test_config)
        expect(described_class.revision).to match(/^[0-9a-f]{8}$/)
        expect(described_class.version).to eq('0.0.2')
      end
    end

    describe 'blobstore config fingerprint' do
      it 'returns the sha1 of the blobstore config' do
        described_class.configure(test_config)
        expect(described_class.blobstore_config_fingerprint).to eq('d8500dc13f23babb7f83d8ebd5995416544df6c1')

      end
    end

    describe 'nats config fingerprint' do
      it 'returns the sha1 of the nats config' do
        described_class.configure(test_config)
        expect(described_class.nats_config_fingerprint).to eq(Digest::SHA1.hexdigest("client_ca_certificate_pathclient_ca_private_key_pathserver_ca_path"))
      end
    end
  end

  describe '#identity_provider' do
    subject(:config) { Bosh::Director::Config.new(test_config) }
    let(:provider_options) do
      { 'blobstore_path' => blobstore_dir }
    end

    after { FileUtils.rm_rf(temp_dir) }

    describe 'authentication configuration' do
      let(:test_config) { base_config.merge('user_management' => { 'provider' => provider }) }

      context 'when no user_management config is specified' do
        let(:test_config) { base_config }

        it 'uses LocalIdentityProvider' do
          expect(config.identity_provider).to be_a(Bosh::Director::Api::LocalIdentityProvider)
        end
      end

      context 'when local provider is supplied' do
        let(:provider) { 'local' }

        it 'uses LocalIdentityProvider' do
          expect(config.identity_provider).to be_a(Bosh::Director::Api::LocalIdentityProvider)
        end
      end

      context 'when a bogus provider is supplied' do
        let(:provider) { 'wrong' }

        it 'should raise an error' do
          expect { config.identity_provider }.to raise_error(ArgumentError)
        end
      end

      context 'when uaa provider is supplied' do
        let(:provider) { 'uaa' }
        let(:provider_options) do
          { 'symmetric_key' => 'some-key', 'url' => 'some-url' }
        end
        let(:token) { CF::UAA::TokenCoder.new(skey: 'some-key').encode(payload) }
        let(:payload) do
          { 'user_name' => 'larry', 'aud' => ['bosh_cli'], 'scope' => ['bosh.admin'], 'jti' => 'some-jti' }
        end
        before { test_config['user_management']['uaa'] = provider_options }

        it 'creates a UAAIdentityProvider' do
          expect(config.identity_provider).to be_a(Bosh::Director::Api::UAAIdentityProvider)
        end

        it 'creates the UAAIdentityProvider with the configured key' do
          request_env = { 'HTTP_AUTHORIZATION' => "bearer #{token}" }
          user = config.identity_provider.get_user(request_env, {})
          expect(user.username).to eq('larry')
        end
      end
    end
  end

  describe '#root_domain' do
    context 'when no dns_domain is set in config' do
      let(:test_config) { base_config.merge('dns' => {}) }
      it 'returns bosh' do
        described_class.configure(test_config)
        expect(described_class.root_domain).to eq('bosh')
      end
    end

    context 'when dns_domain is set in config' do
      let(:test_config) { base_config.merge('dns' => { 'domain_name' => 'test-domain-name' }) }
      it 'returns the DNS domain' do
        described_class.configure(test_config)
        expect(described_class.root_domain).to eq('test-domain-name')
      end
    end
  end

  describe '#name' do
    subject(:config) { Bosh::Director::Config.new(test_config) }

    it 'returns the name specified in the config' do
      expect(config.name).to eq('Test Director')
    end
  end

  describe '#health_monitor_port' do
    subject(:config) { Bosh::Director::Config.new(test_config) }

    it 'returns the name specified in the config' do
      expect(config.health_monitor_port).to eq(12345)
    end
  end

  describe 'director_stemcell_owner deletagion' do
    let(:director_stemcell_owner) do
      double(
        Bosh::Director::DirectorStemcellOwner,
        stemcell_os: 'foo',
        stemcell_version: 'bar',
      )
    end

    before do
      Bosh::Director::Config.director_stemcell_owner = director_stemcell_owner
    end

    it 'delegates' do
      expect(Bosh::Director::Config.stemcell_os).to eq('foo')
      expect(director_stemcell_owner).to have_received(:stemcell_os)
      expect(Bosh::Director::Config.stemcell_version).to eq('bar')
      expect(director_stemcell_owner).to have_received(:stemcell_version)
    end
  end

  describe '#port' do
    subject(:config) { Bosh::Director::Config.new(test_config) }

    it 'returns the port specified in the config' do
      expect(config.port).to eq(8081)
    end
  end

  describe '#version' do
    subject(:config) { Bosh::Director::Config.new(test_config) }

    it 'returns the version specified in the config' do
      expect(config.version).to eq('0.0.2')
    end
  end

  describe '#agent_wait_timeout' do
    before { Bosh::Director::Config.configure(test_config) }

    it 'returns the version specified in the config' do
      expect(Bosh::Director::Config.agent_wait_timeout).to eq(1234)
    end
  end

  describe '#nats_rpc' do
    let(:some_client) { instance_double(Bosh::Director::NatsRpc) }

    before do
      described_class.configure(test_config)
    end

    it 'initializes a new nats rpc client with the appropriate params' do
      expect(Bosh::Director::NatsRpc).to receive(:new)
        .with(test_config['mbus'],
              test_config['nats']['server_ca_path'],
              test_config['nats']['client_private_key_path'],
              test_config['nats']['client_certificate_path'])
        .and_return(some_client)
      expect(described_class.nats_rpc).to eq(some_client)
    end
  end

  describe 'nats' do
    before do
      described_class.configure(test_config)
    end

    it 'should return nats mbus url' do
      expect(described_class.nats_uri).to eq('nats://some-user:some-pass@some-nats-uri:1234')
    end

    context 'when nats_ca is specified' do
      it 'returns non-nil' do
        expect(described_class.nats_server_ca).to eq('server_ca_path')
      end
    end

    context 'when nats_tls is specified' do
      context 'when ca certificate is specified' do
        it 'returns non-nil' do
          expect(described_class.nats_client_ca_certificate_path).to eq('/path/to/client_ca_certificate_path')
        end
      end
      context 'when ca private_key is specified' do
        it 'returns non-nil' do
          expect(described_class.nats_client_ca_private_key_path).to eq('/path/to/client_ca_private_key_path')
        end
      end
      context 'when private_key is specified' do
        it 'returns non-nil' do
          expect(described_class.nats_client_private_key_path).to eq('/path/to/director_private_key_path')
        end
      end
      context 'when certificate is specified' do
        it 'returns non-nil' do
          expect(described_class.nats_client_certificate_path).to eq('/path/to/director_certificate_path')
        end
      end
    end
  end

  describe 'log_director_start_event' do
    it 'stores an event' do
      described_class.configure(test_config)

      expect do
        described_class.log_director_start_event('custom-type', 'custom-name', 'custom' => 'context')
      end.to change {
        Bosh::Director::Models::Event.count
      }.from(0).to(1)

      expect(Bosh::Director::Models::Event.count).to eq(1)
      event = Bosh::Director::Models::Event.first
      expect(event.user).to eq('_director')
      expect(event.action).to eq('start')
      expect(event.object_type).to eq('custom-type')
      expect(event.object_name).to eq('custom-name')
      expect(event.context).to eq('custom' => 'context')
    end
  end

  context 'multiple digest' do
    context 'when verify multidigest is provided' do
      it 'allows access to multidigest path' do
        described_class.configure(base_config)
        expect(described_class.verify_multidigest_path).to eq('/some/path')
      end
    end

    context 'when verify multidigest is not provided' do
      before do
        base_config['verify_multidigest_path'] = nil
      end

      it 'raises an error' do
        expect { described_class.configure(base_config) }.to raise_error(ArgumentError)
      end
    end
  end

  context 'when director starts' do
    it 'stores start event' do
      allow(SecureRandom).to receive(:uuid).and_return('director-uuid')
      described_class.configure(test_config)
      expect do
        described_class.log_director_start
      end.to change {
               Bosh::Director::Models::Event.count
             } .from(0).to(1)
      expect(Bosh::Director::Models::Event.count).to eq(1)
      event = Bosh::Director::Models::Event.first
      expect(event.user).to eq('_director')
      expect(event.action).to eq('start')
      expect(event.object_type).to eq('director')
      expect(event.object_name).to eq('director-uuid')
      expect(event.context).to eq('version' => '0.0.2')
    end
  end

  describe 'enable_cpi_resize_disk' do
    it 'defaults to false' do
      described_class.configure(test_config)
      expect(described_class.enable_cpi_resize_disk).to be_falsey
    end

    context 'when explicitly set' do
      context 'when set to true' do
        before { test_config['enable_cpi_resize_disk'] = true }

        it 'resolves to true' do
          described_class.configure(test_config)
          expect(described_class.enable_cpi_resize_disk).to be_truthy
        end
      end

      context 'when set to false' do
        before { test_config['enable_cpi_resize_disk'] = false }

        it 'resolves to false' do
          described_class.configure(test_config)
          expect(described_class.enable_cpi_resize_disk).to be_falsey
        end
      end
    end
  end

  describe 'parallel_problem_resolution' do
    it 'defaults to true' do
      described_class.configure(test_config)
      expect(described_class.parallel_problem_resolution).to be_truthy
    end

    context 'when explicitly set' do
      context 'when set to true' do
        before { test_config['parallel_problem_resolution'] = true }

        it 'resolves to true' do
          described_class.configure(test_config)
          expect(described_class.parallel_problem_resolution).to be_truthy
        end
      end

      context 'when set to false' do
        before { test_config['parallel_problem_resolution'] = false }

        it 'resolves to false' do
          described_class.configure(test_config)
          expect(described_class.parallel_problem_resolution).to be_falsey
        end
      end
    end
  end

  describe '#configure_db' do
    let(:database) { instance_double(Sequel::Database) }

    before do
      allow(Sequel).to receive(:connect).and_return(database)
      allow(database).to receive(:extension)
      allow(database).to receive_message_chain(:pool, :connection_validation_timeout=)
      allow(database).to receive(:logger=)
      allow(database).to receive(:sql_log_level=)
      allow(database).to receive(:log_connection_info=)
    end

    context 'when db config has empty entries' do
      it 'prunes empty entries before passing it to sequel' do
        parameters = {
          'host' => '127.0.0.1',
          'port' => 5432,
          'nil_value' => nil,
          'empty_value' => '',
        }

        expect(Sequel).to receive(:connect).with('host' => '127.0.0.1', 'port' => 5432).and_return(database)
        described_class.configure_db(parameters)
      end
    end

    context 'when connection_options is defined' do
      it 'will add all entries to top level config' do
        parameters = {
          'host' => '127.0.0.1',
          'port' => 5432,
          'connection_options' => {
            'max_connections' => 100,
            'foo' => 'bar',
          },
        }

        expect(Sequel).to receive(:connect).with(
          'host' => '127.0.0.1', 'port' => 5432, 'max_connections' => 100, 'foo' => 'bar',
        ).and_return(database)

        described_class.configure_db(parameters)
      end

      it 'will overide default options' do
        parameters = {
          'host' => '127.0.0.1',
          'port' => 5432,
          'connection_options' => {
            'host' => 'rds-somewhere',
            'port' => 7000,
            'max_connections' => 100,
            'foo' => 'bar',
          },
        }

        expect(Sequel).to receive(:connect).with(
          'host' => 'rds-somewhere', 'port' => 7000, 'max_connections' => 100, 'foo' => 'bar',
        ).and_return(database)

        described_class.configure_db(parameters)
      end
    end

    context 'when TLS is requested' do
      shared_examples_for 'db connects with custom parameters' do
        it 'connects with TLS enabled for database' do
          expect(Sequel).to receive(:connect).with(connection_parameters).and_return(database)
          described_class.configure_db(config)
        end
      end

      context 'postgres' do
        it_behaves_like 'db connects with custom parameters' do
          let(:config) do
            {
              'adapter' => 'postgres',
              'host' => '127.0.0.1',
              'port' => 5432,
              'tls' => {
                'enabled' => true,
                'cert' => {
                  'ca' => '/path/to/root/ca',
                  'certificate' => '/path/to/client/certificate',
                  'private_key' => '/path/to/client/private_key',
                },
                'bosh_internal' => {
                  'ca_provided' => true,
                  'mutual_tls_enabled' => false,
                },
              },
            }
          end

          let(:connection_parameters) do
            {
              'adapter' => 'postgres',
              'host' => '127.0.0.1',
              'port' => 5432,
              'sslmode' => 'verify-full',
              'sslrootcert' => '/path/to/root/ca',
            }
          end
        end

        context 'when user defines TLS options in connection_options' do
          it_behaves_like 'db connects with custom parameters' do
            let(:config) do
              {
                'adapter' => 'postgres',
                'host' => '127.0.0.1',
                'port' => 5432,
                'tls' => {
                  'enabled' => true,
                  'cert' => {
                    'ca' => '/path/to/root/ca',
                    'certificate' => '/path/to/client/certificate',
                    'private_key' => '/path/to/client/private_key',
                  },
                  'bosh_internal' => {
                    'ca_provided' => true,
                    'mutual_tls_enabled' => false,
                  },
                },
                'connection_options' => {
                  'sslmode' => 'something-custom',
                  'sslrootcert' => '/some/unknow/path',
                },
              }
            end

            let(:connection_parameters) do
              {
                'adapter' => 'postgres',
                'host' => '127.0.0.1',
                'port' => 5432,
                'sslmode' => 'something-custom',
                'sslrootcert' => '/some/unknow/path',
              }
            end
          end
        end

        context 'when user does not pass CA property' do
          it_behaves_like 'db connects with custom parameters' do
            let(:config) do
              {
                'adapter' => 'postgres',
                'host' => '127.0.0.1',
                'port' => 5432,
                'tls' => {
                  'enabled' => true,
                  'cert' => {
                    'ca' => '/path/to/root/ca',
                    'certificate' => '/path/to/client/certificate',
                    'private_key' => '/path/to/client/private_key',
                  },
                  'bosh_internal' => {
                    'ca_provided' => false,
                    'mutual_tls_enabled' => false,
                  },
                },
              }
            end

            let(:connection_parameters) do
              {
                'adapter' => 'postgres',
                'host' => '127.0.0.1',
                'port' => 5432,
                'sslmode' => 'verify-full',
              }
            end
          end
        end

        context 'when mutual tls is enabled' do
          it_behaves_like 'db connects with custom parameters' do
            let(:config) do
              {
                'adapter' => 'postgres',
                'host' => '127.0.0.1',
                'port' => 5432,
                'tls' => {
                  'enabled' => true,
                  'cert' => {
                    'ca' => '/path/to/root/ca',
                    'certificate' => '/path/to/client/certificate',
                    'private_key' => '/path/to/client/private_key',
                  },
                  'bosh_internal' => {
                    'ca_provided' => true,
                    'mutual_tls_enabled' => true,
                  },
                },
              }
            end

            let(:connection_parameters) do
              {
                'adapter' => 'postgres',
                'host' => '127.0.0.1',
                'port' => 5432,
                'sslmode' => 'verify-full',
                'sslrootcert' => '/path/to/root/ca',
                'driver_options' => {
                  'sslcert' =>  '/path/to/client/certificate',
                  'sslkey' => '/path/to/client/private_key',
                },
              }
            end
          end
        end
      end

      context 'mysql2' do
        it_behaves_like 'db connects with custom parameters' do
          let(:config) do
            {
              'adapter' => 'mysql2',
              'host' => '127.0.0.1',
              'port' => 3306,
              'tls' => {
                'enabled' => true,
                'cert' => {
                  'ca' => '/path/to/root/ca',
                  'certificate' => '/path/to/client/certificate',
                  'private_key' => '/path/to/client/private_key',
                },
                'bosh_internal' => {
                  'ca_provided' => true,
                  'mutual_tls_enabled' => false,
                },
              },
            }
          end

          let(:connection_parameters) do
            {
              'adapter' => 'mysql2',
              'host' => '127.0.0.1',
              'port' => 3306,
              'ssl_mode' => 'verify_identity',
              'sslca' => '/path/to/root/ca',
              'sslverify' => true,
            }
          end
        end

        context 'when user defines TLS options in connection_options' do
          it_behaves_like 'db connects with custom parameters' do
            let(:config) do
              {
                'adapter' => 'mysql2',
                'host' => '127.0.0.1',
                'port' => 3306,
                'tls' => {
                  'enabled' => true,
                  'cert' => {
                    'ca' => '/path/to/root/ca',
                    'certificate' => '/path/to/client/certificate',
                    'private_key' => '/path/to/client/private_key',
                  },
                  'bosh_internal' => {
                    'ca_provided' => true,
                    'mutual_tls_enabled' => false,
                  },
                },
                'connection_options' => {
                  'ssl_mode' => 'something-custom',
                  'sslca' => '/some/unknow/path',
                  'sslverify' => false,
                },
              }
            end

            let(:connection_parameters) do
              {
                'adapter' => 'mysql2',
                'host' => '127.0.0.1',
                'port' => 3306,
                'ssl_mode' => 'something-custom',
                'sslca' => '/some/unknow/path',
                'sslverify' => false,
              }
            end
          end
        end

        context 'when user does not pass CA property' do
          it_behaves_like 'db connects with custom parameters' do
            let(:config) do
              {
                'adapter' => 'mysql2',
                'host' => '127.0.0.1',
                'port' => 3306,
                'tls' => {
                  'enabled' => true,
                  'cert' => {
                    'ca' => '/path/to/root/ca',
                    'certificate' => '/path/to/client/certificate',
                    'private_key' => '/path/to/client/private_key',
                  },
                  'bosh_internal' => {
                    'ca_provided' => false,
                    'mutual_tls_enabled' => false,
                  },
                },
              }
            end

            let(:connection_parameters) do
              {
                'adapter' => 'mysql2',
                'host' => '127.0.0.1',
                'port' => 3306,
                'ssl_mode' => 'verify_identity',
                'sslverify' => true,
              }
            end
          end
        end

        context 'when mutual tls is enabled' do
          it_behaves_like 'db connects with custom parameters' do
            let(:config) do
              {
                'adapter' => 'mysql2',
                'host' => '127.0.0.1',
                'port' => 3306,
                'tls' => {
                  'enabled' => true,
                  'cert' => {
                    'ca' => '/path/to/root/ca',
                    'certificate' => '/path/to/client/certificate',
                    'private_key' => '/path/to/client/private_key',
                  },
                  'bosh_internal' => {
                    'ca_provided' => true,
                    'mutual_tls_enabled' => true,
                  },
                },
              }
            end

            let(:connection_parameters) do
              {
                'adapter' => 'mysql2',
                'host' => '127.0.0.1',
                'port' => 3306,
                'ssl_mode' => 'verify_identity',
                'sslca' => '/path/to/root/ca',
                'sslverify' => true,
                'sslcert' =>  '/path/to/client/certificate',
                'sslkey' => '/path/to/client/private_key',
              }
            end
          end
        end
      end
    end
  end

  # TODO: this can be deleted once the CPI api version no longer needs to be specified in the spec
  describe 'preferred_cpi_api_version' do
    context 'when preferred_cpi_api_version is set' do
      before do
        described_class.configure(test_config)
      end

      it 'returns the value' do
        expect(described_class.preferred_cpi_api_version).to eq(2)
      end
    end
  end
end
