require "sinatra"
require "logger"
require "json"
require "net/http"
require "net/smtp"
require "uri"
require "nats/client"
require "open3"

require "data_mapper"

class Users
  include DataMapper::Resource

  storage_names[:default] = 'users'
  property :id,           String,   :key => true
  property :created,      Time
  property :lastmodified, Time
  property :version,      String
  property :username,     String
  property :password,     String
  property :email,        String
  property :authorities,  Text
  property :givenname,    String
  property :familyname,   String
  property :active,       Boolean
  property :phonenumber,  String
end

class User_cc
   include DataMapper::Resource
   
   storage_names[:extra] = 'users'
   property :id,          String, :key => true
   property :guid,        String
   property :created_at,  DateTime
   property :updated_at,  DateTime
   property :default_space_id,   Integer
   property :admin,       Boolean
   property :active,      Boolean
end

class Organizations_users
   include DataMapper::Resource
   
   storage_names[:extra] = 'organizations_users'
   property :organization_id,      String,  :key => true
   property :user_id,              String
end

class Organization
   include DataMapper::Resource
   
   storage_names[:extra] = 'organizations'
   property :id,           String, :key => true
   property :guid,         String
   property :created_at,   DateTime
   property :updated_at,    DateTime
   property :name,         Text
   property :billing_enabled,     Boolean
   property :quota_definition_id, Integer
   property :status,       Text
end

class Spaces
   include DataMapper::Resource
   
   storage_names[:extra] = 'spaces'
   property :id,              Serial,  :key => true
   property :guid,            String
   property :created_at,      DateTime
   property :updated_at,      DateTime
   property :name,            Text
   property :organization_id, Integer
end

class Apps
   include DataMapper::Resource
   
   storage_names[:extra] = 'apps'
   property :id,                  Serial,  :key => true
   property :guid,                String
   property :created_at,          DateTime
   property :updated_at,          DateTime
   property :name,                String
   property :production,          Boolean
   property :environment_json,    Text
   property :memory,              Integer
   property :instances,           Integer
   property :file_descriptors,    Integer
   property :disk_quota,          Integer
   property :state,               Text
   property :package_state,       Text
   property :package_hash,        Text
   property :droplet_hash,        Text
   property :version,             Text
   property :metadata,            Text
   property :buildpack,           Text
   property :space_id,            Integer
   property :stack_id,            Integer
   property :detected_buildpack,  Text
   property :staging_task_id,     Text
   property :kill_after_multiple_restarts, Boolean
   property :deleted_at,          DateTime
   property :not_deleted,         Boolean
end

class Admin


  def initialize(options)
    @options = options
  end


  def start

    ["TERM", "INT"].each { |sig| trap(sig) { exit! } }

    adminWeb = AdminWeb.new(@options)
       
    Rack::Handler::WEBrick.run adminWeb, {:Port => @options[:port]}

  end


  class AdminWeb < Sinatra::Base

    def initialize(options)
      super

      @mbus                         = options[:mbus]
      @cloudControllerURI           = options[:cloud_controller_uri]
      @dataFile                     = options[:data_file]
      @statsFile                    = options[:stats_file]
      @logFile                      = options[:log_file]
      @uiCredentials                = options[:ui_credentials]
      @uiAdminCredentials           = options[:ui_admin_credentials]
      @dropletExecutionAgentRetries = options[:dea_retries]                  || 10
      @natsDiscoveryTimeout         = options[:nats_discovery_timeout]       || 10
      @componentConnectionRetries   = options[:component_connection_retries] || 2
      @senderEmail                  = options[:sender_email] 
      @receiverEmails               = options[:receiver_emails]
      @monitoredComponents          = options[:monitored_components]
      @cacheRefreshInterval         = options[:cache_refresh_interval]       || 30
      @tasksRefreshInterval         = options[:tasks_refresh_interval]       || 5000
      @statsRefreshTime             = options[:stats_refresh_time]           || (60 * 5)
      @statsRetryInterval           = options[:stats_retry_interval]         || 300
      @statsRetries                 = options[:stats_retries]                || 5
      @logFilePageSize              = options[:log_file_page_size]           || 51200
      @logFiles                     = options[:log_files]

      FileUtils.mkpath File.dirname(@dataFile)

      @logger = Logger.new(@logFile)
      @logger.level = Logger::DEBUG

      @@semaphore = Mutex.new
      @@condition = ConditionVariable.new

      @@useCache = true

      @@cache = {}

      @@tasksSemaphore = Mutex.new

      @@tasks = {}

      @@taskIndex = 0

      @@statsSemaphore = Mutex.new

      @@cc_db = ""
      @@uaa_db = ""

      Thread.new do
        loop do
          scheduleDiscovery()  
        end
      end

      Thread.new do
        loop do 
          scheduleStatistics()
        end
      end

      @logger.debug("AdminUI started...")

      puts "\n\n"
      puts "AdminUI started..."
      puts "   data: #{@dataFile}"
      puts "    log: #{@logFile}"
      puts "\n"

    end


    def scheduleDiscovery()

      cache = {}
      cache["items"] = {}

      begin

        @logger.debug("[#{@cacheRefreshInterval} second interval] Starting discovery...")

        @startTime = Time.now.to_f

        @lastDiscoveryTime = 0

        Thread.new do
          while (@lastDiscoveryTime == 0 && (Time.now.to_f - @startTime < @cacheRefreshInterval)) || (Time.now.to_f - @lastDiscoveryTime < @natsDiscoveryTimeout)
            sleep(@natsDiscoveryTimeout)
          end
          NATS.stop
        end

        NATS.start(:uri => @mbus) do
          # Set the connected to true to handle case where NATS is back up but no components are.
          # This gets rid of the disconnected error message on the UI without waiting for the cacheRefreshInterval.
          @@semaphore.synchronize {
            @@cache["connected"] = true
          }

          NATS.request("vcap.component.discover") do |item|
            @lastDiscoveryTime = Time.now.to_f
            itemJSON = JSON.parse(item)
            cache["items"][getItemURI(itemJSON)] = itemJSON
          
            @@uaa_db = get_db(itemJSON,"uaa") if itemJSON["type"] =~ /^uaa$/
            @@cc_db = get_db(itemJSON,"cc") if itemJSON["type"] =~ /^CloudController$/

          end

        end

        if !@@uaa_db.empty?
          DataMapper.setup(:default, @@uaa_db)
        else
          @logger.debug("Error no uaa_db address")
        end

        if !@@cc_db.empty?
          DataMapper.setup(:extra,@@cc_db)
        else
          @logger.debug("Error no cc_db address")
        end
        
        cache["connected"] = true

      rescue => error
        cache["connected"] = false
        @logger.debug("Error during discovery: #{error.inspect}")
        @logger.debug(error.backtrace.join("\n"))
      end

      disconnected = []

      @@semaphore.synchronize {

        @logger.debug("database setup...")

        @@cache = {}

        @@cache["items"]    = {}
        @@cache["notified"] = {}

        begin

          if @@useCache && File.exists?(@dataFile)
            @@cache = JSON.parse(IO.read(@dataFile))
          end

          @@cache["connected"] = cache["connected"]
          @@cache["items"].merge!(cache["items"])

          if @receiverEmails.length > 0

            updateConnectionStatus("NATS", @mbus.partition("@").last[0..-1], @@cache["connected"], disconnected)

            @@cache["items"].each do |url, item|
              updateConnectionStatus(item["type"], url, !cache["items"][url].nil?, disconnected)
            end

          end

          File.open(@dataFile, "w") { |file| file.write(JSON.pretty_generate(@@cache)) }

          Thread.new { sendEmail(disconnected) }

        rescue => error
          @logger.debug("Error during discovery: #{error.inspect}")
        end

        @@useCache = true
        @@condition.broadcast()
        @@condition.wait(@@semaphore, @cacheRefreshInterval)
      }

    end

    
    def scheduleStatistics()        
      begin
        time_until_generate_stats = getTimeUntilGenerateStats() 
        @logger.debug("Waiting #{time_until_generate_stats} seconds before trying to save stats...")
        sleep(time_until_generate_stats)
        generateStats()
      rescue => error
        @logger.debug("Error generating stats: #{error.inspect}")
      end
    end


    configure do
      enable :sessions
      set :static_cache_control, :no_cache
    end


    get "/favicon.ico" do
    end


    get "/" do
      send_file File.expand_path("login.html", settings.public_folder)
    end


    set(:auth) do |*roles|
      condition do
        unless !session[:username].nil? && (!roles.include?(:admin) || session[:admin])
          @logger.debug("Authorization failure, redirecting to login...")
          redirectToLogin()
        end
      end
    end


    def redirectToLogin()

      session[:username] = nil
      session[:admin]    = nil

      if request.xhr?
        halt 303
      else
        redirect "login.html", 303
      end
    end


    post "/login" do

      username = params["username"]
      password = params["password"]

      if username.nil?
        
        redirectToLogin()

      elsif @uiCredentials[:username] == username && @uiCredentials[:password] == password

        authenticated(username, false)

      elsif @uiAdminCredentials[:username] == username && @uiAdminCredentials[:password] == password

        authenticated(username, true)

      else

        session[:username] = nil

        redirect "login.html?error=true"

      end

    end


    def authenticated(username, admin)

        session[:username] = username 

        session[:admin] = admin

        redirect "application.html?user=" + username

    end


    def validateLogFileRequest(path)
      redirectToLogin() unless getLogFiles().include?(path)
    end


    get "/settings", :auth => [:user] do

      settings = {
                   #:mbus => @mbus,                    
                   #:dataFile => @dataFile,
                   #:uiCredentials => @uiCredentials,
                   #:deaRetries => @dropletExecutionAgentRetries,
                   #:logFilePageSize => @logFilePageSize,
                   #:logFiles => @logFiles,
                   #:logFile => @logFile,
                   #:cacheRefreshInterval => @cacheRefreshInterval,
                   :tasksRefreshInterval => @tasksRefreshInterval,
                   :admin => session[:admin]
                 }

      settings.to_json

    end
  

    get "/components", :auth => [:user] do

      puts "======components===="

      getItems("getItem", //).to_json
    end


    get "/cloudControllers", :auth => [:user] do

      puts "======cloudControllers===="

      getItems("getItem", /CloudController/).to_json
    end


    get "/healthManagers", :auth => [:user] do

      puts "======healthManagers===="

      getItems("getItem", /HealthManager/).to_json
    end


    get "/gateways", :auth => [:user] do

      puts "======gateways===="

      getItems("getItem", /-Provisioner/).to_json
    end


    get "/routers", :auth => [:user] do

      puts "======routers===="

      getItems("getItem", /Router/).to_json
    end


    get "/dropletExecutionAgents", :auth => [:user] do
      
      puts "======dropletExecutionAgents===="

      getItems("getDropletExecutionAgents", /DEA/).to_json
    end


    post "/dropletExecutionAgent", :auth => [:admin] do

      scriptPath = File.dirname(__FILE__) + "/scripts/newDEA.sh"     

      taskID = launchCommand("#{scriptPath}")

      result = {:taskID => taskID}

      result.to_json

    end


    get "/tasks", :auth => [:user] do

      puts "======tasks===="

      result = {}

      result[:items] = []

      tasks = {}

      @@tasksSemaphore.synchronize {
  
        tasks.merge!(@@tasks)
    
      }

      tasks.each do |taskID, task|

        result[:items].push({
                              :id      => task[:id],
                              :command => task[:command],
                              :state   => task[:state],
                              :started => task[:started]
                            })

      end

      result.to_json

    end


    get "/taskStatus", :auth => [:user] do

      taskID  = params["taskID"].to_i
      updates = params["updates"] || "false"

      sessionLastTaskUpdate = session[:lastTaskUpdate] || 0


      result = {}

      task = nil

      @@tasksSemaphore.synchronize {
        task = @@tasks[taskID]     
      }

      unless task.nil?    

        task[:semaphore].synchronize {

          data = []

          if (updates == "false") || (sessionLastTaskUpdate == 0)

            data = task[:output]

          else

            if sessionLastTaskUpdate >= task[:updated]
            
              task[:condition].wait(task[:semaphore])

            end

            task[:output].each do |output|            

              if sessionLastTaskUpdate < output[:time]

                data.push(output)    

              end

            end       

          end

          result.merge!({
                          :id     => task[:id],
                          :state  => task[:state],
                          :output => data
                        })

          session[:lastTaskUpdate] = task[:updated]

        }

      end

      result.to_json

    end


    get "/stats" do
      send_file File.expand_path("stats.html", settings.public_folder)
    end

  
    get "/currentStatistics" do

      stats = getCurrentStats()

      if stats.nil?
        halt 503
      end

      stats.to_json

    end    


    get "/statistics" do

      puts "======statistics===="

      result = {}
  
      result["label"] = @cloudControllerURI
      result["items"]  = []

      @@statsSemaphore.synchronize {

        begin

          if File.exists?(@statsFile)
            result["items"] = JSON.parse(IO.read(@statsFile))
          end

        rescue => error

          @logger.debug("Error reading stats file: #{error}")

        end

      }

      result.to_json      

    end
    
    post "/statistics", :auth => [:admin] do

      puts "parameters: #{params}"

      stats = {}

      stats["timestamp"]         = params["timestamp"].to_i
      stats["users"]             = params["users"].to_i
      stats["users_with_apps"]   = params["users_with_apps"].to_i
      stats["apps"]              = params["apps"].to_i
      stats["running_instances"] = params["running_instances"].to_i
      stats["total_instances"]   = params["total_instances"].to_i
      stats["deas"]              = params["deas"].to_i

      if !saveStats(stats)
        halt 500
      end

      [200, stats.to_json]

    end


    def launchCommand(command)

      currentTime = getTimeInMillis(Time.now)

      task = {}

      task[:semaphore] = Mutex.new
      task[:condition] = ConditionVariable.new

      task[:started] = currentTime
      task[:updated] = currentTime
      task[:state]   = "RUNNING"
      task[:command] = command
      task[:output]  = []

      task[:in], task[:out], task[:err], task[:external] = Open3.popen3(command)

      Thread.new do 
        line = ""
        while not line.nil? do
          line = task[:out].gets
          updateTask(task, "out", line)
        end
      end

      Thread.new do 
        line = ""
        while not line.nil? do
          line = task[:err].gets
          updateTask(task, "err", line)
        end
      end

      Thread.new do
        task[:external].join
        task[:semaphore].synchronize {
          task[:state] = "FINISHED"             
          task[:condition].signal()
        }
      end

      @@tasksSemaphore.synchronize {

        task[:id] = @@taskIndex

        @@tasks[task[:id]] = task

        @@taskIndex = @@taskIndex + 1

      }

      task[:id]

    end


    def updateTask(task, type, line)
      task[:semaphore].synchronize {
        currentTime = getTimeInMillis(Time.now)
        task[:updated] = currentTime
        task[:output].push({:type => type, :time => currentTime, :text => line})
        task[:condition].signal()
      }
    end


    get "/fetch", :auth => [:user] do
      configuration = getConfiguration()
      item = configuration["items"][params["uri"]]
      result = getItemResult("getItem", params["uri"], item, nil)
      result.to_json
    end


    get "/download", :auth => [:user] do
      path = params["path"]
      validateLogFileRequest(path)
      file = File.new(path)
      send_file(file, :disposition => "attachment", :filename => File.basename(file))
    end


    get "/logs", :auth => [:user] do

      puts "======logs===="

      logs = {}

      logs[:items] = []  

      getLogFiles().each do |logFile|

        logs[:items].push({
                            :path => logFile,
                            :time => getTimeInMillis(File.mtime(logFile)),
                            :size => File.size(logFile)
                          })

      end

      logs.to_json

    end


    get "/log", :auth => [:user] do

      path  = params["path"]
      start = params["start"]

      validateLogFileRequest(path)

      size = File.size(path)

      start = start.nil? ? -1 : start.to_i
      start = (size - @logFilePageSize) if start < 0
      start = [start, 0].max

      readSize = [size - start, @logFilePageSize].min

      contents = IO.read(path, readSize, start)

      result = {
                 :path => path,
                 :start => start,
                 :readSize => readSize,
                 :pageSize => @logFilePageSize,
                 :fileSize => size,
                 :data => contents.nil? ? "" : contents
               }

      if readSize < size

        if start > 0
          result.merge!(:first => 0)
          back = [start - @logFilePageSize, 0].max
          result.merge!(:back => back)
        end

        if start + readSize < size
          forward = [start + @logFilePageSize, size - @logFilePageSize].min
          result.merge!(:forward => forward)
          result.merge!(:last => -1)
        end

      end

      result.to_json

    end

    get "/users", :auth => [:user] do

      puts "======users===="

      result = {}

      users = []

      users = Users.all  # array

      users_hash = []
      users.each do |user|
        users_hash.push(user.attributes)
      end
      users = users_hash

      users.each_index do |index|

        guid = users[index][:id]

        cc_user = Object.new
        DataMapper.repository(:extra) do
          cc_user = User_cc.first(:guid => guid)
        end

        if cc_user == nil
          users[index][:org_name] = ""
        else

          org_user = Object.new
          DataMapper.repository(:extra) do
            org_user = Organizations_users.first(:user_id => cc_user.id)
          end

          if org_user == nil
            users[index][:org_name] = ""
          else

            org = Object.new
            DataMapper.repository(:extra) do
              org = Organization.get(org_user.organization_id)
            end

            users[index][:org_name] = org.name
          end
        end
      end

      result['items'] = users

      result.to_json
    end

    get "/spaces", :auth => [:user] do

      puts "======spaces===="

      result = {}

      spaces = []

      DataMapper.repository(:extra) do
        spaces = Spaces.all

        spaces_hash = []
        spaces.each do |space|
          spaces_hash.push(space.attributes)
        end
        spaces = spaces_hash

        spaces.each_index do |index|
          space = spaces[index]

          org = Object.new
          DataMapper.repository(:extra) do
            org = Organization.get(space[:organization_id])
          end

          spaces[index][:org_name] = org.name

          apps = Object.new
          DataMapper.repository(:extra) do
            apps = Apps.all(:space_id=>space[:id])
          end

          running_apps = 0
          stopped_apps = 0
          unknown_apps = 0
          apps.each do |app|
            if app.not_deleted == true
              if (app.state == "STARTED" && app.package_state == "STAGED")
                running_apps += 1
              elsif app.state == "STOPPED"
                stopped_apps += 1
              else
                unknown_apps += 1
              end
            end

          end

          spaces[index][:running_apps] = running_apps
          spaces[index][:stopped_apps] = stopped_apps
          spaces[index][:unknown_apps] = unknown_apps

        end
      end

      result["items"] = spaces

      result.to_json

    end

    get "/applications", :auth => [:user] do

      puts "======applications===="

      result = {}

      apps = Object.new
      DataMapper.repository(:extra) do
        apps = Apps.all(:not_deleted=>true)
        
        apps_hash = []
        apps.each do |app|
          apps_hash.push(app.attributes)
        end
        apps = apps_hash

        apps.each_index do |index|
          space = Spaces.get(apps[index][:space_id])
          apps[index][:space_name] = space.name
        end
      end

      result['items'] = apps

      result.to_json

    end


    def getItems(getFunction, typePattern)

      configuration = getConfiguration()

      result = {}

      result["connected"] = configuration["connected"]
      result["items"] = []  

      configuration["items"].each do |url, item|

        typePatternIndex = item["type"] =~ typePattern

        unless typePatternIndex.nil?
          itemName = typePatternIndex == 0 ? item["host"] : item["type"].sub(typePattern, "")
          result["items"].push(getItemResult(getFunction, getItemURI(item), item, itemName))
        end

      end

      result

    end


    def getItem(uriParameter, credentialsArray)

      uri = URI.parse(uriParameter)

      http    = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri.request_uri)

      request.basic_auth(credentialsArray[0], credentialsArray[1])

      http.request(request)

    end


    # For some reason the API does not always return the list of running apps
    # for DEAs.  Unfortunately an empty array is returned in this case, so we
    # have no way of knowing if the API failed or if the DEA Partially does have
    # zero running apps.  To get around this problem we check the list of
    # running apps for each DEA.  If the list is zero length we call the API
    # again until either we get a list of apps or we reach the max retry limit
    # in which case we assume the DEA really does have zero running apps.
    def getDropletExecutionAgents(uri, credentialsArray)

      response = getItem(uri, credentialsArray)

      running_apps = JSON.parse(response.body)["running_apps"]

      attempt = 0

      while response.code == "200" && (running_apps && (running_apps.length == 0)) && (attempt < @dropletExecutionAgentRetries)

        @logger.debug("getDropletExecutionAgents(#{uri}, #{attempt}) : no running apps returned, refetching data...")

        attempt += 1

        sleep(0.1)

        response = getItem(uri, credentialsArray)

        running_apps = JSON.parse(response.body)["running_apps"]

      end

      if (response.code == "200") && (attempt == @dropletExecutionAgentRetries)        
        @logger.debug("getDropletExecutionAgents(#{uri}, #{attempt}) : max retries attempted yet still no running apps returned, assume zero running apps.")
      end

      response

    end


    def getItemResult(getFunction, uri, item, name)

      result = {"uri" => uri}

      unless name.nil?
        result.merge!("name" => name)
      end

      begin

        response = send(getFunction, uri, (item.nil? ? [] : item["credentials"]))

        if response.is_a?(Net::HTTPSuccess) then
          result.merge!("connected" => true, "data" => JSON.parse(response.body))
        else
          result.merge!("connected" => false, "data" => (item.nil? ? {} : item), "error" => response.code + "<br/><br/>" + response.body)
          @logger.debug("getItemResult(" + uri + ") : error [" + response.code + " - " + response.body + "]")
        end

      rescue => error
        result.merge!("connected" => false, "data" => (item.nil? ? {} : item), "error" => error)
        @logger.debug("getItemResult(" + uri + ") : error [#{error.inspect}]")
      end

      result

    end


    def getLogFiles()

      files = Array.new

      @logFiles.each do |logFile|

        logFilePath = logFile.to_s()

        if File.directory?(logFilePath)

          Dir.entries(logFilePath).each do |fileName|

            filePath = File.join(logFilePath, fileName)

            if File.file?(filePath)
              files.push(filePath)
            end

          end

        else

          Dir.glob(logFilePath).each { |fileName| files.push(fileName) }

        end

      end

      files

    end


    def getConfiguration()

      data = {}

      @@semaphore.synchronize {

        while @@cache["items"].nil?
          @@condition.wait(@@semaphore)
        end

        data.merge!(@@cache)
      }

      data

    end


    delete "/removeConfigurationItem", :auth => [:user] do

      if params["uri"].nil?

        @@semaphore.synchronize {

          @@useCache = false

          @@condition.broadcast()

          while !@@useCache
            @@condition.wait(@@semaphore)
          end

        }

      else

        @@semaphore.synchronize {

          if File.exists?(@dataFile)

            @@cache = JSON.parse(IO.read(@dataFile))          

            @@cache["items"].delete(params["uri"])
            @@cache["notified"].delete(params["uri"])

            File.open(@dataFile,"w") { |file| file.write(JSON.pretty_generate(@@cache)) }

          end
        }

      end

      [200, {:uri => params["uri"]}.to_json]

    end


    def getTimeUntilGenerateStats
      current_time = Time.now.to_i
      refresh_time = (Date.today.to_time + 60 * @statsRefreshTime).to_i
      time_difference = refresh_time - current_time
      (time_difference > 0) ? time_difference : (refresh_time + 60 * 60 * 24) - current_time      
    end

    
    def getCurrentStats

      stats = nil

      configuration = getConfiguration()

      while configuration["items"].nil?
        @logger.debug("Configuration not loaded yet so waiting #{NATS_DISCOVERY_TIMEOUT} seconds before trying to save stats again...")
        sleep(NATS_DISCOVERY_TIMEOUT)
        configuration = getConfiguration()
      end    

      retrieved = false
    
      users             = 0
      apps              = 0
      running_instances = 0
      total_instances   = 0

      users = Users.count
      DataMapper.repository(:extra) do
        apps              = Apps.count(:not_deleted=>true)
        running_instances = Apps.sum(:instances, :not_deleted=>true, :state=>'STARTED')
        total_instances   = Apps.sum(:instances, :not_deleted=>true)
      end

      users_with_apps = 0

      deas = 0

      configuration["items"].each do |url, item|
        deas = deas + 1 unless (item["type"] =~ /DEA/).nil?
      end

      current_time = getTimeInMillis(Time.now)

      stats = {:timestamp => current_time, :users => users, :users_with_apps => users_with_apps, :apps => apps, :running_instances => running_instances, :total_instances => total_instances, :deas => deas}

      stats

    end


    def saveStats(stats)

        result = false

        if !stats.nil?

          @@statsSemaphore.synchronize {

            begin

              statsArray = []

              if File.exists?(@statsFile)
                statsArray = JSON.parse(IO.read(@statsFile))
              end

              @logger.debug("Writing stats: #{stats}")

              statsArray.push(stats)

              File.open(@statsFile, "w") { |file| file << JSON.pretty_generate(statsArray) }

              result = true

            rescue => error

              @logger.debug("Error writing stats: #stats, error: #{error}")

            end

          }

        end

        result

    end


    def generateStats()

      stats = getCurrentStats()

      attempt = 0

      while !saveStats(stats) && (attempt < @statsRetries)
        attempt += 1
        @logger.debug("Waiting #{@statsRetryInterval} seconds before trying to save stats again...")
        sleep(@statsRetryInterval)
        stats = getCurrentStats()
      end

      @logger.debug("Reached max number of stat retries, giving up for now...") if attempt == @statsRetries

    end


    def isMonitored(component)

      @monitoredComponents.each do |type|

        if !(component =~ /#{type}/).nil? || type.casecmp("ALL") == 0
          return true
        end

      end

      false

    end


    def sendEmail(disconnected)

      if disconnected.length > 0

        recipients = @receiverEmails.join(", ")
    
        begin

          title = "[" + @cloudControllerURI + "] "

          if disconnected.length == 1
            title += disconnected.first["type"] + " is down"
          else
            title += "Multiple Cloud Foundry components are down"
          end

          rows = ""          
          disconnected.each do |item|
            rows += "<tr style='background-color: rgb(230, 230, 230); color: rgb(35, 35, 35);'>"
            rows += "  <td style='border: 1px solid rgb(100, 100, 100);'>" + item["type"] + "</td>"
            rows += "  <td style='border: 1px solid rgb(100, 100, 100);'>" + item["uri"]  + "</td>"
            rows += "</tr>"
          end

          email = <<END_OF_MESSAGE
From: #{@senderEmail[:account]}
To: #{recipients}
Importance: High
MIME-Version: 1.0
Content-type: text/html
Subject: #{title}

<div style="font-family: verdana,tahoma,sans-serif; font-size: .9em; color: rgb(35, 35, 35);">
  <div style="font-weight: bold; margin-bottom: 1em;">Cloud Controller: #{@cloudControllerURI}</div>
  <div style="margin-bottom: .7em;">The following Cloud Foundry components are down:</div>
</div>

<table cellpadding="5" style="border-collapse: collapse; border: 1px solid rgb(100, 100, 100); font-family: verdana,tahoma,sans-serif; font-size: .9em">
  <tr style="background-color: rgb(150, 160, 170); color: rgb(250, 250, 250); border: 1px solid rgb(100, 100, 100);">
    <th style="border: 1px solid rgb(100, 100, 100);">Type</th>
    <th style="border: 1px solid rgb(100, 100, 100);">URI</th>		
  </tr>
  #{rows}
</table>
END_OF_MESSAGE

          Net::SMTP.start(@senderEmail[:server]) do |smtp|
            smtp.send_message email, @senderEmail[:account], @receiverEmails
          end

          @logger.debug("Email '#{title}' sent to #{recipients}")

        rescue => error
          @logger.debug("Error sending email '#{title}' to addresses #{recipients}: #{error}")
        end

      end

    end


    def updateConnectionStatus(type, uri, connected, disconnectedList)
      if isMonitored(type)
        if !connected
          componentEntry = @@cache["notified"][uri]
          if componentEntry.nil?
            componentEntry = {"type" => type, "uri" => uri, "count" => 0}
          end
          componentEntry["count"] += 1
          @@cache["notified"][uri] = componentEntry
          if componentEntry["count"] < @componentConnectionRetries
            @logger.debug("The #{type} component #{uri} is not responding, its status will be checked again next refresh")
          elsif componentEntry["count"] == @componentConnectionRetries
            @logger.debug("The #{type} component #{uri} has been recognized as disconnected")
            disconnectedList.push(componentEntry)
          else
            @logger.debug("The #{type} component #{uri} is still not responding")
          end
        else
          @@cache["notified"].delete(uri)    
        end
      end
    end


    def getItemURI(item)
      "http://" + item["host"] + "/varz"
    end


    def getTimeInMillis(time)
      (time.to_f * 1000).to_i
    end

    def get_db (itemJSON, type)
      if type == "uaa"
        uaa_uri = getItemURI(itemJSON) + "/spring.application"
        result = getItemResult("getItem", uaa_uri, itemJSON, itemJSON['type'])

        db = result["data"]["config"]["uaa"]["object"]["database"]
        db_ip_port = /^.*(\d+\.\d+\.\d+\.\d+:\d+).*$/.match(db["url"])[1]

        return "postgres://"+ db["username"] + ":" + db["password"]+ "@" + db_ip_port + "/uaa"
      elsif type == "cc"
        result = getItemResult("getItem", getItemURI(itemJSON), itemJSON, itemJSON['type'])
        return result["data"]["config"]["db"]["database"]
      end
    end


  end

end

