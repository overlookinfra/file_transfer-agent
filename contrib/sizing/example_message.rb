require 'digest'
require 'json'

# The exact text of each layer of a final put chunk to three targets, with
# the same serializer calls the gem makes. Placeholders in angle brackets
# stand for the parts that come from keys, certificates, or the outer
# base64, and say what they hold.

identity = 'controller.example.net'
certname = 'controller.example.net'
callerid = "choria=#{certname}"
collective = 'mcollective'
targets = ['web1.example.net', 'web2.example.net', 'db1.example.net']
session = '3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b'
requestid = '9e107d9d372bb6826bd81d3542a419d6'
content = 'hello'
ttl = 60
time = 1_758_758_400
pid = 4242
seq = 3

body = JSON.dump('agent' => 'file_transfer', 'action' => 'put', 'caller' => callerid,
  'data' => { 'session' => session, 'name' => 'app.tar', 'offset' => 0, 'data' => [content].pack('m0'), 'final' => true,
              'sha256' => Digest::SHA256.hexdigest(content), 'mode' => '0644', 'destination' => '/opt/app/app.tar' })
filter = { 'fact' => [], 'cf_class' => [], 'agent' => ['file_transfer'], 'identity' => [], 'compound' => [] }
envelope = JSON.dump('protocol' => 'choria:request:1', 'message' => body,
  'envelope' => { 'requestid' => requestid, 'senderid' => identity, 'callerid' => callerid, 'filter' => filter,
                  'collective' => collective, 'agent' => 'file_transfer', 'ttl' => ttl, 'time' => time })
secure = JSON.dump('protocol' => 'choria:secure:request:1', 'message' => envelope,
  'signature' => '<base64_lines(RSA-SHA256 signature of the message string) without its last newline>',
  'pubcert' => '<the client certificate PEM text without its last newline>')
reply_to = "#{collective}.reply.#{Digest::MD5.hexdigest(callerid)}.#{pid}.#{seq}"
headers = { 'mc_sender' => identity, 'reply-to' => reply_to }
connected = { 'protocol' => 'choria:transport:1', 'data' => '<base64_lines(secure request)>', 'headers' => headers }.to_json
federated = JSON.dump('protocol' => 'choria:transport:1', 'data' => '<base64_lines(secure request)>',
  'headers' => { 'federation' => { 'target' => targets.map { |target| "#{collective}.node.#{target}" }, 'req' => requestid } }.merge(headers))

puts "BODY (#{body.bytesize} bytes):"
puts body
puts
puts "ENVELOPE (#{envelope.bytesize} bytes):"
puts envelope
puts
puts 'SECURE REQUEST (placeholders for the signature and certificate):'
puts secure
puts
puts 'CONNECTED WIRE MESSAGE (placeholder for the outer base64), one copy per subject:'
puts connected
targets.each { |target| puts "  PUB #{collective}.node.#{target} #{reply_to} <size>" }
puts
puts 'FEDERATED WIRE MESSAGE (placeholder for the outer base64), one message per network:'
puts federated
puts "  PUB choria.federation.<network>.federation #{reply_to} <size>"
puts
puts "sha256 of #{content.inspect}: #{Digest::SHA256.hexdigest(content)}"
puts "md5 of #{callerid.inspect}: #{Digest::MD5.hexdigest(callerid)}"
puts "escaping check: #{JSON.dump("eé \u0001 \u007f")}"
