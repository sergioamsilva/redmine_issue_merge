# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

module RedmineIssueMerge
  # "Merge" entry in the actions menu of the issue page and in the context menu of the issue list
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_issues_show_details_bottom, partial: 'issue_merges/issue_menu_item'
    render_on :view_issues_context_menu_end, partial: 'issue_merges/context_menu'
  end
end
