# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'vivlio_starter/pdf'

require 'minitest/autorun'
# Object#stub を使うので明示的に読む。Minitest 6 は minitest/mock を別の gem に分離した。
require 'minitest/mock'
require 'minitest/pride'
