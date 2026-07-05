# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "pathname"
require "securerandom"
require "time"
require "yaml"

module PriceSentinel
  class ActiveScanError < StandardError
    attr_reader :config_path, :lock_path

    def initialize(config_path, lock_path)
      @config_path = config_path
      @lock_path = lock_path
      super("Scan already active for config: #{config_path}")
    end
  end

  module MonitorState
    DEFAULT_DIR = ".price-sentinel"
    DEFAULT_ALERT_STATE_FILE = "alert-state.json"
    DEFAULT_LAST_SCAN_FILE = "last-scan.json"

    module_function

    def with_lock(config_path)
      config = load_config(config_path)
      path = lock_path(config_path, config)
      lock = acquire_lock(config_path, path, config)
      yield
    ensure
      release_lock(lock) if lock
    end

    def write_last_scan(config_path, report)
      path = last_scan_path(config_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(last_scan_payload(report))}\n")
      path
    end

    def last_scan_path(config_path)
      config = load_config(config_path)
      path_from_state(config, config_path, "last_scan_file", DEFAULT_LAST_SCAN_FILE)
    end

    def alert_state_path(config_path)
      config = load_config(config_path)
      path_from_state(config, config_path, "alert_state_file", DEFAULT_ALERT_STATE_FILE)
    end

    def lock_path(config_path, config = load_config(config_path))
      path_from_state(config, config_path, "lock_file", default_lock_file(config_path))
    end

    def load_config(config_path)
      YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false) || {}
    end

    def path_from_state(config, config_path, key, default_name)
      state = config["state"].is_a?(Hash) ? config["state"] : {}
      configured = state[key]
      return resolve_path(configured, File.dirname(config_path)) if present?(configured)

      File.join(state_dir(config, config_path), default_name)
    end

    def state_dir(config, config_path)
      state = config["state"].is_a?(Hash) ? config["state"] : {}
      configured = state["dir"]
      return resolve_path(configured, File.dirname(config_path)) if present?(configured)

      File.join(File.dirname(config_path), DEFAULT_DIR)
    end

    def resolve_path(path, base_dir)
      return path if Pathname.new(path).absolute?

      File.expand_path(path, base_dir)
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def last_scan_payload(report)
      report.to_h.merge(
        "completed_at" => Time.now.utc.iso8601
      )
    end

    def default_lock_file(config_path)
      config_digest = Digest::SHA256.hexdigest(File.expand_path(config_path))[0, 12]
      "scan-#{File.basename(config_path)}-#{config_digest}.lock"
    end

    def acquire_lock(config_path, path, config)
      FileUtils.mkdir_p(File.dirname(path))
      file = File.open(path, File::RDWR | File::CREAT, 0o644)

      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise ActiveScanError.new(config_path, path)
      end

      existing_payload = read_lock_payload(file)
      if existing_payload && process_alive?(existing_payload["pid"]) &&
         !stale_lock_payload?(existing_payload, stale_lock_after_ms(config))
        file.flock(File::LOCK_UN)
        file.close
        raise ActiveScanError.new(config_path, path)
      end

      if existing_payload
        warn "Recovered stale scan lock: #{path}"
      end

      token = SecureRandom.hex(16)
      write_lock_payload(file, config_path, token)
      Lock.new(file, path, token)
    end

    def release_lock(lock)
      begin
        File.delete(lock.path) if lock_owner?(lock)
      ensure
        lock.file.flock(File::LOCK_UN)
        lock.file.close
      end
    end

    def stale_lock_after_ms(config)
      value = config.dig("run", "stale_lock_after_ms")
      return 1_800_000 if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      1_800_000
    end

    # flock is released by the OS when a process dies, so a successful flock plus
    # a dead payload pid means the previous scan crashed; recover immediately
    # instead of waiting out the stale window. The time-based threshold remains
    # the fallback for payloads without a usable pid (and pid-reuse edge cases).
    def process_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    rescue ArgumentError, TypeError
      false
    end

    def stale_lock_payload?(payload, threshold_ms)
      return false unless threshold_ms.positive?

      Time.now.utc - lock_started_at(payload) > threshold_ms / 1000.0
    end

    def lock_started_at(payload)
      Time.iso8601(payload.fetch("started_at"))
    rescue KeyError, ArgumentError
      Time.at(0).utc
    end

    def read_lock_payload(file)
      file.rewind
      content = file.read
      return nil if content.nil? || content.empty?

      JSON.parse(content)
    rescue JSON::ParserError
      { "started_at" => Time.at(0).utc.iso8601 }
    end

    def write_lock_payload(file, config_path, token)
      file.rewind
      file.truncate(0)
      file.write(
        JSON.generate(
          "config_path" => config_path,
          "started_at" => Time.now.utc.iso8601,
          "pid" => Process.pid,
          "owner_token" => token
        )
      )
      file.flush
    end

    def lock_owner?(lock)
      return false unless File.exist?(lock.path)

      payload = JSON.parse(File.read(lock.path))
      payload["owner_token"] == lock.token
    rescue JSON::ParserError
      false
    end

    Lock = Struct.new(:file, :path, :token, keyword_init: false)
  end
end
