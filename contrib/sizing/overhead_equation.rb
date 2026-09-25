require 'json'

# Builds every layer of a file_transfer put request exactly as the gem
# does, with placeholder strings of the given lengths standing in for the
# values that vary. The constants of the closed form are taken from one
# built case and the form is then checked against the other cases, whose
# variables all differ.
#
# Layers and the gem code they follow:
#   body      RPC::Client#new_request                    rpc/client.rb:162-165
#   envelope  Security::Choria#encoderequest             security/choria.rb:43-52, empty_request 671-686
#   secure    Security::Choria#encoderequest             security/choria.rb:54-63, Signer::Choria#local_sign!, sign 618
#   payload   SSL.base64_encode is Base64.encode64       ssl.rb:188-190, which is pack('m')
#   wire      Connector::Nats#publish_connected_directed nats.rb:276-289, publish_federated_directed 239-259

def enc64(bytes)
  chars = 4 * ((bytes + 2) / 3)
  [chars, (chars + 59) / 60]
end

def build(identity:, certname:, collective:, name:, destination:, content:, cert_lines:, sig_bytes:, ttl: 60, time: 1_758_000_000, pid: 12345, seq: 7, targets: nil)
  callerid = "choria=#{certname}"
  data = { 'session' => 's' * 36, 'name' => name, 'offset' => 10**15, 'data' => ['x' * content].pack('m0'), 'final' => true, 'sha256' => 'f' * 64, 'mode' => '0777' }
  data['destination'] = destination if destination
  body = JSON.dump('agent' => 'file_transfer', 'action' => 'put', 'caller' => callerid, 'data' => data)
  filter = { 'fact' => [], 'cf_class' => [], 'agent' => ['file_transfer'], 'identity' => [], 'compound' => [] }
  envelope = JSON.dump('protocol' => 'choria:request:1', 'message' => body,
    'envelope' => { 'requestid' => 'a' * 32, 'senderid' => identity, 'callerid' => callerid, 'filter' => filter,
                    'collective' => collective, 'agent' => 'file_transfer', 'ttl' => ttl, 'time' => time })
  signature = ['s' * sig_bytes].pack('m').chomp
  pem = (['-----BEGIN CERTIFICATE-----'] + Array.new(cert_lines) { 'c' * 64 } + ['-----END CERTIFICATE-----']).join("\n")
  secure = JSON.dump('protocol' => 'choria:secure:request:1', 'message' => envelope, 'signature' => signature, 'pubcert' => pem)
  payload = [secure].pack('m')
  headers = { 'mc_sender' => identity, 'reply-to' => "#{collective}.reply.#{'0' * 32}.#{pid}.#{seq}" }
  wire = if targets
           JSON.dump('protocol' => 'choria:transport:1', 'data' => payload,
             'headers' => { 'federation' => { 'target' => targets.map { |target| "#{collective}.node.#{target}" }, 'req' => 'a' * 32 } }.merge(headers))
         else
           { 'protocol' => 'choria:transport:1', 'data' => payload, 'headers' => headers }.to_json
         end
  { body: body, envelope: envelope, secure: secure, payload: payload, wire: wire, signature: signature, pem: pem, filter: JSON.dump(filter) }
end

# The variable parts of each layer, so a constant is what remains of the
# built text once they are taken out.
def parts(identity:, certname:, collective:, name:, destination:, content:, cert_lines:, sig_bytes:, ttl: 60, time: 1_758_000_000, pid: 12345, seq: 7, targets: nil)
  callerid = 7 + certname.bytesize
  sig_chars = 4 * ((sig_bytes + 2) / 3)
  sig_newlines = ((sig_chars + 59) / 60) - 1
  pem = 27 + 25 + (cert_lines * 64) + cert_lines + 1
  pem_newlines = cert_lines + 1
  {
    body: callerid + name.bytesize + (4 * ((content + 2) / 3)) + (destination ? 17 + destination.bytesize : 0),
    body_quotes: destination ? 42 : 38,
    envelope: 32 + identity.bytesize + callerid + 79 + collective.bytesize + ttl.to_s.bytesize + time.to_s.bytesize,
    secure: sig_chars + (2 * sig_newlines) + pem + pem_newlines,
    reply: collective.bytesize + 7 + 32 + 1 + pid.to_s.bytesize + 1 + seq.to_s.bytesize,
    identity: identity.bytesize,
    federation: targets ? 67 + (3 * targets.length) + targets.sum { |target| collective.bytesize + 6 + target.bytesize } : 0,
  }
end

def closed_form(constants, settings)
  variable = parts(**settings)
  body = constants[:body] + variable[:body]
  envelope = constants[:envelope] + body + variable[:body_quotes] + variable[:envelope]
  envelope_escapes = constants[:envelope_escapes] + (2 * variable[:body_quotes])
  secure = constants[:secure] + envelope + envelope_escapes + variable[:secure]
  chars, newlines = enc64(secure)
  wire = constants[:wire] + chars + (2 * newlines) + variable[:identity] + variable[:reply] + variable[:federation]
  { body: body, envelope: envelope, secure: secure, wire: wire }
end

def actual_sizes(built)
  { body: built[:body].bytesize, envelope: built[:envelope].bytesize, secure: built[:secure].bytesize, wire: built[:wire].bytesize }
end

base = { identity: 'controller.example.com', certname: 'controller.example.com', collective: 'mcollective', name: 'app.tar', destination: '/opt/app/app.tar', content: 0, cert_lines: 25, sig_bytes: 256 }
built = build(**base)
variable = parts(**base)
sizes = actual_sizes(built)
chars, newlines = enc64(sizes[:secure])
constants = {
  body: sizes[:body] - variable[:body],
  envelope: sizes[:envelope] - sizes[:body] - variable[:body_quotes] - variable[:envelope],
  envelope_escapes: built[:envelope].count('"\\') - (2 * variable[:body_quotes]),
  secure: sizes[:secure] - sizes[:envelope] - built[:envelope].count('"\\') - variable[:secure],
  wire: sizes[:wire] - chars - (2 * newlines) - variable[:identity] - variable[:reply],
}
puts "constants from the fixed text: #{constants}"
puts "body quotes with a destination #{built[:body].count('"')}, filter #{built[:filter].bytesize} bytes, signature #{built[:signature].bytesize} bytes with #{built[:signature].count("\n")} newlines, certificate #{built[:pem].bytesize} bytes with #{built[:pem].count("\n")} newlines"

cases = [
  base.merge(identity: 'c', certname: 'c', collective: 'm', name: 'n', destination: nil, cert_lines: 1, sig_bytes: 3, ttl: 5, time: 999, pid: 1, seq: 123_456),
  base.merge(collective: 'production', name: 'a' * 4096, destination: '/' + ('b' * 4095), cert_lines: 30, sig_bytes: 512),
  base.merge(content: 539_000),
  base.merge(content: 1),
  base.merge(targets: Array.new(200) { |index| format('node%03d.example.com', index) }),
  base.merge(content: 539_000, targets: Array.new(56) { |index| format('n%d.x', index) }),
  base.merge(destination: nil, content: 16_384, cert_lines: 12, sig_bytes: 64, targets: ['a']),
]

cases.each_with_index do |settings, index|
  predicted = closed_form(constants, settings)
  actual = actual_sizes(build(**settings))
  status = actual == predicted ? 'closed form matches' : "MISMATCH predicted #{predicted} actual #{actual}"
  puts "case #{index + 1}: #{status}, wire #{actual[:wire]} bytes, content #{settings[:content]}, targets #{settings[:targets]&.length || 'none (connected)'}"
end

puts "overhead before content, connected, 22 byte identity and certname, 25 line certificate, 256 byte signature: #{sizes[:wire]} bytes"
federated = build(**base.merge(targets: Array.new(200) { |index| format('node%03d.example.com', index) }))
puts "the same through federation with 200 targets of 19 bytes: #{federated[:wire].bytesize} bytes"
