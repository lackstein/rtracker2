require 'sinatra'
require 'daemons'
#require 'schedule'

Sinatra::Application.default_options.merge!(
  :run => false,
  :env => :production,
  :raise_errors => true,
  :app_file => 'tracker.rb'
)


#Daemons.call { Schedule.new.run }
require 'tracker'
run Sinatra.application