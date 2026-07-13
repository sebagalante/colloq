defmodule Colloq.Pagination do
  @moduledoc """
  Simple cursor-free pagination helper for Ecto queries.
  """

  import Ecto.Query
  alias Colloq.Repo

  @type page :: %{
          entries: list(),
          page: integer(),
          page_size: integer(),
          total_count: integer(),
          total_pages: integer()
        }

  @doc """
  Paginate an Ecto query.

  Options:
    - :page — current page (default 1)
    - :page_size — items per page (default 25)
  """
  @spec paginate(Ecto.Query.t(), keyword()) :: page()
  def paginate(query, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = max(Keyword.get(opts, :page_size, 25), 1)

    total_count = Repo.aggregate(query, :count, :id)
    offset = (page - 1) * page_size

    entries =
      query
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    total_pages = max(ceil(total_count / page_size), 1)

    %{
      entries: entries,
      page: page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages
    }
  end
end
