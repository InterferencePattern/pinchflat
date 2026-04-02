defmodule PinchflatWeb.Sources.SourceLive.IndexTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery
  use Pinchflat.Sources.SourcesQuery

  import PinchflatWeb.Helpers.SortingHelpers
  import PinchflatWeb.Helpers.PaginationHelpers

  alias Pinchflat.Cache
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  def mount(_params, session, socket) do
    limit = session["results_per_page"]

    initial_params =
      Map.merge(
        %{
          sort_key: session["initial_sort_key"],
          sort_direction: session["initial_sort_direction"]
        },
        get_pagination_attributes(sources_query(), 1, limit)
      )

    socket
    |> assign(initial_params)
    |> set_sources()
    |> then(&{:ok, &1})
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    new_page = update_page_number(assigns.page, direction, assigns.total_pages)

    socket
    |> assign(get_pagination_attributes(sources_query(), new_page, assigns.limit))
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  def handle_event("sort_update", %{"sort_key" => sort_key}, %{assigns: assigns} = socket) do
    new_sort_key = String.to_existing_atom(sort_key)

    new_params = %{
      sort_key: new_sort_key,
      sort_direction: get_sort_direction(assigns.sort_key, new_sort_key, assigns.sort_direction)
    }

    socket
    |> assign(new_params)
    |> set_sources()
    |> then(&{:noreply, &1})
  end

  defp sort_attr(:media_profile_name), do: dynamic([s, mp], fragment("? COLLATE NOCASE", mp.name))
  defp sort_attr(:custom_name), do: dynamic([s], fragment("? COLLATE NOCASE", s.custom_name))
  defp sort_attr(:enabled), do: dynamic([s], s.enabled)

  @ets_sort_keys [:pending_count, :downloaded_count, :media_size_bytes]

  defp set_sources(%{assigns: assigns} = socket) do
    sources =
      if assigns.sort_key in @ets_sort_keys do
        sources_query()
        |> Repo.all()
        |> Enum.map(&merge_counts/1)
        |> Enum.sort_by(&Map.get(&1, assigns.sort_key, 0), assigns.sort_direction)
        |> Enum.slice(assigns.offset, assigns.limit)
      else
        sources_query()
        |> order_by(^[{assigns.sort_direction, sort_attr(assigns.sort_key)}, asc: :id])
        |> limit(^assigns.limit)
        |> offset(^assigns.offset)
        |> Repo.all()
        |> Enum.map(&merge_counts/1)
      end

    assign(socket, %{sources: sources})
  end

  defp merge_counts(source) do
    default = %{downloaded_count: 0, pending_count: 0, media_size_bytes: 0}
    counts = Cache.get({:source_counts, source.id}, default)
    Map.merge(source, Map.merge(default, counts))
  end

  defp sources_query do
    from s in Source,
      inner_join: mp in assoc(s, :media_profile),
      where: is_nil(s.marked_for_deletion_at) and is_nil(mp.marked_for_deletion_at),
      preload: [media_profile: mp],
      select: map(s, ^Source.__schema__(:fields))
  end
end
