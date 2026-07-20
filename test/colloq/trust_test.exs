defmodule Colloq.TrustTest do
  use Colloq.DataCase, async: true

  alias Colloq.Trust
  alias Colloq.Trust.TrustLevel

  setup do
    levels = [
      %{level: 0, name: "Nuevo", min_posts: 0, min_days_registered: 0,
        can_create_topics: true, can_send_pms: false, can_edit_posts: false,
        can_upload_images: false, daily_post_limit: 100, daily_reaction_limit: 100,
        max_tags_per_topic: 0},
      %{level: 1, name: "Básico", min_posts: 1_000, min_days_registered: 1,
        can_create_topics: true, can_send_pms: true, can_edit_posts: false,
        can_upload_images: false, daily_post_limit: 200, daily_reaction_limit: 200,
        max_tags_per_topic: 5},
      %{level: 2, name: "Miembro", min_posts: 2_500, min_days_registered: 7,
        can_create_topics: true, can_send_pms: true, can_edit_posts: true,
        can_upload_images: true, daily_post_limit: 500, daily_reaction_limit: 500,
        max_tags_per_topic: 10},
      %{level: 3, name: "Regular", min_posts: 6_500, min_days_registered: 0,
        can_create_topics: true, can_send_pms: true, can_edit_posts: true,
        can_upload_images: true, daily_post_limit: 0, daily_reaction_limit: 0,
        max_tags_per_topic: 15},
      %{level: 4, name: "Líder", min_posts: 10_000, min_days_registered: 0,
        can_create_topics: true, can_send_pms: true, can_edit_posts: true,
        can_upload_images: true, daily_post_limit: 0, daily_reaction_limit: 0,
        max_tags_per_topic: -1}
    ]

    Enum.each(levels, fn attrs ->
      %TrustLevel{}
      |> TrustLevel.changeset(attrs)
      |> Repo.insert!()
    end)

    :ok
  end

  describe "daily_post_limit/1" do
    test "TL0 returns 100" do
      assert Trust.daily_post_limit(0) == 100
    end

    test "TL1 returns 200" do
      assert Trust.daily_post_limit(1) == 200
    end

    test "TL2 returns 500" do
      assert Trust.daily_post_limit(2) == 500
    end

    test "TL3 returns :unlimited" do
      assert Trust.daily_post_limit(3) == :unlimited
    end

    test "TL4 returns :unlimited" do
      assert Trust.daily_post_limit(4) == :unlimited
    end

    test "unknown level returns 0" do
      assert Trust.daily_post_limit(99) == 0
    end
  end

  describe "daily_reaction_limit/1" do
    test "TL0 returns 100" do
      assert Trust.daily_reaction_limit(0) == 100
    end

    test "TL2 returns 500" do
      assert Trust.daily_reaction_limit(2) == 500
    end

    test "TL3 returns :unlimited" do
      assert Trust.daily_reaction_limit(3) == :unlimited
    end
  end

  describe "can_create_topics?/1" do
    test "TL0 can create topics" do
      assert Trust.can_create_topics?(0) == true
    end

    test "all levels can create topics" do
      for level <- 0..4 do
        assert Trust.can_create_topics?(level) == true
      end
    end
  end

  describe "can_send_pms?/1" do
    test "TL0 cannot send PMs" do
      assert Trust.can_send_pms?(0) == false
    end

    test "TL1+ can send PMs" do
      assert Trust.can_send_pms?(1) == true
      assert Trust.can_send_pms?(4) == true
    end
  end

  describe "can_edit_posts?/1" do
    test "TL0 and TL1 cannot edit" do
      assert Trust.can_edit_posts?(0) == false
      assert Trust.can_edit_posts?(1) == false
    end

    test "TL2+ can edit" do
      assert Trust.can_edit_posts?(2) == true
    end
  end

  describe "can_upload_images?/1" do
    test "TL0 and TL1 cannot upload" do
      assert Trust.can_upload_images?(0) == false
      assert Trust.can_upload_images?(1) == false
    end

    test "TL2+ can upload" do
      assert Trust.can_upload_images?(2) == true
    end
  end

  describe "max_tags_per_topic/1" do
    test "TL0 may not tag at all" do
      assert Trust.max_tags_per_topic(0) == 0
    end

    test "the cap widens with each level" do
      assert Trust.max_tags_per_topic(1) == 5
      assert Trust.max_tags_per_topic(2) == 10
      assert Trust.max_tags_per_topic(3) == 15
    end

    test "TL4 is unlimited (stored as -1, not 0)" do
      assert Trust.max_tags_per_topic(4) == :unlimited
    end

    test "an unknown level denies rather than granting unlimited" do
      assert Trust.max_tags_per_topic(99) == 0
    end
  end
end
