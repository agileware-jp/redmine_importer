require File.dirname(__FILE__) + '/../test_helper'

class ImporterHelperTest < ActionView::TestCase
  include ImporterHelper

  test 'force_utf8 handles nil' do
    assert_equal '', force_utf8(nil)
    assert_equal Encoding::UTF_8, force_utf8(nil).encoding
  end

  test 'force_utf8 handles ASCII-8BIT string with non-ASCII bytes' do
    binary = "\x82\xC4\x82\xB7\x82\xC6".force_encoding('ASCII-8BIT')
    result = force_utf8(binary)
    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
  end

  test 'force_utf8 preserves valid UTF-8' do
    str = 'テスト'
    assert_equal str, force_utf8(str)
  end

  test 'force_utf8 replaces invalid sequences instead of raising' do
    invalid = "\xFF\xFE".force_encoding('UTF-8')
    assert_nothing_raised { force_utf8(invalid) }
    assert_equal Encoding::UTF_8, force_utf8(invalid).encoding
  end
end