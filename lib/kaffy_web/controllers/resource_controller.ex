defmodule KaffyWeb.ResourceController do
  @moduledoc false

  use Phoenix.Controller, namespace: KaffyWeb
  use Phoenix.HTML

  def index(conn, %{"context" => context, "resource" => resource}) do
    my_resource = Kaffy.Utils.get_resource(context, resource)

    case can_proceed?(my_resource, conn) do
      false ->
        unauthorized_access(conn)

      true ->
        fields = Kaffy.ResourceAdmin.index(my_resource)

        render(conn, "index.html",
          context: context,
          resource: resource,
          fields: fields,
          my_resource: my_resource
        )
    end
  end

  def show(conn, %{"context" => context, "resource" => resource, "id" => id}) do
    my_resource = Kaffy.Utils.get_resource(context, resource)
    schema = my_resource[:schema]
    resource_name = Kaffy.ResourceAdmin.singular_name(my_resource) |> String.capitalize()

    case can_proceed?(my_resource, conn) do
      false ->
        unauthorized_access(conn)

      true ->
        entry = Kaffy.ResourceQuery.fetch_resource(my_resource, id)
        changeset = Ecto.Changeset.change(entry)

        render(conn, "show.html",
          changeset: changeset,
          context: context,
          resource: resource,
          my_resource: my_resource,
          resource_name: resource_name,
          schema: schema,
          entry: entry
        )
    end
  end

  def update(conn, %{"context" => context, "resource" => resource, "id" => id} = params) do
    my_resource = Kaffy.Utils.get_resource(context, resource)
    schema = my_resource[:schema]
    params = Kaffy.Resource.decode_map_fields(resource, schema, params)

    resource_name = Kaffy.ResourceAdmin.singular_name(my_resource) |> String.capitalize()

    case can_proceed?(my_resource, conn) do
      false ->
        unauthorized_access(conn)

      true ->
        entry = Kaffy.ResourceQuery.fetch_resource(my_resource, id)
        changes = Map.get(params, resource, %{})

        result =
          Kaffy.ResourceAdmin.update_changeset(my_resource, entry, changes)
          |> Kaffy.Utils.repo().update()

        {conn, changeset} =
          case result do
            {:ok, entry} ->
              changeset = Ecto.Changeset.change(entry)
              conn = put_flash(conn, :info, "Saved #{resource} successfully")
              {conn, changeset}

            {:error, changeset} ->
              conn =
                put_flash(
                  conn,
                  :error,
                  "A problem occurred while trying to save this #{resource}"
                )

              {conn, changeset}
          end

        render(conn, "show.html",
          changeset: changeset,
          context: context,
          resource: resource,
          my_resource: my_resource,
          resource_name: resource_name,
          schema: schema,
          entry: entry
        )
    end
  end

  def new(conn, %{"context" => context, "resource" => resource}) do
    my_resource = Kaffy.Utils.get_resource(context, resource)

    case can_proceed?(my_resource, conn) do
      false ->
        unauthorized_access(conn)

      true ->
        changeset = Ecto.Changeset.change(my_resource[:schema].__struct__)

        render(conn, "new.html",
          changeset: changeset,
          context: context,
          resource: resource,
          my_resource: my_resource
        )
    end
  end

  def create(conn, %{"context" => context, "resource" => resource} = params) do
    changes = Map.get(params, resource, %{})
    my_resource = Kaffy.Utils.get_resource(context, resource)
    resource_name = Kaffy.ResourceAdmin.singular_name(my_resource)

    case can_proceed?(my_resource, conn) do
      false ->
        unauthorized_access(conn)

      true ->
        changeset = Kaffy.ResourceAdmin.create_changeset(my_resource, changes)

        case Kaffy.Utils.repo().insert(changeset) do
          {:ok, entry} ->
            redirect_to =
              case Map.get(params, "submit") do
                "Save" ->
                  Kaffy.Utils.router().kaffy_resource_path(
                    conn,
                    :show,
                    context,
                    resource,
                    entry.id
                  )

                _ ->
                  Kaffy.Utils.router().kaffy_resource_path(conn, :new, context, resource)
              end

            put_flash(conn, :info, "Created a new #{resource_name} successfully")
            |> redirect(to: redirect_to)

          {:error, changeset} ->
            render(conn, "new.html",
              changeset: changeset,
              context: context,
              resource: resource,
              my_resource: my_resource
            )
        end
    end
  end

  def api(conn, %{"context" => context, "resource" => resource} = params) do
    my_resource = Kaffy.Utils.get_resource(context, resource)
    fields = Kaffy.ResourceAdmin.index(my_resource)
    {filtered_count, entries} = Kaffy.ResourceQuery.list_resource(my_resource, params)

    records =
      Enum.map(entries, fn entry ->
        rows =
          Enum.reduce(fields, [], fn field, e ->
            [Kaffy.Resource.kaffy_field_value(entry, field) | e]
          end)
          |> Enum.reverse()

        [first | rest] = rows

        {:safe, first} =
          link(first,
            to: Kaffy.Utils.router().kaffy_resource_path(conn, :show, context, resource, entry.id)
          )

        first = to_string(first)

        [first | rest]
      end)

    total_count = Kaffy.ResourceQuery.total_count(my_resource)

    final_result = %{
      raw: Map.get(params, "raw", "0") |> String.to_integer(),
      recordsTotal: total_count,
      recordsFiltered: filtered_count,
      data: records
    }

    json(conn, final_result)
  end

  defp can_proceed?(resource, conn) do
    Kaffy.ResourceAdmin.authorized?(resource, conn)
  end

  defp unauthorized_access(conn) do
    conn
    |> put_flash(:error, "You are not authorized to access that page")
    |> redirect(to: Kaffy.Utils.router().kaffy_home_path(conn, :index))
  end
end
