require 'capistrano'
require 'drush_deploy/error'
require 'drush_deploy/configuration'
require 'yaml'
require 'php_serialize'

module DrushDeploy
  class Database
    class Error < DrushDeploy::Error; end


    STANDARD_KEYS = %w(driver database username password host port prefix collation).map &:to_sym
    MANAGE_KEYS   = %w(driver database username password host port prefix 
                       admin_username admin_password).map &:to_sym
  
    def initialize(config)
      @config = config
      @seen_paths = {}
      @db_status = {}
    end

    def method_missing(sym, *args, &block)
      if @config.respond_to?(sym)
        @config.send(sym, *args, &block)
      else
        super
      end
    end

    def configure
      databases_path.find do |val|
        set :databases, load_path( val, databases )
        MANAGE_KEYS.all? {|k| databases.key? k}
      end
    end

    def load_path(path,databases = {})
      unless @seen_paths[path]
        logger.info "Trying to load database setting from #{path.inspect}"
        if path !~ /^[\/~]/
          path = latest_release+"/"+path
        end
        if path =~ /.php$/
          @seen_paths[path] = load_php_path path
        elsif path =~ /.yml$/
          @seen_paths[path] = load_yml_path path
        else
          throw Error.new "Unknown file type: #{path}"
        end
      end
      DrushDeploy::Database.deep_merge(@seen_paths[path],databases)
    end

    def load_php_path(path)
      prefix = ''
      if path.sub!(/^~/,'')
        prefix = "getenv('HOME')." 
      end

      script = <<-END.gsub(/^ */,'')
        <?php
        $filename = #{prefix}'#{path}';
        if( file_exists($filename) ) {
          require_once($filename);
          if( isset($databases) ) {
            print serialize($databases);
          }
        } 
      END

      tmp = capture('mktemp').strip
      put script, tmp, :once => true
      resp = capture "#{drush_bin} php-script '#{tmp}' && rm -f '#{tmp}'"
      
      settings = {}
      unless resp.empty?
        resp = DrushDeploy::Configuration.unserialize_php(resp)
        if resp != []
          settings = resp
        end
      end
      settings
    end

    def load_yml_path(path)
      prefix = ''
      if path.sub!(/^~/,'')
        prefix = '"$HOME"'
      end

      yaml =  capture("[ ! -e #{prefix}'#{path}' ] || cat #{prefix}'#{path}'")
      if yaml.empty?
        {}
      else
        credentials = YAML.load yaml
        DrushDeploy::Configuration.normalize_value(credentials)
      end
    end

    def update_settings(settings,template = 'sites/default/default.settings.php')
      if template !~ /^[\/~]/
        template = latest_release+"/"+template
      end
      prefix = ''
      if template.sub!(/^~/,'')
        prefix = "getenv('HOME')." 
      end
      script = <<-END.gsub(/^ */,'')
        <?php
        define('DRUPAL_ROOT', '#{latest_release}');
        define('MAINTENANCE_MODE', 'install');

        $template = #{prefix}'#{template}';
        $default = DRUPAL_ROOT.'/sites/default/default.settings.php';
        $backup = '/tmp/default_settings_backup.php';

        $databases = unserialize('#{PHP.serialize(settings)}');
        $settings["databases"] = array( 'comment' => 'Generated by drush-deploy',
                                        'value' => $databases );

        require_once(DRUPAL_ROOT.'/includes/bootstrap.inc');
        require_once(DRUPAL_ROOT.'/includes/install.inc');

        $backed_up = false;
        if ($template != $default && file_exists($default)) {
          rename($default,$backup);
          $backed_up = true;
        }
        rename($template,$default);
        drupal_rewrite_settings($settings);
        if ($backed_up) {
          rename($backup,$default);
        }
        __END__
      END

      run %Q{TMP=`mktemp` && sed -n '/^__END__$/ q; p' > $TMP && cd '#{latest_release}' && #{drush_bin} php-script $TMP && rm -f "$TMP"},
          :data => script
    end

    def updatedb
      run "cd '#{latest_release}' && #{drush_bin} updatedb --yes", :once => true
    end

    def config(*args)
      options = (args.size>0 && args.last.is_a?(Hash)) ? args.pop : {}
      site_name = args[0] || :default
      db_name = args[1] || :default
      conf = databases[site_name][db_name].dup
      if options[:admin] && conf[:admin_username]
        conf[:username] = conf[:admin_username]
        conf[:password] = conf[:admin_password]
      end
      conf.merge options
    end

    def remote_sql(sql,options={})
      url = options[:config] ? DrushDeploy::Database.url(options[:config]) : nil
      tmp = capture('mktemp').strip
      put(sql,tmp)
      cmd = %Q{cd '#{latest_release}' && #{drush_bin} sql-cli #{url ? "--db-url='#{url}'" : ''} < '#{tmp}' && rm -f '#{tmp}'}
      if options[:capture]
        capture(cmd)
      else
        run cmd, :once => true
      end
    end

    def db_empty?(db = nil)
      conf = config
      conf[:database] = db if db
      db = conf[:database]
      if @db_status[db].nil?
        logger.info "Fetching status of db #{conf[:database]}"
        sql = %q{SELECT count(*) FROM information_schema.tables 
                 WHERE table_schema = '%{database}' LIMIT 1} % conf
        conf[:database] = 'information_schema'
        res = remote_sql(sql, :config => conf, :capture => true)
        @db_status[db] = res.split(/\n/)[1].to_i == 0
      end
      @db_status[db]
    end

    def db_versions
      conf = config(:admin => true)
      logger.info "Getting list of databases versions"
      sql = %q{SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
               WHERE SCHEMA_NAME REGEXP '%{database}_[0-9]+';} % conf
      (remote_sql(sql, :config => conf, :capture => true).split(/\n/)[1..-1] || []).sort.reverse
    end

    def db_exists?(db = nil)
      conf = config(:admin => true)
      conf[:database] = db if db
      logger.info "Checking existence of #{conf[:database]}"
      sql = %q{SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '%{database}';} % conf
      conf[:database] = 'information_schema'
      remote_sql(sql, :config => conf, :capture => true).split(/\n/)[1].to_i != 0
    end

    def db_tables(db = nil)
      conf = config(:admin => true)
      conf[:database] = db if db
      db = conf[:database]
      logger.info "Fetching table list of #{conf[:database]}"
      db_tables_query = %q{SELECT table_name FROM information_schema.tables
                           WHERE table_schema = '%{database}'
                             AND table_type = 'BASE TABLE'};
      sql = db_tables_query % conf
      conf[:database] = 'information_schema'
      tables = remote_sql(sql, :config => conf, :capture => true).split(/\n/)[1..-1] || []
      @db_status[db] = tables.size == 0
      tables
    end

    def copy_database(from,to)
      logger.info "Copying database #{from} to #{to}"
      tables = db_tables
      conf = config(:database => from, :admin => true)

      remote_sql("CREATE DATABASE #{to};", :config => conf)
      sql = ''
      tables.each do |table|
        sql += <<-END 
          CREATE TABLE #{to}.#{table} LIKE #{from}.#{table};
          INSERT INTO #{to}.#{table} SELECT * FROM #{from}.#{table};
        END
      end
      remote_sql(sql, :config => conf)
      @db_status.delete(to)
    end

    def rename_database(from,to)
      logger.info "Renaming database #{from} to #{to}"
      conf = config(:database => from, :admin => true)
      sql = ''
      if conf[:driver] == :mysql
        sql += "CREATE DATABASE `#{to}`;"
        db_tables(from).each do |table|
          sql += "RENAME TABLE `#{from}`.`#{table}` TO `#{to}`.`#{table}`;"
        end
        sql += "DROP DATABASE `#{from}`;"
      else
        sql += "ALTER TABLE #{from} RENAME TO #{to};"
      end
      remote_sql(sql, :config => conf)
      @db_status.delete(to)
    end

    def drop_database(db)
      logger.info "Dropping database #{db}"
      conf = config(:database => db, :admin => true)
      remote_sql("DROP DATABASE #{db};", :config => conf)
      @db_status[db] = false
    end

    # Should split these out
    def self.deep_update(h1,h2)
      h1.inject({}) do |h,(k,v)|
        if Hash === v && Hash === h2[k]
          h[k] = deep_update(v,h2[k])
        else
          h[k] = h2.key?(k) ? h2[k] : v
        end
        h
      end
    end

    def self.deep_merge(h1,h2)
      merger = proc { |key,v1,v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
      h1.merge(h2, &merger)
    end

    def self.each_db(databases)
      databases.each do |site_name,site|
        site.each do |db_name,db|
          yield db,site_name,db_name
        end
      end
    end

    def self.url(db)
      "#{db[:driver]}://#{db[:username]}:#{db[:password]}@#{db[:host]}:#{db[:port]}/#{db[:database]}"
    end
  end
end
