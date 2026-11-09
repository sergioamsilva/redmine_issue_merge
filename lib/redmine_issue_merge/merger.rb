# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

module RedmineIssueMerge
  # Merges one or more source issues into a destination issue.
  #
  #   merger = RedmineIssueMerge::Merger.new(destination, [source], user: User.current)
  #   merger.valid?   # permissions and structure; fills #errors, writes nothing
  #   merger.plans    # what each source carries (for the preview)
  #   merger.merge!   # one transaction: everything or nothing; raises Merger::Error
  #
  # Notes, time entries, files, revisions and checklist items are moved row by row (their history and authors
  # stay untouched). Subtasks and relations go through the core models, so the nested set, the cycle checks and
  # the rescheduling of following issues behave exactly as in Redmine. The source is then closed as a duplicate
  # (default) or deleted, and the destination gets one journal that describes the merge.
  class Merger # rubocop:disable Metrics/ClassLength
    include Redmine::I18n

    # Raised when the merge cannot go ahead; the message is ready to show to the user
    class Error < StandardError; end

    Plan = Struct.new(:source, :journals, :time_entries, :hours, :attachments, :children, :relations,
                      :watchers, :changesets, :checklists, keyword_init: true)

    attr_reader :destination, :sources, :user, :errors

    def initialize(destination, sources, user: User.current)
      @destination = destination
      @sources = Array(sources).compact.uniq
      @user = user
      @errors = []
      @report = []
    end

    def valid?
      @errors = []
      check_destination
      sources.each { |source| check_source(source) }
      @errors.uniq!
      @errors.empty?
    end

    def plans
      @plans ||= sources.map { |source| plan_for(source) }
    end

    def merge!
      raise Error, errors.join(' ') unless valid?

      Issue.transaction do
        sources.each { |source| merge_source(source) }
        finish_destination
      end
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotDestroyed,
           ActiveRecord::StaleObjectError => e
      Rails.logger.error("[issue_merge] #{e.class}: #{e.message}")
      raise Error, l(:error_issue_merge_failed, message: e.message)
    end

    private

    # --- checks ---------------------------------------------------------------------------------------------

    def check_destination
      @errors << l(:error_issue_merge_no_source) if sources.empty?
      return @errors << l(:error_issue_merge_not_found, id: destination.id) unless destination.visible?(user)
      return unless allowed?(destination.project)
      return if destination.editable?(user)

      @errors << l(:error_issue_merge_destination_not_editable, id: destination.id)
    end

    def check_source(source)
      return @errors << l(:error_issue_merge_same) if source.id == destination.id
      return @errors << l(:error_issue_merge_not_found, id: source.id) unless source.visible?(user)
      return unless allowed?(source.project)

      check_source_permission(source)
      check_source_structure(source)
    end

    def allowed?(project)
      return true if user.allowed_to?(:merge_issues, project)

      @errors << l(:error_issue_merge_not_allowed, project: project.name)
      false
    end

    def check_source_permission(source)
      if RedmineIssueMerge.delete_source?
        @errors << l(:error_issue_merge_cannot_delete, id: source.id) unless source.deletable?(user)
      elsif !source.attributes_editable?(user)
        @errors << l(:error_issue_merge_cannot_close, id: source.id)
      end
      @errors << l(:error_issue_merge_protected, id: source.id) if RedmineIssueMerge.protected?(source)
    end

    def check_source_structure(source)
      if Issue.find(source.id).is_ancestor_of?(fresh_destination)
        @errors << l(:error_issue_merge_ancestor, id: source.id, destination: destination.id)
      end
      if source.time_entries.exists? && !destination.project.module_enabled?(:time_tracking)
        @errors << l(:error_issue_merge_time_tracking, id: source.id, project: destination.project.name)
      end
      check_children(source)
    end

    def check_children(source)
      source.children.each do |child|
        next if sources.include?(child) || child.valid_parent_project?(destination)

        @errors << l(:error_issue_merge_subtask, child: child.id, destination: destination.id)
      end
    end

    # --- merge ----------------------------------------------------------------------------------------------

    def plan_for(source)
      Plan.new(source: source,
               journals: source.journals.count,
               time_entries: source.time_entries.count,
               hours: source.time_entries.sum(:hours).to_f,
               attachments: source.attachments.count,
               children: source.children.count,
               relations: relations_of(source).count,
               watchers: source.watchers.count,
               changesets: source.changesets.count,
               checklists: RedmineIssueMerge.checklists? ? ::Checklist.where(issue_id: source.id).count : 0)
    end

    def merge_source(source)
      source.reload
      entry = { plan: plan_for(source), snapshot: snapshot_of(source) }
      copy_description(source)
      move_rows(source)
      move_watchers(source)
      move_children(source)
      entry[:skipped] = move_relations(source)
      Redmine::Hook.call_hook(:model_issue_merge_before_source_removal,
                              source: source, destination: fresh_destination, user: user)
      finish_source(source)
      @report << entry
    end

    # The source description becomes a note on the destination, dated when the source was created, so the
    # history reads in order and inline images keep resolving (the files move too)
    def copy_description(source)
      return if source.description.blank?

      text = "#{l(:text_issue_merge_description, id: source.id, subject: source.subject)}\n\n#{source.description}"
      journal = Journal.new(journalized: fresh_destination, user: source.author, notes: text)
      journal.notify = false
      journal.save!
      # Both timestamps, otherwise the note shows as "Edited"
      Journal.where(id: journal.id).update_all( # rubocop:disable Rails/SkipsModelValidations
        created_on: source.created_on, updated_on: source.created_on
      )
    end

    # rubocop:disable Rails/SkipsModelValidations
    def move_rows(source)
      Journal.where(journalized_type: 'Issue', journalized_id: source.id).update_all(journalized_id: destination.id)
      TimeEntry.where(issue_id: source.id).update_all(issue_id: destination.id, project_id: destination.project_id)
      Attachment.where(container_type: 'Issue', container_id: source.id).update_all(container_id: destination.id)
      move_changesets(source)
      move_checklists(source)
    end

    def move_checklists(source)
      return unless RedmineIssueMerge.checklists?

      start = ::Checklist.where(issue_id: destination.id).maximum(:position).to_i
      ::Checklist.where(issue_id: source.id).order(:position, :id).pluck(:id).each_with_index do |id, index|
        ::Checklist.where(id: id).update_all(issue_id: destination.id, position: start + index + 1)
      end
    end
    # rubocop:enable Rails/SkipsModelValidations

    def move_changesets(source)
      target = fresh_destination
      moved = source.changesets.to_a - target.changesets.to_a
      target.changesets << moved if moved.any?
      source.changesets.clear
    end

    def move_watchers(source)
      target = fresh_destination
      candidates = source.watcher_users.to_a
      candidates += [source.author, source.assigned_to] if RedmineIssueMerge.enabled?(:add_watchers)
      existing = target.watcher_users.to_a
      candidates.compact.uniq.each do |principal|
        next if existing.include?(principal) || !watcher_allowed?(principal, target)

        watcher = Watcher.new(watchable: target, user: principal)
        if watcher.save
          existing << principal
        else
          Rails.logger.warn("[issue_merge] watcher #{principal.id} not added to ##{target.id}: " \
                            "#{watcher.errors.full_messages.to_sentence}")
        end
      end
    end

    def watcher_allowed?(principal, issue)
      return principal.givable? if principal.is_a?(Group)

      principal.is_a?(User) && !principal.anonymous? && principal.active? && issue.visible?(principal)
    end

    # Through the core, so lft/rgt/root_id stay consistent and the parent attributes are recalculated
    def move_children(source)
      source.children.to_a.each do |child|
        child.reload
        child.init_journal(user).notify = false
        child.parent_issue_id = destination.id
        child.save!
      end
    end

    # Each relation is recreated against the destination with the core validations (cycles, descendants,
    # cross-project setting) and the core rescheduling of following issues. Those that cannot move are listed
    # in the merge note; with "close" they stay on the closed source.
    def move_relations(source)
      relations_of(source).to_a.filter_map { |relation| move_relation(relation, source) }
    end

    # Returns [description, reason] when the relation stays behind, nil otherwise
    def move_relation(relation, source)
      other_id = relation.issue_from_id == source.id ? relation.issue_to_id : relation.issue_from_id
      return drop(relation) if other_id == destination.id || sources.any? { |s| s.id == other_id }

      existing = destination_relation_with(other_id)
      if existing
        # Same relation already on the destination: redundant. A different one: keep both visible
        return drop(relation) if existing.relation_type == relation.relation_type

        return [describe_relation(relation, source), l(:text_issue_merge_already_related, id: destination.id)]
      end
      moved = rebuild_relation(relation, source)
      return drop(relation) if moved.save

      [describe_relation(relation, source), moved.errors.full_messages.to_sentence]
    end

    def drop(relation)
      relation.destroy
      nil
    end

    def rebuild_relation(relation, source)
      moved = IssueRelation.new(relation_type: relation.relation_type, delay: relation.delay)
      if relation.issue_from_id == source.id
        moved.issue_from = fresh_destination
        moved.issue_to = Issue.find(relation.issue_to_id)
      else
        moved.issue_from = Issue.find(relation.issue_from_id)
        moved.issue_to = fresh_destination
      end
      moved
    end

    def describe_relation(relation, source)
      other = relation.other_issue(source)
      "#{l(relation.label_for(source))} ##{other.id}"
    end

    # The relation the destination already has with that issue, if any (the core allows one per pair)
    def destination_relation_with(other_id)
      relations_of(destination).find_by(['issue_from_id = :id OR issue_to_id = :id', { id: other_id }])
    end

    def relations_of(issue)
      IssueRelation.where(issue_from_id: issue.id).or(IssueRelation.where(issue_to_id: issue.id))
    end

    def finish_source(source)
      source.reload
      if RedmineIssueMerge.delete_source?
        source.destroy!
      else
        close_source(source)
      end
    end

    def close_source(source)
      source.init_journal(user, l(:text_issue_merge_stub, id: destination.id)).notify = false
      source.status = RedmineIssueMerge.closed_status unless source.closed?
      source.save!
      return if source.is_descendant_of?(destination)

      IssueRelation.new(issue_from: source.reload, issue_to: fresh_destination,
                        relation_type: IssueRelation::TYPE_DUPLICATES).save
    end

    # Children, relations and deletions above may have rewritten the destination row (parent attributes,
    # rescheduling), so the final journal is written on a fresh copy
    def finish_destination
      target = fresh_destination
      journal = target.init_journal(user)
      journal.notify = RedmineIssueMerge.enabled?(:notify)
      apply_priority(target)
      filled = apply_custom_fields(target)
      journal.notes = merge_note(filled)
      target.save!
      write_private_fields(target)
      @destination = target
    end

    def apply_priority(target)
      return unless RedmineIssueMerge.enabled?(:escalate_priority)

      top = @report.filter_map { |entry| entry[:snapshot][:priority] }.max_by(&:position)
      return unless top && target.priority && top.position > target.priority.position
      return unless target.safe_attribute?('priority_id', user)

      target.priority = top
    end

    def apply_custom_fields(target)
      return [] unless RedmineIssueMerge.enabled?(:fill_custom_fields)

      editable = target.editable_custom_field_values(user).index_by(&:custom_field_id)
      values = {}
      @report.each do |entry|
        entry[:snapshot][:custom_values].each do |field_id, value|
          current = editable[field_id]
          next if current.nil? || present_value?(current.value) || values.key?(field_id.to_s)

          values[field_id.to_s] = value
        end
      end
      target.custom_field_values = values if values.any?
      values.keys.map(&:to_i)
    end

    # Values of custom fields restricted to some roles go to a private note, never to the public merge note
    def write_private_fields(target)
      lines = @report.filter_map do |entry|
        fields = entry[:snapshot][:private_fields]
        l(:text_issue_merge_private_fields, id: entry[:snapshot][:id], fields: fields.join('; ')) if fields.any?
      end
      return if lines.empty?

      journal = Journal.new(journalized: target, user: user, notes: lines.join("\n\n"), private_notes: true)
      journal.notify = false
      journal.save!
    end

    # --- note -----------------------------------------------------------------------------------------------

    def snapshot_of(source)
      {
        id: source.id, subject: source.subject, tracker: source.tracker&.name, status: source.status&.name,
        author: source.author&.name, assignee: source.assigned_to&.name, created: format_date(source.created_on),
        priority: source.priority
      }.merge(field_snapshot(source))
    end

    def field_snapshot(source)
      values = source.custom_field_values.select { |v| present_value?(v.value) }
      public_values, private_values = values.partition { |v| v.custom_field.visible? }
      {
        custom_values: values.to_h { |v| [v.custom_field_id, v.value] },
        public_fields: public_values.map { |v| format_field(v) },
        private_fields: private_values.map { |v| format_field(v) }
      }
    end

    def merge_note(filled)
      blocks = @report.map { |entry| note_block(entry) }
      if filled.any?
        names = CustomField.where(id: filled).order(:position).pluck(:name)
        blocks << l(:text_issue_merge_filled_fields, fields: names.join(', '))
      end
      blocks.join("\n\n")
    end

    def note_block(entry)
      snap = entry[:snapshot]
      lines = ["* #{original_line(snap)}"]
      moved = moved_line(entry[:plan])
      lines << "* #{moved}" if moved
      lines << "* #{l(:text_issue_merge_fields, fields: snap[:public_fields].join('; '))}" if snap[:public_fields].any?
      entry[:skipped].each do |relation, reason|
        lines << "* #{l(:text_issue_merge_skipped_relation, relation: relation, reason: reason)}"
      end
      outcome = RedmineIssueMerge.delete_source? ? :text_issue_merge_deleted : :text_issue_merge_closed
      lines << "* #{l(outcome, id: snap[:id])}"
      "#{l(:text_issue_merge_note, id: snap[:id], subject: snap[:subject])}\n\n#{lines.join("\n")}"
    end

    def original_line(snap)
      text = l(:text_issue_merge_original, tracker: snap[:tracker], status: snap[:status], author: snap[:author],
                                           created: snap[:created])
      snap[:assignee] ? "#{text} #{l(:text_issue_merge_original_assignee, name: snap[:assignee])}" : text
    end

    def moved_line(plan)
      parts = []
      parts << "#{l(:label_issue_merge_notes)}: #{plan.journals}" if plan.journals.positive?
      if plan.time_entries.positive?
        parts << "#{l(:label_issue_merge_time)}: #{plan.time_entries} (#{format('%.2f', plan.hours)} h)"
      end
      { attachments: :files, children: :subtasks, relations: :relations, watchers: :watchers,
        changesets: :revisions, checklists: :checklist }.each do |attr, label|
        count = plan.public_send(attr)
        parts << "#{l(:"label_issue_merge_#{label}")}: #{count}" if count.positive?
      end
      parts.any? ? "#{l(:text_issue_merge_moved)} #{parts.join(', ')}" : nil
    end

    def format_field(value)
      shown = Array(value.custom_field.cast_value(value.value)).map do |v|
        case v
        when true then l(:general_text_Yes)
        when false then l(:general_text_No)
        else v.to_s
        end
      end
      "#{value.custom_field.name}: #{shown.join(', ')}"
    end

    def present_value?(value)
      value.is_a?(Array) ? value.compact_blank.any? : value.present?
    end

    def fresh_destination
      Issue.find(destination.id)
    end
  end
end
