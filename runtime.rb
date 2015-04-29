require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'json'
require 'puma'
require 'lxc'
require 'net/http'
require 'thread'
require 'mongo'

configure{ set :server, :puma}

$process_hash = Hash.new
$Process = Struct.new(:user, :cpu, :ram, :repo, :container, :ip_addr)
$Template = LXC::Container.new('ComputeNode')
$thread_list = Array.new

def randomChar(length)
	o = [('a'..'z'), ('A'..'Z')].map{|i| i.to_a}.flatten
	string = (0..length).map{ o[rand(o.length)]}.join
	return string
end

def watch_process(info)
	process = LXC::Container.new(info[:container])
	while process.ip_addresses[0].nil?
		sleep(0.5)
	end
	info[:ip_addr] = process.ip_addresses
	ip_addr = info.ip_addr[0]
	http = Net::HTTP.new(ip_addr, '80')
	check_alive = Net::HTTP::Get.new('/status')
	usage_request = Net::HTTP::Get.new('/usage')

	repo_post = Net::HTTP::Post.new('/repo')
	repo_post.body = {'repo' => info[:repo]}.to_json
	http.request(repo_post)
	start_get = Net::HTTP::Get.new('/start')
	http.request(start_get)
	begin
		response = http.request(check_alive)
		parsed_response = JSON.parse(response.body.read)
		#Get usage

		#Save to database
		#
		#Sleep for fixed time
		sleep(20)
	end until parsed_response['finished']
	output_request = Net::HTTP::Get.new('/all_output')
	response = http.request(output_request)
	parsed_response = JSON.parse(response.body)
	#Put output to database

	#
	#Remove process from hash
	$process_hash.delete(info[:container])
	$thread_list.delete(Thread.current)
	process.stop
	process.destroy
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
		new_container.start({:daemonize => true})
		#while new_container.ip_addresses[0].nil?
		#end
		new_process = $Process.new(@req_data['user'], @req_data['cpu'], @req_data['ram'], @req_data['repo'], container_name, new_container.ip_addresses)
		$process_hash.store(container_name, new_process)
		#Start watch_process thread
		$thread_list << Thread.new{watch_process(new_process)}
		redirect ('/container/' + container_name + '/info')
	end
end

get '/container/:id/output' do
	if not $process_hash[params[:id]].nil?
		info = $process_hash[params[:id]]
		ip_addr = info[:ip_addr]
		http = Net::HTTP.new(ip_addr, '80')
		req = Net::HTTP::Get.new('/output')
		response = http.request(req)

		content_type :json
		response.body
	end
end

post '/container/:id/input' do
	input = @req_data['stdin']
	if not $process_hash[params[:id]].nil?
		info = $process_hash[params[:id]]
		http = Net::HTTP.new(info[:ip_addr][0], '80')
		req = Net::HTTP::Post.new('/input')
		req.body = {'stdin' => input}.to_json
		http.request(req)
	end
end

get '/container/:id/info' do
	if not $process_hash[params[:id]].nil?
		info = $process_hash[params[:id]]

		content_type :json
		{'id' => info[:container],
   'user' => info[:user],
		'repo' => info[:repo],
		'cpu' => info[:cpu],
		'ram' => info[:ram]
		}.to_json
	end
end
