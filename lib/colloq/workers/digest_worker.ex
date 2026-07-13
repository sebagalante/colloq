defmodule Colloq.Workers.DigestWorker do
  @moduledoc """
  Daily digest worker. Sends forum activity summary to subscribed users.
  Cron: 9:00 AM daily. Will become an automation rule in a future version.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  alias Colloq.Repo
  alias Colloq.Accounts.User
  alias Colloq.Forum
  alias Colloq.Mailer
  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  @impl Oban.Worker
  def perform(_job) do
    users = Repo.all(from(u in User, where: u.notifications_enabled == true))
    stats = load_digest_stats()

    Enum.each(users, fn user ->
      send_digest(user, stats)
    end)

    {:ok, length(users)}
  end

  defp load_digest_stats do
    yesterday = DateTime.utc_now() |> DateTime.add(-24, :hour)

    %{
      topics: Forum.list_topics(per_page: 10).entries,
      date: Date.utc_today() |> Date.add(-1)
    }
  end

  defp send_digest(user, stats) do
    email =
      new()
      |> to({user.display_name || user.username, user.email})
      |> Swoosh.Email.from({"Colloq", "notificaciones@colloq.local"})
      |> subject("Resumen diario de Colloq — #{stats.date}")
      |> html_body(digest_html(user, stats))
      |> text_body(digest_text(user, stats))

    Mailer.deliver(email)
  end

  defp digest_html(user, stats) do
    topic_links = Enum.map(stats.topics, fn t ->
      "<li><a href=\"/t/#{t.id}\">#{t.title}</a> — #{t.posts_count} comentarios</li>"
    end)

    """
    <h2>¡Hola, #{user.display_name || user.username}!</h2>
    <p>Esto es lo que pasó en Colloq el #{stats.date}:</p>
    <ul>#{topic_links}</ul>
    <p><a href=\"/\">Ver el foro</a></p>
    """
  end

  defp digest_text(user, stats) do
    topic_lines = Enum.map(stats.topics, fn t ->
      "- #{t.title} (#{t.posts_count} comentarios)\n  /t/#{t.id}"
    end)

    """
    ¡Hola, #{user.display_name || user.username}!

    Esto es lo que pasó en Colloq el #{stats.date}:

    #{Enum.join(topic_lines, "\n")}

    Ver el foro: /
    """
  end
end