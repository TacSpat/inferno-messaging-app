require "net/http"
require "uri"

class Message < ApplicationRecord
  include HasPublicId
  belongs_to :user
  belongs_to :channel, optional: true
  belongs_to :conversation, optional: true
  belongs_to :parent, class_name: "Message", optional: true
  has_many :replies, class_name: "Message", foreign_key: :parent_id, dependent: :nullify
  has_many :reactions, dependent: :destroy
  has_many_attached :files

  validates :content, presence: true, unless: :has_files?
  validates :content, length: { maximum: 4000 }, allow_blank: true

  after_create_commit :create_mention_notifications
  after_create_commit :render_and_cache!
  after_create_commit :publish_to_nostr_group, if: :in_shared_channel?
  after_update_commit :render_and_cache!, if: :saved_change_to_content?

  scope :ordered, -> { order(created_at: :asc) }
  scope :recent, -> { order(created_at: :desc) }

  IMAGE_URL_REGEX = /(?:https?:\/\/\S+\.(?:png|jpe?g|gif|webp|svg)(?:\?\S*)?|(?:\/rails\/active_storage\/\S+))/i
  YOUTUBE_REGEX = /(?:https?:\/\/)?(?:www\.)?(?:youtube\.com\/watch\?v=|youtu\.be\/)([\w-]{11})(?:[&?][\S]*)*/i
  INSTAGRAM_REGEX = /(?:https?:\/\/)?(?:www\.)?(?:instagram\.com|kkinstagram\.com)\/(reel|p)\/([\w-]+)/i
  VIDEO_URL_REGEX = /https?:\/\/\S+\.(?:mp4|webm|mov|ogv)(?:\?\S*)?/i
  TIKTOK_REGEX = /(?:https?:\/\/)?(?:www\.)?(?:tiktok\.com|vm\.tiktok\.com)\/(?:@[\w.]+\/video\/(\d+)|([\w]+))/i
  TENOR_REGEX = /https?:\/\/tenor\.com\/view\/([\w-]+)-(\d+)/i
  REDDIT_REGEX = /https?:\/\/(?:www\.)?(?:old\.)?reddit\.com\/r\/(\w+)\/comments\/(\w+)(?:\/([^\s\/\?#]*))?/i
  URL_REGEX = /https?:\/\/[^\s<>]+/i
  DISCORD_LINK_REGEX = /https?:\/\/(?:discord\.com|discordapp\.com)\/channels\/(\d+)\/(\d+)\/(\d+)/i
  MESSAGE_LINK_REGEX = /\/servers\/([a-zA-Z0-9]+)\/channels\/([a-zA-Z0-9]+)#message[-_]([a-zA-Z0-9]+)/

  def rendered_content
    return "" if content.blank?
    rendered_content_cached.presence&.html_safe || render_content_html(sync_tenor: true).html_safe
  end

  def render_and_cache!
    return if content.blank?
    html = render_content_html(sync_tenor: false)
    update_column(:rendered_content_cached, html)
    TenorUnfurlJob.perform_later(id) if content.match?(TENOR_REGEX)
  end

  def render_content_html(sync_tenor: true)
    markdown = Redcarpet::Markdown.new(
      HtmlWithRouge.new(hard_wrap: true, link_attributes: { target: "_blank", rel: "noopener" }),
      autolink: true, fenced_code_blocks: true, strikethrough: true,
      no_intra_emphasis: true, tables: true
    )
    html = markdown.render(content)
    html = render_mentions(html)
    html = render_custom_emojis(html)
    html = enlarge_emoji_only(html)
    html = unfurl_videos(html)
    html = unfurl_images(html)
    html = unfurl_links(html, sync_tenor: sync_tenor)
    html
  end

  def unfurl_videos(html)
    html.gsub(/<a[^>]*href="(#{VIDEO_URL_REGEX})"[^>]*>[^<]*<\/a>/i) do |match|
      url = $1
      fname = File.basename(URI.parse(url).path) rescue url
      %(<div class="mt-2 inline-block relative rounded-lg overflow-hidden" data-controller="video-player"><video preload="metadata" class="max-w-lg max-h-96 block" src="#{url}" data-video-player-target="video" data-video-src="#{url}" data-video-filename="#{ERB::Util.html_escape(fname)}"></video></div>)
    end
  end

  def unfurl_images(html)

    html.gsub(/<a[^>]*href="([^"]+)"[^>]*>([^<]*)<\/a>/) do |match|
      url = $1
      if url.match?(IMAGE_URL_REGEX)
        fname = begin; File.basename(URI.parse(url).path); rescue; 'image'; end
        %(<div class="mt-2"><img src="#{url}" class="max-w-sm max-h-72 rounded-lg cursor-pointer hover:shadow-lg transition-shadow" loading="lazy" data-preview-src="#{url}" data-preview-filename="#{fname}"></div>)
      else
        match
      end
    end
  end

def unfurl_links(html, sync_tenor: true)
  embeds = []
  # Collect internal message link embeds
  (content || "").scan(MESSAGE_LINK_REGEX).each do |server_id, channel_id, message_id|
    linked_msg = Message.find_by(public_id: message_id)
    if linked_msg && linked_msg.channel&.public_id == channel_id
      author = linked_msg.user
      preview = ActionController::Base.helpers.truncate(linked_msg.content.to_s.gsub(/```\w*
?/, "").gsub(/```/, "").strip, length: 200)
      time = linked_msg.created_at.strftime("%l:%M %p")
      ch_name = linked_msg.channel.name rescue "unknown"
      server_name = linked_msg.channel.server.name rescue "unknown"
      link_url = "/servers/#{server_id}/channels/#{channel_id}#message-#{message_id}"
      display = ERB::Util.html_escape(author.display_name || author.username)
      if author.avatar.attached?
        avatar_url = Rails.application.routes.url_helpers.rails_blob_path(author.avatar, only_path: true)
        avatar_html = %(<img src="#{avatar_url}" class="w-5 h-5 rounded-full shrink-0 object-cover" />)
      else
        avatar_initial = ERB::Util.html_escape(author.username[0].upcase)
        avatar_html = %(<div class="w-5 h-5 rounded-full bg-indigo-600 flex items-center justify-center text-white text-xs font-bold shrink-0">#{avatar_initial}</div>)
      end
      # Strip the raw link from rendered HTML (both plain and <a>-wrapped versions)
      # Strip the entire line/paragraph containing the message link
      html = html.gsub(/<a[^>]*href="[^"]*\/servers\/#{server_id}\/channels\/#{channel_id}[^"]*#message[-_]#{message_id}[^"]*"[^>]*>[^<]*<\/a>/, "")
      html = html.gsub(/<a[^>]*href="[^"]*\/servers\/#{server_id}\/channels\/#{channel_id}[^"]*"[^>]*>[^<]*<\/a>/, "")
      html = html.gsub(/https?:\/\/[^\s<>]*\/servers\/#{server_id}\/channels\/#{channel_id}#message[-_]#{message_id}[^\s<>]*/, "")
      html = html.gsub(/<p>\s*<\/p>/, "")
      # Clean up empty <p> tags left behind
      html = html.gsub(/<p>\s*<\/p>/, "")
      embeds << %(<a href="#{link_url}" data-turbo="false" class="mt-2 block border-l-4 border-indigo-500 bg-gray-800/60 hover:bg-gray-700/60 rounded-r-lg pl-3 pr-3 py-2 no-underline transition-colors cursor-pointer" data-message-link="true"><div class="flex items-center gap-2 mb-1">#{avatar_html}<span class="text-white font-semibold text-sm">#{display}</span><span class="text-gray-400 text-xs">#{time}</span></div><div class="text-sm text-gray-300">#{ERB::Util.html_escape(preview)}</div><div class="text-xs text-gray-500 mt-1">#{ERB::Util.html_escape(server_name)} &middot; ##{ERB::Util.html_escape(ch_name)}</div></a>)
    end
  end
# Collect Discord message link embeds
(content || "").scan(DISCORD_LINK_REGEX).each do |guild_id, channel_id, message_id|
  next if embeds.any? { |e| e.include?("discord-#{message_id}") }
  discord_url = "https://discord.com/channels/#{guild_id}/#{channel_id}/#{message_id}"
  # Strip the raw link from rendered HTML
  html = html.gsub(/<a[^>]*href="[^"]*discord[^"]*\/channels\/#{guild_id}\/#{channel_id}\/#{message_id}[^"]*"[^>]*>[^<]*<\/a>/, "")
  html = html.gsub(/<p>\s*<\/p>/, "")
  embeds << %(<a href="#{discord_url}" target="_blank" rel="noopener" class="mt-2 flex items-center gap-3 max-w-xs rounded-lg border border-gray-700 bg-[#5865F2]/10 hover:bg-[#5865F2]/20 transition-colors no-underline px-3 py-2.5 group" data-discord-#{message_id}><div class="w-10 h-10 rounded-full bg-[#5865F2] flex items-center justify-center shrink-0"><svg class="w-6 h-6 text-white" viewBox="0 0 24 24" fill="currentColor"><path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028 14.09 14.09 0 0 0 1.226-1.994.076.076 0 0 0-.041-.106 13.107 13.107 0 0 1-1.872-.892.077.077 0 0 1-.008-.128 10.2 10.2 0 0 0 .372-.292.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127 12.299 12.299 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.839 19.839 0 0 0 6.002-3.03.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03z"/></svg></div><div><div class="text-[#5865F2] text-sm font-semibold group-hover:underline">Discord Message</div><div class="text-gray-400 text-xs">Click to view on Discord</div></div></a>)
end
    # Collect YouTube embeds
  (content || "").scan(YOUTUBE_REGEX) do
    video_id = $1
    next if embeds.any? { |e| e.include?(video_id) }
    embeds << %(<div class="mt-2 max-w-lg"><div class="relative w-full" style="padding-bottom:56.25%"><iframe class="absolute inset-0 w-full h-full rounded-lg" src="https://www.youtube.com/embed/#{video_id}" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen loading="lazy"></iframe></div></div>)
  end

  # Collect Instagram embeds (reels + posts) as clickable cards
  (content || "").scan(INSTAGRAM_REGEX) do
    type = $1
    shortcode = $2
    next if embeds.any? { |e| e.include?(shortcode) }
    ig_url = "https://www.instagram.com/#{type}/#{shortcode}/"
    label = type == "reel" ? "Instagram Reel" : "Instagram Post"
    embed_url = "https://www.instagram.com/#{type}/#{shortcode}/embed/"
  # Strip the raw Instagram URL from rendered HTML
    html = html.gsub(/<a[^>]*href="[^"]*(?:instagram\.com|kkinstagram\.com)\/(?:reel|p)\/#{shortcode}[^"]*"[^>]*>[^<]*<\/a>/, "")
    html = html.gsub(/<p>\s*<\/p>/, "")
embeds << %(<div class="mt-2 max-w-sm rounded-lg overflow-hidden border border-gray-700 bg-black relative group" style="height:450px"><iframe src="https://www.instagram.com/#{type}/#{shortcode}/embed/" style="width:100%;height:150%;border:none;position:absolute;top:0;left:0;transform-origin:top center" scrolling="no" allowtransparency="true" loading="lazy"></iframe><a href="#{ig_url}" target="_blank" rel="noopener" class="absolute bottom-2 left-2 opacity-0 group-hover:opacity-100 transition-opacity bg-black/60 hover:bg-black/80 text-white/80 hover:text-white rounded px-2 py-1 text-xs no-underline z-10 flex items-center gap-1"><svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24"><path d="M12 2.163c3.204 0 3.584.012 4.85.07 3.252.148 4.771 1.691 4.919 4.919.058 1.265.069 1.645.069 4.849 0 3.205-.012 3.584-.069 4.849-.149 3.225-1.664 4.771-4.919 4.919-1.266.058-1.644.07-4.85.07-3.204 0-3.584-.012-4.849-.07-3.26-.149-4.771-1.699-4.919-4.92-.058-1.265-.07-1.644-.07-4.849 0-3.204.013-3.583.07-4.849.149-3.227 1.664-4.771 4.919-4.919 1.266-.057 1.645-.069 4.849-.069zM12 0C8.741 0 8.333.014 7.053.072 2.695.272.273 2.69.073 7.052.014 8.333 0 8.741 0 12c0 3.259.014 3.668.072 4.948.2 4.358 2.618 6.78 6.98 6.98C8.333 23.986 8.741 24 12 24c3.259 0 3.668-.014 4.948-.072 4.354-.2 6.782-2.618 6.979-6.98.059-1.28.073-1.689.073-4.948 0-3.259-.014-3.667-.072-4.947-.196-4.354-2.617-6.78-6.979-6.98C15.668.014 15.259 0 12 0zm0 5.838a6.162 6.162 0 100 12.324 6.162 6.162 0 000-12.324zM12 16a4 4 0 110-8 4 4 0 010 8zm6.406-11.845a1.44 1.44 0 100 2.881 1.44 1.44 0 000-2.881z"/></svg>View on Instagram</a></div>)
  end

  # Collect Tenor GIF embeds
  (content || "").scan(TENOR_REGEX).each do |slug, gif_id|
    next if embeds.any? { |e| e.include?("tenor-#{gif_id}") }
    tenor_url = "https://tenor.com/view/#{slug}-#{gif_id}"
    # Strip raw URL
    html = html.gsub(/<a[^>]*href="[^"]*tenor\.com\/view\/[^"]*#{gif_id}[^"]*"[^>]*>[^<]*<\/a>/, "")
    html = html.gsub(/<p>\s*<\/p>/, "")

    if sync_tenor
      # Synchronous fetch for immediate display (fallback/uncached path)
      gif_src = fetch_tenor_og_image(tenor_url)
      if gif_src
        embeds << %(<div class="mt-2 inline-block relative group/gif" data-tenor-gif-id="#{gif_id}" data-tenor-url="#{tenor_url}" data-gif-url="#{gif_src}" data-preview-url="#{gif_src}"><img src="#{gif_src}" alt="GIF" class="max-w-full sm:max-w-sm max-h-72 rounded-lg cursor-pointer" loading="lazy" data-animated-gif data-preview-src="#{gif_src}" data-preview-filename="tenor-#{gif_id}.gif"></div>)
      else
        embeds << %(<a href="#{tenor_url}" target="_blank" rel="noopener" class="mt-2 flex items-center gap-3 max-w-xs rounded-lg border border-gray-700 bg-gray-800 hover:bg-gray-750 transition-colors no-underline px-3 py-2.5"><span class="text-blue-400 text-sm">View GIF on Tenor</span></a>)
      end
    else
      # Placeholder for async path (new messages — TenorUnfurlJob resolves later)
      embeds << %(<div class="mt-2 tenor-placeholder" data-tenor-id="#{gif_id}" data-tenor-gif-id="#{gif_id}" data-tenor-url="#{tenor_url}"><a href="#{tenor_url}" target="_blank" rel="noopener" class="flex items-center gap-3 max-w-xs rounded-lg border border-gray-700 bg-gray-800 hover:bg-gray-750 transition-colors no-underline px-3 py-2.5"><div class="w-8 h-8 rounded border border-gray-600 bg-gray-700 flex items-center justify-center"><svg class="w-4 h-4 text-gray-400 animate-pulse" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/></svg></div><span class="text-blue-400 text-sm">Loading GIF...</span></a></div>)
    end
  end

# Collect TikTok video embeds
(content || "").scan(TIKTOK_REGEX).each do |video_id, short_id|
  id = video_id || short_id
  next if embeds.any? { |e| e.include?("tiktok-#{id}") }
  orig_url = video_id ? "https://www.tiktok.com/@/video/#{video_id}" : "https://vm.tiktok.com/#{short_id}"
  # Strip raw URL
  html = html.gsub(/<a[^>]*href="[^"]*tiktok[^"]*#{Regexp.escape(id)}[^"]*"[^>]*>[^<]*<\/a>/, "")
  html = html.gsub(/<p>\s*<\/p>/, "")
  if video_id
    embeds << %(<div class="mt-2 max-w-xs rounded-lg overflow-hidden border border-gray-700 bg-black relative group" style="height:500px"><iframe src="https://www.tiktok.com/player/v1/#{video_id}?music_info=0&description=0&rel=0" style="width:100%;height:100%;border:none" allow="encrypted-media" loading="lazy"></iframe><a href="#{orig_url}" target="_blank" rel="noopener" class="absolute bottom-2 left-2 opacity-0 group-hover:opacity-100 transition-opacity bg-black/60 hover:bg-black/80 text-white/80 hover:text-white rounded px-2 py-1 text-xs no-underline z-10 flex items-center gap-1"><svg class="w-3.5 h-3.5" viewBox="0 0 24 24" fill="currentColor"><path d="M19.59 6.69a4.83 4.83 0 01-3.77-4.25V2h-3.45v13.67a2.89 2.89 0 01-2.88 2.5 2.89 2.89 0 01-2.89-2.89 2.89 2.89 0 012.89-2.89c.28 0 .54.04.79.1v-3.5a6.37 6.37 0 00-.79-.05A6.34 6.34 0 003.15 15.2a6.34 6.34 0 006.34 6.34 6.34 6.34 0 006.34-6.34V8.87a8.16 8.16 0 004.76 1.52v-3.4a4.85 4.85 0 01-1-.3z"/></svg>View on TikTok</a></div>)
  else
    embeds << %(<a href="#{orig_url}" target="_blank" rel="noopener" class="mt-2 flex items-center gap-3 max-w-xs rounded-lg border border-gray-700 bg-gray-800 hover:bg-gray-750 transition-colors no-underline px-3 py-2.5 group" data-tiktok-#{id}><div class="w-10 h-10 rounded-full bg-black flex items-center justify-center shrink-0"><svg class="w-6 h-6" viewBox="0 0 24 24" fill="white"><path d="M19.59 6.69a4.83 4.83 0 01-3.77-4.25V2h-3.45v13.67a2.89 2.89 0 01-2.88 2.5 2.89 2.89 0 01-2.89-2.89 2.89 2.89 0 012.89-2.89c.28 0 .54.04.79.1v-3.5a6.37 6.37 0 00-.79-.05A6.34 6.34 0 003.15 15.2a6.34 6.34 0 006.34 6.34 6.34 6.34 0 006.34-6.34V8.87a8.16 8.16 0 004.76 1.52v-3.4a4.85 4.85 0 01-1-.3z"/></svg></div><div><div class="text-white text-sm font-semibold group-hover:underline">TikTok Video</div><div class="text-gray-400 text-xs">Click to watch on TikTok</div></div></a>)
  end
end
  # Collect Reddit embeds
  (content || "").scan(REDDIT_REGEX).each do |subreddit, post_id, slug|
    next if embeds.any? { |e| e.include?("reddit-#{post_id}") }
    slug ||= ""
    reddit_url = "https://www.reddit.com/r/#{subreddit}/comments/#{post_id}/#{slug}"
    embed_url = "https://embed.reddit.com/r/#{subreddit}/comments/#{post_id}/#{slug}?embed=true&theme=dark&showmedia=true"
    # Strip raw URL
    html = html.gsub(/<a[^>]*href="[^"]*reddit\.com\/r\/#{subreddit}\/comments\/#{post_id}[^"]*"[^>]*>[^<]*<\/a>/, "")
    html = html.gsub(/<p>\s*<\/p>/, "")
    embeds << %(<div class="mt-2 max-w-md rounded-lg overflow-hidden border border-gray-700 bg-[#1a1a1b] relative group" style="height:400px" data-reddit-#{post_id}><iframe src="#{embed_url}" style="width:100%;height:100%;border:none" scrolling="yes" loading="lazy" sandbox="allow-scripts allow-same-origin allow-popups"></iframe><a href="#{reddit_url}" target="_blank" rel="noopener" class="absolute bottom-2 left-2 opacity-0 group-hover:opacity-100 transition-opacity bg-black/60 hover:bg-black/80 text-white/80 hover:text-white rounded px-2 py-1 text-xs no-underline z-10 flex items-center gap-1"><svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24"><path d="M12 0A12 12 0 000 12a12 12 0 0012 12 12 12 0 0012-12A12 12 0 0012 0zm5.01 4.744c.688 0 1.25.561 1.25 1.249a1.25 1.25 0 01-2.498.056l-2.597-.547-.8 3.747c1.824.07 3.48.632 4.674 1.488.308-.309.73-.491 1.207-.491.968 0 1.754.786 1.754 1.754 0 .716-.435 1.333-1.01 1.614a3.111 3.111 0 01.042.52c0 2.694-3.13 4.87-7.004 4.87-3.874 0-7.004-2.176-7.004-4.87 0-.183.015-.366.043-.534A1.748 1.748 0 014.028 12c0-.968.786-1.754 1.754-1.754.463 0 .898.196 1.207.49 1.207-.883 2.878-1.43 4.744-1.487l.885-4.182a.342.342 0 01.14-.197.35.35 0 01.238-.042l2.906.617a1.214 1.214 0 011.108-.701zM9.25 12C8.561 12 8 12.562 8 13.25c0 .687.561 1.248 1.25 1.248.687 0 1.248-.561 1.248-1.249 0-.688-.561-1.249-1.249-1.249zm5.5 0c-.687 0-1.248.561-1.248 1.25 0 .687.561 1.248 1.249 1.248.688 0 1.249-.561 1.249-1.249 0-.687-.562-1.249-1.25-1.249zm-5.466 3.99a.327.327 0 00-.231.094.33.33 0 000 .463c.842.842 2.484.913 2.961.913.477 0 2.105-.056 2.961-.913a.361.361 0 00.029-.463.33.33 0 00-.464 0c-.547.533-1.684.73-2.512.73-.828 0-1.979-.196-2.512-.73a.326.326 0 00-.232-.095z"/></svg>r/#{ERB::Util.html_escape(subreddit)}</a></div>)
  end

    # Collect other URL previews (non-image, non-youtube)
  seen_urls = Set.new
  (content || "").scan(URL_REGEX).each do |url|
    next if url.match?(IMAGE_URL_REGEX)
    next if url.match?(YOUTUBE_REGEX)
    next if url.match?(MESSAGE_LINK_REGEX)
    next if url.match?(INSTAGRAM_REGEX)
    next if url.match?(DISCORD_LINK_REGEX)
    next if url.match?(VIDEO_URL_REGEX)
    next if url.match?(TIKTOK_REGEX)
    next if url.match?(TENOR_REGEX)
    next if url.match?(REDDIT_REGEX)
    next if seen_urls.include?(url)
    seen_urls << url
    domain = begin; URI.parse(url).host; rescue; url; end
    embeds << %(<div class="mt-2 border-l-4 border-gray-600 pl-3 py-1"><a href="#{ERB::Util.html_escape(url)}" target="_blank" rel="noopener" class="text-blue-400 hover:underline text-sm break-all">#{ERB::Util.html_escape(domain)}</a></div>)
  end
  html + embeds.join
end

# Extract mentioned user ids from content

  def mentioned_user_ids
    return [] if content.blank?
    server = channel&.server
    return [] unless server

    ids = []
    # @username mentions
    content.scan(/@(\w+)/).flatten.each do |username|
      user = server.members.find_by("LOWER(username) = ?", username.downcase)
      ids << user.id if user
    end
    # @everyone / @here
    ids << :everyone if content.include?("@everyone")
    ids << :here if content.include?("@here")
    ids.uniq
  end

  # Extract mentioned role names
  def mentioned_roles
    return [] if content.blank?
    server = channel&.server
    return [] unless server

    content.scan(/@(\w+)/).flatten.filter_map do |name|
      server.roles.find_by("LOWER(name) = ? OR LOWER(name) = ?", "@#{name.downcase}", name.downcase)
    end.uniq
  end

  def edited?
    edited_at.present?
  end

  private

  def has_files?
    files.attached? || files.any?
  end

  def in_shared_channel?
    channel&.shared? && !system_message? && !user&.remote?
  end

  def publish_to_nostr_group
    NostrGroupPublishJob.perform_later(id)
  end

  def fetch_tenor_og_image(tenor_url)
    fetch_uri = URI.parse(tenor_url)
    3.times do
      http = Net::HTTP.new(fetch_uri.host, fetch_uri.port)
      http.use_ssl = true
      http.open_timeout = 3
      http.read_timeout = 5
      req = Net::HTTP::Get.new(fetch_uri)
      req["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
      response = http.request(req)
      if response.is_a?(Net::HTTPRedirection)
        fetch_uri = URI.parse(response["location"])
        next
      end
      if response.body&.match(/property="og:image"\s+content="([^"]+)"/)
        return $1
      end
      break
    end
    nil
  rescue => e
    Rails.logger.warn("Tenor fetch failed: #{e.message}")
    nil
  end

  def create_mention_notifications
    return if system_message?
    server = channel&.server
    return unless server

    notified_ids = Set.new
    notified_ids << user.id # Don't notify yourself

    # @everyone / @here
    if content&.include?("@everyone")
      server.members.where.not(id: user.id).find_each do |member|
        Notification.create(user: member, server: server, channel: channel, message: self, notification_type: :everyone_mention)
        notified_ids << member.id
      end
    elsif content&.include?("@here")
      server.members.where(online_state: [:online, :idle]).where.not(id: user.id).find_each do |member|
        Notification.create(user: member, server: server, channel: channel, message: self, notification_type: :everyone_mention)
        notified_ids << member.id
      end
    end

    # @username mentions
    content&.scan(/@(\w+)/)&.flatten&.each do |username|
      member = server.members.find_by("LOWER(username) = ?", username.downcase)
      if member && !notified_ids.include?(member.id)
        Notification.create(user: member, server: server, channel: channel, message: self, notification_type: :mention)
        notified_ids << member.id
      end
    end

    # @role mentions
    content&.scan(/@(\w+)/)&.flatten&.each do |name|
      role = server.roles.find_by("LOWER(name) = ? OR LOWER(name) = ?", "@#{name.downcase}", name.downcase)
      if role
        role.server_memberships.includes(:user).each do |membership|
          unless notified_ids.include?(membership.user_id)
            Notification.create(user: membership.user, server: server, channel: channel, message: self, notification_type: :role_mention)
            notified_ids << membership.user_id
          end
        end
      end
    end

    # Broadcast notification badges to mentioned users
    notified_ids.reject { |nid| nid == user.id }.each do |uid|
      ActionCable.server.broadcast("user_notifications_#{uid}", {
        type: "mention",
        server_id: server.public_id,
        channel_id: channel.public_id,
        message_id: public_id
      })
    end
  end

  def render_custom_emojis(html)
    # Find all :emoji_name: patterns (not inside code blocks)
    emoji_names = html.scan(/:([a-z0-9_]+):/).flatten.uniq
    return html if emoji_names.empty?

    # For channel messages, use the channel's server; for DMs, use the sender's servers
    if channel&.server
      emojis = channel.server.server_emojis.where(name: emoji_names).includes(image_attachment: :blob)
    else
      emojis = ServerEmoji.where(server_id: user.servers.select(:id), name: emoji_names).includes(image_attachment: :blob)
    end
    return html if emojis.empty?

    # Deduplicate by name (first match wins)
    seen = {}
    emojis.each do |emoji|
      next unless emoji.image.attached?
      next if seen[emoji.name]
      seen[emoji.name] = true
      img_url = Rails.application.routes.url_helpers.rails_blob_path(emoji.image, only_path: true)
      img_tag = %(<img src="#{img_url}" alt=":#{emoji.name}:" title=":#{emoji.name}:" class="inline-block align-text-bottom" style="height:1.375em;width:auto" loading="lazy">)
      html = html.gsub(/:#{Regexp.escape(emoji.name)}:/, img_tag)
    end

    html
  end

  # If a message contains only emoji (Unicode or custom <img>), enlarge them
  EMOJI_REGEX = /[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F1E0}-\u{1F1FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{FE00}-\u{FE0F}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}\u{200D}\u{20E3}\u{E0020}-\u{E007F}\u{231A}-\u{231B}\u{23E9}-\u{23F3}\u{23F8}-\u{23FA}\u{25AA}-\u{25AB}\u{25B6}\u{25C0}\u{25FB}-\u{25FE}\u{2934}-\u{2935}\u{2B05}-\u{2B07}\u{2B1B}-\u{2B1C}\u{2B50}\u{2B55}\u{3030}\u{303D}\u{3297}\u{3299}]/

  def enlarge_emoji_only(html)
    # Strip wrapping <p> tags and whitespace
    stripped = html.gsub(/<\/?p>/, "").strip
    # Remove custom emoji <img> tags to check remaining text
    without_imgs = stripped.gsub(/<img[^>]*class="inline-block[^>]*>/, "")
    # Remove Unicode emojis and variation selectors
    without_emojis = without_imgs.gsub(EMOJI_REGEX, "").gsub(/[\s\uFE0F]/, "")
    # If nothing remains, it's emoji-only
    if without_emojis.empty? && stripped.length > 0
      # Count emojis (max 10 to qualify for big display)
      emoji_count = stripped.scan(EMOJI_REGEX).length + stripped.scan(/<img[^>]*class="inline-block/).length
      if emoji_count > 0 && emoji_count <= 10
        # Enlarge custom emoji images
        enlarged = stripped.gsub(/style="height:1\.375em;width:auto"/, 'style="height:3.5rem;width:auto"')
        return %(<p class="emoji-only">#{enlarged}</p>)
      end
    end
    html
  end

  def render_mentions(html)
    server = channel&.server
    return html unless server

    # Replace @everyone and @here
    html = html.gsub(/@everyone/, '<span class="mention mention-everyone">@everyone</span>')
    html = html.gsub(/@here/, '<span class="mention mention-here">@here</span>')

    # Only query members whose usernames actually appear in the content
    mentioned_names = content.scan(/@(\w+)/).flatten.map(&:downcase).uniq
    return html if mentioned_names.empty?

    # Replace @username with styled mention — only fetch matching members
    server.members.where("LOWER(username) IN (?)", mentioned_names).each do |member|
      html = html.gsub(/@#{Regexp.escape(member.username)}\b/i) do
        %(<span class="mention" data-user-id="#{member.public_id}">@#{ERB::Util.html_escape(member.username)}</span>)
      end
    end

    # Replace @rolename with styled mention — only fetch matching roles
    server.roles.where.not(name: "@everyone").where("LOWER(REPLACE(name, '@', '')) IN (?)", mentioned_names).each do |role|
      role_name = role.name.delete_prefix("@")
      html = html.gsub(/@#{Regexp.escape(role_name)}\b/i) do
        color = role.color.present? ? role.color : "#f97316"
        %(<span class="mention mention-role" style="color: #{color}">@#{ERB::Util.html_escape(role_name)}</span>)
      end
    end

    html
  end
end
