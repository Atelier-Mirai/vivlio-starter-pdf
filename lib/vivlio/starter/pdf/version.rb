# frozen_string_literal: true

module Vivlio
  module Starter
    module Pdf
      VERSION = "1.0.0"
    end

    PDF = Pdf unless const_defined?(:PDF)
  end
end
