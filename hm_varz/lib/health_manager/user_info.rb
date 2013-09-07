require "net/http"
require "uri"
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

module HealthManager

  class UserInfo

    include HealthManager::Common

    attr_reader :varz

    def initialize(varz)
      @varz = varz
    end

    def start

      NATS.request("vcap.component.discover") do |item|

        itemJSON = JSON.parse(item)

        uaa_db = get_uaa_db(itemJSON) if itemJSON["type"] =~ /^uaa$/
        puts uaa_db.inspect

        if (uaa_db != "")

          DataMapper.setup(:default, uaa_db)

          users = Users.all(:fields => [:username, :email])

          users_hash = []

          users.each do |user|
            users_hash.push(user.attributes)
          end

          puts "================== users_hash =================="
          puts users_hash.inspect

          varz[:users] = users_hash

          #VCAP::Component.varz.synchronize do
          #  VCAP::Component.varz[:users] = users_hash
          #end

        end

      end

    end

    def get_uaa_db (itemJSON)

      uaa_uri = "http://" + itemJSON["host"] + "/varz/spring.application"

      begin

        uri = URI.parse(uaa_uri)

        http    = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Get.new(uri.request_uri)

        request.basic_auth(itemJSON["credentials"][0], itemJSON["credentials"][1])

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess) then

          data = JSON.parse(response.body)

          db = data["config"]["uaa"]["object"]["database"]

          db_ip_port = /^.*(\d+\.\d+\.\d+\.\d+:\d+).*$/.match(db["url"])[1]

          return "postgres://"+ db["username"] + ":" + db["password"]+ "@" + db_ip_port + "/uaa"

        else

          logger.error("Error getting UAA database info: #{response.code}")

        end

      rescue => error

        logger.error("Error getting UAA database info: #{error}")

      end

      ""

    end

  end

end
