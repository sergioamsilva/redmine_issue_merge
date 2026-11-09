# frozen_string_literal: true

# Redmine Issue Merge plugin
#
# Copyright 2026 Sérgio Silva
#
# Licensed under the Apache License, Version 2.0 (see LICENSE and NOTICE).

require File.expand_path('lib/redmine_issue_merge', __dir__)

Redmine::Plugin.register :redmine_issue_merge do
  name 'Redmine Issue Merge'
  author 'Sérgio Silva'
  description 'Merge duplicate issues into one, keeping notes, time, files, subtasks, relations and watchers'
  version RedmineIssueMerge::VERSION
  url 'https://github.com/sergioamsilva/redmine_issue_merge'
  author_url 'https://github.com/sergioamsilva'

  requires_redmine version_or_higher: '6.0.0'

  settings partial: 'settings/issue_merge_settings', default: RedmineIssueMerge::DEFAULTS

  project_module :issue_tracking do
    permission :merge_issues,
               { issue_merges: %i[new create new_multiple create_multiple] },
               require: :member
  end
end
