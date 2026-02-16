require "net/http"
require "json"

class Api::TenorController < ApplicationController
  before_action :authenticate_user!

  def search
    query = params[:q].to_s.strip
    return render json: { results: [], next: "" } if query.blank?

    cache_key = "tenor/search/#{Digest::MD5.hexdigest(query)}/#{params[:pos]}"
    data = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
      fetch_tenor("search", q: query, pos: params[:pos])
    end

    render json: format_response(data)
  end

  def trending
    cache_key = "tenor/trending/#{params[:pos]}"
    data = Rails.cache.fetch(cache_key, expires_in: 15.minutes) do
      fetch_tenor("featured", pos: params[:pos])
    end

    render json: format_response(data)
  end

  def categories
    data = Rails.cache.fetch("tenor/categories", expires_in: 15.minutes) do
      fetch_tenor("categories", type: "featured")
    end

    results = (data&.dig("tags") || []).map do |tag|
      {
        name: tag["searchterm"],
        image: tag["image"]
      }
    end

    render json: { categories: results }
  end

  private

  def api_key
    Rails.application.config.tenor_api_key
  end

  def fetch_tenor(endpoint, params = {})
    return nil unless api_key.present?

    uri = URI("https://tenor.googleapis.com/v2/#{endpoint}")
    uri.query = URI.encode_www_form(params.compact.merge(
      key: api_key,
      client_key: "inferno_chat",
      limit: 20,
      media_filter: "tinygif,gif"
    ))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10

    response = http.request(Net::HTTP::Get.new(uri))
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue => e
    Rails.logger.warn("Tenor API error: #{e.message}")
    nil
  end

  def format_response(data)
    results = (data&.dig("results") || []).map do |gif|
      tiny = gif.dig("media_formats", "tinygif") || {}
      full = gif.dig("media_formats", "gif") || {}
      {
        id: gif["id"],
        url: gif["url"],
        preview_url: tiny["url"],
        gif_url: full["url"],
        description: gif["content_description"].to_s
      }
    end

    { results: results, next: data&.dig("next").to_s }
  end
end
