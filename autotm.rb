#!/usr/bin/ruby

require 'yaml'
require 'time'

module Autotm

  CONF_FILE = '/etc/autotm.conf'
  
  def get_conf
    ## conf file format:
    # servers:
    #  - hostname: myhost.local
    #    username: myusername
    #    password: mypassword
    # -----------------------
    # optionally add (defaults to /Backup):
    #    path: /mypath
    # -----------------------
    # Entries will be assembled to the following backup url:
    #  "afp://#{user}:#{password}@#{hostname}#{path}"
  
    conf_file = File.expand_path(CONF_FILE)
    
    if File.exist?(conf_file)
      conf = YAML.load(File.read(conf_file))
    else
      raise Exception.new("Configuration file is missing.")
    end
    
    conf
  end
  
  
  def ping(hostname)
    res = %x[ping -q -c 10 -t 1 #{hostname}]
    if $?.exitstatus == 0
      res.each do |line|
        if line =~ /^round-trip min\/avg\/max\/stddev = ([\d\.]+)/
          return $1.to_f
        end
      end
    else
      return 0
    end
  end
  
  
  def get_available_servers
    available = []
    servers = get_conf['servers']
    
    servers.each do |server|
      hostname = server['hostname']
      time = ping(hostname)
      if time > 0
        server['ping'] = time
        available << server
      end
    end
    
    available = available.sort {|a,b| a['ping'] <=> b['ping']}
  end
  
  
  
  def get_tm_events
    events = []
    
    File.read('/var/log/system.log').each do |line|
      if line =~ /com.apple.backupd/
        if line =~ /NAConnectToServerSync failed with error: 64 for url: (\S+)/
          url = $1
          events << [:failure, "#{url}"]
        end
        
        if line =~ /Mounted network destination at mountpoint: \S+ using URL: (\S+)/
          url = $1
          events << [:success, "#{url}"]
        end
        
        if line =~ /Backup failed with error: (\d+)/
          events << [:failure, nil]
        end
        
        if line =~ /Backing up to: (.+)\/Backups.backupd/
          disk = $1
          events << [:success , "#{disk}"]
        end
      end
    end
      
    events
  end
  
  
  def is_available(url)
    get_available_servers.each do |server|
      hostname = server['hostname']
      if url.include?(hostname)
        return true
      end
    end
    return false
  end
  
  
  def schedule_tm_backup(server)
    user = server['username']
    hostname = server['hostname']
    password = server['password']
    path = server['path'] || '/Backups'
    tm_url = "afp://#{user}:#{password}@#{hostname}#{path}"
    puts "#{Time.now}: Backing up to: afp://#{user}@#{hostname}#{path}"
    
    %x[sudo tmutil setdestination #{tm_url}]
    sleep(5)
    %x[tmutil startbackup]
  end
  
  
  def run_backup
    available = get_available_servers
    
    if available.size > 0
      # servers are ordered by ping time, take fastest one
      # (prevents backing up to alternatives available via WAN)
      server = available[0]
      schedule_tm_backup(server)
    else
      puts "#{Time.now}: No time machine server found"
    end
  end

end # module


if __FILE__ == $0
  include Autotm
  
  events = get_tm_events
  
  if events == []
    puts "#{Time.now}: No backup events found (can happen after syslog roll at midnight)"
    return
  end
  
  last_status, last_url = events[-1]
  if last_status == :failure
    puts "#{Time.now}: Last backup failed, trying available servers"
    run_backup
  else # :success
    if not is_available(last_url)
      puts "#{Time.now}: Last used TM not available, trying configured alternatives"
      run_backup
    else
      puts "#{Time.now}: No action required: Last backup successful and TM available"
    end
  end
end
