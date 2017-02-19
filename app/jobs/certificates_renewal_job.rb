require 'local_acme'
require 'sidekiq-cron'

class CertificatesRenewalJob
  include Sidekiq::Worker

  def initialize
    @time_renewal = APP_CONFIG['time_renewal'] * 60 * 60 * 24
  end

  def perform
    begin
      certificates = Certificate.where(status: :valid_rec)
      certificates.each do |cert|
        begin
        openSSLCert = OpenSSL::X509::Certificate.new(cert.last_crt)
        timeNow = Time.now.utc.to_i
        timeCert = openSSLCert.not_after.to_i
        diffTime = timeCert - timeNow
        if diffTime < @time_renewal
          if cert.auto_renewal
            CertificatesCreateJob.perform_later cert
          else
            diffTime <= 0 ? cert.expired! : cert.warning!
          end
        end
        rescue => e
          puts e.message
          puts e.backtrace.join("\n")
          logger.warn "Unable to renewal certificate: #{e}"
          cert.error!
        end
      end
    rescue => e
      puts e.message
      puts e.backtrace.join("\n")
      logger.warn "Unable to search valid certificate: #{e}"
    end
  end
end