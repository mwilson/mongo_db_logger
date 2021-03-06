require 'erb'
require 'mongo'

class MongoLogger < ActiveSupport::BufferedLogger
  default_capsize = (Rails.env == 'production') ? 250.megabytes : 100.megabytes

  user_config = YAML::load(ERB.new(IO.read(File.join(Rails.root, 'config/database.yml'))).result)[Rails.env]['mongo'] || {}

  @db_configuration = {
    'host' => 'localhost',
    'port' => 27017,
    'capsize' => default_capsize}.merge(user_config)

  def self.create_collection
    @mongo_connection.create_collection(@mongo_collection_name, {:capped => true, :size => @db_configuration['capsize']})
  end

  begin
    @mongo_collection_name = "#{Rails.env}_log"
    @mongo_connection ||= Mongo::Connection.new(@db_configuration['host'], @db_configuration['port'], :auto_reconnect => true).db(@db_configuration['database'])

    # setup the capped collection if it doesn't already exist
    unless @mongo_connection.collection_names.include?(@mongo_collection_name)
      MongoLogger.create_collection
    end
  rescue => e
    # in case the logger is fouled up use stdout
    puts "=> !! A connection to mongo could not be established - the logger will function like a normal ActiveSupport::BufferedLogger !!"
    puts e.message + "\n" + e.backtrace.join("\n")
  end

  class << self
    attr_reader :mongo_collection_name, :mongo_connection

    # Drop the capped_collection and recreate it
    def reset_collection
      @mongo_connection[@mongo_collection_name].drop
      MongoLogger.create_collection
    end
  end

  def initialize(level=DEBUG)
    super(File.join(Rails.root, "log/#{Rails.env}.log"), level)
  end

  def level_to_sym(level)
    case level
      when 0 then :debug
      when 1 then :info
      when 2 then :warn
      when 3 then :error
      when 4 then :fatal
      when 5 then :unknown
    end
  end

  def mongoize(options={})
    @mongo_record = options.merge({
      :messages => Hash.new { |hash, key| hash[key] = Array.new },
      :request_time => Time.now.getutc
    })
    # In case of exception, make sure it's set
    runtime = 0
    runtime = Benchmark.measure do
      yield
    end
  rescue Exception => e
    add(3, e.message + "\n" + e.backtrace.join("\n"))
    # Reraise the exception for anyone else who cares
    raise e
  ensure
    insert_log_record(runtime)
  end

  def insert_log_record(runtime)
    @mongo_record[:runtime] = (runtime.real * 1000).ceil
    self.class.mongo_connection[self.class.mongo_collection_name].insert(@mongo_record) rescue nil
  end

  def add_metadata(options={})
    options.each_pair do |key, value|
      unless [:messages, :request_time, :ip, :runtime].include?(key.to_sym)
        info("[MongoLogger : metadata] '#{key}' => '#{value}'")
        @mongo_record[key] = value
      else
        raise ArgumentError, ":#{key} is a reserved key for the mongo logger. Please choose a different key"
      end
    end
  end

  def add(severity, message = nil, progname = nil, &block)
    if @level <= severity && message.present? && @mongo_record.present?
      # remove Rails colorization to get the actual message
      message.gsub!(/(\e(\[([\d;]*[mz]?))?)?/, '').strip! if logging_colorized?
      @mongo_record[:messages][level_to_sym(severity)] << message
    end
    super
  end

  def logging_colorized?
    Object.const_defined?(:ActiveRecord) &&
    (Rails::VERSION::MAJOR >= 3 ?
      ActiveRecord::LogSubscriber.colorize_logging :
      ActiveRecord::Base.colorize_logging)
  end
end # class MongoLogger
