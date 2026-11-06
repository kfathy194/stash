# Stash glossary

| Term | Meaning |
|---|---|
| Clip item | A captured or manually created content record with metadata and optional binary representations. |
| History | The private chronological view of items whose isInHistory flag is true. |
| Pinboard | A named colored collection; an item belongs to at most one pinboard. |
| Paste Stack | Temporary ordered queue of item identifiers consumed by successive paste actions. |
| Shared graph | Separate board/item records reachable by CKShare; it excludes private history relationships. |
| Device consent | Local opt-in for iCloud, MCP or Suggestions; never enabled by cloud preferences. |
| Acceptance gate | A required real-world validation, distinct from successful compilation or unit tests. |

## Authored content

**Item format**:
A clip item's chosen text-editing mode: Plain Text, Rich Text or Code with one selected language.
_Avoid_: File extension, paste destination format

**Code item**:
A clip item containing source text with one selected language, such as CSS, HTML or PHP.
_Avoid_: Rich-text document, code block

## Attachments

**Saved attachment**:
A file whose contents are preserved as part of a clip item. Its saved contents are independent of changes to the original file.
_Avoid_: External file reference, live file

**Managed file copy**:
A local working copy of a saved attachment that belongs to Stash. It can be recreated from the attachment's saved contents.
_Avoid_: Original file, external file reference

**External file reference**:
A clip item's reference to an original file outside Stash's ownership. The referenced file remains owned by its user and can change independently of the clip item.
_Avoid_: Saved attachment, managed file copy
