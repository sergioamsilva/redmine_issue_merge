# frozen_string_literal: true

# Redmine Issue Merge plugin — test helper (Apache-2.0, see LICENSE and NOTICE)

# Load the Redmine test helper (__FILE__, not __dir__: the plugin is usually a symlink in the Redmine tree)
require File.expand_path('../../../../test/test_helper', __FILE__)

# Shared helpers for the plugin tests
module IssueMergeTestHelper
  FIXTURES = %i[projects users email_addresses user_preferences roles members member_roles issues issue_statuses
                trackers projects_trackers enumerations enabled_modules journals journal_details issue_categories
                versions custom_fields custom_values custom_fields_trackers custom_fields_projects workflows
                attachments time_entries issue_relations watchers queries].freeze

  def with_merge_settings(overrides = {}, &)
    settings = RedmineIssueMerge::DEFAULTS.merge(overrides.transform_keys(&:to_s))
    with_settings(plugin_redmine_issue_merge: settings, &)
  end

  def grant_merge(*role_ids)
    (role_ids.presence || [1]).each { |id| Role.find(id).add_permission!(:merge_issues) }
  end

  # A fresh issue in eCookbook (project 1), created by jsmith (user 2, Manager)
  def new_issue(attributes = {})
    issue = Issue.new({ project_id: 1, tracker_id: 1, author_id: 2, status_id: 1, priority_id: 4,
                        subject: 'Merge test' }.merge(attributes))
    issue.save!
    issue.reload
  end

  def log_time(issue, hours, user_id: 2)
    TimeEntry.create!(project: issue.project, issue: issue, user_id: user_id, author_id: user_id, hours: hours,
                      spent_on: Date.current, activity_id: 9, comments: 'merge test entry')
  end

  def merge(destination, sources, user: User.find(2), **settings)
    ActionMailer::Base.deliveries.clear
    with_merge_settings(settings) do
      merger = RedmineIssueMerge::Merger.new(destination, Array(sources), user: user)
      merger.merge!
      merger
    end
  end
end
