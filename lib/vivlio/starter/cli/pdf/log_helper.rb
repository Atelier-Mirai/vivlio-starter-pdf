# frozen_string_literal: true

module Vivlio
  module Starter
    module Pdf
      # Logging helper that integrates with vivlio-starter CLI when available
      module LogHelper
        module_function

        def log_action(message)
          dispatch(:log_action, message) { puts(message) }
        end

        def log_info(message)
          dispatch(:log_info, message) { puts(message) }
        end

        def log_success(message)
          dispatch(:log_success, message) { puts(message) }
        end

        def log_warn(message)
          dispatch(:log_warn, message) { warn(message) }
        end

        def log_error(message)
          dispatch(:log_error, message) { warn(message) }
        end

        def dispatch(method, message)
          if defined?(Vivlio::Starter::CLI::Common)
            Vivlio::Starter::CLI::Common.public_send(method, message)
          else
            yield if block_given?
          end
        end
      end
    end
  end
end
