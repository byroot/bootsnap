# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

module Bootsnap
  # YJIT is a runtime JIT and does not change the serialized instruction
  # sequences the compile cache stores, so toggling it must not invalidate the
  # cache. Enabling YJIT at interpreter startup adds a " +YJIT" marker to
  # RUBY_DESCRIPTION, which is part of the cache key, so this can only be
  # exercised across separate processes.
  class YJITCompileCacheTest < Minitest::Test
    include CompileCacheISeqHelper

    def test_cache_is_reused_when_yjit_is_toggled
      skip("MRI only") unless RUBY_ENGINE == "ruby"
      skip("YJIT unavailable") unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)

      Dir.mktmpdir("bootsnap-yjit") do |dir|
        cache_dir = File.join(dir, "cache")
        source = File.join(dir, "a.rb")
        File.write(source, "def a; a = 1; end\n")

        # The first run populates the cache; the second reads it back with
        # `--yjit`. The two runs must actually observe different YJIT states for
        # this to exercise the toggle. If YJIT can't be turned off here (e.g. a
        # future Ruby that enables it by default), there is no toggle to test,
        # so skip rather than fail.
        populate = run_subprocess(cache_dir, source, yjit: false)
        reuse = run_subprocess(cache_dir, source, yjit: true)

        if populate[:yjit] == reuse[:yjit]
          skip("Cannot exercise a YJIT toggle in this environment (YJIT=#{reuse[:yjit]})")
        end

        assert_equal("miss", populate[:event], populate[:output])

        # Reusing the cache across the YJIT toggle must be a hit, not stale:
        # YJIT changes RUBY_DESCRIPTION but not the serialized ISeq.
        assert_equal("hit", reuse[:event], reuse[:output])
      end
    end

    private

    # Boots the locally-built bootsnap in a subprocess (so YJIT can be toggled
    # at interpreter startup), loads `source` through the ISeq compile cache in
    # `cache_dir`, and reports whether YJIT was enabled and which cache event
    # (`hit`/`miss`/`stale`) occurred.
    SUBPROCESS_SCRIPT = <<~'RUBY'
      require "bootsnap"
      Bootsnap::CompileCache.setup(cache_dir: ENV.fetch("CACHE_DIR"), iseq: true, yaml: false)
      event = nil
      Bootsnap.instrumentation = ->(e, _path) { event = e }
      load(ENV.fetch("TARGET"))
      puts("YJIT:#{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}")
      puts("EVENT:#{event}")
    RUBY

    def run_subprocess(cache_dir, source, yjit:)
      env = {
        "CACHE_DIR" => cache_dir,
        "TARGET" => source,
        "RUBYOPT" => yjit ? "--yjit" : "",
      }
      lib = File.expand_path("../../../lib", __FILE__)
      output, status = Open3.capture2e(env, RbConfig.ruby, "-I", lib, "-e", SUBPROCESS_SCRIPT)
      assert_predicate(status, :success?, output)

      {
        yjit: output[/YJIT:(\w+)/, 1],
        event: output[/EVENT:(\w+)/, 1],
        output: output,
      }
    end
  end
end
