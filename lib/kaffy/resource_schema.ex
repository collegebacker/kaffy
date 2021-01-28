defmodule Kaffy.ResourceSchema do
  @moduledoc false

  def primary_key(schema) do
    schema.__schema__(:primary_key)
  end

  def excluded_fields(schema) do
    {pk, _, _} = schema.__schema__(:autogenerate_id)
    autogenerated = schema.__schema__(:autogenerate)

    case length(autogenerated) do
      1 ->
        [{auto_fields, _}] = autogenerated
        [pk] ++ auto_fields

      _ ->
        [pk]
    end
  end

  def index_fields(schema) do
    Keyword.drop(fields(schema), fields_to_be_removed(schema))
  end

  def form_fields(schema) do
    to_be_removed = fields_to_be_removed(schema) ++ [:id, :inserted_at, :updated_at]
    Keyword.drop(fields(schema), to_be_removed)
  end

  def cast_fields(schema) do
    to_be_removed =
      fields_to_be_removed(schema) ++
        get_has_many_associations(schema) ++
        get_has_one_assocations(schema) ++
        get_many_to_many_associations(schema) ++ [:id, :inserted_at, :updated_at]

    Keyword.drop(fields(schema), to_be_removed)
  end

  def fields(schema) do
    schema
    |> get_all_fields()
    |> reorder_fields(schema)
  end

  defp get_all_fields(schema) do
    schema.__changeset__()
    |> Enum.map(fn {k, _} -> {k, default_field_options(schema, k)} end)
  end

  def default_field_options(schema, field) do
    type = field_type(schema, field)
    label = Kaffy.ResourceForm.form_label_string(field)
    merge_field_options(%{label: label, type: type})
  end

  def merge_field_options(options) do
    default = %{
      create: :editable,
      update: :editable,
      label: nil,
      type: nil,
      choices: nil
    }

    Map.merge(default, options || %{})
  end

  defp fields_to_be_removed(schema) do
    # if schema defines belongs_to associations, remove assoc fields and keep their actual *_id fields.
    schema.__changeset__()
    |> Enum.reduce([], fn {field, type}, all ->
      case type do
        {:assoc, %Ecto.Association.BelongsTo{}} ->
          [field | all]

        {:assoc, %Ecto.Association.Has{cardinality: :many}} ->
          [field | all]

        {:assoc, %Ecto.Association.Has{cardinality: :one}} ->
          [field | all]

        _ ->
          all
      end
    end)
  end

  defp reorder_fields(fields_list, schema) do
    [_id, first_field | _fields] = schema.__schema__(:fields)

    # this is a "nice" feature to re-order the default fields to put the specified fields at the top/bottom of the form
    fields_list
    |> reorder_field(first_field, :first)
    |> reorder_field(:email, :first)
    |> reorder_field(:name, :first)
    |> reorder_field(:title, :first)
    |> reorder_field(:id, :first)
    |> reorder_field(:inserted_at, :last)
    |> reorder_field(:updated_at, :last)

    # |> reorder_field(Kaffy.ResourceSchema.embeds(schema), :last)
  end

  defp reorder_field(fields_list, [], _), do: fields_list

  defp reorder_field(fields_list, [field | rest], position) do
    fields_list = reorder_field(fields_list, field, position)
    reorder_field(fields_list, rest, position)
  end

  defp reorder_field(fields_list, field_name, position) do
    if field_name in Keyword.keys(fields_list) do
      {field_options, fields_list} = Keyword.pop(fields_list, field_name)

      case position do
        :first -> [{field_name, field_options}] ++ fields_list
        :last -> fields_list ++ [{field_name, field_options}]
      end
    else
      fields_list
    end
  end

  def has_field_filters?(resource) do
    admin_fields = Kaffy.ResourceAdmin.index(resource)

    fields_with_filters =
      Enum.map(admin_fields, fn f -> kaffy_field_filters(resource[:schema], f) end)

    Enum.any?(fields_with_filters, fn
      {_, filters} -> filters
      _ -> false
    end)
  end

  def kaffy_field_filters(_schema, {field, options}) do
    {field, Map.get(options || %{}, :filters, false)}
  end

  def kaffy_field_filters(_, _), do: false

  def kaffy_field_name(schema, {field, options}) do
    default_name = kaffy_field_name(schema, field)
    name = Map.get(options || %{}, :name)

    cond do
      is_binary(name) -> name
      is_function(name) -> name.(schema)
      true -> default_name
    end
  end

  def kaffy_field_name(_schema, field) when is_atom(field) do
    Kaffy.ResourceAdmin.humanize_term(field)
  end

  def kaffy_field_value(conn, schema, {field, options}) do
    ft = Kaffy.ResourceSchema.field_type(schema.__struct__, field)
    value = Map.get(options || %{}, :value)

    cond do
      is_function(value) ->
        value.(schema)

      is_map(value) && Map.has_key?(value, :__struct__) ->
        if value.__struct__ in [NaiveDateTime, DateTime, Date, Time] do
          value
        else
          Map.from_struct(value)
          |> Map.drop([:__meta__])
          |> Kaffy.Utils.json().encode!(escape: :html_safe, pretty: true)
        end

      Kaffy.Utils.is_module(ft) && Keyword.has_key?(ft.__info__(:functions), :render_index) ->
        ft.render_index(conn, schema, field, options)

      is_map(value) ->
        Kaffy.Utils.json().encode!(value, escape: :html_safe, pretty: true)

      is_binary(value) ->
        value

      true ->
        kaffy_field_value(schema, field)
    end
  end

  def kaffy_field_value(schema, field) when is_atom(field) do
    value = Map.get(schema, field, "")

    cond do
      is_map(value) && Map.has_key?(value, :__struct__) && value.__struct__ == Decimal ->
        value

      is_map(value) && Map.has_key?(value, :__struct__) ->
        if value.__struct__ in [NaiveDateTime, DateTime, Date, Time] do
          value
        else
          Map.from_struct(value)
          |> Map.drop([:__meta__])
          |> Kaffy.Utils.json().encode!(escape: :html_safe, pretty: true)
        end

      is_map(value) ->
        Kaffy.Utils.json().encode!(value, escape: :html_safe, pretty: true)

      is_binary(value) ->
        String.slice(value, 0, 140)

      is_list(value) ->
        pretty_list(value)

      true ->
        value
    end
  end

  def kaffy_field_sortable?(_schema, {_field, options}), do: !Map.get(options || %{}, :no_sort, false)
  def kaffy_field_sortable?(_schema, _field_options), do: false

  def kaffy_target_url(entry, context, {_field, %{target_url: target_url}}) when is_function(target_url) do
    target_url.(entry, context)
  end

  def kaffy_target_url(entry, _context, {_field, %{target_url: target_url}}) when is_binary(target_url) do
    Enum.join([target_url, entry.id])
  end

  def kaffy_target_url(_entry, _context, {_field, _options}), do: nil

  def display_string_fields([], all), do: Enum.reverse(all) |> Enum.join(",")

  def display_string_fields([{field, _} | rest], all) do
    display_string_fields(rest, [field | all])
  end

  def display_string_fields([field | rest], all) do
    display_string_fields(rest, [field | all])
  end

  def associations(schema) do
    schema.__schema__(:associations)
  end

  def get_has_many_associations(schema) do
    associations(schema)
    |> Enum.filter(fn a ->
      case association(schema, a) do
        %Ecto.Association.Has{cardinality: :many} -> true
        _ -> false
      end
    end)
  end

  def get_has_one_assocations(schema) do
    associations(schema)
    |> Enum.filter(fn a ->
      case association(schema, a) do
        %Ecto.Association.Has{cardinality: :one} -> true
        _ -> false
      end
    end)
  end

  def get_many_to_many_associations(schema) do
    associations(schema)
    |> Enum.filter(fn a ->
      case association(schema, a) do
        %Ecto.Association.ManyToMany{cardinality: :many} -> true
        _ -> false
      end
    end)
  end

  def association(schema, name) do
    schema.__schema__(:association, name)
  end

  def association_schema(schema, assoc) do
    association(schema, assoc).queryable
  end

  def embeds(schema) do
    schema.__schema__(:embeds)
  end

  def embed(schema, name) do
    schema.__schema__(:embed, name)
  end

  def embed_struct(schema, name) do
    embed(schema, name).related
  end

  def search_fields(resource) do
    schema = resource[:schema]
    persisted_fields = schema.__schema__(:fields)

    Enum.filter(fields(schema), fn f ->
      field_name = elem(f, 0)

      field_type(schema, f).type in [:string, :textarea, :richtext] &&
        field_name in persisted_fields
    end)
    |> Enum.map(fn {f, _} -> f end)
  end

  def filter_fields(_), do: nil

  def field_type(_schema, {_, type}), do: type
  def field_type(schema, field), do: schema.__changeset__() |> Map.get(field, :string)
  # def field_type(schema, field), do: schema.__schema__(:type, field)

  def get_map_fields(schema) do
    get_all_fields(schema)
    |> Enum.filter(fn
      {_f, %{type: :map}} ->
        true

      f when is_atom(f) ->
        f == :map

      _ ->
        false
    end)
  end

  def widgets(_resource) do
    []
  end

  defp pretty_list([]), do: ""
  defp pretty_list([item]), do: to_string(item)
  defp pretty_list([a, b]), do: "#{a} and #{b}"
  defp pretty_list([a, b, c]), do: "#{a}, #{b} and #{c}"
  defp pretty_list([a, b, c, d]), do: "#{a}, #{b}, #{c} and #{d}"
  defp pretty_list([a, b, c | rest]), do: "#{a}, #{b}, #{c} and #{length(rest)} others..."
end
