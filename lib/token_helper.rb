# frozen_string_literal: true

require_relative './server'
require_relative './config'
require_relative './client'
require 'jwt'
require 'base64'
require 'openssl'

# Need this constant to encode subject the right way.
ASN1_STRFLGS_ESC_MSB = 4

# A helper for building JWT access tokens and ID tokens
class TokenHelper
  def self.build_access_token_stub(attrs, client, scopes, resources, claims)
    base_config = Config.base_config
    now = Time.new.to_i
    token = {
      'scope' => (scopes.join ' '),
      'aud' => resources,
      'iss' => base_config.dig('token', 'issuer'),
      'nbf' => now,
      'iat' => now,
      'jti' => Base64.urlsafe_encode64(rand(2**64).to_s),
      'exp' => now + base_config.dig('token', 'expiration'),
      'client_id' => client.client_id
    }
    reserved = {}
    reserved['userinfo_req_claims'] = claims['userinfo'] unless (claims['userinfo'] || {}).empty?
    token['omejdn_reserved'] = reserved unless reserved.empty?
    token.merge(map_claims_to_userinfo(attrs, claims['access_token'], client, scopes))
  end

  # Builds a JWT access token for client including scopes and attributes
  def self.build_access_token(client, user, scopes, claims, resources)
    # Use user attributes if we have a user context, else use client
    # attributes.
    if user
      new_payload = build_access_token_stub(user.attributes, client, scopes, resources, claims)
      new_payload['sub'] = user.username
    else
      new_payload = build_access_token_stub(client.attributes, client, scopes, resources, claims)
      new_payload['sub'] = client.client_id if user.nil?
    end
    signing_material = Server.load_skey('token')
    kid = JSON::JWK.new(signing_material['pk'])[:kid]
    JWT.encode new_payload, signing_material['sk'], 'RS256', { typ: 'at+jwt', kid: kid }
  end

  def self.address_claim?(key)
    %w[street_address postal_code locality region country].include?(key)
  end

  def self.add_jwt_claim(jwt_body, key, value)
    # Address is handled differently. For reasons...
    if address_claim?(key)
      jwt_body['address'] ||= {}
      jwt_body['address'][key] = value
      return
    end
    jwt_body[key] = value
  end

  def self.map_claims_to_userinfo(attrs, claims, client, scopes)
    new_payload = {}
    claims ||= {}

    # Add attribute if it was requested indirectly through OIDC
    # scope and scope is allowed for client.
    allowed_scoped_attrs = client.allowed_scoped_attributes(scopes)
    attrs.select { |a| allowed_scoped_attrs.include?(a['key']) }
         .each { |a| add_jwt_claim(new_payload, a['key'], a['value']) }
    return new_payload if claims.empty?

    # Add attribute if it was specifically requested through OIDC
    # claims parameter.
    attrs.each do |attr|
      next unless (name = claims[attr['key']])

      if    attr['dynamic'] && name['value']
        add_jwt_claim(new_payload, attr['key'], name['value'])
      elsif attr['dynamic'] && name['values']
        add_jwt_claim(new_payload, attr['key'], name.dig('values', 0))
      elsif attr['value']
        add_jwt_claim(new_payload, attr['key'], attr['value'])
      end
    end
    new_payload
  end

  # Builds a JWT ID token for client including user attributes
  def self.build_id_token(client, user, scopes, claims, nonce)
    base_config = Config.base_config
    now = Time.new.to_i
    new_payload = {
      'aud' => client.client_id,
      'iss' => base_config.dig('id_token', 'issuer'),
      'sub' => user.username,
      'nbf' => now,
      'iat' => now,
      'exp' => now + base_config.dig('id_token', 'expiration'),
      'auth_time' => user.auth_time
    }.merge(map_claims_to_userinfo(user.attributes, claims['id_token'], client, scopes))
    new_payload['nonce'] = nonce unless nonce.nil?
    signing_material = Server.load_skey('id_token')
    kid = JSON::JWK.new(signing_material['pk'])[:kid]
    JWT.encode new_payload, signing_material['sk'], 'RS256', { typ: 'JWT', kid: kid }
  end
end
