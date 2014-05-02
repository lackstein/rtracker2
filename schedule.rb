##################################################################
## Ruby BitTorrent Tracker                                      ##
##                                                              ##
##                                                              ##
## Copyright 2008 Noah                                          ##
## Released under the Creative Commons Attribution License      ##
##################################################################

# Require RubyGems
require 'rubygems'
# Require the mysql gem
require 'mysql'
# Require the memcache gem
require 'memcache'
# Require YAML to parse config files
require 'yaml'

@config = YAML::load( open('config.yml') )
@cache = MemCache::new(@config[:cache][:host], :namespace => @config[:cache][:namespace])
@mysql = Mysql::new($config[:mysql][:host], $config[:mysql][:user], $config[:mysql][:pass], $config[:mysql][:database])

class Schedule
  def run
    loop do
      update_users
      flush_inactive_peers
      sleep @config[:user_update_int]
    end
  end
  
  def update_users
    update_list = @cache.get("user_update_list")
    unless update_list.nil?
      user_values = update_list.collect { |user| "(#{user[:id]}, #{user[:uploaded]}, #{user[:downloaded]})" }.join(',')
      peer_values = update_list.collect { |user| "(#{user[:id]}, #{user[:uploaded]}, #{user[:downloaded]}, #{user[:left]})" }.join(',')
      @mysql.query( "INSERT LOW PRIORITY INTO users_main (ID, Uploaded, Downloaded) VALUES #{user_values} ON DUPLICATE KEY UPDATE Uploaded=Uploaded+VALUES(Uploaded), Downloaded=Downloaded+VALUES(Downloaded)")
      @mysql.query( "INSERT LOW PRIORITY INTO tracker_peers (ID, Uploaded, Downloaded, Left) VALUES #{peer_values} ON DUPLICATE KEY UPDATE Uploaded=Uploaded+VALUES(Uploaded), Downloaded=Downloaded+VALUES(Downloaded), Left=VALUES(Left), Time=NOW()")
      @cache.set("users_update_list", [], 60*60*1)
    end
  end

  def flush_inactive_peers
    @mysql.query( "DELETE FROM tracker_peers WHERE Time < TIMESTAMP(NOW()-INTERVAL 2 HOUR)")
  end
end