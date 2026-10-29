# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent — safe to run multiple times. Uses ON CONFLICT DO NOTHING.

alias Kith.Repo

now = DateTime.utc_now(:second)

# ── Helper ──────────────────────────────────────────────────────────────
defmodule Seeds do
  def insert_all(repo, table, rows, conflict_target, now) do
    entries =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        row
        |> Map.put(:position, Map.get(row, :position, idx))
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    repo.insert_all(table, entries, on_conflict: :nothing, conflict_target: conflict_target)
  end
end

# ── Currencies (top 30 ISO 4217) ────────────────────────────────────────
currencies = [
  %{code: "USD", name: "US Dollar", symbol: "$"},
  %{code: "EUR", name: "Euro", symbol: "€"},
  %{code: "GBP", name: "British Pound", symbol: "£"},
  %{code: "JPY", name: "Japanese Yen", symbol: "¥"},
  %{code: "CAD", name: "Canadian Dollar", symbol: "CA$"},
  %{code: "AUD", name: "Australian Dollar", symbol: "A$"},
  %{code: "CHF", name: "Swiss Franc", symbol: "CHF"},
  %{code: "CNY", name: "Chinese Yuan", symbol: "¥"},
  %{code: "INR", name: "Indian Rupee", symbol: "₹"},
  %{code: "BRL", name: "Brazilian Real", symbol: "R$"},
  %{code: "KRW", name: "South Korean Won", symbol: "₩"},
  %{code: "MXN", name: "Mexican Peso", symbol: "MX$"},
  %{code: "SGD", name: "Singapore Dollar", symbol: "S$"},
  %{code: "HKD", name: "Hong Kong Dollar", symbol: "HK$"},
  %{code: "NOK", name: "Norwegian Krone", symbol: "kr"},
  %{code: "SEK", name: "Swedish Krona", symbol: "kr"},
  %{code: "DKK", name: "Danish Krone", symbol: "kr"},
  %{code: "NZD", name: "New Zealand Dollar", symbol: "NZ$"},
  %{code: "ZAR", name: "South African Rand", symbol: "R"},
  %{code: "RUB", name: "Russian Ruble", symbol: "₽"},
  %{code: "TRY", name: "Turkish Lira", symbol: "₺"},
  %{code: "PLN", name: "Polish Zloty", symbol: "zł"},
  %{code: "THB", name: "Thai Baht", symbol: "฿"},
  %{code: "IDR", name: "Indonesian Rupiah", symbol: "Rp"},
  %{code: "CZK", name: "Czech Koruna", symbol: "Kč"},
  %{code: "ILS", name: "Israeli Shekel", symbol: "₪"},
  %{code: "PHP", name: "Philippine Peso", symbol: "₱"},
  %{code: "TWD", name: "Taiwan Dollar", symbol: "NT$"},
  %{code: "ARS", name: "Argentine Peso", symbol: "AR$"},
  %{code: "CLP", name: "Chilean Peso", symbol: "CL$"}
]

currency_entries =
  Enum.map(currencies, fn c ->
    Map.merge(c, %{inserted_at: now, updated_at: now})
  end)

Repo.insert_all("currencies", currency_entries, on_conflict: :nothing, conflict_target: [:code])

# ── Genders (global, account_id = NULL) ─────────────────────────────────
genders =
  ~w(Male Female Non-binary Other)
  |> Enum.with_index()
  |> Enum.map(fn {name, pos} ->
    %{name: name, account_id: nil, position: pos, inserted_at: now, updated_at: now}
  end)

Repo.insert_all("genders", genders, on_conflict: :nothing)

# ── Emotions (global, account_id = NULL) ────────────────────────────────
emotions =
  ~w(Happy Grateful Relaxed Content Excited Proud Amused Hopeful
     Neutral Surprised Confused Anxious Sad Angry Frustrated
     Disappointed Lonely Stressed Guilty Jealous)
  |> Enum.with_index()
  |> Enum.map(fn {name, pos} ->
    %{name: name, account_id: nil, position: pos, inserted_at: now, updated_at: now}
  end)

Repo.insert_all("emotions", emotions, on_conflict: :nothing)

# ── Activity Type Categories (global, account_id = NULL) ────────────────
activity_types = [
  %{name: "Ate out", icon: "utensils"},
  %{name: "Went to a movie", icon: "film"},
  %{name: "Went for a walk", icon: "footprints"},
  %{name: "Went to a concert", icon: "music"},
  %{name: "Played a sport", icon: "trophy"},
  %{name: "Had a drink", icon: "wine"},
  %{name: "Had coffee", icon: "coffee"},
  %{name: "Cooked together", icon: "chef-hat"},
  %{name: "Traveled together", icon: "plane"},
  %{name: "Video call", icon: "video"},
  %{name: "Gift exchange", icon: "gift"},
  %{name: "Other", icon: "ellipsis"}
]

activity_type_entries =
  activity_types
  |> Enum.with_index()
  |> Enum.map(fn {row, pos} ->
    Map.merge(row, %{account_id: nil, position: pos, inserted_at: now, updated_at: now})
  end)

Repo.insert_all("activity_type_categories", activity_type_entries, on_conflict: :nothing)

# ── Life Event Types (global, account_id = NULL) ───────────────────────
life_event_types = [
  # Career
  %{name: "New job", icon: "briefcase", category: "Career"},
  %{name: "Promotion", icon: "trending-up", category: "Career"},
  %{name: "Retirement", icon: "sunset", category: "Career"},
  # Education
  %{name: "Graduation", icon: "graduation-cap", category: "Education"},
  %{name: "Started school", icon: "book-open", category: "Education"},
  # Family
  %{name: "Birth of a child", icon: "baby", category: "Family"},
  %{name: "Engagement", icon: "ring", category: "Family"},
  %{name: "Marriage", icon: "heart", category: "Family"},
  %{name: "Divorce", icon: "heart-crack", category: "Family"},
  %{name: "Death of a loved one", icon: "flower-2", category: "Family"},
  %{name: "Adoption", icon: "hand-heart", category: "Family"},
  # Health
  %{name: "Surgery", icon: "stethoscope", category: "Health"},
  %{name: "Diagnosis", icon: "clipboard", category: "Health"},
  %{name: "Recovery", icon: "heart-pulse", category: "Health"},
  # Home
  %{name: "Moved", icon: "home", category: "Home"},
  %{name: "Bought a house", icon: "key", category: "Home"},
  # Travel
  %{name: "Trip", icon: "map-pin", category: "Travel"},
  %{name: "Moved abroad", icon: "globe", category: "Travel"},
  # Other
  %{name: "Other", icon: "star", category: "Other"}
]

life_event_entries =
  life_event_types
  |> Enum.with_index()
  |> Enum.map(fn {row, pos} ->
    Map.merge(row, %{account_id: nil, position: pos, inserted_at: now, updated_at: now})
  end)

Repo.insert_all("life_event_types", life_event_entries, on_conflict: :nothing)

# ── Contact Field Types (global, account_id = NULL) ─────────────────────
contact_field_types =
  Kith.DAV.FieldRegistry.definitions() ++
    [
      %{name: "Twitter", protocol: "https://twitter.com/", icon: "twitter", vcard_label: nil},
      %{name: "Facebook", protocol: "https://facebook.com/", icon: "facebook", vcard_label: nil},
      %{
        name: "LinkedIn",
        protocol: "https://linkedin.com/in/",
        icon: "linkedin",
        vcard_label: nil
      },
      %{
        name: "Instagram",
        protocol: "https://instagram.com/",
        icon: "instagram",
        vcard_label: nil
      },
      %{name: "Telegram", protocol: "https://t.me/", icon: "send", vcard_label: nil},
      %{name: "WhatsApp", protocol: "https://wa.me/", icon: "message-circle", vcard_label: nil}
    ]

cft_entries =
  contact_field_types
  |> Enum.with_index()
  |> Enum.map(fn {row, pos} ->
    Map.merge(%{system_key: nil}, row)
    |> Map.merge(%{account_id: nil, position: pos, inserted_at: now, updated_at: now})
  end)

Repo.insert_all("contact_field_types", cft_entries, on_conflict: :nothing)

# ── Relationship Types (global, account_id = NULL) ──────────────────────
relationship_types = [
  %{system_key: "partner", name: "Partner", reverse_name: "Partner", is_bidirectional: true},
  %{system_key: "spouse", name: "Spouse", reverse_name: "Spouse", is_bidirectional: true},
  %{system_key: "friend", name: "Friend", reverse_name: "Friend", is_bidirectional: true},
  %{
    system_key: "best_friend",
    name: "Best friend",
    reverse_name: "Best friend",
    is_bidirectional: true
  },
  %{system_key: "parent", name: "Parent", reverse_name: "Child", is_bidirectional: false},
  %{system_key: "child", name: "Child", reverse_name: "Parent", is_bidirectional: false},
  %{system_key: "sibling", name: "Sibling", reverse_name: "Sibling", is_bidirectional: true},
  %{
    system_key: "grandparent",
    name: "Grandparent",
    reverse_name: "Grandchild",
    is_bidirectional: false
  },
  %{
    system_key: "grandchild",
    name: "Grandchild",
    reverse_name: "Grandparent",
    is_bidirectional: false
  },
  %{
    system_key: "uncle_aunt",
    name: "Uncle/Aunt",
    reverse_name: "Nephew/Niece",
    is_bidirectional: false
  },
  %{
    system_key: "nephew_niece",
    name: "Nephew/Niece",
    reverse_name: "Uncle/Aunt",
    is_bidirectional: false
  },
  %{system_key: "cousin", name: "Cousin", reverse_name: "Cousin", is_bidirectional: true},
  %{
    system_key: "colleague",
    name: "Colleague",
    reverse_name: "Colleague",
    is_bidirectional: true
  },
  %{system_key: "boss", name: "Boss", reverse_name: "Subordinate", is_bidirectional: false},
  %{
    system_key: "subordinate",
    name: "Subordinate",
    reverse_name: "Boss",
    is_bidirectional: false
  },
  %{system_key: "mentor", name: "Mentor", reverse_name: "Mentee", is_bidirectional: false},
  %{system_key: "mentee", name: "Mentee", reverse_name: "Mentor", is_bidirectional: false},
  %{system_key: "neighbor", name: "Neighbor", reverse_name: "Neighbor", is_bidirectional: true},
  %{system_key: "roommate", name: "Roommate", reverse_name: "Roommate", is_bidirectional: true},
  %{
    system_key: "ex_partner",
    name: "Ex-partner",
    reverse_name: "Ex-partner",
    is_bidirectional: true
  },
  %{system_key: "contact", name: "Contact", reverse_name: "Contact", is_bidirectional: true}
]

rt_entries =
  relationship_types
  |> Enum.with_index()
  |> Enum.map(fn {row, pos} ->
    Map.merge(row, %{account_id: nil, position: pos, inserted_at: now, updated_at: now})
  end)

Repo.insert_all("relationship_types", rt_entries, on_conflict: :nothing)

# ── Call Directions (global) ──────────────────────────────────────────
call_directions =
  ~w(Inbound Outbound Missed)
  |> Enum.with_index()
  |> Enum.map(fn {name, pos} ->
    %{name: name, position: pos, inserted_at: now, updated_at: now}
  end)

Repo.insert_all("call_directions", call_directions,
  on_conflict: :nothing,
  conflict_target: [:name]
)

IO.puts("Seeds loaded successfully!")
