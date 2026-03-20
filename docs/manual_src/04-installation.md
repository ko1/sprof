# Installation

## Requirements

Before installing sprof, ensure your environment meets these requirements:

| Requirement | Details |
|-------------|---------|
| **Ruby** | >= 4.0.0 (CRuby/MRI) |
| **OS** | Linux only |
| **C compiler** | gcc or clang (for building the C extension) |
| **pprof** (optional) | `go tool pprof` for viewing output |

> [!WARNING]
> sprof uses the Linux kernel ABI for per-thread CPU clocks. It will not compile or work on macOS, Windows, or other operating systems.

## Installing the Gem

```bash
gem install sprof
```

Or add it to your Gemfile:

```ruby
# Gemfile
gem "sprof", group: :development
```

Then run:

```bash
bundle install
```

## Building from Source

If you want to build sprof from the repository:

```bash
git clone https://github.com/ko1/sprof.git
cd sprof
rake compile
```

The `rake compile` command builds the C extension. If you encounter issues with ccache, try:

```bash
CCACHE_DISABLE=1 rake compile
```

## Verifying the Installation

```bash
ruby -e "require 'sprof'; puts Sprof::VERSION"
```

This should print the sprof version number.

## Installing pprof

To view sprof output, you need `go tool pprof`. This is included with any Go installation:

```bash
# Ubuntu/Debian
sudo apt install golang-go

# Or download from https://go.dev/dl/
```

Verify pprof is available:

```bash
go tool pprof -h
```

> [!TIP]
> If you don't want to install Go, you can use the standalone pprof tool:
> ```bash
> go install github.com/google/pprof@latest
> ```
> This installs the `pprof` binary to `$GOPATH/bin/`.
