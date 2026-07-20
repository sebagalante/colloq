defmodule Colloq.Trust.TrustLevel do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trust_levels" do
    field :level, :integer
    field :name, :string
    field :min_posts, :integer, default: 0
    field :min_days_registered, :integer, default: 0
    field :can_create_topics, :boolean, default: true
    field :can_send_pms, :boolean, default: true
    field :can_edit_posts, :boolean, default: true
    field :can_flag_posts, :boolean, default: true
    field :can_upload_images, :boolean, default: true
    field :daily_post_limit, :integer, default: 0
    field :daily_reaction_limit, :integer, default: 0
    # -1 = unlimited, 0 = may not tag at all. Deliberately NOT the
    # 0-means-unlimited convention of the daily_* limits above: TL0 needs to be
    # able to express "no tagging", so 0 had to stay a real zero here.
    field :max_tags_per_topic, :integer, default: 5

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(level, attrs) do
    level
    |> cast(attrs, [
      :level, :name, :min_posts, :min_days_registered,
      :can_create_topics, :can_send_pms, :can_edit_posts,
      :can_flag_posts, :can_upload_images,
      :daily_post_limit, :daily_reaction_limit,
      :max_tags_per_topic
    ])
    |> validate_required([:level, :name])
    |> unique_constraint(:level)
    |> unique_constraint(:name)
  end
end