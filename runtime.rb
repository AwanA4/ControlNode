require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'json'
require 'puma'
require 'lxc'
require 'net/http'
require 'thread'

configure{ set :server, :puma}

$process_hash = Hash.new
$Process = Struct.new(:user, :cpu, :ram, :repo, :container)
$Template = LXC::Container.new('ComputeNode')

def randomChar(length)
	o = [('a'..'z'), ('A'..'Z')].map{|i| i.to_a}.flatten
	string = (0..length).map{ o[rand(o.length)]}.join
	return string
end

def watch_process(process)
	ip_addr = process.ip_address
	http = Net::HTTP.new(ip_addr, '80')
	check_alive = Net::HTTP::Get.new('/status')
	usage_request = Net::HTTP::Get.new('/usage')
	begin
		response = http.request(check_alive)
		parsed_response = JSON.parse(response.body.read)
		#Get usage

		#Save to database
		sleep(20)
	end until parsed_response['finished']
	output_request = = Net::HTTP::Get.new('/all_output')
	response = http.request(output_request)
	parsed_response = JSON.parse(response.body.read)
	#Put output to database

	#
	#Remove process from hash
	#
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
	container_name = @req_data['user'] + '-' + randomChar(10)
	new_container = $Template.clone(container_name, {:flags => LXC::LXC_CLONE_SNAPSHOT})
	$process_hash.store(container_name, new_container)

	#start the process
	#Start watch_process thread
end
