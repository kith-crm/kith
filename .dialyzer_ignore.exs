# Suppress dialyzer warnings produced by generated code in third-party
# libraries. Re-evaluate this list whenever we upgrade deps.

[
  # ex_cldr_territories generates type specs that are slightly broader than
  # the success typing for these zero-arg accessors on Kith.Cldr.Territory.
  # Reported as `:contract_supertype` against lib/kith/cldr.ex (the backend
  # module that injects the provider). Not actionable from our code.
  {"lib/kith/cldr.ex", :contract_supertype}
]
