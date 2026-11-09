# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

require File.expand_path('../../test_helper', __FILE__)

class IssueMergeLocalesTest < ActiveSupport::TestCase
  DIR = File.expand_path('../../../config/locales', __FILE__)

  def keys(file)
    YAML.load_file(file).values.first.keys.sort
  end

  def test_every_locale_has_the_same_keys
    reference = keys(File.join(DIR, 'en.yml'))
    Dir[File.join(DIR, '*.yml')].each do |file|
      assert_equal reference, keys(file), "#{File.basename(file)} differs from en.yml"
    end
  end
end
