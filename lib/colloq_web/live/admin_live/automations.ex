defmodule ColloqWeb.AdminLive.Automations do
  use ColloqWeb, :live_view

  alias Colloq.Automations
  alias Colloq.Automations.Automation
  alias Phoenix.LiveView.JS

  @trigger_options [
    {"Recurring", "recurring"},
    {"User Registered", "user_registered"},
    {"User Promoted", "user_promoted"},
    {"Post Created", "post_created"},
    {"Stalled Topic", "stalled_topic"},
    {"Point in Time", "point_in_time"},
    {"API Call", "api_call"}
  ]

  @script_options [
    {"Send PM", "send_pm"},
    {"Create Post", "create_post"},
    {"LLM Respond", "llm_respond"},
    {"Close Topic", "close_topic"},
    {"Pin Topic", "pin_topic"},
    {"Flag Post", "flag_post"},
    {"Auto Tag", "auto_tag"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Automations"))
      |> assign(:automations, Automations.list_automations())
      |> assign(:show_modal, false)
      |> assign(:editing, nil)
      |> assign_form(%Automation{})

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
         |> assign_form(%Automation{})}

      :edit ->
        id = String.to_integer(params["id"])
        automation = Enum.find(socket.assigns.automations, &(&1.id == id))

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, automation)
         |> assign_form(automation)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    automation = Enum.find(socket.assigns.automations, &(&1.id == String.to_integer(id)))

    case Automations.update_automation(automation, %{enabled: !automation.enabled}) do
      {:ok, updated} ->
        automations = replace_in_list(socket.assigns.automations, updated)

        {:noreply,
         socket
         |> assign(:automations, automations)
         |> put_flash(:info, if(updated.enabled, do: gettext("Automation enabled."), else: gettext("Automation disabled.")))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change the status."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    automation = Enum.find(socket.assigns.automations, &(&1.id == String.to_integer(id)))

    case Automations.delete_automation(automation) do
      {:ok, _} ->
        automations = Enum.reject(socket.assigns.automations, &(&1.id == automation.id))

        {:noreply,
         socket
         |> assign(:automations, automations)
         |> put_flash(:info, gettext("Automation deleted."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the automation."))}
    end
  end

  def handle_event("save", %{"automation" => attrs}, socket) do
    parsed = parse_configs(attrs)

    case socket.assigns.editing do
      nil ->
        case Automations.create_automation(parsed) do
          {:ok, automation} ->
            {:noreply,
             socket
             |> assign(:automations, [automation | socket.assigns.automations])
             |> assign(:show_modal, false)
             |> put_flash(:info, gettext("Automation created."))}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign_form(%Automation{})
             |> put_changeset_errors(changeset)}
        end

      editing ->
        case Automations.update_automation(editing, parsed) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:automations, replace_in_list(socket.assigns.automations, updated))
             |> assign(:show_modal, false)
             |> put_flash(:info, gettext("Automation updated."))}

          {:error, changeset} ->
            {:noreply, put_changeset_errors(socket, changeset)}
        end
    end
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing, nil)
     |> push_patch(to: ~p"/admin/automations")}
  end

  def handle_event("open-new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing, nil)
     |> assign_form(%Automation{})
     |> push_patch(to: ~p"/admin/automations/new")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    automation = Enum.find(socket.assigns.automations, &(&1.id == String.to_integer(id)))
    {:noreply, push_patch(socket, to: ~p"/admin/automations/#{automation.id}/edit")}
  end

  defp assign_form(socket, automation) do
    form =
      if automation do
        %{
          name: automation.name || "",
          trigger: automation.trigger || "recurring",
          trigger_config: Jason.encode!(automation.trigger_config || %{}),
          script: automation.script || "send_pm",
          script_config: Jason.encode!(automation.script_config || %{}),
          enabled: automation.enabled
        }
      else
        %{
          name: "",
          trigger: "recurring",
          trigger_config: "{}",
          script: "send_pm",
          script_config: "{}",
          enabled: true
        }
      end

    assign(socket, :form, form)
  end

  defp parse_configs(attrs) do
    trigger_config =
      case Jason.decode(attrs["trigger_config"] || "{}") do
        {:ok, map} -> map
        _ -> %{}
      end

    script_config =
      case Jason.decode(attrs["script_config"] || "{}") do
        {:ok, map} -> map
        _ -> %{}
      end

    %{
      name: attrs["name"],
      trigger: attrs["trigger"],
      trigger_config: trigger_config,
      script: attrs["script"],
      script_config: script_config,
      enabled: attrs["enabled"] == "true"
    }
  end

  defp replace_in_list(list, updated) do
    Enum.map(list, fn item -> if item.id == updated.id, do: updated, else: item end)
  end

  defp put_changeset_errors(socket, changeset) do
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
