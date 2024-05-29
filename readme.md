# zquickjs

[![zquickjs - Docs](https://img.shields.io/badge/zquickjs-Docs-2ea44f)](https://eknkc.github.io/zquickjs/)

A Zig binding for [QuickJS](https://bellard.org/quickjs/).
This is **work in progress** and not ready for production use.

## Installation

```sh
zig fetch --save https://github.com/eknkc/zquickjs/archive/refs/heads/master.tar.gz
```

Add the following to your `build.zig`:

```zig
const zquickjs = b.dependency("zquickjs", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zquickjs", zquickjs.module("zquickjs"));
```

## License

MIT
