require "digest/md5"

module Blazer
  class DataSource
    attr_reader :id, :settings, :connection_model

    def initialize(id, settings)
      @id = id
      @settings = settings

      unless settings["url"] || Rails.env.development?
        raise Blazer::Error, "Empty url"
      end

      @connection_model =
        Class.new(Blazer::Connection) do
          def self.name
            "Blazer::Connection::#{object_id}"
          end
          establish_connection(settings["url"]) if settings["url"]
        end
    end

    def name
      settings["name"] || @id
    end

    def linked_columns
      settings["linked_columns"] || {}
    end

    def smart_columns
      settings["smart_columns"] || {}
    end

    def smart_variables
      settings["smart_variables"] || {}
    end

    def variable_defaults
      settings["variable_defaults"] || {}
    end

    def timeout
      settings["timeout"]
    end

    def cache
      @cache ||= begin
        if settings["cache"].is_a?(Hash)
          settings["cache"]
        elsif settings["cache"]
          {
            "mode" => "all",
            "expires_in" => settings["cache"]
          }
        else
          {
            "mode" => "off"
          }
        end
      end
    end

    def cache_mode
      cache["mode"]
    end

    def cache_expires_in
      (cache["expires_in"] || 60).to_f
    end

    def cache_slow_threshold
      (cache["slow_threshold"] || 15).to_f
    end

    def local_time_suffix
      @local_time_suffix ||= Array(settings["local_time_suffix"])
    end

    def use_transaction?
      settings.key?("use_transaction") ? settings["use_transaction"] : true
    end

    def cost(statement)
      result = explain(statement)
      match = /cost=\d+\.\d+..(\d+\.\d+) /.match(result)
      match[1] if match
    end

    def explain(statement)
      if postgresql? || redshift?
        connection_model.connection.select_all("EXPLAIN #{statement}").rows.first.first
      end
    rescue
      nil
    end

    def run_main_statement(statement, options = {})
      query = options[:query]
      Blazer.transform_statement.call(self, statement) if Blazer.transform_statement

      # audit
      if Blazer.audit
        audit = Blazer::Audit.new(statement: statement)
        audit.query = query
        audit.data_source = id
        audit.user = options[:user]
        audit.save!
      end

      start_time = Time.now
      result = run_statement(statement, options)
      duration = Time.now - start_time

      if Blazer.audit
        audit.duration = duration if audit.respond_to?(:duration=)
        audit.error = result.error if audit.respond_to?(:error=)
        audit.timed_out = result.timed_out? if audit.respond_to?(:timed_out=)
        audit.cached = result.cached? if audit.respond_to?(:cached=)
        if !result.cached?
          cost_start_time = Time.now
          audit.cost = cost(statement) if audit.respond_to?(:cost=)
          cost_duration = Time.now - cost_start_time
          Rails.logger.info "[blazer cost duration] #{id} #{(cost_duration.to_f * 1000).round}ms"
        end
        audit.save! if audit.changed?
      end

      if query && !result.timed_out? && !result.error.to_s.include?("permission denied for relation")
        query.checks.each do |check|
          check.update_state(result)
        end
      end

      result
    end

    def read_cache(cache_key)
      value = Blazer.cache.read(cache_key)
      if value
        Blazer::Result.new(self, *Marshal.load(value), nil)
      end
    end

    def run_results(run_id)
      read_cache(run_cache_key(run_id))
    end

    def delete_results(run_id)
      Blazer.cache.delete(run_cache_key(run_id))
    end

    def run_statement(statement, options = {})
      run_id = options[:run_id]
      result = nil
      if cache_mode != "off" && !options[:refresh_cache]
        result = read_cache(statement_cache_key(statement))
      end

      unless result
        comment = "blazer"
        if options[:user].respond_to?(:id)
          comment << ",user_id:#{options[:user].id}"
        end
        if options[:user].respond_to?(Blazer.user_name)
          # only include letters, numbers, and spaces to prevent injection
          comment << ",user_name:#{options[:user].send(Blazer.user_name).to_s.gsub(/[^a-zA-Z0-9 ]/, "")}"
        end
        if options[:query].respond_to?(:id)
          comment << ",query_id:#{options[:query].id}"
        end
        if options[:check]
          comment << ",check_id:#{options[:check].id},check_emails:#{options[:check].emails}"
        end
        result = run_statement_helper(statement, comment, options[:run_id])
      end

      result
    end

    def clear_cache(statement)
      Blazer.cache.delete(statement_cache_key(statement))
    end

    def cache_key(key)
      (["blazer", "v4"] + key).join("/")
    end

    def statement_cache_key(statement)
      cache_key(["statement", id, Digest::MD5.hexdigest(statement)])
    end

    def run_cache_key(run_id)
      cache_key(["run", run_id])
    end

    def schemas
      default_schema = (postgresql? || redshift?) ? "public" : connection_model.connection_config[:database]
      settings["schemas"] || [connection_model.connection_config[:schema] || default_schema]
    end

    def tables
      result = run_statement(connection_model.send(:sanitize_sql_array, ["SELECT table_name FROM information_schema.tables WHERE table_schema IN (?) ORDER BY table_name", schemas]))
      result.rows.map(&:first)
    end

    def postgresql?
      ["PostgreSQL", "PostGIS"].include?(adapter_name)
    end

    def redshift?
      ["Redshift"].include?(adapter_name)
    end

    def mysql?
      ["MySQL", "Mysql2", "Mysql2Spatial"].include?(adapter_name)
    end

    def reconnect
      connection_model.establish_connection(settings["url"])
    end

    protected

    def run_statement_helper(statement, comment, run_id)
      columns = []
      rows = []
      error = nil
      start_time = Time.now
      result = nil

      begin
        in_transaction do
          if timeout
            if postgresql? || redshift?
              connection_model.connection.execute("SET statement_timeout = #{timeout.to_i * 1000}")
            elsif mysql?
              connection_model.connection.execute("SET max_execution_time = #{timeout.to_i * 1000}")
            else
              raise Blazer::TimeoutNotSupported, "Timeout not supported for #{adapter_name} adapter"
            end
          end

          result = connection_model.connection.select_all("#{statement} /*#{comment}*/")
        end
      rescue ActiveRecord::StatementInvalid => e
        error = e.message.sub(/.+ERROR: /, "")
        error = Blazer::TIMEOUT_MESSAGE if Blazer::TIMEOUT_ERRORS.any? { |e| error.include?(e) }
      end

      duration = Time.now - start_time

      if result
        columns = result.columns
        cast_method = Rails::VERSION::MAJOR < 5 ? :type_cast : :cast_value
        result.rows.each do |untyped_row|
          rows << (result.column_types.empty? ? untyped_row : columns.each_with_index.map { |c, i| untyped_row[i] ? result.column_types[c].send(cast_method, untyped_row[i]) : nil })
        end
      end

      cache_data = nil
      cache = !error && (cache_mode == "all" || (cache_mode == "slow" && duration >= cache_slow_threshold))
      if cache || run_id
        cache_data =
          begin
            Marshal.dump([columns, rows, error, cache ? Time.now : nil])
          rescue => e
            Rails.logger.info "[blazer serialize error] #{e.class.name} #{e.message} #{run_id}"
            nil
          end
      end

      if cache && cache_data
        Blazer.cache.write(statement_cache_key(statement), cache_data, expires_in: cache_expires_in.to_f * 60)
      end

      if run_id
        unless cache_data
          error = "Error storing the results of this query :("
          cache_data = Marshal.dump([[], [], error, nil])
        end
        Blazer.cache.write(run_cache_key(run_id), cache_data, expires_in: 30.seconds)
      end

      Blazer::Result.new(self, columns, rows, error, nil, cache && !cache_data.nil?)
    end

    def adapter_name
      connection_model.connection.adapter_name
    end

    def in_transaction
      if use_transaction?
        connection_model.transaction do
          yield
          raise ActiveRecord::Rollback
        end
      else
        yield
      end
    end
  end
end
