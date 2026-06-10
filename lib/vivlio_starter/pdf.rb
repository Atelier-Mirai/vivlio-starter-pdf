# frozen_string_literal: true

require_relative "cli/pdf/version"
require_relative "cli/pdf/reader"
require_relative "cli/pdf/enhanced_provider"
require_relative "cli/pdf/outline_writer"
require_relative "cli/pdf/utilities"

module VivlioStarter
  module Pdf
    class Error < StandardError; end
  end
end
