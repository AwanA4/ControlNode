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

$process_hash = Hash.new
$Process = Struct.new(:user, :cpu, :ram, :repo, :container, :ip_addr)
$all_output = ''
$Template = LXC::Container.new('ComputeNode')
$thread_list = Array.new

def randomChar(length)
	o = [('a'..'z'), ('A'..'Z')].map{|i| i.to_a}.flatten
	string = (0..length).map{ o[rand(o.length)]}.join
	return string
end

def watch_process(info)
	process = LXC::Container.new(info[:container])
	sleep(1) while process.ip_addresses[0].nil?

	puts info[:container] + ' get IP address'
	info[:ip_addr] = process.ip_addresses
	ip_addr = info.ip_addr[0]

	sleep(1) until is_port_open?(ip_addr, 80)

	http = Net::HTTP.new(ip_addr, '80')
	http.read_timeout = 10
	check_alive = Net::HTTP::Get.new('/status')
	usage_request = Net::HTTP::Get.new('/usage')
	repo_get = Net::HTTP::Get.new('/repo')
	theRepo = Hash.new
	begin
		repo_post = Net::HTTP::Post.new('/repo')
		repo_post.body = {'repo' => info['repo'].to_s}.to_json
		puts info[:container] + " send repo " + info[:repo]
		response = http.request(repo_post)
	rescue Timeout::Error => e
		puts 'Send repo #{e}'
		retry
	else
		puts info[:container] + ' response ' + response.body
		#theRepo = JSON.parse(response.body)
		#puts theRepo[:repo]
	end

	begin
		puts "Send start command to #{info[:container]}"
		start_get = Net::HTTP::Get.new('/start')
		response = http.request(start_get)
	rescue Timeout::Error => e
		puts 'Error start #{e}'
		retry
	else
		puts info[:container] + " send start"
		$started = true	
	end

	begin
		puts 'Checking if process in ' + info[:container] + ' is still alive'
		response = http.request(check_alive)
		parsed_response = JSON.parse(response.body)
		puts parsed_response
		if parsed_response[:finished]
			puts 'Process ' + info[:container] + 'finished'
		end
		#Get usage

		#Save to database
		#
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
		container_name = @req_data['user'] + '-' + randomChar(10)
		new_container = $Template.clone(container_name, {:flags => LXC::LXC_CLONE_SNAPSHOT})

		#start the process
		#new_container.set_cgroup_item('memory.limit_in_bytes', @req_data['ram'].to_s)
		new_container.save_config
		new_container.start({:daemonize => true})
		new_process = $Process.new(@req_data['user'], @req_data['cpu'], @req_data['ram'], @req_data['repo'], container_name, new_container.ip_addresses)
		#$process_hash.store(container_name, new_process)
		#Start watch_process thread
		#$process_queue.push(new_process)
		$thread_list << Thread.new{watch_process(new_process)}
		redirect ('/container/' + container_name + '/info')
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
		content_type :json
		$all_output.to_json unless $all_output.nil?
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
	end
end

get '/container/:id/info' do
	unless $process_hash[params[:id]].nil?
		info = $process_hash[params[:id]]

		content_type :json
		{'id' => info[:container],
   'user' => info[:user],
		'repo' => info[:repo],
		'cpu' => info[:cpu],
		'ram' => info[:ram],
		'ip' => info[:ip_addr][0].to_s,
		'started' => $started
		}.to_json
	end
end
