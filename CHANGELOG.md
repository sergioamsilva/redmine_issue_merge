# Changelog

## 1.0.0 — 2026-11-09

First release. Rewrite of [redmine_merge_issues](https://github.com/EnhydraV/redmine_merge_issues) 0.0.4
with these differences:

- **Subtasks move through the core** (`parent_issue_id` + `save`), so `lft`/`rgt`/`root_id` stay valid.
  Moving them with `update_columns(parent_id:)` left a corrupt nested set.
- **Time entries take the destination project**, not only the destination issue.
- **Relations are recreated with the core validations**: cycles, descendants and the cross-project setting
  are checked, following issues are rescheduled, and anything that cannot move is listed in the merge note.
- **Close or delete**: by default the merged issue is closed as a duplicate (its URL keeps working); deletion
  is a setting and then requires the `delete_issues` permission as well.
- **Preview before merging**, with the counts of everything that will move and every problem found.
- **One transaction**: a failure at any step changes nothing.
- **One notification** for the kept issue (optional); none for moved notes, subtasks or the closed issue.
- Empty custom fields of the kept issue are filled from the merged one; restricted fields only go to a
  private note.
- Author and assignee of the merged issue become watchers of the kept one.
- Checklist items of the RedmineUP checklists plugin move too, in order.
- Optional protection: issues matching a regular expression (for example issues kept in sync with another
  system) cannot be merged.
- Hook `model_issue_merge_before_source_removal` for other plugins.
- Visible-issue scoping everywhere; locales en, pt, pt-BR, fr; unit and functional tests on Redmine 6.1
  and 7.0.
