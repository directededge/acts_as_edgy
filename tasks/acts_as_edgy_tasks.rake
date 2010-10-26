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
end
