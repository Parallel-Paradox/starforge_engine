# StarForge Engine

## Test

Run all test suites:

```sh
zig build test
```

Use `--summary all` suffix to get the detailed summary like count of passed/failed tests.

## Dependencies

Packages listed in `build.zig.zon` are fetched into `zig-pkg/` which Zig generates on demand.

`zig fetch` honors `http_proxy`/`https_proxy`, but not `no_proxy`. Some local
proxy setups (for example a Clash instance) break HTTP client of zig even though
`git` and `curl` work through the same proxy, and fetching fails with:

```
error: unable to discover remote git server capabilities: HttpConnectionClosing
```

In that case, bypass the proxy for the fetch when fetching or first building:

```sh
env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY zig build test
```

## AGENT

- Project skills live in `skills/`.
