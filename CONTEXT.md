# MoonBit Project Creation

The language used to describe creating MoonBit projects with moon-new.

## Language

**Default template**:
The starter project used when no template repository is selected.
_Avoid_: Hello template

**Template repository**:
A Git repository selected as the source for a new project.
_Avoid_: Template engine

**Template root**:
The directory within a template repository whose contents form the new project.
It may be the repository root or a selected subdirectory.
_Avoid_: Destination directory

**Template file**:
A file in a template repository whose contents are expanded to produce a project
file, rather than copied unchanged.
_Avoid_: Template repository

**Built-in variable**:
A named project value supplied by moon-new for use in template files and paths:
the username or the project's short name. Template authors do not define
additional variables.
_Avoid_: Custom template parameter

**Template configuration**:
The template author's rules for selecting which file contents are expanded and
which files or directories are omitted from the generated project.
_Avoid_: Module configuration

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
