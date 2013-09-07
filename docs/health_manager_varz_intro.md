admin_ui new feature
===

## problem description

I'd like to see if we can make a change request to pivotal fairly soon.  Do you think it would be possible for you to produce the set of changes to the /varz output for the Health Manager to add the user data to the output?  For now let's ignore spaces and orgs (unless its trivial to add it to the user data).  I'm assuming the edits to the existing CF/HealthManager code won't be too much but if there's a smaller change for some other /varz data let me know - I'd like the first change request to be a simple one that should hopefully be accepted w/o much push back.

For NG health manager /varz, do you want the outputs follow the V1 format?

there's a users field already in the varz output? Just empty.

Start with

	"users": [
		{
			"email" : "abc@abc.com"
		},
		{
			"email" : "test@test.com"
		},
	]

## health_manager varz endpoint analyse

### health_manager v1 varz outputs


### health_manager v2 varz outputs


### health_manager v1 varz relative source code 

Firstly, we have to find the right source code, as we all know, we could use [vcap project](https://github.com/cloudfoundry/vcap) to deploy a whole cloudfoundry of v1.

Then, we can find the submodule in vcap project, click the `cloud_controller @ 31ab65c`, we can find health_manager v1 source code.

In v1 there is only one file for health\_manager, where it actually expose user info with varz enpoint. But it fetches those info from database.

For more details, we could see the relatvie source code in this page.

[external link](https://github.com/cloudfoundry/cloud_controller/blob/31ab65cdf0b9863677675b3812aac7305001267e/health_manager/lib/health_manager.rb)

Line 729, we fetch the user_email from the database model `User` and expose it with varz.

	VCAP::Component.varz[:users] = User.all_email_addresses.map {|e| {:email => e}}

Line 179 - 190  Function : configure_database

Line 224 

	ActiveRecord::Base.establish_connection(db_config)

Codes list above show that we will use cloud_controller config file which contains database connection info.

So, in summary, For NG health manager /varz, we also have to connect database to fetch user email info. 

### health_manager v2 varz relative source code

when health_manager starts, we will new a object which mainly handles user info.

Obvously, we have to figure out the right solution about getting the database connection info.

	* add some fields in health_manager config file, which is healh_manager.yml
	* request 'varz.discover' channel via nats, get the uaa varz info, and get the 

And we also have to add some gems to access the database, for details we can reference implementation in V1.



Notes:

1. bundle install  could not use `bundle install` as there may be some gems are older

	gems 

2. bundle install --local

3. sudo apt-get install libpq

4. ruby execution path  /var/vcap/packages/ruby_next/bin