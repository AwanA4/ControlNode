require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'json'
require 'puma'
require 'lxc'
require 'net/http'
require 'thread'
require 'mongo'
require 'socket'
require 'timeout'

configure{ set :server, :puma}
configure{ :development}
configure{ enable :logging, :dump_errors, :raise_errors}
configure do
	conn = Mongo::Client.new(['10.151.34.168:27017'], :database => 'CodeLoud')
	set :mongo_db, conn
end

$process_hash = Hash.new
$Process = Struct.new(:user, :cpu, :ram, :repo, :container, :ip_addr, :started)
$all_output = ''
$Template = LXC::Container.new('ComputeNode')
$thread_list = Array.new

def randomChar(length)
	o = [('a'..'z'), ('A'..'Z')].map{|i| i.to_a}.flatten
	string = (0..length).map{ o[rand(o.length)]}.join
	return string
end

def to_bson_id(val)
	return BSON::ObjectId.from_string(val)
end

def watch_process(info)
	process = LXC::Container.new(info[:container])
	object_id = to_bson_id(info[:container])
	sleep(1) while process.ip_addresses[0].nil?

	puts info[:container] + ' get IP address'
	info[:ip_addr] = process.ip_addresses
	ip_addr = info.ip_addr[0]

	sleep(1) until is_port_open?(ip_addr, 80)

	http = Net::HTTP.new(ip_addr, '80')
	http.read_timeout = 10
	check_alive = Net::HTTP::Get.new('/status')
	usage_request = Net::HTTP::Get.new('/usage')
	theRepo = Hash.new
	begin
		repo_post = Net::HTTP::Post.new('/repo')
		repo_post.body = {'repo' => info['repo'].to_s}.to_json
		puts info[:container] + " send repo " + info[:repo]
		response = http.request(repo_post)
	rescue Timeout::Error => e
		puts "Send repo #{e}"
		retry
	else
		puts info[:container] + ' response ' + response.body
	end

	begin
		puts "Send start command to #{info[:container]}"
		start_get = Net::HTTP::Get.new('/start')
		response = http.request(start_get)
	rescue Timeout::Error => e
		puts "Error start #{e}"
		retry
	else
		puts info[:container] + " send start"
		start_time = Time.now
	end

	begin
		#Get usage
		response = http.request(usage_request)
		parsed_response = JSON.parse(response.body)
		elapsed = Time.now - start_time
		#Save to database
		result = settings.mongo_db[:Node].find(:_id => object_id).
			find_one_and_update('$push' =>
								{
									:usages =>
									{
										time: elapsed.to_i,
										cpu: parsed_response[:cpu],
										ram: parsed_response[:ram]
									}
								})

		puts 'Checking if process in ' + info[:container] + ' is still alive'
		response = http.request(check_alive)
		parsed_response = JSON.parse(response.body)
		puts parsed_response
		if parsed_response[:finished]
			puts 'Process ' + info[:container] + 'finished'
		end
	rescue Timeout::Error => e
		puts 'Check alive timeout'
		next
	else
		#Sleep for fixed time
		sleep(20)
	end until parsed_response['finished']

	begin
		puts 'Getting all output ' + info[:container]
		output_request = Net::HTTP::Get.new('/all_output')
		response = http.request(output_request)
		parsed_response = JSON.parse(response.body)
		result = settings.mongo_db[:Node].find(:_id => object_id).
			find_one_and_update('$set' =>
								{
									stdout: parsed_response[:stdout],
									stderr: parsed_response[:stderr],
								})
		$all_output = parsed_response
	rescue Timeout::Error => e
		puts 'Error retrieving all output ' + info[:container]
		retry
	end
	#Put output to database

	#
rescue => e
	p e
ensure
	#Remove process from hash
	$process_hash.delete(info[:container])
	$thread_list.delete(Thread.current)
	result = settings.mongo_db[:Node].find(:_id => object_id).
		find_one_and_update('$set' =>
							{
								status: true
							})
	begin
		puts 'Stopping container ' + info[:container]
		process.stop
		puts 'Destroying ' + info[:container]
		process.destroy
	rescue => e
		p e
	end
end

def is_port_open?(ip, port)
	begin
		Timeout::timeout(1) do
			begin
				s = TCPSocket.new(ip, port).close
				puts "Socket open"
				return true
			rescue  Errno::ECONNREFUSED, Errno::EHOSTUNREACH
				return false
			end
		end
	rescue Timeout::Error
	end
	return false
end

before do
	next unless request.post?
	request.body.rewind
	@req_data = JSON.parse request.body.read
end

post '/container' do
	#Sent data => user, cpu, ram, repo
	unless @req_data['user'].nil? or @req_data['ram'].nil? or @req_data['repo'].nil?
		result = settings.mongo_db[:Node].insert_one({
			cpu: @req_data['cpu'],
			ram: @req_data['ram'],
			status: false,
			stdout: '',
			stderr: '',
			url: @req_data['repo'],
			usages: [],
			stdin: '',
			server: Socket.ip_address_list[1].ip_address
		})
		container_name = result.inserted_id.to_s
		new_container = $Template.clone(container_name, {:flags => LXC::LXC_CLONE_SNAPSHOT})

		#start the process
		#new_container.set_cgroup_item('memory.limit_in_bytes', @req_data['ram'].to_s)
		new_container.save_config
		new_container.start({:daemonize => true})
		new_process = $Process.new(
			@req_data['user'],
			@req_data['cpu'],
			@req_data['ram'],
			@req_data['repo'],
			container_name,
			new_container.ip_addresses,
			false
		)
		$process_hash.store(container_name, new_process)
		#Start watch_process thread
		$thread_list << Thread.new{watch_process(new_process)}
		result = settings.mongo_db[:User].find(:_id => to_bson_id(@req_data['user'])).
			find_one_and_update('$push' =>
								{
									:nodes => to_bson_id(container_name)
								})

		content_type :json
		{
			"user" => new_process[:user],
			"cpu" => new_process[:cpu],
			"ram" => new_process[:ram],
			"repo" => new_process[:repo],
			"id" => new_process[:container]
		}.to_json
	end
end

get '/container/:id/output' do
	unless $process_hash[params[:id]].nil?
		info = $process_hash[params[:id]]
		ip_addr = info[:ip_addr][0]
		http = Net::HTTP.new(ip_addr, '80')
		req = Net::HTTP::Get.new('/output')
		response = http.request(req)

		content_type :json
		response.body unless response.nil?
	else
		#Read database and redirect request
		result = settings.mongo_db[:Node].find(:_id => to_bson_id(params[:id]))
		if result and not result[:status]
				http = Net::HTTP.new(result[:server], '80')
				req = Net::HTTP::Get.new("/container/#{params[:id]}/output")
			begin
				response = http.request(req)
			rescue Timeout::Error => e
				p e
			else
				content_type :json
				response.body unless response.nil?
			end
		end
	end
end

get '/container/:id/complete_output' do
	result = settings.mongo_db[:Node].find(:_id => to_bson_id(params[:id]))
	if result and result[:status]
		content_type :json
		{
			'stdout' => result[:stdout],
			'stderr' => result[:stderr]
		}.to_json
	end
end

post '/container/:id/input' do
	input = @req_data['stdin']
	unless $process_hash[params[:id]].nil?
		info = $process_hash[params[:id]]
		http = Net::HTTP.new(info[:ip_addr][0], '80')
		req = Net::HTTP::Post.new('/input')
		req.body = {'stdin' => input}.to_json
		http.request(req)
	else
		#Read database and redirect the request
		result = settings.mongo_db[:Node].find(:_id => to_bson_id(params[:id]))
		if result and not result[:status]
				http = Net::HTTP.new(result[:server], '80')
				req = Net::HTTP::Post.new("/container/#{params[:id]}/input")
				req.body = {'stdin' => input}.to_json
			begin
				http.request(req)
			rescue Timeout::Error => e
				p e
			end
		end
	end
end

#dummy method for debugging purpose
get '/container/:id/info' do
	#unless $process_hash[params[:id]].nil?
		#info = $process_hash[params[:id]]

		#content_type :json
		#{
			#'id' => info[:container],
			#'repo' => info[:repo],
			#'cpu' => info[:cpu],
			#'ram' => info[:ram],
			#'finished' => false
		#}.to_json
	#else
		#Check database and redirect the request
		result = settings.mongo_db[:Node].find(:_id => to_bson_id(params[:id]))
		if result
			content_type :json
			{
				'id' => result[:_id],
				'repo' => result[:url],
				'cpu' => result[:cpu],
				'ram' => result[:ram],
				'finished' => result[:status]
			}.to_json
		end
	#end
end

post '/container/:id/stop' do
	unless $process_hash[params[:id]].nil?
		if @req_data[:stop]
			info = $process_hash[params[:id]]
			http = Net::HTTP.new(info[:ip_addr], '80')
			stop_req = Net::HTTP::Post.new('/stop')
			stop_req.body = {"stop" => true}.to_json
			begin
				response = http.request(stop_req)
				parsed = JSON.parse(response.body)
				if parsed[:stopped]
					content_type :json
					{"stopped" => true}.to_json
				end
			rescue Timeout::Error => e
				content_type :json
				{"stopped" => false}.to_json
			end
		end
	else
		#Read database and redirect request
		result = settings.mongo_db[:Node].find(:_id => to_bson_id(params[:id]))
		if result and @req_data[:stop] and not result[:status]
			http = Net::HTTP.new(result[:server], '80')
			stop_req = Net::HTTP::Post.new("/container/#{params[:id]}/stop")
			stop_req.body = {'stop' => true}.to_json
			begin
				response = http.request(stop_req)
				parsed = JSON.parse(response.body)
				if parsed[:stopped]
					content_type :json
					{"stopped" => true}.to_json
				end
			rescue Timeout::Error => e
				content_type :json
				{"stopped" => false}.to_json
			end
		end
	end
end
