# frozen_string_literal: true

require_relative "pdf/version"
require_relative "pdf/reader"
require_relative "cli/pdf/enhanced_provider"
require_relative "cli/pdf/outline_writer"
require_relative "cli/pdf/utilities"

module Vivlio
  module Starter
    module PDF
      class Error < StandardError; end
    end
  end
end
