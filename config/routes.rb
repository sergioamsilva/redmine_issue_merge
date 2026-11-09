# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

RedmineApp::Application.routes.draw do
  get 'issues/:issue_id/merge', to: 'issue_merges#new', as: 'new_issue_merge', issue_id: /\d+/
  post 'issues/:issue_id/merge', to: 'issue_merges#create', as: 'issue_merge', issue_id: /\d+/
  get 'issue_merges/new', to: 'issue_merges#new_multiple', as: 'new_issue_merges'
  post 'issue_merges', to: 'issue_merges#create_multiple', as: 'issue_merges'
end
