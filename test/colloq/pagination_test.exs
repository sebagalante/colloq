defmodule Colloq.PaginationTest do
  use Colloq.DataCase, async: true

  alias Colloq.Pagination
  alias Colloq.Forum.{Category, Topic}

  import Ecto.Query

  setup do
    user = insert(:user)
    category = insert(:category)

    topics =
      for i <- 1..15 do
        {:ok, topic} =
          Colloq.Forum.create_topic(user, %{
            "title" => "Topic #{i}",
            "category_id" => category.id,
            "body" => "Body #{i}"
          })

        topic
      end

    %{topics: topics, category: category}
  end

  describe "paginate/2" do
    test "returns first page with correct entries" do
      result =
        Topic
        |> order_by(desc: :inserted_at)
        |> Pagination.paginate(page: 1, page_size: 5)

      assert length(result.entries) == 5
      assert result.page == 1
      assert result.page_size == 5
      assert result.total_count == 15
      assert result.total_pages == 3
    end

    test "returns second page" do
      result =
        Topic
        |> order_by(desc: :inserted_at)
        |> Pagination.paginate(page: 2, page_size: 5)

      assert length(result.entries) == 5
      assert result.page == 2
    end

    test "returns partial last page" do
      result =
        Topic
        |> order_by(desc: :inserted_at)
        |> Pagination.paginate(page: 3, page_size: 5)

      assert length(result.entries) == 5
    end

    test "total_pages is at least 1 for empty result" do
      result =
        Topic
        |> where([t], t.title == "nonexistent")
        |> Pagination.paginate(page: 1, page_size: 5)

      assert result.entries == []
      assert result.total_pages == 1
      assert result.total_count == 0
    end

    test "defaults to page 1, page_size 25" do
      result = Pagination.paginate(Topic)

      assert result.page == 1
      assert result.page_size == 25
      assert result.total_count == 15
      assert length(result.entries) == 15
    end
  end
end
