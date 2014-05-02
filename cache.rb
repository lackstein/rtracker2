##################################################################
## Ruby BitTorrent Tracker                                      ##
##                                                              ##
##                                                              ##
## Copyright 2008 Noah                                          ##
## Released under the Creative Commons Attribution License      ##
##################################################################

# Require RubyGems
require 'rubygems'
# Require the memcache gem
require 'memcache'

class Cache
  attr_reader :cache, :mysql, :user, :torrent
  
  def initialize(options = {})
    raise CacheError, "You must provide a host and a namespace!" if options[:host].nil? or options[:namespace].nil?
    @cache = MemCache::new options[:host], :namespace => options[:namespace]
    
    unless options[:load_subclasses] == false # So we can get access to the cache without having it instantiate user and torrent objects
      raise CacheError, "You must provide a MySQL object!" unless options[:mysql].is_a?(Mysql)
      @mysql = options[:mysql]
      raise CacheError, "You must provide an info_hash!" if options[:info_hash].nil?
      @torrent = Torrent.new(cache, mysql, options[:info_hash])
      raise CacheError, "You must provide a passkey and a peer_id!" if options[:passkey].nil? or options[:peer_id].nil?
      @user = User.new(cache, mysql, options[:passkey], options[:peer_id], @torrent)
      
      @torrent.user = @user # Let out classes know about each other
    end
  end
  
  def stats
    { :user => cache.get("user_cache_hits"), :torrent => cache.get("torrent_cache_hits") }
  end
  
  class User
    attr_reader :cache, :mysql, :passkey, :peer, :user
    attr_accessor :torrent
    
    def initialize(cache, mysql, passkey, peer_id, torrent)
      @cache, @mysql, @passkey, @peer_id, @torrent = cache, mysql, passkey, peer_id, torrent
      self.find # Either pull the user out of the cache, or reload! it from mysql
    end
    
    def find
      @user = cache.get("user_#{passkey}") # Try to pull the user out of the cache
      cache.incr("user_cache_hits", 1) unless user.nil? # We've got a hit!
      self.reload! if user.nil? # Try and find us in the database
      
      # Find the torrent's peerlist entry which belongs to us
      @peer = torrent.peers.select { |peer| peer['PeerID'] == @peer_id }.first
    end
    
    def reload!
      @user = mysql.query( "SELECT um.ID, um.Enabled, um.can_leech, p.Level FROM users_main AS um LEFT JOIN permissions AS p ON um.PermissionID=p.ID WHERE torrent_pass = '#{passkey}'" ).fetch_hash
      cache.set("user_#{passkey}", user.merge({ 'Cached' => true }), 60*60*1) # Save the result to the cache, and leave a note saying it was cached
    end
    
    def update(uploaded, downloaded, left)
      uploaded, downloaded = uploaded.to_i - peer['Uploaded'].to_i, downloaded.to_i - peer['Downloaded'].to_i # Find out exactly how much they uploaded since their last announce
      if uploaded > 0 || downloaded > 0 # Only update if they've uploaded / downloaded something
        # Set download = 0 if the torrent is freeleech
        downloaded = 0 if torrent.freeleech?
        
        # Add the user to the update queue
        update_list = cache.get("user_update_list") || [] # Set it to a blank array if it's nil
        update_list << { :id => user['ID'], :uploaded => uploaded, :downloaded => downloaded, :left => left, :peer => peer['ID'] }
        cache.set("user_update_list", update_list)
      end
    end

    def exists?
      !user.nil? && user['Enabled'] == '1'
    end

    def can_leech?
      user['can_leech'] == '1'
    end
    
    def cached?
      !!user['Cached']
    end
    
    def [](column)
      user[column]
    end
  end
  
  class Torrent
    attr_reader :cache, :mysql, :hash, :torrent, :peers
    attr_accessor :user
    
    def initialize(cache, mysql, info_hash)
      @cache, @mysql, @hash = cache, mysql, info_hash
      self.find
    end
    
    def find
      # Find the torrent
      @torrent = @cache.get("torrent_#{hash}")
      @cache.incr("torrent_cache_hits", 1) unless @torrent.nil?
      self.reload! if @torrent.nil?
      
      # Find the peers
      @peers = @cache.get("torrent_#{hash}_peers")
      @cache.incr("peers_cache_hits", 1) unless @peers.nil?
      self.reload_peers! if @peers.nil?
    end
    
    def reload!
      @torrent = @mysql.query( "SELECT t.ID, t.FreeTorrent, t.Seeders, t.Leechers, t.Snatched, g.Name FROM torrents AS t LEFT JOIN torrents_group AS g ON t.GroupID=g.ID WHERE info_hash = '#{@hash}'" ).fetch_hash
      @cache.set("torrent_#{hash}", @torrent.merge({ 'Cached' => true }), 60*60*1)
    end
    
    def reload_peers!
      @peers = [] # MySQL is weird when returning lists of things, and memcache doesn't like that, so we're going to convert them to an array
      @mysql.query( "SELECT p.ID, p.UserID, p.IP, p.Port, p.PeerID FROM tracker_peers AS p WHERE TorrentID = #{@torrent['ID']} ORDER BY RAND()" ).each_hash do |peer|
        @peers << peer
      end
      @cache.set("torrent_#{hash}_peers", @peers, 60*60*1)
    end
    
    def new_peer(ip, port, left, peer_id)
      @mysql.query( "INSERT INTO tracker_peers (UserID, TorrentID, IP, Port, Uploaded, Downloaded, tracker_peers.Left, PeerID) VALUES (#{user['ID']}, #{@torrent['ID']}, '#{ip}', '#{port}', 0, 0, #{left}, '#{peer_id}')" )
      id = @mysql.insert_id
      @peers = @cache.get("torrent_#{hash}_peers") || []
      @peers << { 'ID' => id, 'UserID' => user['ID'], 'IP' => ip, 'Port' => port, 'PeerID' => peer_id }
      @cache.set("torrent_#{hash}_peers", @peers, 60*60*1)
    end
    
    def delete_peer
      @mysql.query( "DELETE FROM tracker_peers WHERE ID = #{user.peer['ID']}" )
      @peers = @cache.get("torrent_#{hash}_peers") || []
      @peers = @peers.reject { |peer| peer['ID'] == user.peer['ID'] }
      @cache.set("torrent_#{hash}_peers", @peers, 60*60*1)
    end
    
    def exists?
      !@torrent.nil?
    end
    
    def freeleech?
      !!@torrent['FreeTorrent']
    end
    
    def cached?
      !!@torrent['Cached']
    end
    
    def [](column)
      @torrent[column]
    end
  end
end

# Error class
class CacheError < RuntimeError; end # Used to clearly identify errors