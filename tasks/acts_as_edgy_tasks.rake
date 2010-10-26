require File.join(File.dirname(__FILE__), '../lib/acts_as_edgy')

namespace :edgy do
  desc "Imports your site's data to your Directed Edge account."
  task :export, :needs => :environment do

    unless DirectedEdge::Edgy::database
      puts "acts_as_edgy has not yet been configured, check config/initializers/edgy.rb"
      exit
    end

    # Force all models to be loaded

    (ActiveRecord::Base.connection.tables - %w[schema_migrations]).each do |table|
      table.classify.constantize rescue nil
    end

    DirectedEdge::Edgy.export
  end

  desc "Sets the credentials for your Directed Edge account."
  task :configure do
    path = "#{Rails.root}/config/initializers/edgy.rb"

    if File.exists?(path)
      puts "Overwrite existing configuration? [Y/n]"
      overwrite = STDIN.gets.chomp
      exit unless overwrite.empty? || overwrite[0, 1].upcase == 'Y'
    end

    puts "Directed Edge user name:"
    user = STDIN.gets.chomp
    puts "Directed Edge password:"
    password = STDIN.gets.chomp

    file = File.new(path, 'w')
    file.write("DirectedEdge::Edgy.configure do |config|\n")
    file.write("  config.user = '#{user}'\n")
    file.write("  config.password = '#{password}'\n")
    file.write("end\n");
    file.close
  end
end
