# frozen_string_literal: true

module Vivlio
  module Starter
    module Pdf
      VERSION = "0.1.0"
    end

    PDF = Pdf unless const_defined?(:PDF)
  end
end
