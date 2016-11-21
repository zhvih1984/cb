require 'sinatra'
require 'json'
require "base64"

set :bind, '0.0.0.0'
set :port, 8080

ssh_dir = "/opt/ssh"
daemon_key_file_prefix = "http_server_added_"

authorized_keys_file_path = File.join(ssh_dir, "authorized_keys")
authorized_keys_daemon_dir_path = File.join(ssh_dir, "authorized_keys.d")

helpers do
  def protected!
    return if authorized?
    headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
    halt 401, "Not authorized\n"
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == ['admin', 'secret']
  end
end

get '/' do
  'Hi'
end

post '/add_public_key' do
  protected!

  if !File.file?(authorized_keys_file_path) || !File.directory?(authorized_keys_daemon_dir_path)
    halt 500, "SSH authorized_keys file #{authorized_keys_file_path} or daemon directory #{authorized_keys_daemon_dir_path} not found"
  end

  request.body.rewind
  begin

    data = JSON.parse request.body.read
    encoded_ssh_key = data['ssh_public_key']
    unless encoded_ssh_key.nil?

      begin
        ssh_key = Base64.strict_decode64(encoded_ssh_key)

        ssh_key = ssh_key.end_with?("\n") ? ssh_key : ssh_key + "\n"

        File.open(authorized_keys_file_path, 'a') do |authorized_keys_file|
          authorized_keys_file.puts ssh_key
        end

        i = 0
        begin
          i = i + 1
          daemon_key_file_path = File.join(authorized_keys_daemon_dir_path, daemon_key_file_prefix + i.to_s())
        end while File.file?(daemon_key_file_path)

        File.open(daemon_key_file_path, 'w') do |daemon_key_file|
          daemon_key_file.puts ssh_key
        end

        "Key successfully saved:\n#{ssh_key}"
      rescue ArgumentError => e
        halt 400, "The ssh_public_key property is not a valid base64 encoded string"
      end

    else
      halt 400, "Your JSON request is missing the required ssh_public_key property"
    end

  rescue JSON::ParserError => e
    halt 400, "Please provide a JSON object with a ssh_public_key property"
  end

end
