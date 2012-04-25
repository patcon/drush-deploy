require 'yaml'
require 'drupal_deploy/database'

db = DrupalDeploy::Database.new self

set :databases_path, [ 'sites/default/settings.php',
                       '~/.drush/database.php', '~/.drush/database.yml', 
                       '/etc/drush/database.php','/etc/drush/database.yml' ]
set :databases, {}

set :database_ports, { :pgsql => 5432, :mysql => 3306 }

settings_attrs = %w(driver database username password host port prefix collation).map &:to_sym

namespace :drupal do
  namespace :db do
    task :import, :roles => :db_access do
      run "#{drush_bin}" 
    end

    task :update, :roles => :db_access do
    end


    task :configure do
      db.configure

      unless databases.nil? || databases.is_a?(Hash)
        throw DrupalDeploy::Error.new "Invalid value for databases: #{databases.inspect}"
      end

      # Set some defaults
      db.each_db(databases) do |db|
        if db[:driver]
          db[:driver] = db[:driver].to_sym
        else
          db[:driver] = db[:port] == database_ports[:pgsql] ? :pgsql : :mysql
        end
        db[:host] ||= 'localhost'
        db[:port] ||= database_ports[db[:driver]]
        db[:prefix] ||= ''
        db[:collation] ||= 'utf8_general_ci'
      end

      logger.important "Using database settings #{databases.inspect}"
    end

    task :update_settings do
      configure
      settings = databases.inject({}) do |h,(k,site)|
        h[k] = site.inject({}) do |h,(k,db)|
          h[k] = db.keep_if { |k,v| DrupalDeploy::Database::STANDARD_KEYS.include? k }
          h
        end
        h
      end
      db.update_settings(settings)
    end
  end

  namespace :version do
    task :create, :roles => :db_access do
    end

    task :rollback, :roles => :db_access do
    end
  end
end
