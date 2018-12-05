require 'acme-client'
require 'singleton'
require 'openssl'
require 'net/http'
require 'net/dns'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

class LocalAcme
  include Singleton

  def initialize
    @acme_endpoint = APP_CONFIG['acme_endpoint']+"/dir"
    @gdns_endpoint = APP_CONFIG['gdns_endpoint']
    @gdns_token = APP_CONFIG['gdns_token']
    @server_dns = APP_CONFIG['server_dns']
  end

  def register_project(project)
    client = _new_client(project)
    _register_client(client, project, true) unless client.nil?
  end

  def revoke_cert(certificate)
    unless certificate.last_crt.nil?
      client = _new_client(certificate.project)
      cert = OpenSSL::X509::Certificate.new(certificate.last_crt)
      client.revoke_certificate(cert)
    end
  end

  def request_cert(certificate)
    client = _new_client(certificate.project)
    order = client.new_order(identifiers: certificate.cn)
    authorizations = order.authorizations
    authorization = authorizations.first
    challenge = authorization.dns01
    token = challenge.record_content
    add_dns_txt(certificate.cn, token)
    CertificatesChallengeJob.set(wait: 1.minutes).perform_later(certificate,authorization.url, token, 1, order.url) #TODO move to job or controller
  end

  def challenge(certificate, authorization, token, attempts, order)
    res = Net::DNS::Resolver.new(:nameservers => @server_dns, :recursive => true)
    p res
    packet = res.query("_acme-challenge.#{certificate.cn}", Net::DNS::TXT)
    found_txt = false
    packet.answer.each do |rr|
      if rr.txt.strip == token
        puts "Found txt register for #{certificate.cn}"
        found_txt = true
        break
      end
    end
    unless found_txt
      if attempts <= 20
        puts "#{attempts} attempts. Token #{token} not found in txt dns for #{certificate.cn}. Sending again..."
        attempts += 1
        CertificatesChallengeJob.set(wait: 1.minutes).perform_later(certificate,authorization, token, attempts)
        return
      else
        raise "Token #{token} _acme-challenge not found in txt for #{certificate.cn}."
      end
    end

    client = _new_client(certificate.project)
    challenge = client.authorization(url: authorization).dns01
    challenge.request_validation
    sleep(2)
    count = 0
    while challenge.status == 'pending'
      challenge.reload
      sleep(2)
      if count < 60
        count += 1
      else
        raise "LetsEncrypt: authorization kept pending for a long time"
      end
    end
    if challenge.status == 'valid'
      csr = Acme::Client::CertificateRequest.new(common_name: certificate.cn)
      order = client.order(url: order)
      order.finalize(csr: csr)
      sleep(1) 
      while order.status == 'processing'
        order.reload
      end
      crt_pem = order.certificate # => PEM-formatted certificate

      unless certificate.environment.nil?
        path_prefix = certificate.environment.destination_crt + "#{certificate.cn}"
        path_key = path_prefix + ".key"
        path_crt = path_prefix + ".crt"
        File.open(path_crt, "w+") do |f|
          f.write("#{crt_pem}")
        end
        File.open(path_key, "w+") do |f|
          f.write("#{certificate.key}")
        end
      end

      openSSLCert = OpenSSL::X509::Certificate.new(crt_pem)

      certificate.last_crt = crt_pem
      certificate.valid_rec!
      certificate.expired_at = openSSLCert.not_after
      certificate.save
    else
      certificate.status_detail = challenge.authorization.dns01.error
      certificate.invalid_rec!
      certificate.save
      puts challenge.authorization.dns01.error
    end
  end

  private
  def _new_client(project)
    raise "Project does not exist or project does not contains the private key" if project.nil? or project.private_pem.nil?
    pem = project.private_pem.split('@').join(10.chr)
    private_key = OpenSSL::PKey::RSA.new(pem)
    client = Acme::Client.new(private_key: private_key,
                              directory: @acme_endpoint,
                              connection_options: {request: {open_timeout: 60, timeout: 60}})
    raise "Some error happined when create client with LetsEncrypt" if client.nil?
    return client
  end

  def _register_client(client, project, agree=false)
    contact = "mailto:#{project.email}".freeze
    registration = client.new_account(contact: contact, terms_of_service_agreed: true)
    # registration.agree_terms if agree and !registration.nil?
  end

  def add_dns_txt(domain, token) #TODO verify status http code to return error or success
    id_domain = add_domain_with_records(domain)
    add_record_token(domain, id_domain, token)
    call_export
  end

  def call_export
    uri = URI(@gdns_endpoint + "/bind9/schedule_export.json")
    req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    req['X-Auth-Token'] = @gdns_token

    res = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end
    puts res.body
  end

  def add_record_token(domain, id_domain, token)
    # TODO Verify if exists the record _acme-challenge
    uri = URI(@gdns_endpoint + "/domains/#{id_domain}/records.json")
    req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    req['X-Auth-Token'] = @gdns_token

    req.body = {record: {name: "_acme-challenge.#{domain}.", type: "TXT", content: "#{token}"}}.to_json
    res = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end
  end

  def search_gdns(domain)
    uri = URI(@gdns_endpoint + '/domains.json')
    params = { :query => domain }
    uri.query = URI.encode_www_form(params)
    req = Net::HTTP::Get.new(uri)
    req['X-Auth-Token'] = @gdns_token

    res = Net::HTTP.start(uri.hostname) do |http|
      http.request(req)
    end

    if !res.is_a?(Net::HTTPSuccess)
      puts 'Search domain failed'
      return nil #TODO Return error with gdns
    end
    domains_res = JSON.parse res.body
    return domains_res
  end

  def get_domain_root(domain)
    res = Net::DNS::Resolver.new(:nameservers => @server_dns, :recursive => true)
    p res
    packet = res.query("#{domain}", Net::DNS::SOA)
    # CNAME?
    packet = resolver.query(packet.each_address.first.cname, Net::DNS::SOA) if packet.authority.first == nil
    return packet.authority.first.name
  end

  def add_domain_with_records(domain)
    domain_root = get_domain_root(domain)
    domain_root = domain_root.gsub(/\.$/, '')
    id_domain = nil
    res_domain = search_gdns(domain_root)
    if res_domain.empty?
      uri = URI(@gdns_endpoint + '/domains.json')
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req['X-Auth-Token'] = @gdns_token
      req.body = {domain: {name: domain_root, type: "MASTER", ttl: 86400, notes: "A domain", primary_ns: "ns01.#{domain}", contact: "fapesp.corp.globo.com", refresh: 10800, retry: 3600, expire: 604800, minimum: 21600, authority_type: "M"}}.to_json
      res = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(req)
      end
      if res.is_a?(Net::HTTPSuccess)
        domain_created = JSON.parse res.body
        if !domain_created.empty?
          id_domain = domain_created['domain']['id']
          uri = URI(@gdns_endpoint + "/domains/#{id_domain}/records.json")
          req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
          req['X-Auth-Token'] = @gdns_token

          req.body = {record: {name: "@", type: "NS", content: "ns01.globo.com"}}.to_json
          res = Net::HTTP.start(uri.hostname, uri.port) do |http|
            http.request(req)
          end
          #TODO verify if success, because if not, we have delete the domain created for avoid problem with export
        end
      else
        raise res.body
      end
    else
      id_domain = res_domain[0]['domain']['id']
    end
    return id_domain

  end
end