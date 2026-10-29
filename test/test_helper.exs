# Test tag conventions:
#   @tag :integration  — tests that touch the database (most tests, given Ecto sandbox)
#   @tag :external     — tests that hit real external APIs (Immich, LocationIQ).
#                        Skipped unless EXTERNAL_TESTS=true.
#   @tag :slow         — performance tests with large datasets. Run with: mix test --only slow
ExUnit.start(exclude: [:external, :slow])
Ecto.Adapters.SQL.Sandbox.mode(Kith.Repo, :manual)
