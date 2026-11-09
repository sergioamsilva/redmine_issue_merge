# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

require File.expand_path('../test_helper', __dir__)

class IssueMergeIssuePageTest < Redmine::ControllerTest
  include IssueMergeTestHelper

  tests IssuesController
  fixtures(*IssueMergeTestHelper::FIXTURES)

  def test_issue_page_has_the_merge_entry_when_allowed
    grant_merge(1)
    @request.session[:user_id] = 2
    get :show, params: { id: 1 }

    assert_response :success
    assert_select 'template#issue-merge-menu-item'
  end

  def test_issue_page_has_no_merge_entry_without_permission
    @request.session[:user_id] = 2
    get :show, params: { id: 1 }

    assert_response :success
    assert_select 'template#issue-merge-menu-item', 0
  end
end

class IssueMergeContextMenuTest < Redmine::ControllerTest
  include IssueMergeTestHelper

  # Redmine 7.0 moved the issue context menu to ContextMenus::IssuesController#index
  CONTROLLER, ACTION = begin
    [ContextMenus::IssuesController, :index]
  rescue NameError
    [ContextMenusController, :issues]
  end

  tests CONTROLLER
  fixtures(*IssueMergeTestHelper::FIXTURES)

  def test_context_menu_for_several_issues
    grant_merge(1)
    @request.session[:user_id] = 2
    get ACTION, params: { ids: [1, 2] }

    assert_response :success
    assert_select 'a.icon-bullet-go[href*=?]', '/issue_merges/new'
  end

  def test_context_menu_for_one_issue
    grant_merge(1)
    @request.session[:user_id] = 2
    get ACTION, params: { ids: [1] }

    assert_response :success
    assert_select 'a.icon-bullet-go[href=?]', '/issues/1/merge'
  end

  def test_no_context_menu_entry_without_permission
    @request.session[:user_id] = 2
    get ACTION, params: { ids: [1, 2] }

    assert_response :success
    assert_select 'a.icon-bullet-go', 0
  end
end
