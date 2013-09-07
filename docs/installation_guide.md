Installation Guide
===

First, please make sure your server can access the Internet, such as check proxy and dns resolving issues. Below is an example, type in shell:

	export http_proxy="http://9.123.107.67:3128"
	export https_proxy="https://9.123.107.67:3128" 

Second, install postgres support library, type in shell:
	
	sudo apt-get install libpq-dev

Third, bundle install with local gems, for example type in shell:

	cd ~/admin_ui

	/var/vcap/packages/ruby/bin/bundle install --local

Fourth, change nats address and may be delete file in data directory. For example:

	vim ~/admin_ui/config/default.yml
	mbus: nats://nats:nats@*.*.*.*:4222  (your nats address)

	cd ~/admin_ui/data/
	rm data.json
	rm stats.json

Last, start server and enjoy it. For example type in shell:

	/var/vcap/packages/ruby/bin/ruby ~/admin_ui/bin/admin