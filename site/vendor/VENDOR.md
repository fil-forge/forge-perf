# Vendored libraries

The page draws its history chart with Observable Plot, which runs on d3. Both
are copied here unmodified from their npm packages, so the public page loads no
script from a third-party host and every change to them shows up in review.

The files are the packages' UMD builds, loaded with classic `<script>` tags in
this order: `d3.min.js` defines the global `d3`, then `plot.umd.min.js` reads it
and defines the global `Plot`. Plot 0.6.17 declares `d3@^7.9.0`, and its UMD
build names d3 7.9.0.

| Package | Version | License | Tarball | npm integrity |
|---|---|---|---|---|
| `d3` | 7.9.0 | ISC | https://registry.npmjs.org/d3/-/d3-7.9.0.tgz | `sha512-e1U46jVP+w7Iut8Jt8ri1YsPOvFpg46k+K8TpCb0P+zjCkjkPnV7WzfDJzMHy1LnA+wj5pLT1wjO901gLXeEhA==` |
| `@observablehq/plot` | 0.6.17 | ISC | https://registry.npmjs.org/@observablehq/plot/-/plot-0.6.17.tgz | `sha512-/qaXP/7mc4MUS0s4cPPFASDRjtsWp85/TbfsciqDgU1HwYixbSbbytNuInD8AcTYC3xaxACgVX06agdfQy9W+g==` |

## Files

`scripts/ci/check-vendor.sh` reads this table. Every file in this directory
other than `VENDOR.md` must have a row, and its SHA-256 must match.

| File | Package path | SHA-256 |
|---|---|---|
| `d3.min.js` | `d3/dist/d3.min.js` | `f2094bbf6141b359722c4fe454eb6c4b0f0e42cc10cc7af921fc158fceb86539` |
| `LICENSE.d3` | `d3/LICENSE` | `3e6849627f74ff73c257a3ae1efb574015d94fc1035c05ec3c15805165efcbc4` |
| `plot.umd.min.js` | `@observablehq/plot/dist/plot.umd.min.js` | `4358086467740777dd788d6b27a95cebdbaefdd50c730a3060117073bd7134cb` |
| `LICENSE.plot` | `@observablehq/plot/LICENSE` | `4b295e011e0e046170041b5b46f1349393aeceb95797793a55bd21dbb543363a` |

## Checking against the published packages

```sh
curl -fsSLO https://registry.npmjs.org/d3/-/d3-7.9.0.tgz
curl -fsSLO https://registry.npmjs.org/@observablehq/plot/-/plot-0.6.17.tgz
# Compare with the npm integrity column.
for f in d3-7.9.0.tgz plot-0.6.17.tgz; do
  echo "$f sha512-$(openssl dgst -sha512 -binary "$f" | base64)"
done
mkdir d3 plot
tar -xzf d3-7.9.0.tgz -C d3
tar -xzf plot-0.6.17.tgz -C plot
# Compare with the SHA-256 column.
shasum -a 256 d3/package/dist/d3.min.js d3/package/LICENSE \
  plot/package/dist/plot.umd.min.js plot/package/LICENSE
```

## Upgrading

Download the new tarballs, check their integrity against
`npm view <package>@<version> dist.integrity`, copy the same four files, and
update both tables. Keep d3 at the version Plot's UMD build names.
