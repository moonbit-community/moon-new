# MoonBit Project Creation

The language used to describe creating MoonBit projects with moon-new.

## Language

**Default template**:
The starter project used when no template repository is selected.
_Avoid_: Hello template

**Template repository**:
A Git repository selected as the source for a new project.
_Avoid_: Template engine

**Destination directory**:
The filesystem location where the new project is created.
_Avoid_: Module name

**Empty destination**:
An existing destination directory with no entries, including hidden entries.
A directory containing only `.git` is not empty.
_Avoid_: Directory without conflicting files

**Module name**:
The MoonBit module identity, such as `Milky2018/hello`, distinct from the
destination directory's name.
_Avoid_: Directory name
