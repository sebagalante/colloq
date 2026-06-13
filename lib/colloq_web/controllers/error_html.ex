defmodule ColloqWeb.ErrorHTML do
  @moduledoc """
  Error HTML pages for Colloq.
  """
  use ColloqWeb, :html

  def render("404.html", _assigns) do
    ~H"""
    <div class="text-center py-20">
      <h1 class="text-6xl font-bold text-white mb-4">404</h1>
      <p class="text-gray-400 text-lg">Página no encontrada</p>
      <a href="/" class="mt-6 inline-block text-blue-400 hover:text-blue-300 underline">
        Volver al inicio
      </a>
    </div>
    """
  end

  def render("403.html", _assigns) do
    ~H"""
    <div class="text-center py-20">
      <h1 class="text-6xl font-bold text-red-500 mb-4">403</h1>
      <p class="text-gray-400 text-lg">Acceso denegado</p>
      <p class="text-gray-500 mt-2">No tienes permiso para acceder a esta página.</p>
    </div>
    """
  end

  def render("500.html", _assigns) do
    ~H"""
    <div class="text-center py-20">
      <h1 class="text-6xl font-bold text-red-500 mb-4">500</h1>
      <p class="text-gray-400 text-lg">Error interno del servidor</p>
      <p class="text-gray-500 mt-2">Algo salió mal. Intenta de nuevo más tarde.</p>
    </div>
    """
  end

  @doc """
  The default is to render a "404 Not Found" page.
  """
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
