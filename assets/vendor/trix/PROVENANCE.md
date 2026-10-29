Trix 2.1.19 source, unchanged from the upstream tag archive:
https://codeload.github.com/basecamp/trix/tar.gz/refs/tags/v2.1.19
Archive SHA-256: 896c510cb1f44fd1ab9e40d2e1c7275270aaeb807310b4c74dbf5bdf65100b6c

Only src/trix/, package.json, and LICENSE are retained. Esbuild resolves
trix/* to this source via config/config.exs. Its `import DOMPurify from
"dompurify"` resolves the separate, integrity-locked assets npm package 3.4.17.
The npm Trix distribution is retained for CSS, but its prebundled JavaScript
(with DOMPurify 3.4.2) is never imported. No generated Trix bundle is patched.

To refresh: verify a new upstream archive, replace these unmodified files,
update this provenance, rebuild assets, inspect the generated sanitizer version,
and run editor paste/drop and server sanitation regressions. npm ci alone does
not guarantee the sanitizer embedded in upstream distributed JavaScript is safe.
