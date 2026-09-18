# Require a nonexistent or empty destination

Project creation accepts only a nonexistent destination or an existing directory
with no entries, including hidden entries. Unlike the official `moon new`, it
does not merge generated files into a populated directory, even when there are
no filename collisions. This gives creation a clear boundary and makes restoring
the original absent or empty destination straightforward after a handled failure.
The trade-off is that directories containing `.git` or unrelated files are rejected;
users must choose an empty directory, which may still be inside a parent Git
working tree.
