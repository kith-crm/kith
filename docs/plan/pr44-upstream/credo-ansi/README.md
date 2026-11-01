# Credo ANSI upstream candidate

Bunt remains an unresolved maintenance blocker in Kith. This patch targets published Credo 1.7.19; it is **not adopted in Kith**, not published, and not a replacement release.

The candidate removes both the Bunt dependency and application startup entry. Existing terminal output uses Elixir's maintained IO.ANSI API, preserving the exact extended orange color (index 214), reset behavior, stdout/stderr, explicit no-color mode and output suppression. It introduces no Hex package. A fresh consumer resolves only FileSystem 1.1.1 and Jason 1.4.5, including Jason's absent optional Decimal edge. Upstream development/test dependencies are not consumer dependencies.

Run `./run.sh` to download the checksum-verified official archive, apply the patch, compile original and candidate in separate consumers, compare real JSON findings and blocking exit status, and check terminal byte parity against captured Bunt 1.0.0 output. The 2026-11-01 run on Darwin arm64, Elixir 1.19.5 / OTP 28.5.0.5 passed: two output tests (24 stdout/stderr comparisons), identical machine-readable findings and strict exit status 4. Both isolated audits pass. The intentionally bad source must generate a finding; empty JSON output fails the probe.

Remaining upstream gates: review supported older Elixir/OTP runtimes, upstream test suite, third-party Credo plugins/custom color uses, and Bunt `color_aliases` configuration consumers. The candidate preserves built-in styles used by Credo/Kith, not the entire Bunt extension API. A genuine maintained Credo release removing Bunt (or maintained Bunt release) is still required before Kith's policy can close. No upstream message or PR has been sent.
