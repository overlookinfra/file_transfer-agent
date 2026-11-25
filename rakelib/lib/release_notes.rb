# frozen_string_literal: true

# Reads the notes of one release from a CHANGELOG.md that
# github_changelog_generator wrote.
module ReleaseNotes
  # Returns the text between the heading of the version and the next
  # heading, or nil when no heading names the version or the section is blank.
  def self.extract(changelog, version)
    match = changelog.match(/^## \[#{Regexp.escape(version)}\][^\n]*\n(?<notes>.+?)(?=^## \[|\z)/m)
    return nil unless match
    notes = match[:notes].strip
    notes unless notes.empty?
  end
end
