# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

require File.expand_path('../../test_helper', __FILE__)

class IssueMergesControllerTest < Redmine::ControllerTest
  include IssueMergeTestHelper

  fixtures(*IssueMergeTestHelper::FIXTURES)

  def setup
    grant_merge(1)
    @request.session[:user_id] = 2
  end

  def test_new_shows_the_form
    with_merge_settings { get :new, params: { issue_id: 1 } }

    assert_response :success
    assert_select 'input#other_issue_id'
    assert_select 'input[name=direction][value=into_other][checked=checked]'
    assert_select 'table.issue-merge-plan', 0
  end

  def test_new_with_the_other_issue_shows_the_preview
    source = new_issue
    destination = new_issue
    log_time(source, 1.5)

    with_merge_settings { get :new, params: { issue_id: source.id, other_issue_id: "##{destination.id}" } }

    assert_response :success
    assert_select 'table.issue-merge-plan td', text: /1\.50 h/
    assert_select 'form#issue-merge-confirm[action=?]', "/issues/#{source.id}/merge"
    assert_select 'form#issue-merge-confirm input[name=other_issue_id][value=?]', destination.id.to_s
  end

  def test_preview_lists_problems_and_hides_the_confirm_button
    source = new_issue
    child = new_issue(parent_issue_id: source.id)

    with_merge_settings { get :new, params: { issue_id: source.id, other_issue_id: child.id } }

    assert_response :success
    assert_select '#errorExplanation li', text: /##{source.id}/
    assert_select 'form#issue-merge-confirm', 0
  end

  def test_unknown_other_issue
    with_merge_settings { get :new, params: { issue_id: 1, other_issue_id: '999999' } }

    assert_response :success
    assert_select '#flash_error', text: /999999/
  end

  def test_create_merges_this_issue_into_the_other
    source = new_issue
    destination = new_issue

    with_merge_settings { post :create, params: { issue_id: source.id, other_issue_id: "##{destination.id}" } }

    assert_redirected_to "/issues/#{destination.id}"
    assert source.reload.closed?
  end

  def test_create_merges_the_other_issue_into_this_one
    kept = new_issue
    other = new_issue

    with_merge_settings do
      post :create, params: { issue_id: kept.id, other_issue_id: other.id, direction: 'into_this' }
    end

    assert_redirected_to "/issues/#{kept.id}"
    assert other.reload.closed?
    assert_not kept.reload.closed?
  end

  def test_create_with_a_problem_changes_nothing
    source = new_issue
    child = new_issue(parent_issue_id: source.id)

    with_merge_settings { post :create, params: { issue_id: source.id, other_issue_id: child.id } }

    assert_response :redirect
    assert_not source.reload.closed?
    assert_match(/##{source.id}/, flash[:error])
  end

  def test_forbidden_without_the_permission
    @request.session[:user_id] = 3

    with_merge_settings { get :new, params: { issue_id: 1 } }

    assert_response :forbidden
  end

  def test_invisible_issue_is_not_found
    with_merge_settings { get :new, params: { issue_id: 999_999 } }

    assert_response :not_found
  end

  def test_new_multiple_proposes_the_oldest_as_destination
    issues = [new_issue, new_issue, new_issue]

    with_merge_settings { get :new_multiple, params: { ids: issues.map(&:id) } }

    assert_response :success
    assert_select 'input[name=destination_id]', 3
    assert_select 'input[name=destination_id][value=?][checked=checked]', issues.first.id.to_s
  end

  def test_new_multiple_needs_two_issues
    with_merge_settings { get :new_multiple, params: { ids: [new_issue.id] } }

    assert_response :not_found
  end

  def test_create_multiple
    destination, *sources = [new_issue, new_issue, new_issue]

    with_merge_settings do
      post :create_multiple, params: { ids: [destination.id] + sources.map(&:id), destination_id: destination.id }
    end

    assert_redirected_to "/issues/#{destination.id}"
    assert(sources.all? { |issue| issue.reload.closed? })
  end
end
