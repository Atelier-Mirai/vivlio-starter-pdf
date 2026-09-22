# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'vivlio_starter/pdf'

require 'minitest/autorun'
# **明示的に読む。** Minitest 6 は minitest/mock を本体から外し、minitest-mock gem へ
# 分離した。5 では autorun がついでに読んでいたので書かなくても Object#stub が使えたが、
# 6 では `undefined method 'stub'` になる——5 で緑・6 で赤という版依存の壊れ方をしていた。
require 'minitest/mock'
require 'minitest/pride'
