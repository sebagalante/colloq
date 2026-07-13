defmodule Colloq.Factory do
  use ExMachina.Ecto, repo: Colloq.Repo

  alias Colloq.Accounts.User
  alias Colloq.Forum.{Category, Topic, Post}

  def user_factory do
    %User{
      email: sequence(:email, &"user#{&1}@test.com"),
      username: sequence(:username, &"user#{&1}"),
      display_name: "Test User",
      password_hash: Bcrypt.hash_pwd_salt("password123"),
      trust_level: 2
    }
  end

  def category_factory do
    %Category{
      name: sequence(:name, &"Category #{&1}"),
      slug: sequence(:slug, &"category-#{&1}"),
      position: 1
    }
  end

  def topic_factory do
    %Topic{
      title: "Test topic title",
      slug: "test-topic-title",
      user: build(:user),
      category: build(:category),
      posts_count: 0,
      bumped_at: DateTime.utc_now()
    }
  end

  def post_factory do
    %Post{
      body: "Test post body",
      post_number: 1,
      topic: build(:topic),
      user: build(:user)
    }
  end
end
