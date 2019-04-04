#!/usr/bin/ruby

require 'aws-sdk'
require 'shellwords'
require 'facter'
require 'retriable'

ENV['DB_INSTANCE_IDENTIFIER'] or raise 'DB_INSTANCE_IDENTIFIER is required'
ENV['BUCKET'] or raise 'BUCKET is required'

rds = Aws::RDS::Client.new
files = rds.describe_db_log_files(db_instance_identifier: ENV['DB_INSTANCE_IDENTIFIER'])
files = files.to_h[:describe_db_log_files]

log_file_count = ENV['LOG_FILE_COUNT'] ? ENV['LOG_FILE_COUNT'].to_i : 5

downloaded_files = files.last(log_file_count).map do |file|
  File.basename(file[:log_file_name]).tap do |basename|
    command = ["rds-download-db-logfile",
               "--db-instance-identifier", ENV['DB_INSTANCE_IDENTIFIER'],
               "-I", ENV['AWS_ACCESS_KEY_ID'],
               "-S", ENV['AWS_SECRET_ACCESS_KEY'],
               "--region", ENV['AWS_DEFAULT_REGION'],
               "--log-file-name", file[:log_file_name]]

    puts file[:log_file_name]
    Retriable.retriable(tries: 8) do
      system("#{Shellwords.shelljoin command} >#{basename}") or raise "rds-download-db-logfile failed"
      raise "Expected #{basename} to not be empty" if File.size(basename).zero?
      
      if file != files.last && file[:size] != File.size(basename)
        raise "Expected #{basename} size to be #{file[:size]} but was #{File.size(basename)}"
      end
    end
  end
end

system(*["pgbadger",
         "--verbose",
         "--jobs", Facter.value('processors')['count'].to_s,
         "--prefix", "%t:%r:%u@%d:[%p]:"] + downloaded_files) or raise 'pgbadger failed'

s3 = Aws::S3::Resource.new
key = "pgbadger-#{Time.now.strftime("%F-%H-%M-%S")}.html"
obj = s3.bucket(ENV['BUCKET']).object(key)
obj.upload_file 'out.html', {acl: 'public-read'}

puts "https://s3.amazonaws.com/#{ENV['BUCKET']}/#{key}"
