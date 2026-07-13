defmodule ColloqWeb.AdminLive.LlmSettings do
  use ColloqWeb, :live_view

  alias Colloq.SiteSettings
  alias Colloq.Llm

  @providers [
    %{key: "llm_api_key_groq", name: "Groq", slug: "groq", test_model: "llama-3.1-8b-instant"},
    %{key: "llm_api_key_nvidia", name: "NVIDIA NIM", slug: "nvidia", test_model: "nvidia/llama-3.1-nemotron-70b-instruct"},
    %{key: "llm_api_key_anthropic", name: "Anthropic", slug: "anthropic", test_model: "claude-3-haiku-20240307"},
    %{key: "llm_api_key_openrouter", name: "OpenRouter", slug: "openrouter", test_model: "openai/gpt-4o-mini"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    providers = load_providers()

    socket =
      socket
      |> assign(:page_title, gettext("LLM Settings"))
      |> assign(:providers, providers)
      |> assign(:testing_provider, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("save", %{"key" => key, "value" => api_key}, socket) do
    case SiteSettings.put(key, api_key, type: "secret", group: "llm") do
      {:ok, _} ->
        providers = load_providers()
        {:noreply, socket |> assign(:providers, providers) |> put_flash(:info, gettext("API key saved."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the API key."))}
    end
  end

  def handle_event("test", %{"key" => setting_key, "provider" => slug}, socket) do
    provider_info = Enum.find(@providers, &(&1.slug == slug))

    socket =
      socket
      |> assign(:testing_provider, slug)

    result =
      Llm.complete(slug, [%{role: "user", content: "."}], %{
        model: provider_info.test_model,
        max_tokens: 1,
        temperature: 0.0
      })

    providers =
      socket.assigns.providers
      |> Enum.map(fn p ->
        if p.slug == slug do
          Map.put(p, :test_result, result)
          |> Map.put(:tested_at, DateTime.utc_now())
        else
          p
        end
      end)

    socket =
      case result do
        {:ok, _} ->
          socket
          |> assign(:providers, providers)
          |> put_flash(:info, gettext("Connection with %{name} successful.", name: provider_info.name))

        {:error, reason} ->
          socket
          |> assign(:providers, providers)
          |> put_flash(:error, gettext("Error connecting with %{name}: %{reason}", name: provider_info.name, reason: inspect(reason)))
      end

    {:noreply, assign(socket, :testing_provider, nil)}
  end

  defp load_providers do
    Enum.map(@providers, fn provider ->
      setting = SiteSettings.get(provider.key)
      configured = setting != nil

      %{
        key: provider.key,
        name: provider.name,
        slug: provider.slug,
        configured: configured,
        test_model: provider.test_model,
        test_result: nil,
        tested_at: nil
      }
    end)
  end
end
