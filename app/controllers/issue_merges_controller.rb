# frozen_string_literal: true

# Redmine Issue Merge plugin (Apache-2.0, see LICENSE and NOTICE)

# Merge screens. One issue with another (from the issue page) or several issues selected on the issue list
# (context menu). GET shows the form and, once the issues are chosen, a preview of what will move; POST merges.
class IssueMergesController < ApplicationController
  before_action :find_issue, only: %i[new create]
  before_action :find_selected_issues, only: %i[new_multiple create_multiple]
  before_action :authorize_merge

  def new
    @direction = direction_param
    @other_id = issue_id_param(params[:other_issue_id])
    return unless @other_id

    other = Issue.visible.find_by(id: @other_id)
    if other
      @merger = merger_for(other)
      @merger.valid?
    else
      flash.now[:error] = l(:error_issue_merge_not_found, id: @other_id)
    end
  end

  def create
    other_id = issue_id_param(params[:other_issue_id])
    other = Issue.visible.find_by(id: other_id) if other_id
    unless other
      flash[:error] = l(:error_issue_merge_not_found, id: other_id)
      return redirect_to new_issue_merge_path(@issue)
    end

    @direction = direction_param
    perform(merger_for(other), new_issue_merge_path(@issue, other_issue_id: other.id, direction: @direction))
  end

  def new_multiple
    @destination = @issues.detect { |issue| issue.id == params[:destination_id].to_i }
    return unless @destination

    @merger = RedmineIssueMerge::Merger.new(@destination, @issues - [@destination])
    @merger.valid?
  end

  def create_multiple
    destination = @issues.detect { |issue| issue.id == params[:destination_id].to_i }
    back = new_issue_merges_path(ids: @issues.map(&:id), destination_id: destination&.id)
    unless destination
      flash[:error] = l(:error_issue_merge_no_destination)
      return redirect_to back
    end

    perform(RedmineIssueMerge::Merger.new(destination, @issues - [destination]), back)
  end

  private

  def perform(merger, back)
    merger.merge!
    flash[:notice] = l(:notice_issue_merge_done, sources: merger.sources.map { |s| "##{s.id}" }.join(', '),
                                                 destination: merger.destination.id)
    redirect_to issue_path(merger.destination)
  rescue RedmineIssueMerge::Merger::Error => e
    flash[:error] = e.message
    redirect_to back
  end

  # "into_other": this issue goes away; "into_this": the other issue goes away
  def merger_for(other)
    if @direction == 'into_this'
      RedmineIssueMerge::Merger.new(@issue, [other])
    else
      RedmineIssueMerge::Merger.new(other, [@issue])
    end
  end

  def direction_param
    params[:direction] == 'into_this' ? 'into_this' : 'into_other'
  end

  def issue_id_param(value)
    id = value.to_s.strip.delete_prefix('#').to_i
    id.positive? ? id : nil
  end

  def find_issue
    @issue = Issue.visible.find_by(id: params[:issue_id])
    return render_404 unless @issue

    @project = @issue.project
  end

  def find_selected_issues
    ids = Array(params[:ids]).map(&:to_i).select(&:positive?).uniq
    @issues = Issue.visible.where(id: ids).includes(:project).order(:id).to_a
    return render_404 if ids.size < 2 || @issues.size != ids.size

    projects = @issues.map(&:project).uniq
    @project = projects.first if projects.one?
  end

  def authorize_merge
    projects = @issue ? [@issue.project] : @issues.map(&:project).uniq
    deny_access unless projects.all? { |project| User.current.allowed_to?(:merge_issues, project) }
  end
end
