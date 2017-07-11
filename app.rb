require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'httparty'
require 'json'
require 'addressable/uri'
require 'byebug' if development?

class OffsiteGatewaySim < Sinatra::Base

  def initialize(base_path: '')
    @base_path = base_path
    @key = 'iU44RWxeik'
    super
  end

  def fields
    @fields ||= if request.content_type == 'application/json'
      JSON.load(request.body.read)
    else
      request.params.select { |k, v| k.start_with?('x_') }
    end
  end

  def request_fields
    YAML.load_file('request_fields.yml')
  end

  def response_fields
    YAML.load_file('response_fields.yml')
  end

  def sign(fields, key=@key)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), key, fields.sort.join)
  end

  def signature_valid?
    provided_signature = fields['x_signature']
    expected_signature = sign(fields.reject{|k,_| k == 'x_signature'})
    provided_signature && provided_signature.casecmp(expected_signature) == 0
  end

  get '/' do
    erb :get, :locals => { key: @key }
  end

  post '/' do
    erb :post, :locals => { signature_ok: signature_valid? }
  end

  post '/incontext' do
    erb :incontext, :locals => { signature_ok: signature_valid? }
  end

  get '/calculator' do
    erb :calculator, :locals => {
      request_fields: request_fields,
      response_fields: response_fields,
      signature: sign(fields.delete_if { |_, v| v.empty? }, params['secret_key'] || @key)
    }
  end

  post '/capture' do
    content_type :json

    if signature_valid?
      200
    else
      [401, {}, { x_status: 'failed', x_error_message: 'Invalid signature' }.to_json]
    end
  end

  post '/refund' do
    content_type :json

    if signature_valid?
      [200, {}, fields.merge(x_status: 'success',
                             x_gateway_reference: SecureRandom.hex,
                             x_timestamp: Time.now.utc.iso8601).to_json]
    else
      [401, {}, { x_status: 'failed', x_error_message: 'Invalid signature' }.to_json]
    end
  end

  post '/execute/:action' do |action|
    ts = Time.now.utc.iso8601
    payload = {
      'x_account_id'        => fields['x_account_id'],
      'x_reference'         => fields['x_reference'],
      'x_currency'          => fields['x_currency'],
      'x_test'              => fields['x_test'],
      'x_amount'            => fields['x_amount'],
      'x_result'            => action,
      'x_gateway_reference' => SecureRandom.hex,
      'x_timestamp'         => ts
      }
    if action == "failed"
      payload['x_message'] = "This is a custom error message."
    end
    payload['x_signature'] = sign(payload)
    result = {timestamp: ts}
      payload['x_message'] = "This is a custom error message AAAA."
    redirect_url = Addressable::URI.parse(fields['x_url_cancel'])
    redirect_url.query_values = payload
    if request.params['fire_callback'] == 'true'
      callback_url = fields['x_url_callback']
      response = HTTParty.post(callback_url, body: payload)
      if response.code == 200
        result[:redirect] = redirect_url
      else
        result[:error] = response
      end
    else
      result[:redirect] = redirect_url
    end
    result.to_json
  end

  run! if app_file == $0
end
