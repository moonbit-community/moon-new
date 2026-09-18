# moon-new

A MoonBit project generator intended to eventually replace the official
`moon new` command, with support for creating projects from Git repositories
through a `--template` option.

The project is in its initial setup stage. Project generation and `--template`
are not implemented yet.

## Development

Install the [MoonBit toolchain](https://www.moonbitlang.com/download/), then run:

```sh
moon check
moon test
moon run cmd/main
```

Before committing, update generated interfaces and format the project:

```sh
moon info && moon fmt
```

An optional pre-commit hook is available in [.githooks](.githooks/README.md).

## License

[Apache-2.0](LICENSE)
