require "test_helper"

module Tingee
  # The gem must stay pure Ruby: no Rails/ActiveSupport constant may creep into lib/,
  # so any app can use it and webhook verification never depends on framework helpers.
  class RailsFreeBoundaryTest < Minitest::Test
    FORBIDDEN = /\b(Rails|ActiveRecord|ActiveSupport|ActionController|ActiveJob)\b/

    def test_lib_references_no_rails_constants
      files = Dir[File.expand_path("../../lib/**/*.rb", __dir__)]
      assert_operator files.size, :>=, 5, "expected the tingee lib files to exist"

      files.each do |file|
        # strip full-line comments; comments naming these constants are harmless
        code = File.readlines(file).reject { |line| line.strip.start_with?("#") }.join
        refute_match FORBIDDEN, code, "#{file} references a forbidden Rails constant"
      end
    end
  end
end
