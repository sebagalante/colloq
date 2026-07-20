defmodule ColloqWeb.AdminLive.LlmSettings do
  use ColloqWeb, :live_view

  alias Colloq.SiteSettings
  alias Colloq.Llm

  # API keys are NOT stored here — they come from the environment (`.env` in
  # dev, Infisical-injected env vars in prod). This page only reflects which
  # providers are configured and lets you pick the summarizer provider/model.
  @providers [
    %{name: "Groq", slug: "groq", env_var: "GROQ_API_KEY", test_model: "llama-3.1-8b-instant"},
    %{name: "NVIDIA NIM", slug: "nvidia", env_var: "NVIDIA_NIM_API_KEY", test_model: "nvidia/llama-3.1-nemotron-70b-instruct"},
    %{name: "DeepSeek", slug: "deepseek", env_var: "DEEPSEEK_API_KEY", test_model: "deepseek-chat"},
    %{name: "OpenRouter", slug: "openrouter", env_var: "OPENROUTER_API_KEY", test_model: "openai/gpt-4o-mini"},
    %{name: "Google Gemma", slug: "gemma", env_var: "GEMMA_API_KEY", test_model: "gemma-3-12b-it"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("LLM Settings"))
      |> assign(:providers, load_providers())
      |> assign(:testing_provider, nil)
      |> assign(:provider_choices, configured_choices())
      |> load_summarizer()

    {:ok, socket}
  end

  # Only providers with a key in the environment can be picked as summarizer.
  defp configured_choices do
    configured = Llm.configured_providers()

    @providers
    |> Enum.filter(&(&1.slug in configured))
    |> Enum.map(&{&1.name, &1.slug})
  end

  defp load_summarizer(socket) do
    socket
    |> assign(:summarizer_provider, SiteSettings.get("summarizer_provider") || "")
    |> assign(:summarizer_model, SiteSettings.get("summarizer_model") || "")
  end

  @impl true
  def handle_event("save-summarizer", %{"provider" => provider, "model" => model}, socket) do
    model = String.trim(model)

    results = [
      SiteSettings.put("summarizer_provider", provider, group: "llm"),
      SiteSettings.put("summarizer_model", model, group: "llm")
    ]

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:noreply,
       socket
       |> load_summarizer()
       |> put_flash(:info, gettext("Summarizer settings saved."))}
    else
      {:noreply, put_flash(socket, :error, gettext("Could not save summarizer settings."))}
    end
  end

  def handle_event("test", %{"provider" => slug}, socket) do
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
      %{
        name: provider.name,
        slug: provider.slug,
        env_var: provider.env_var,
        configured: Llm.provider_configured?(provider.slug),
        test_model: provider.test_model,
        test_result: nil,
        tested_at: nil
      }
    end)
  end
end
