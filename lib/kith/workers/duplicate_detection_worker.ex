defmodule Kith.Workers.DuplicateDetectionWorker do
  @moduledoc """
  Oban worker that detects potential duplicate contacts within an account.
  Runs weekly via cron or can be triggered manually per-account.

  Detection algorithm:
  1. Name similarity via pg_trgm similarity() on display_name (threshold: 0.5)
  2. Case-insensitive email match across contact_fields
  3. Normalized phone match across contact_fields (digits only)
  4. Address match on line1 + postal_code

  Scoring (max-signal + bonus):
    Each signal has an independent base score:
      - email_match:   0.85
      - phone_match:   0.75
      - address_match: 0.60
      - name_match:    the raw pg_trgm similarity (> 0.5)
    Final score = max(base scores) + 0.05 per additional signal, capped at 1.0
    Threshold: >= 0.5
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  import Ecto.Query
  alias Kith.Contacts.{Address, Contact, ContactField, ContactFieldType, DuplicateCandidate}
  alias Kith.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    detect_duplicates(account_id)
    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    # Run for all accounts when triggered by cron (no account_id)
    account_ids =
      from(a in Kith.Accounts.Account, select: a.id)
      |> Repo.all()

    Enum.each(account_ids, &detect_duplicates/1)
    :ok
  end

  defp detect_duplicates(account_id) do
    contact_count =
      Contact
      |> where([c], c.account_id == ^account_id)
      |> where([c], is_nil(c.deleted_at))
      |> Repo.aggregate(:count)

    if contact_count >= 2, do: find_duplicates(account_id)
  end

  defp find_duplicates(account_id) do
    name_matches = find_name_matches(account_id)
    email_matches = find_email_matches(account_id)
    phone_matches = find_phone_matches(account_id)
    address_matches = find_address_matches(account_id)

    all_pairs =
      merge_matches(name_matches, email_matches, phone_matches, address_matches)
      |> Enum.filter(fn {_pair, score, _reasons} -> score >= 0.5 end)

    existing =
      DuplicateCandidate
      |> where([d], d.account_id == ^account_id)
      |> where([d], d.status in ["pending", "dismissed"])
      |> select([d], {d.contact_id, d.duplicate_contact_id})
      |> Repo.all()
      |> MapSet.new()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(all_pairs, fn {{id1, id2}, score, reasons} ->
      {contact_id, dup_id} = if id1 < id2, do: {id1, id2}, else: {id2, id1}

      unless MapSet.member?(existing, {contact_id, dup_id}) do
        %DuplicateCandidate{account_id: account_id}
        |> DuplicateCandidate.changeset(%{
          contact_id: contact_id,
          duplicate_contact_id: dup_id,
          score: score,
          reasons: reasons,
          detected_at: now
        })
        |> Repo.insert(on_conflict: :nothing)
      end
    end)
  end

  defp find_name_matches(account_id) do
    query = """
    SELECT c1.id AS id1, c2.id AS id2, similarity(c1.display_name, c2.display_name) AS sim
    FROM contacts c1
    JOIN contacts c2 ON c1.id < c2.id
      AND c1.account_id = c2.account_id
    WHERE c1.account_id = $1
      AND c1.deleted_at IS NULL
      AND c2.deleted_at IS NULL
      AND c1.display_name IS NOT NULL AND c1.display_name != ''
      AND c2.display_name IS NOT NULL AND c2.display_name != ''
      AND similarity(c1.display_name, c2.display_name) > 0.5
    ORDER BY sim DESC
    LIMIT 500
    """

    case Repo.query(query, [account_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id1, id2, sim] ->
          {{id1, id2}, sim, ["name_match"]}
        end)

      _ ->
        []
    end
  end

  defp find_email_matches(account_id) do
    # Case-insensitive email match on TRIMmed values. Trim is required because
    # CardDAV-style imports occasionally leak trailing whitespace; the != ''
    # checks on the trimmed form prevent whitespace-only values from forming a
    # cartesian product across all such rows.
    query =
      from cf1 in ContactField,
        join: cf2 in ContactField,
        on:
          fragment("LOWER(TRIM(?))", cf1.value) == fragment("LOWER(TRIM(?))", cf2.value) and
            cf1.id < cf2.id,
        join: cft1 in ContactFieldType,
        on: cf1.contact_field_type_id == cft1.id,
        join: cft2 in ContactFieldType,
        on: cf2.contact_field_type_id == cft2.id,
        where: cf1.account_id == ^account_id,
        where: cf2.account_id == ^account_id,
        where: fragment("? LIKE 'mailto%'", cft1.protocol),
        where: fragment("? LIKE 'mailto%'", cft2.protocol),
        where: cf1.contact_id != cf2.contact_id,
        where: not is_nil(cf1.value) and fragment("TRIM(?) <> ''", cf1.value),
        where: not is_nil(cf2.value) and fragment("TRIM(?) <> ''", cf2.value),
        select: {cf1.contact_id, cf2.contact_id}

    query
    |> Repo.all()
    |> Enum.map(fn {id1, id2} ->
      if id1 < id2, do: {id1, id2}, else: {id2, id1}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {id1, id2} -> {{id1, id2}, 1.0, ["email_match"]} end)
  end

  defp find_phone_matches(account_id) do
    # Phone values are normalized to E.164 on import (see
    # `Kith.Contacts.PhoneFormatter.normalize/2`), so this becomes a plain
    # equality join. The previous in-query regex normalization combined with a
    # raw-value `!= ""` filter let formatting-only inputs (`+`, `()`, `-`)
    # collapse to an empty string and cartesian-explode (see Bug A).
    query =
      from cf1 in ContactField,
        join: cf2 in ContactField,
        on: cf1.value == cf2.value and cf1.id < cf2.id,
        join: cft1 in ContactFieldType,
        on: cf1.contact_field_type_id == cft1.id,
        join: cft2 in ContactFieldType,
        on: cf2.contact_field_type_id == cft2.id,
        where: cf1.account_id == ^account_id,
        where: cf2.account_id == ^account_id,
        where: fragment("? LIKE 'tel%'", cft1.protocol),
        where: fragment("? LIKE 'tel%'", cft2.protocol),
        where: cf1.contact_id != cf2.contact_id,
        where: not is_nil(cf1.value) and fragment("TRIM(?) <> ''", cf1.value),
        where: not is_nil(cf2.value) and fragment("TRIM(?) <> ''", cf2.value),
        select: {cf1.contact_id, cf2.contact_id}

    query
    |> Repo.all()
    |> Enum.map(fn {id1, id2} ->
      if id1 < id2, do: {id1, id2}, else: {id2, id1}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {id1, id2} -> {{id1, id2}, 1.0, ["phone_match"]} end)
  end

  defp find_address_matches(account_id) do
    # Match on normalized line1 + postal_code
    query =
      from a1 in Address,
        join: a2 in Address,
        on:
          fragment("LOWER(TRIM(?))", a1.line1) == fragment("LOWER(TRIM(?))", a2.line1) and
            fragment("LOWER(TRIM(?))", a1.postal_code) ==
              fragment("LOWER(TRIM(?))", a2.postal_code) and
            a1.id < a2.id,
        where: a1.account_id == ^account_id,
        where: a2.account_id == ^account_id,
        where: a1.contact_id != a2.contact_id,
        where: a1.line1 != "" and not is_nil(a1.line1),
        where: a1.postal_code != "" and not is_nil(a1.postal_code),
        where: a2.line1 != "" and not is_nil(a2.line1),
        where: a2.postal_code != "" and not is_nil(a2.postal_code),
        select: {a1.contact_id, a2.contact_id}

    query
    |> Repo.all()
    |> Enum.map(fn {id1, id2} ->
      if id1 < id2, do: {id1, id2}, else: {id2, id1}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {id1, id2} -> {{id1, id2}, 1.0, ["address_match"]} end)
  end

  defp merge_matches(name_matches, email_matches, phone_matches, address_matches) do
    (name_matches ++ email_matches ++ phone_matches ++ address_matches)
    |> Enum.group_by(fn {pair, _score, _reasons} -> pair end)
    |> Enum.map(&compute_merged_score/1)
  end

  defp compute_merged_score({pair, matches}) do
    reasons = matches |> Enum.flat_map(fn {_, _, r} -> r end) |> Enum.uniq()
    name_sim = Enum.find_value(matches, 0.0, &extract_name_score/1)

    # Base score for each signal type
    base_scores =
      []
      |> then(fn acc -> if "email_match" in reasons, do: [0.85 | acc], else: acc end)
      |> then(fn acc -> if "phone_match" in reasons, do: [0.75 | acc], else: acc end)
      |> then(fn acc -> if "address_match" in reasons, do: [0.60 | acc], else: acc end)
      |> then(fn acc -> if name_sim > 0.0, do: [name_sim | acc], else: acc end)

    signal_count = length(base_scores)
    max_score = Enum.max(base_scores, fn -> 0.0 end)
    bonus = max(signal_count - 1, 0) * 0.05

    score = min(max_score + bonus, 1.0)

    {pair, Float.round(score, 2), reasons}
  end

  defp extract_name_score({_, score, reasons}) do
    if "name_match" in reasons, do: score
  end
end
