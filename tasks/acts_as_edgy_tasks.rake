require File.join(File.dirname(__FILE__), '../lib/acts_as_edgy')

namespace :edgy do
  desc "Imports your site's data to your Directed Edge account."
  task :export, :needs => :environment do

    unless DirectedEdge::Edgy::database
      puts "acts_as_edgy has not yet been configured, please run 'rake edgy:configure'"
      exit
    end

    # Force all models to be loaded

    (ActiveRecord::Base.connection.tables - %w[schema_migrations]).each do |table|
      table.classify.constantize rescue nil
    end

    DirectedEdge::Edgy.export
  end

  desc "Sets the credentials for your Directed Edge account."
  task :configure, :user, :password, :needs => :environment do |t, args|
    path = "#{Rails.root}/config/initializers/edgy.rb"

    if File.exists?(path) && !(args[:user] && args[:password])
      puts "Overwrite existing configuration? [Y/n]"
      overwrite = STDIN.gets.chomp
      exit unless overwrite.empty? || overwrite[0, 1].upcase == 'Y'
    end

    unless args[:user]
      puts "Directed Edge user name:"
      args[:user] = STDIN.gets.chomp
    end

    unless args[:password]
      puts "Directed Edge password:"
      args[:password] = STDIN.gets.chomp
    end

    file = File.new(path, 'w')
    file.write("DirectedEdge::Edgy.configure do |config|\n")
    file.write("  config.user = '#{args[:user]}'\n")
    file.write("  config.password = '#{args[:password]}'\n")
    file.write("end\n");
    file.close
  end
end
