# frozen_string_literal: true

require "test_helper"

class CLITest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vivlio::Starter::PDF::VERSION
  end

  def test_that_cli_runs_without_error
    result = Vivlio::Starter::PDF::CLI.new(["--help"]).call
    assert_equal 0, result
  end

  def test_that_cli_prints_version
    stdout, = capture_io do
      result = Vivlio::Starter::PDF::CLI.new(["--version"]).call
      assert_equal 0, result
    end

    assert_equal("#{Vivlio::Starter::PDF::VERSION}\n", stdout)
  end
end
