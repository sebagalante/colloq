defmodule ColloqWeb.AdminLive.Bots do
  use ColloqWeb, :live_view

  alias Colloq.Bots
  alias Colloq.Bots.BotSystem
  alias Colloq.Llm
  alias Colloq.Repo
  alias Phoenix.LiveView.JS

  @provider_options [
    {"Groq", "groq"},
    {"NVIDIA NIM", "nvidia"},
    {"Anthropic", "anthropic"},
    {"OpenRouter", "openrouter"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Bots")
      |> assign(:personas, Bots.list_personas())
      |> assign(:show_modal, false)
      |> assign(:editing, nil)
      |> assign(:test_response, nil)
      |> assign(:test_loading, false)
      |> assign_form(nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, nil)
         |> assign_form(nil)}

      :edit ->
        id = String.to_integer(params["id"])
        persona = Enum.find(socket.assigns.personas, &(&1.id == id))

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, persona)
         |> assign_form(persona)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    persona = Enum.find(socket.assigns.personas, &(&1.id == String.to_integer(id)))

    case Repo.delete(persona) do
      {:ok, _} ->
        personas = Enum.reject(socket.assigns.personas, &(&1.id == persona.id))

        {:noreply,
         socket
         |> assign(:personas, personas)
         |> put_flash(:info, "Bot eliminado.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el bot.")}
    end
  end

  def handle_event("save", %{"bot" => attrs}, socket) do
    config = build_config(attrs)

    slug =
      (attrs["slug"] || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "-")

    params = %{
      name: attrs["name"],
      slug: slug,
      type: "persona",
      active: attrs["active"] == "true",
      config: config
    }

    case socket.assigns.editing do
      nil ->
        changeset = BotSystem.changeset(%BotSystem{}, params) |> Map.put(:action, :insert)

        case Repo.insert(changeset) do
          {:ok, persona} ->
            {:noreply,
             socket
             |> assign(:personas, [persona | socket.assigns.personas])
             |> assign(:show_modal, false)
             |> put_flash(:info, "Bot creado.")}

          {:error, changeset} ->
            {:noreply, put_changeset_flash(socket, changeset)}
        end

      editing ->
        changeset = BotSystem.changeset(editing, params) |> Map.put(:action, :update)

        case Repo.update(changeset) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:personas, replace_in_list(socket.assigns.personas, updated))
             |> assign(:show_modal, false)
             |> put_flash(:info, "Bot actualizado.")}

          {:error, changeset} ->
            {:noreply, put_changeset_flash(socket, changeset)}
        end
    end
  end

  def handle_event("test", %{"prompt" => prompt, "provider" => provider, "model" => model, "system_prompt" => system_prompt}, socket) do
    temperature = Application.get_env(:colloq, :bot_default_temperature, 0.7)
    max_tokens = Application.get_env(:colloq, :bot_default_max_tokens, 1024)

    {:noreply, assign(socket, :test_loading, true)}

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: prompt}
    ]

    case Llm.complete(provider, messages, %{model: model, temperature: temperature, max_tokens: max_tokens}) do
      {:ok, %{content: content}} ->
        {:noreply,
         socket
         |> assign(:test_response, content)
         |> assign(:test_loading, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:test_response, "Error: #{inspect(reason)}")
         |> assign(:test_loading, false)}
    end
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing, nil)
     |> assign(:test_response, nil)
     |> push_patch(to: ~p"/admin/bots")}
  end

  def handle_event("open-new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing, nil)
     |> assign(:test_response, nil)
     |> assign_form(nil)
     |> push_patch(to: ~p"/admin/bots/new")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    persona = Enum.find(socket.assigns.personas, &(&1.id == String.to_integer(id)))
    {:noreply, push_patch(socket, to: ~p"/admin/bots/#{persona.id}/edit")}
  end

  defp assign_form(socket, nil) do
    assign(socket, :form, %{
      name: "",
      slug: "",
      avatar_url: "",
      description: "",
      system_prompt: "",
      provider: "groq",
      model: "gpt-4o-mini",
      temperature: "0.7",
      max_tokens: "1024",
      trigger_on_mention: "true",
      allowed_trust_level: "0",
      rate_limit_per_user: "5",
      managed_by_worker: "true",
      active: "true"
    })
  end

  defp assign_form(socket, persona) do
    cfg = persona.config || %{}

    assign(socket, :form, %{
      name: persona.name || "",
      slug: persona.slug || "",
      avatar_url: Map.get(cfg, "avatar_url", ""),
      description: Map.get(cfg, "description", ""),
      system_prompt: Map.get(cfg, "system_prompt", ""),
      provider: Map.get(cfg, "provider", "groq"),
      model: Map.get(cfg, "model", "gpt-4o-mini"),
      temperature: to_string(Map.get(cfg, "temperature", 0.7)),
      max_tokens: to_string(Map.get(cfg, "max_tokens", 1024)),
      trigger_on_mention: to_string(Map.get(cfg, "trigger_on_mention", true)),
      allowed_trust_level: to_string(Map.get(cfg, "allowed_trust_level", 0)),
      rate_limit_per_user: to_string(Map.get(cfg, "rate_limit_per_user", 5)),
      managed_by_worker: to_string(Map.get(cfg, "managed_by_worker", true)),
      active: to_string(persona.active)
    })
  end

  defp build_config(attrs) do
    %{
      "avatar_url" => attrs["avatar_url"] || "",
      "description" => attrs["description"] || "",
      "system_prompt" => attrs["system_prompt"] || "",
      "provider" => attrs["provider"],
      "model" => attrs["model"],
      "temperature" => parse_float(attrs["temperature"], 0.7),
      "max_tokens" => parse_int(attrs["max_tokens"], 1024),
      "trigger_on_mention" => attrs["trigger_on_mention"] == "true",
      "allowed_trust_level" => parse_int(attrs["allowed_trust_level"], 0),
      "rate_limit_per_user" => parse_int(attrs["rate_limit_per_user"], 5),
      "managed_by_worker" => attrs["managed_by_worker"] == "true"
    }
  end

  defp parse_float(str, default) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end

  defp replace_in_list(list, updated) do
    Enum.map(list, fn item -> if item.id == updated.id, do: updated, else: item end)
  end

  defp put_changeset_flash(socket, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
      |> Enum.join("; ")

    put_flash(socket, :error, errors)
  end
end
