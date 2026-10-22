defmodule Kith.DAV.AddressObject do
  @moduledoc "Atomic writes to account-scoped address objects."
  import Plug.Conn
  alias Kith.{Contacts, Repo}
  alias Kith.DAV.{Store, VCardAdapter, XMLBuilder}

  def put(conn, raw, body) do
    with {:ok, name} <- resource_name(raw),
         {:ok, [_card]} <- Kith.VCard.Parser.parse(body),
         {attrs, children} <-
           VCardAdapter.vcard_to_attrs(body, strip_nils: false, account_id: account_id(conn)) do
      write(conn, name, attrs, children, Kith.VCard.Extras.extract(body), true)
    else
      {:error, :name} -> send_resp(conn, 400, "Bad Request")
      _ -> invalid(conn)
    end
  end

  def valid_name?(raw), do: match?({:ok, _}, resource_name(raw))

  defp resource_name(raw) do
    name = URI.decode(raw)

    if String.valid?(name) and String.ends_with?(name, ".vcf") and
         name not in [".vcf", "..vcf"] and not String.contains?(name, ["/", "\\", "\0"]) and
         not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, raw) and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, name), do: {:ok, name}, else: {:error, :name}
  end

  defp write(conn, name, attrs, children, extras, retry?) do
    aid = account_id(conn)

    result =
      transaction(aid, fn ->
        Store.ensure_rows(aid)
        contact = locked(aid, name)

        cond do
          contact && hidden?(contact) ->
            Repo.rollback(:hidden)

          contact && not matches?(conn, contact) ->
            Repo.rollback(:precondition)

          is_nil(contact) && get_req_header(conn, "if-match") != [] ->
            Repo.rollback(:precondition)

          contact && children.uid && children.uid != contact.dav.uid ->
            Repo.rollback({:uid, Store.get_by_uid(aid, children.uid) || contact})

          true ->
            if is_nil(contact) && children.uid do
              if holder = Store.get_by_uid(aid, children.uid), do: Repo.rollback({:uid, holder})
            end

            {status, updated} =
              if contact do
                {204, unwrap(Contacts.update_contact(contact, attrs))}
              else
                created = unwrap(Contacts.create_contact(aid, attrs))
                Store.ensure_rows(aid)
                created = Repo.preload(created, :dav)

                unwrap(
                  Store.put_identity(created.dav, %{
                    uid: children.uid || created.dav.uid,
                    resource_name: name
                  })
                )

                {201, created}
              end

            unwrap(Contacts.replace_contact_children(updated, aid, children))
            updated = Repo.preload(updated, :dav, force: true)
            unwrap(Store.put_extras(updated.dav, extras))
            Store.touch(aid, [updated.id])
            status
        end
      end)

    case result do
      {:ok, status} ->
        send_resp(conn, status, "")

      {:error, %Ecto.Changeset{} = changeset} ->
        cond do
          Keyword.has_key?(changeset.errors, :uid) ->
            uid_conflict(conn, Store.get_by_uid(aid, children.uid))

          Keyword.has_key?(changeset.errors, :resource_name) && retry? ->
            write(conn, name, attrs, children, extras, false)

          true ->
            invalid(conn)
        end

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def delete(conn, raw) do
    with {:ok, name} <- resource_name(raw) do
      result =
        transaction(account_id(conn), fn ->
          Store.ensure_rows(account_id(conn))
          contact = locked(account_id(conn), name)

          cond do
            is_nil(contact) || hidden?(contact) ->
              Repo.rollback(:missing)

            not matches?(conn, contact) ->
              Repo.rollback(:precondition)

            true ->
              unwrap(Contacts.soft_delete_contact(contact))
              204
          end
        end)

      case result do
        {:ok, status} -> send_resp(conn, status, "")
        {:error, reason} -> error(conn, reason)
      end
    else
      _ -> send_resp(conn, 400, "Bad Request")
    end
  end

  defp transaction(aid, fun) do
    Store.transaction(aid, fun)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :deadlock_detected,
        do: {:error, :deadlock},
        else: reraise(e, __STACKTRACE__)
  end

  defp locked(aid, name) do
    case Store.get_by_resource_name(aid, name) do
      nil -> nil
      contact -> Store.lock(contact)
    end
  end

  defp matches?(conn, contact) do
    etag = "\"#{contact.dav.revision}\""
    matches = get_req_header(conn, "if-match")
    none = get_req_header(conn, "if-none-match")

    (matches == [] ||
       Enum.any?(matches, fn h ->
         String.trim(h) == "*" || etag in String.split(String.trim(h), ~r/\s*,\s*/)
       end)) &&
      not Enum.any?(none, fn h ->
        String.trim(h) == "*" ||
          Enum.any?(
            String.split(String.trim(h), ~r/\s*,\s*/),
            &(String.replace_prefix(&1, "W/", "") == etag)
          )
      end)
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
  defp hidden?(contact), do: contact.deleted_at != nil || contact.is_archived
  defp account_id(conn), do: conn.assigns.current_scope.account.id
  defp error(conn, :hidden), do: send_resp(conn, 409, "Conflict")
  defp error(conn, :missing), do: send_resp(conn, 404, "Not Found")
  defp error(conn, :precondition), do: send_resp(conn, 412, "Precondition Failed")

  defp error(conn, :deadlock),
    do: conn |> put_resp_header("retry-after", "1") |> send_resp(503, "Service Unavailable")

  defp error(conn, {:uid, holder}), do: uid_conflict(conn, holder)
  defp error(conn, _), do: invalid(conn)

  defp invalid(conn),
    do: xml(conn, 403, XMLBuilder.precondition_error("valid-address-data", "Invalid vCard data"))

  defp uid_conflict(conn, holder) do
    href = if holder, do: "<d:href>#{XMLBuilder.escape(Store.href(holder))}</d:href>", else: ""

    xml(
      conn,
      409,
      XMLBuilder.error_body(
        "<card:no-uid-conflict>#{href}</card:no-uid-conflict>",
        "UID conflict"
      )
    )
  end

  defp xml(conn, status, body),
    do: conn |> put_resp_content_type("application/xml") |> send_resp(status, body)
end
