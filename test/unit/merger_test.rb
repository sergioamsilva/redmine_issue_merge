# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

require File.expand_path('../test_helper', __dir__)

class MergerTest < ActiveSupport::TestCase
  include IssueMergeTestHelper

  fixtures(*IssueMergeTestHelper::FIXTURES)

  def setup
    User.current = User.find(2)
    grant_merge(1)
    set_tmp_attachments_directory
    ActionMailer::Base.deliveries.clear
  end

  def test_moves_notes_time_files_and_watchers_and_closes_the_source
    destination = new_issue(subject: 'Keep')
    source = new_issue(subject: 'Drop', description: 'Original text')
    source.init_journal(User.find(3), 'a note from dlopper')
    source.save!
    note = source.journals.last
    entry = log_time(source, 2.5)
    file = Attachment.create!(container: source, file: uploaded_test_file('testfile.txt', 'text/plain'),
                              author: User.find(2))
    Watcher.create!(watchable: source, user: User.find(3))

    merge(destination, source)

    assert_equal destination.id, note.reload.journalized_id
    assert_equal 3, note.user_id
    assert_equal destination.id, entry.reload.issue_id
    assert_equal destination.id, file.reload.container_id
    assert_includes destination.reload.watcher_user_ids, 3
    assert(destination.journals.any? { |j| j.notes.to_s.include?('Original text') })

    source.reload
    assert source.closed?
    assert IssueRelation.exists?(issue_from_id: source.id, issue_to_id: destination.id, relation_type: 'duplicates')
    assert_empty source.time_entries
  end

  def test_merge_note_describes_the_source
    destination = new_issue
    source = new_issue(subject: 'Printer on fire')
    log_time(source, 1)

    merge(destination, source)

    note = destination.reload.journals.order(:id).last.notes
    assert_includes note, "##{source.id}"
    assert_includes note, 'Printer on fire'
    assert_includes note, '1.00 h'
  end

  def test_delete_mode_removes_the_source_and_keeps_its_records
    destination = new_issue
    source = new_issue
    entry = log_time(source, 1)

    merge(destination, source, source_action: 'delete')

    assert_not Issue.exists?(source.id)
    assert_equal destination.id, entry.reload.issue_id
  end

  def test_time_entries_follow_the_destination_project
    Project.find(3).enable_module!(:time_tracking)
    destination = new_issue
    source = new_issue(project_id: 3)
    entry = log_time(source, 1, user_id: 1)

    merge(destination, source, user: User.find(1))

    entry.reload
    assert_equal destination.id, entry.issue_id
    assert_equal 1, entry.project_id
  end

  def test_subtasks_move_without_breaking_the_tree
    destination = new_issue
    source = new_issue
    child = new_issue(parent_issue_id: source.id)

    merge(destination, source, source_action: 'delete')

    child.reload
    destination.reload
    assert_equal destination.id, child.parent_id
    assert_equal destination.root_id, child.root_id
    assert_operator child.lft, :>, destination.lft
    assert_operator child.rgt, :<, destination.rgt
  end

  def test_relations_move_to_the_destination
    destination = new_issue
    source = new_issue
    other = new_issue
    IssueRelation.create!(issue_from: source, issue_to: other, relation_type: 'blocks')

    merge(destination, source)

    assert IssueRelation.exists?(issue_from_id: destination.id, issue_to_id: other.id, relation_type: 'blocks')
    assert_not IssueRelation.exists?(issue_from_id: source.id, issue_to_id: other.id)
  end

  def test_relation_that_would_create_a_cycle_is_reported_and_left_on_the_source
    destination = new_issue
    source = new_issue
    middle = new_issue
    other = new_issue
    IssueRelation.create!(issue_from: destination, issue_to: middle, relation_type: 'blocks')
    IssueRelation.create!(issue_from: middle, issue_to: other, relation_type: 'blocks')
    IssueRelation.create!(issue_from: other, issue_to: source, relation_type: 'blocks')

    merge(destination, source)

    assert IssueRelation.exists?(issue_from_id: other.id, issue_to_id: source.id)
    note = destination.reload.journals.order(:id).last.notes
    assert_includes note, "##{other.id}"
  end

  def test_different_relation_already_on_the_destination_is_reported
    destination = new_issue
    source = new_issue
    other = new_issue
    IssueRelation.create!(issue_from: destination, issue_to: other, relation_type: 'relates')
    IssueRelation.create!(issue_from: source, issue_to: other, relation_type: 'blocks')

    merge(destination, source)

    assert IssueRelation.exists?(issue_from_id: source.id, issue_to_id: other.id, relation_type: 'blocks')
    assert_includes destination.reload.journals.order(:id).last.notes, "##{other.id}"
  end

  def test_relation_already_on_the_destination_is_not_duplicated
    destination = new_issue
    source = new_issue
    other = new_issue
    IssueRelation.create!(issue_from: destination, issue_to: other, relation_type: 'relates')
    IssueRelation.create!(issue_from: source, issue_to: other, relation_type: 'relates')

    merge(destination, source)

    assert_equal 1, IssueRelation.where(issue_from_id: [destination.id, other.id],
                                        issue_to_id: [destination.id, other.id]).count
    assert_not_includes destination.reload.journals.last.notes, other.id.to_s
  end

  def test_relation_between_source_and_destination_is_dropped
    destination = new_issue
    source = new_issue
    IssueRelation.create!(issue_from: source, issue_to: destination, relation_type: 'relates')

    merge(destination, source, source_action: 'delete')

    assert_equal 0, IssueRelation.where(issue_from_id: destination.id).or(
      IssueRelation.where(issue_to_id: destination.id)
    ).count
  end

  def test_higher_priority_and_empty_custom_fields_come_from_the_source
    field = IssueCustomField.create!(name: 'Merge field', field_format: 'string', is_for_all: true,
                                     tracker_ids: [1])
    destination = new_issue(priority_id: 4)
    source = new_issue(priority_id: 7)
    source.custom_field_values = { field.id.to_s => 'from source' }
    source.save!

    merge(destination, source, user: User.find(1))

    destination.reload
    assert_equal 7, destination.priority_id
    assert_equal 'from source', destination.custom_field_value(field)
  end

  def test_filled_values_do_not_overwrite_the_destination
    field = IssueCustomField.create!(name: 'Merge field', field_format: 'string', is_for_all: true,
                                     tracker_ids: [1])
    destination = new_issue
    destination.custom_field_values = { field.id.to_s => 'kept' }
    destination.save!
    source = new_issue
    source.custom_field_values = { field.id.to_s => 'lost' }
    source.save!

    merge(destination, source, user: User.find(1), escalate_priority: '0')

    assert_equal 'kept', destination.reload.custom_field_value(field)
  end

  def test_several_sources_in_one_merge
    destination = new_issue
    first = new_issue
    second = new_issue
    log_time(first, 1)
    log_time(second, 2)

    merge(destination, [first, second])

    assert_in_delta 3.0, destination.reload.time_entries.sum(:hours), 0.001
    assert first.reload.closed?
    assert second.reload.closed?
  end

  def test_refuses_merging_a_parent_into_its_child
    source = new_issue
    destination = new_issue(parent_issue_id: source.id)
    merger = RedmineIssueMerge::Merger.new(destination, [source], user: User.find(2))

    with_merge_settings { assert_not merger.valid? }
    assert(merger.errors.any? { |e| e.include?("##{source.id}") })
  end

  def test_merging_a_subtask_into_its_parent_is_allowed
    destination = new_issue
    source = new_issue(parent_issue_id: destination.id)

    merge(destination, source, source_action: 'delete')

    assert_not Issue.exists?(source.id)
  end

  def test_refuses_an_issue_into_itself
    issue = new_issue
    merger = RedmineIssueMerge::Merger.new(issue, [issue], user: User.find(2))

    with_merge_settings { assert_not merger.valid? }
  end

  def test_protected_issues_are_refused
    destination = new_issue
    source = new_issue(description: 'Pedido importado do Network')
    merger = RedmineIssueMerge::Merger.new(destination, [source], user: User.find(2))

    with_merge_settings(protected_pattern: 'importado do network') { assert_not merger.valid? }
    with_merge_settings(protected_pattern: '') { assert merger.valid? }
  end

  def test_invalid_protected_pattern_protects_nothing
    with_merge_settings(protected_pattern: '([unclosed') do
      assert_nil RedmineIssueMerge.protected_regexp
      assert_not RedmineIssueMerge.protected?(new_issue)
    end
  end

  def test_requires_the_merge_permission
    Role.find(1).remove_permission!(:merge_issues)
    merger = RedmineIssueMerge::Merger.new(new_issue, [new_issue], user: User.find(2))

    with_merge_settings { assert_not merger.valid? }
  end

  def test_delete_mode_requires_the_delete_permission
    grant_merge(2)
    Role.find(2).remove_permission!(:delete_issues)
    merger = RedmineIssueMerge::Merger.new(new_issue, [new_issue], user: User.find(3))

    with_merge_settings(source_action: 'delete') { assert_not merger.valid? }
  end

  def test_failure_rolls_everything_back
    destination = new_issue
    source = new_issue
    entry = log_time(source, 1)
    Issue.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new('boom'))

    assert_raises(RedmineIssueMerge::Merger::Error) { merge(destination, source, source_action: 'delete') }

    assert Issue.exists?(source.id)
    assert_equal source.id, entry.reload.issue_id
  end

  def test_one_notification_for_the_destination_and_none_for_the_source
    destination = new_issue(assigned_to_id: 3)
    source = new_issue(assigned_to_id: 3)
    with_settings(notified_events: %w[issue_updated]) { merge(destination, source) }

    assert ActionMailer::Base.deliveries.any?
    assert(ActionMailer::Base.deliveries.all? { |mail| mail.subject.include?("##{destination.id}") })
  end

  def test_notifications_can_be_turned_off
    destination = new_issue(assigned_to_id: 3)
    source = new_issue(assigned_to_id: 3)
    with_settings(notified_events: %w[issue_updated]) { merge(destination, source, notify: '0') }

    assert_empty ActionMailer::Base.deliveries
  end
end
