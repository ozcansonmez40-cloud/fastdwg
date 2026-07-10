# LibreDWG (vendored source, not tracked in this repo)

FastDWG's native parser links **LibreDWG 0.14** (GPLv3). The source tree lives
at `third_party/libredwg/source/` but is **not committed** here — it is the
upstream release checkout plus one local build patch.

## Reproducing `source/`

```sh
git clone https://github.com/LibreDWG/libredwg third_party/libredwg/source
cd third_party/libredwg/source
git checkout 0.14        # commit d9468ae, "Release 0.14"
git apply ../patches/0001-cmake-strip-so-version-whitespace.patch
```

The single patch fixes CMake on Windows hosts: `get-so-version.pl` output has a
trailing newline that corrupts the generated SO version string
(`OUTPUT_STRIP_TRAILING_WHITESPACE`).

## License obligations

LibreDWG is GPLv3. Because FastDWG statically links it, any distributed FastDWG
binary must be accompanied by complete corresponding source (this repo + the
instructions above satisfy that) and the combined work must be licensed
GPLv3-compatible. See `NOTICE.md` at the repo root.

Official project:

- https://www.gnu.org/software/libredwg/
- https://www.gnu.org/software/libredwg/manual/
