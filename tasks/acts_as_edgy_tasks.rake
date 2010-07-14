require File.join(File.dirname(__FILE__), '../lib/acts_as_edgy')

namespace :edgy do
  desc "Imports your site's data to your Directed Edge account."
  task :export, :user, :pass, :needs => :environment do |t, args|

    unless args[:user] && args[:pass]
      puts "You must pass the Directed Edge account name and password as arguments."
      puts "e.g. rake edgy:export[testdb,testpass]"
      exit
    end
        
    DirectedEdge::Edgy.database = DirectedEdge::Database.new(args[:user], args[:pass])

    # Force all models to be loaded

    (ActiveRecord::Base.connection.tables - %w[schema_migrations]).each do |table|
      table.classify.constantize rescue nil
    end

    DirectedEdge::Edgy.export
  end
end
