require 'json'

# The largest content a put request can carry under a payload limit,
# from the layers as the gem builds them, for stated inputs. The
# federation header is the connector's own structure for the group.

def build(identity:, certname:, collective:, name:, destination:, content:, cert_lines:, sig_bytes:, ttl: 60, time: 1_758_758_400, pid: 4242, seq: 3, targets: nil)
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
  if targets
    JSON.dump('protocol' => 'choria:transport:1', 'data' => payload,
      'headers' => { 'federation' => { 'target' => targets.map { |target| "#{collective}.node.#{target}" }, 'req' => 'a' * 32 } }.merge(headers)).bytesize
  else
    { 'protocol' => 'choria:transport:1', 'data' => payload, 'headers' => headers }.to_json.bytesize
  end
end

# The largest content whose message stays within the limit, by search
# over the monotone size function.
def largest_content(limit, **settings)
  low = 0
  high = limit
  while low < high
    middle = (low + high + 1) / 2
    if build(content: middle, **settings) <= limit
      low = middle
    else
      high = middle - 1
    end
  end
  low
end

limit = 1_048_576
base = { identity: 'controller.example.net', certname: 'controller.example.net', collective: 'mcollective', name: 'app.tar', destination: '/opt/app/app.tar', cert_lines: 25, sig_bytes: 256 }
scenarios = {
  'single broker' => base,
  'federation, 200 targets of 16 bytes' => base.merge(targets: Array.new(200) { |index| format('n%03d.example.net', index) }),
  'federation, 200 targets of 40 bytes' => base.merge(targets: Array.new(200) { |index| format('node%03d.longer-site-name.example.net', index)[0, 40].ljust(40, 'x') }),
  'federation, 200 targets of 253 bytes' => base.merge(targets: Array.new(200) { |index| format('n%03d', index).ljust(253, 'x') }),
  'single broker, name and destination of 4096 bytes' => base.merge(name: 'n' * 4096, destination: '/' + ('d' * 4095)),
}

scenarios.each do |label, settings|
  overhead = build(content: 0, **settings)
  content = largest_content(limit, **settings)
  puts format('%-52s overhead before content %6d bytes, largest content %7d bytes, %5.2f%% of the limit', label, overhead, content, 100.0 * content / limit)
end
