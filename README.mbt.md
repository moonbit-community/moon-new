# MoonBit tools

MoonBit implementations of tools currently written in Rust. Each tool is an independently versioned and published module in this workspace.

## Modules

- [moon-new](moon-new/README.mbt.md): create a MoonBit project from the bundled hello starter or a Git repository.

## Development

Run workspace checks from the repository root:

```sh
moon check --deny-warn
moon build
moon test
moon info
moon fmt
```

Package and publish individual modules:

```sh
moon -C moon-new package
moon -C moon-new publish
```
