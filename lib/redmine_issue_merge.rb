# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

# Settings shared by the merge service, the controller and the views
module RedmineIssueMerge
  VERSION = '1.0.0'

  SOURCE_ACTIONS = %w[close delete].freeze

  DEFAULTS = {
    'source_action' => 'close',
    'closed_status_id' => '',
    'escalate_priority' => '1',
    'fill_custom_fields' => '1',
    'add_watchers' => '1',
    'notify' => '1',
    'protected_pattern' => ''
  }.freeze

  class << self
    def settings
      stored = Setting.plugin_redmine_issue_merge
      stored = {} unless stored.respond_to?(:to_h)
      DEFAULTS.merge(stored.to_h.transform_keys(&:to_s))
    end

    def enabled?(key)
      settings[key.to_s].to_s == '1'
    end

    # What happens to a merged issue: 'close' (default, keeps a stub that points to the kept issue) or 'delete'
    def source_action
      SOURCE_ACTIONS.include?(settings['source_action']) ? settings['source_action'] : 'close'
    end

    def delete_source?
      source_action == 'delete'
    end

    # The configured closed status, or the first closed status by position
    def closed_status
      id = settings['closed_status_id'].to_i
      status = IssueStatus.find_by(id: id, is_closed: true) if id.positive?
      status || IssueStatus.where(is_closed: true).sorted.first
    end

    # Issues whose subject or description match this expression are never merged (e.g. issues kept in sync with
    # another system, which would be recreated). An invalid expression protects nothing and is reported in the
    # settings page.
    def protected_regexp
      raw = settings['protected_pattern'].to_s.strip
      return nil if raw.empty?

      Regexp.new(raw, Regexp::IGNORECASE, timeout: 1.0)
    rescue RegexpError
      nil
    end

    def protected?(issue)
      regexp = protected_regexp
      return false unless regexp

      regexp.match?(issue.subject.to_s) || regexp.match?(issue.description.to_s)
    rescue Regexp::TimeoutError
      true
    end

    # Checklist items (redmine_checklists / RedmineUP) move with the issue when that plugin is installed
    def checklists?
      return @checklists if defined?(@checklists)

      @checklists = Object.const_defined?(:Checklist) && ::Checklist.table_exists? &&
                    ::Checklist.column_names.include?('issue_id')
    rescue StandardError
      @checklists = false
    end
  end
end

require File.expand_path('redmine_issue_merge/merger', __dir__)
require File.expand_path('redmine_issue_merge/hooks', __dir__)
